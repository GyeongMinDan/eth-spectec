import fs from "node:fs";
import path from "node:path";
import { ssz } from "@lodestar/types";
import { isCachedBeaconState, stateTransition, DataAvailabilityStatus, ExecutionPayloadStatus, getBlockRootAtSlot, processSlots } from "@lodestar/state-transition";
import { generateCachedState } from "./generateCachedStateCapella.js";
import * as config from "@lodestar/config";

// Lodestar 내 스펙 함수 import
// Epoch processing functions
import { beforeProcessEpoch } from "@lodestar/state-transition";
import { processJustificationAndFinalization } from "@lodestar/state-transition/epoch";
import { processInactivityUpdates } from "@lodestar/state-transition/epoch";
import { processRewardsAndPenalties } from "@lodestar/state-transition/epoch";
import { processSyncCommitteeUpdates } from "@lodestar/state-transition/epoch";
// Additional epoch processing functions
// Import from epoch module (these may need to be checked against actual Lodestar exports)
import {
  processRegistryUpdates,
  processSlashings,
  processEffectiveBalanceUpdates,
  processEth1DataReset,
  processSlashingsReset,
  processRandaoMixesReset,
  processHistoricalSummariesUpdate,
  processParticipationFlagUpdates,
} from "@lodestar/state-transition/epoch";

// Block processing functions
import { processBlockHeader } from "@lodestar/state-transition/block";
import { processWithdrawals } from "@lodestar/state-transition/block";
import { processExecutionPayload } from "@lodestar/state-transition/block";
import { processSyncAggregate } from "@lodestar/state-transition/block";
import { processProposerSlashing } from "@lodestar/state-transition/block";
import { processAttesterSlashing } from "@lodestar/state-transition/block";
import { processAttestations } from "@lodestar/state-transition/block";
import { processDeposit } from "@lodestar/state-transition/block";
import { processVoluntaryExit } from "@lodestar/state-transition/block";
import { processBlsToExecutionChange } from "@lodestar/state-transition/block";



// Override config for pure network (fork epochs = 0)
function getPureConfig(forkVersion = "capella") {
  const baseConfig = {
    ...config.mainnet,
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: 0,
    CAPELLA_FORK_EPOCH: 0,
    DENEB_FORK_EPOCH: forkVersion === "deneb" ? 0 : 75520,
  };
  return baseConfig;
}

// For backward compatibility
const pureCapellaConfig = getPureConfig("capella");

// Define default options for state transition
const defaultOptions = {
  verifyProposer: true,
  verifyStateRoot: true,
  executionPayloadStatus: ExecutionPayloadStatus.valid,
  dataAvailabilityStatus: DataAvailabilityStatus.Available,
};

// Function to parse command and arguments
function parseCommand(args) {
  if (args.length < 3) {
    console.error("Usage: node transition.js <command> [arguments...]");
    console.error("Commands: state-transition, operation, epoch-processing, sanity-slots");
    process.exit(2);
  }

  const command = args[2];
  const commandArgs = args.slice(3);

  // Parse flags (--key=value format)
  const flags = {};
  const positional = [];
  
  for (const arg of commandArgs) {
    if (arg.startsWith("--")) {
      const [key, value] = arg.slice(2).split("=");
      flags[key] = value ?? true;
    } else {
      positional.push(arg);
    }
  }

  return { command, flags, positional };
}

// Function to parse state-transition input
function parseStateTransitionInput(flags, positional) {
  // Support both flag-based and positional arguments
  const statePath = flags["pre-state-path"] || positional[0];
  const blockPath = flags["block-path"] || positional[1];
  const outputPath = flags["post-state-output-path"] || flags["expected-post-state-path"] || positional[2];
  const forkVersion = flags["fork-version"] || "capella";

  if (!statePath || !blockPath || !outputPath) {
    console.error("Usage: node transition.js state-transition --pre-state-path=<path> --block-path=<path> --post-state-output-path=<path> [--fork-version=capella|deneb]");
    process.exit(2);
  }

  return { statePath, blockPath, outputPath, forkVersion };
}

// Function to parse operation input
function parseOperationInput(flags, positional) {
  const statePath = flags["pre-state-path"] || positional[0];
  const operationPath = flags["operation-path"] || flags["operation-data"] || positional[1];
  const operationType = flags["operation-type"] || positional[2];
  const outputPath = flags["post-state-output-path"] || positional[3];
  const forkVersion = flags["fork-version"] || "capella";
  const executionValid = flags["execution-valid"] !== undefined ? flags["execution-valid"] === "true" || flags["execution-valid"] === true : null;

  if (!statePath || !operationPath || !operationType || !outputPath) {
    console.error("Usage: node transition.js operation --pre-state-path=<path> --operation-path=<path> --operation-type=<type> --post-state-output-path=<path> [--fork-version=capella|deneb] [--execution-valid=true|false]");
    process.exit(2);
  }

  return { statePath, operationPath, operationType, outputPath, forkVersion, executionValid };
}

// Function to parse epoch-processing input
function parseEpochProcessingInput(flags, positional) {
  const statePath = flags["pre-state-path"] || positional[0];
  const epochProcessingType = flags["epoch-processing-type"] || positional[1];
  const outputPath = flags["post-state-output-path"] || positional[2];
  const forkVersion = flags["fork-version"] || "capella";

  if (!statePath || !epochProcessingType || !outputPath) {
    console.error("Usage: node transition.js epoch-processing --pre-state-path=<path> --epoch-processing-type=<type> --post-state-output-path=<path> [--fork-version=capella|deneb]");
    process.exit(2);
  }

  return { statePath, epochProcessingType, outputPath, forkVersion };
}

// Function to parse sanity-slots input
function parseSanitySlotsInput(flags, positional) {
  const statePath = flags["pre-state-path"] || positional[0];
  const slotValue = flags["slot"] || positional[1];
  const outputPath = flags["post-state-output-path"] || positional[2];
  const forkVersion = flags["fork-version"] || "capella";

  if (!statePath || slotValue === undefined || !outputPath) {
    console.error("Usage: node transition.js sanity-slots --pre-state-path=<path> --slot=<number> --post-state-output-path=<path> [--fork-version=capella|deneb]");
    process.exit(2);
  }
  // radix 10 from diff_testing.py
  return { statePath, slotValue: parseInt(slotValue, 10), outputPath, forkVersion };
}

// Function to update options based on user input
function updateOptions(defaultOpts, flags) {
  const updatedOptions = { ...defaultOpts };

  for (const [key, value] of Object.entries(flags)) {
    if (key in updatedOptions) {
      // Convert string to correct data type
      if (typeof defaultOpts[key] === "boolean") {
        updatedOptions[key] = value === "true";
      } else if (key === "executionPayloadStatus") {
        updatedOptions[key] = ExecutionPayloadStatus[value] || defaultOpts[key];
      } else if (key === "dataAvailabilityStatus") {
        updatedOptions[key] = DataAvailabilityStatus[value] || defaultOpts[key];
      } else {
        updatedOptions[key] = value;
      }
    }
  }

  return updatedOptions;
}

// Create external data for Lodestar functions
function createExternalData(opts) {
  return {
    executionPayloadStatus: opts.executionPayloadStatus,
    dataAvailableStatus: opts.dataAvailabilityStatus,
  };
}

// Process operation
function processOperation(statePath, operationPath, operationType, outputPath, forkVersion = "capella", executionValid = null) {
  try {
    // Read state and operation files
    const stateFile = fs.readFileSync(statePath);
    const operationFile = fs.readFileSync(operationPath);

    // Deserialize pre-state based on fork version
    let preState;
    if (forkVersion === "deneb") {
      preState = ssz.deneb.BeaconState.deserializeToViewDU(stateFile);
    } else {
      preState = ssz.capella.BeaconState.deserializeToViewDU(stateFile);
    }
    
    // Get fork epoch from state (like official test runner)
    const forkEpoch = preState.fork.epoch;
    
    // Create config based on state's fork epoch (like official test runner)
    // Use state's fork epoch to determine correct fork boundaries
    const pureConfig = getPureConfig(forkVersion);
    const stateConfig = {
      ...pureConfig,
      // If state's fork epoch is 0, all forks are at epoch 0
      // Otherwise, use state's fork epoch
      CAPELLA_FORK_EPOCH: forkEpoch,
      BELLATRIX_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      ALTAIR_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      DENEB_FORK_EPOCH: forkVersion === "deneb" ? (forkEpoch > 0 ? forkEpoch : 0) : pureConfig.DENEB_FORK_EPOCH,
    };
    
    const cachedState = generateCachedState(preState, stateConfig);

    // Get fork sequence
    const fork = cachedState.config.getForkSeq(cachedState.slot);

    // Create external data
    const externalData = createExternalData(defaultOptions);
    const verifySignatures = defaultOptions.verifyProposer;

    // Process operation based on type
    switch (operationType) {
      case "attestation": {
        const attestation = ssz.phase0.Attestation.deserialize(operationFile);
        processAttestations(fork, cachedState, [attestation]);
        break;
      }
      case "attester_slashing": {
        const attesterSlashing = ssz.phase0.AttesterSlashing.deserialize(operationFile);
        processAttesterSlashing(fork, cachedState, attesterSlashing, verifySignatures);
        break;
      }
      case "proposer_slashing": {
        const proposerSlashing = ssz.phase0.ProposerSlashing.deserialize(operationFile);
        processProposerSlashing(fork, cachedState, proposerSlashing);
        break;
      }
      case "block_header": {
        // For block_header, the operation file contains a BeaconBlock
        let block;
        if (forkVersion === "deneb") {
          block = ssz.deneb.BeaconBlock.deserialize(operationFile);
        } else {
          block = ssz.capella.BeaconBlock.deserialize(operationFile);
        }
        processBlockHeader(cachedState, block);
        break;
      }
      case "deposit": {
        const deposit = ssz.phase0.Deposit.deserialize(operationFile);
        processDeposit(fork, cachedState, deposit);
        break;
      }
      case "voluntary_exit": {
        const voluntaryExit = ssz.phase0.SignedVoluntaryExit.deserialize(operationFile);
        processVoluntaryExit(fork, cachedState, voluntaryExit);
        break;
      }
      case "sync_aggregate": {
        // For sync_aggregate, we need to create a minimal block with sync aggregate
        // Following official test runner pattern
        const syncAggregate = ssz.altair.SyncAggregate.deserialize(operationFile);
        let block;
        if (forkVersion === "deneb") {
          block = ssz.deneb.BeaconBlock.defaultValue();
        } else {
          block = ssz.capella.BeaconBlock.defaultValue();
        }
        block.slot = cachedState.slot;
        block.body.syncAggregate = ssz.altair.SyncAggregate.toViewDU(syncAggregate);
        block.parentRoot = getBlockRootAtSlot(cachedState, Math.max(block.slot, 1) - 1);
        processSyncAggregate(cachedState, block);
        break;
      }
      case "execution_payload": {
        // For execution_payload, operation file contains BeaconBlockBody
        let body;
        if (forkVersion === "deneb") {
          body = ssz.deneb.BeaconBlockBody.deserialize(operationFile);
        } else {
          body = ssz.capella.BeaconBlockBody.deserialize(operationFile);
        }
        // Use execution_valid from execution.yaml if provided, otherwise default to valid
        const executionPayloadStatus = (executionValid !== null && executionValid !== undefined)
          ? (executionValid ? ExecutionPayloadStatus.valid : ExecutionPayloadStatus.invalid)
          : ExecutionPayloadStatus.valid;
        // processExecutionPayload only needs executionPayloadStatus, not dataAvailabilityStatus
        processExecutionPayload(fork, cachedState, body, {
          executionPayloadStatus: executionPayloadStatus,
        });
        break;
      }
      case "bls_to_execution_change": {
        const blsChange = ssz.capella.SignedBLSToExecutionChange.deserialize(operationFile);
        processBlsToExecutionChange(cachedState, blsChange);
        break;
      }
      case "withdrawal": {
        // For withdrawal, operation file contains ExecutionPayload
        let executionPayload;
        if (forkVersion === "deneb") {
          executionPayload = ssz.deneb.ExecutionPayload.deserialize(operationFile);
        } else {
          executionPayload = ssz.capella.ExecutionPayload.deserialize(operationFile);
        }
        processWithdrawals(fork, cachedState, executionPayload);
        break;
      }
      default:
        throw new Error(`Unknown operation type: ${operationType}`);
    }

    // Serialize and save post-state
    const postStateBytes = cachedState.serialize();
    fs.writeFileSync(outputPath, postStateBytes);

    const result = {
      statusCode: 0,
      output: `Operation ${operationType} processed successfully, post-state written to ${outputPath}`,
    };
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    let errorMessage = e.message;
    if (e.stack) {
      errorMessage += "\n\nStack trace:\n" + e.stack;
    }
    
    const errorResult = {
      statusCode: 1,
      output: errorMessage,
    };
    console.error(JSON.stringify(errorResult, null, 2));
    process.exit(1);
  }
}

// Process epoch-processing
function processEpochProcessing(statePath, epochProcessingType, outputPath, forkVersion = "capella") {
  try {
    // Read state file
    const stateFile = fs.readFileSync(statePath);

    // Deserialize pre-state based on fork version
    let preState;
    if (forkVersion === "deneb") {
      preState = ssz.deneb.BeaconState.deserializeToViewDU(stateFile);
    } else {
      preState = ssz.capella.BeaconState.deserializeToViewDU(stateFile);
    }
    
    // Get fork epoch from state (like official test runner)
    const forkEpoch = preState.fork.epoch;
    
    // Create config based on state's fork epoch (like official test runner)
    const pureConfig = getPureConfig(forkVersion);
    const stateConfig = {
      ...pureConfig,
      CAPELLA_FORK_EPOCH: forkEpoch,
      BELLATRIX_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      ALTAIR_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      DENEB_FORK_EPOCH: forkVersion === "deneb" ? (forkEpoch > 0 ? forkEpoch : 0) : pureConfig.DENEB_FORK_EPOCH,
    };
    
    const cachedState = generateCachedState(preState, stateConfig);

    // Get fork sequence
    const fork = cachedState.config.getForkSeq(cachedState.slot);

    // Process epoch operation based on type
    switch (epochProcessingType) {
      case "justification_and_finalization": {
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processJustificationAndFinalization(cachedState, epochTransitionCache);
        break;
      }
      case "inactivity_updates": {
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processInactivityUpdates(cachedState, epochTransitionCache);
        break;
      }
      case "rewards_and_penalties": {
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processRewardsAndPenalties(cachedState, epochTransitionCache);
        break;
      }
      case "registry_updates": {
        if (!processRegistryUpdates) {
          throw new Error("processRegistryUpdates not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processRegistryUpdates(fork, cachedState, epochTransitionCache);
        break;
      }
      case "slashings": {
        if (!processSlashings) {
          throw new Error("processSlashings not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processSlashings(cachedState, epochTransitionCache);
        break;
      }
      case "eth1_data_reset": {
        if (!processEth1DataReset) {
          throw new Error("processEth1DataReset not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processEth1DataReset(cachedState, epochTransitionCache);
        break;
      }
      case "effective_balance_updates": {
        if (!processEffectiveBalanceUpdates) {
          throw new Error("processEffectiveBalanceUpdates not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processEffectiveBalanceUpdates(fork, cachedState, epochTransitionCache);
        break;
      }
      case "slashings_reset": {
        if (!processSlashingsReset) {
          throw new Error("processSlashingsReset not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processSlashingsReset(cachedState, epochTransitionCache);
        break;
      }
      case "randao_mixes_reset": {
        if (!processRandaoMixesReset) {
          throw new Error("processRandaoMixesReset not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processRandaoMixesReset(cachedState, epochTransitionCache);
        break;
      }
      case "historical_summaries_update": {
        if (!processHistoricalSummariesUpdate) {
          throw new Error("processHistoricalSummariesUpdate not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processHistoricalSummariesUpdate(cachedState, epochTransitionCache);
        break;
      }
      case "participation_flag_updates": {
        if (!processParticipationFlagUpdates) {
          throw new Error("processParticipationFlagUpdates not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processParticipationFlagUpdates(cachedState, epochTransitionCache);
        break;
      }
      case "sync_committee_updates": {
        processSyncCommitteeUpdates(fork, cachedState);
        break;
      }
      default:
        throw new Error(`Unknown epoch processing type: ${epochProcessingType}`);
    }

    // Serialize and save post-state
    const postStateBytes = cachedState.serialize();
    fs.writeFileSync(outputPath, postStateBytes);

    const result = {
      statusCode: 0,
      output: `Epoch processing ${epochProcessingType} completed successfully, post-state written to ${outputPath}`,
    };
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    let errorMessage = e.message;
    if (e.stack) {
      errorMessage += "\n\nStack trace:\n" + e.stack;
    }
    
    const errorResult = {
      statusCode: 1,
      output: errorMessage,
    };
    console.error(JSON.stringify(errorResult, null, 2));
    process.exit(1);
  }
}

// Process sanity-slots (matches official test runner)
function processSanitySlots(statePath, slotValue, outputPath, forkVersion = "capella") {
  try {
    // Read state file
    const stateFile = fs.readFileSync(statePath);

    // Deserialize pre-state based on fork version
    let preState;
    if (forkVersion === "deneb") {
      preState = ssz.deneb.BeaconState.deserializeToViewDU(stateFile);
    } else {
      preState = ssz.capella.BeaconState.deserializeToViewDU(stateFile);
    }
    
    // Get fork epoch from state (like official test runner)
    const forkEpoch = preState.fork.epoch;
    
    // Create config based on state's fork epoch (like official test runner)
    const pureConfig = getPureConfig(forkVersion);
    const stateConfig = {
      ...pureConfig,
      CAPELLA_FORK_EPOCH: forkEpoch,
      BELLATRIX_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      ALTAIR_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      DENEB_FORK_EPOCH: forkVersion === "deneb" ? (forkEpoch > 0 ? forkEpoch : 0) : pureConfig.DENEB_FORK_EPOCH,
    };
    
    // Create cached state (same as official test runner: createCachedBeaconStateTest)
    const cachedState = generateCachedState(preState, stateConfig);

    // Process slots (same as official test runner: processSlots(state, state.slot + bnToNum(testcase.slots), {assertCorrectProgressiveBalances}))
    const targetSlot = cachedState.slot + slotValue;
    const postState = processSlots(cachedState, targetSlot, {
      // assertCorrectProgressiveBalances is not exported, so we skip it
    });
    
    // Commit state (same as official test runner: postState.commit())
    postState.commit();

    // Serialize and save post-state
    const postStateBytes = postState.serialize();
    fs.writeFileSync(outputPath, postStateBytes);

    const result = {
      statusCode: 0,
      output: `Sanity slots processed successfully, post-state written to ${outputPath}`,
    };
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    let errorMessage = e.message;
    if (e.stack) {
      errorMessage += "\n\nStack trace:\n" + e.stack;
    }
    
    const errorResult = {
      statusCode: 1,
      output: errorMessage,
    };
    console.error(JSON.stringify(errorResult, null, 2));
    process.exit(1);
  }
}

// Main execution
const { command, flags, positional } = parseCommand(process.argv);

if (command === "state-transition") {
  const { statePath, blockPath, outputPath, forkVersion } = parseStateTransitionInput(flags, positional);
  const options = updateOptions(defaultOptions, flags);

  try {
    // Read state and block files
    const signedBlockData = fs.readFileSync(blockPath);
    const beaconStateFile = fs.readFileSync(statePath);

    // Deserialize pre-state based on fork version
    let preState;
    if (forkVersion === "deneb") {
      preState = ssz.deneb.BeaconState.deserializeToViewDU(beaconStateFile);
    } else {
      preState = ssz.capella.BeaconState.deserializeToViewDU(beaconStateFile);
    }
    
    // Get fork epoch from state (like official test runner)
    const forkEpoch = preState.fork.epoch;
    
    // Create config based on state's fork epoch (like official test runner)
    const pureConfig = getPureConfig(forkVersion);
    const stateConfig = {
      ...pureConfig,
      CAPELLA_FORK_EPOCH: forkEpoch,
      BELLATRIX_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      ALTAIR_FORK_EPOCH: forkEpoch > 0 ? forkEpoch : 0,
      DENEB_FORK_EPOCH: forkVersion === "deneb" ? (forkEpoch > 0 ? forkEpoch : 0) : pureConfig.DENEB_FORK_EPOCH,
    };
    
    const cachedState = generateCachedState(preState, stateConfig);
    let signedBlock;
    if (forkVersion === "deneb") {
      signedBlock = ssz.deneb.SignedBeaconBlock.deserialize(signedBlockData);
    } else {
      signedBlock = ssz.capella.SignedBeaconBlock.deserialize(signedBlockData);
    }

    // Perform state transition
    const postState_deserialized = stateTransition(cachedState, signedBlock, options);
    const postState = postState_deserialized.serialize();

    fs.writeFileSync(outputPath, postState);

    // Output the process result
    const processResult = {
      statusCode: 0,
      output: "Post state successful, written to " + outputPath,
    };
    console.log(JSON.stringify(processResult, null, 2));

  } catch (e) {
    // Handle errors
    let errorMessage = e.message;
    if (e.stack) {
      errorMessage += "\n\nStack trace:\n" + e.stack;
    }
    
    const errorResult = {
      statusCode: 1,
      output: errorMessage,
    };
    console.error(JSON.stringify(errorResult, null, 2));
    process.exit(1);
  }
} else if (command === "operation") {
  const { statePath, operationPath, operationType, outputPath, forkVersion, executionValid } = parseOperationInput(flags, positional);
  processOperation(statePath, operationPath, operationType, outputPath, forkVersion, executionValid);
} else if (command === "epoch-processing") {
  const { statePath, epochProcessingType, outputPath, forkVersion } = parseEpochProcessingInput(flags, positional);
  processEpochProcessing(statePath, epochProcessingType, outputPath, forkVersion);
} else if (command === "sanity-slots") {
  const { statePath, slotValue, outputPath, forkVersion } = parseSanitySlotsInput(flags, positional);
  processSanitySlots(statePath, slotValue, outputPath, forkVersion);
} else {
  console.error(`Unknown command: ${command}`);
  console.error("Available commands: state-transition, operation, epoch-processing, sanity-slots");
  process.exit(2);
}
