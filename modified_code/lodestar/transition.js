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
  processHistoricalRootsUpdate,
  processHistoricalSummariesUpdate,
  processParticipationRecordUpdates,
  processParticipationFlagUpdates,
  processPendingDeposits,
  processPendingConsolidations,
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
import { processDepositRequest } from "@lodestar/state-transition/block";
import { processWithdrawalRequest } from "@lodestar/state-transition/block";
import { processConsolidationRequest } from "@lodestar/state-transition/block";
const DISABLED_FORK_EPOCH = 2000000000;

const PURE_FORK_EPOCHS = {
  phase0: {
    ALTAIR_FORK_EPOCH: DISABLED_FORK_EPOCH,
    BELLATRIX_FORK_EPOCH: DISABLED_FORK_EPOCH,
    CAPELLA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    DENEB_FORK_EPOCH: DISABLED_FORK_EPOCH,
    ELECTRA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
  altair: {
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: DISABLED_FORK_EPOCH,
    CAPELLA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    DENEB_FORK_EPOCH: DISABLED_FORK_EPOCH,
    ELECTRA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
  bellatrix: {
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: 0,
    CAPELLA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    DENEB_FORK_EPOCH: DISABLED_FORK_EPOCH,
    ELECTRA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
  capella: {
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: 0,
    CAPELLA_FORK_EPOCH: 0,
    DENEB_FORK_EPOCH: DISABLED_FORK_EPOCH,
    ELECTRA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
  deneb: {
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: 0,
    CAPELLA_FORK_EPOCH: 0,
    DENEB_FORK_EPOCH: 0,
    ELECTRA_FORK_EPOCH: DISABLED_FORK_EPOCH,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
  electra: {
    ALTAIR_FORK_EPOCH: 0,
    BELLATRIX_FORK_EPOCH: 0,
    CAPELLA_FORK_EPOCH: 0,
    DENEB_FORK_EPOCH: 0,
    ELECTRA_FORK_EPOCH: 0,
    FULU_FORK_EPOCH: DISABLED_FORK_EPOCH + 1,
    GLOAS_FORK_EPOCH: DISABLED_FORK_EPOCH + 2,
  },
};

function assertSupportedFork(forkVersion) {
  if (!(forkVersion in PURE_FORK_EPOCHS)) {
    throw new Error(`Unsupported fork-version: ${forkVersion}. Supported forks: ${Object.keys(PURE_FORK_EPOCHS).join(", ")}`);
  }
}

function forkSsz(forkVersion) {
  assertSupportedFork(forkVersion);
  return ssz[forkVersion];
}

// Override config for pure network.
function getPureConfig(forkVersion = "capella") {
  assertSupportedFork(forkVersion);
  return {
    ...config.mainnet,
    ...PURE_FORK_EPOCHS[forkVersion],
  };
}

// For backward compatibility
const pureCapellaConfig = getPureConfig("capella");

function deserializeState(stateFile, forkVersion) {
  return forkSsz(forkVersion).BeaconState.deserializeToViewDU(stateFile);
}

function deserializeBeaconBlock(blockFile, forkVersion) {
  return forkSsz(forkVersion).BeaconBlock.deserialize(blockFile);
}

function defaultBeaconBlock(forkVersion) {
  return forkSsz(forkVersion).BeaconBlock.defaultValue();
}

function deserializeBeaconBlockBody(bodyFile, forkVersion) {
  return forkSsz(forkVersion).BeaconBlockBody.deserialize(bodyFile);
}

function deserializeExecutionPayload(payloadFile, forkVersion) {
  return forkSsz(forkVersion).ExecutionPayload.deserialize(payloadFile);
}

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
    console.error("Usage: node transition.js state-transition --pre-state-path=<path> --block-path=<path> --post-state-output-path=<path> [--fork-version=phase0|altair|bellatrix|capella|deneb|electra]");
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
    console.error("Usage: node transition.js operation --pre-state-path=<path> --operation-path=<path> --operation-type=<type> --post-state-output-path=<path> [--fork-version=phase0|altair|bellatrix|capella|deneb|electra] [--execution-valid=true|false]");
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
    console.error("Usage: node transition.js epoch-processing --pre-state-path=<path> --epoch-processing-type=<type> --post-state-output-path=<path> [--fork-version=phase0|altair|bellatrix|capella|deneb|electra]");
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
    console.error("Usage: node transition.js sanity-slots --pre-state-path=<path> --slot=<number> --post-state-output-path=<path> [--fork-version=phase0|altair|bellatrix|capella|deneb|electra]");
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

    const preState = deserializeState(stateFile, forkVersion);
    const stateConfig = getPureConfig(forkVersion);
    
    const cachedState = generateCachedState(preState, stateConfig);

    // Get fork sequence
    const fork = cachedState.config.getForkSeq(cachedState.slot);

    // Create external data
    const externalData = createExternalData(defaultOptions);
    const verifySignatures = defaultOptions.verifyProposer;

    // Process operation based on type
    switch (operationType) {
      case "attestation": {
        const attestationSsz = forkVersion === "electra" ? ssz.electra.Attestation : ssz.phase0.Attestation;
        const attestation = attestationSsz.deserialize(operationFile);
        processAttestations(fork, cachedState, [attestation]);
        break;
      }
      case "attester_slashing": {
        const attesterSlashingSsz = forkVersion === "electra" ? ssz.electra.AttesterSlashing : ssz.phase0.AttesterSlashing;
        const attesterSlashing = attesterSlashingSsz.deserialize(operationFile);
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
        const block = deserializeBeaconBlock(operationFile, forkVersion);
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
        const block = defaultBeaconBlock(forkVersion);
        block.slot = cachedState.slot;
        block.body.syncAggregate = ssz.altair.SyncAggregate.toViewDU(syncAggregate);
        block.parentRoot = getBlockRootAtSlot(cachedState, Math.max(block.slot, 1) - 1);
        processSyncAggregate(cachedState, block);
        break;
      }
      case "execution_payload": {
        // For execution_payload, operation file contains BeaconBlockBody
        const body = deserializeBeaconBlockBody(operationFile, forkVersion);
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
        const executionPayload = deserializeExecutionPayload(operationFile, forkVersion);
        processWithdrawals(fork, cachedState, executionPayload);
        break;
      }
      case "withdrawals": {
        const executionPayload = deserializeExecutionPayload(operationFile, forkVersion);
        processWithdrawals(fork, cachedState, executionPayload);
        break;
      }
      case "deposit_request": {
        const depositRequest = ssz.electra.DepositRequest.deserialize(operationFile);
        processDepositRequest(cachedState, depositRequest);
        break;
      }
      case "withdrawal_request": {
        const withdrawalRequest = ssz.electra.WithdrawalRequest.deserialize(operationFile);
        processWithdrawalRequest(fork, cachedState, withdrawalRequest);
        break;
      }
      case "consolidation_request": {
        const consolidationRequest = ssz.electra.ConsolidationRequest.deserialize(operationFile);
        processConsolidationRequest(cachedState, consolidationRequest);
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

    const preState = deserializeState(stateFile, forkVersion);
    const stateConfig = getPureConfig(forkVersion);
    
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
      case "historical_roots_update": {
        if (!processHistoricalRootsUpdate) {
          throw new Error("processHistoricalRootsUpdate not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processHistoricalRootsUpdate(cachedState, epochTransitionCache);
        break;
      }
      case "participation_record_updates": {
        if (!processParticipationRecordUpdates) {
          throw new Error("processParticipationRecordUpdates not available in Lodestar");
        }
        processParticipationRecordUpdates(cachedState);
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
      case "pending_deposits": {
        if (!processPendingDeposits) {
          throw new Error("processPendingDeposits not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processPendingDeposits(cachedState, epochTransitionCache);
        break;
      }
      case "pending_consolidations": {
        if (!processPendingConsolidations) {
          throw new Error("processPendingConsolidations not available in Lodestar");
        }
        const epochTransitionCache = beforeProcessEpoch(cachedState);
        processPendingConsolidations(cachedState, epochTransitionCache);
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

    const preState = deserializeState(stateFile, forkVersion);
    const stateConfig = getPureConfig(forkVersion);
    
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

    const forkTypes = forkSsz(forkVersion);
    const preState = forkTypes.BeaconState.deserializeToViewDU(beaconStateFile);
    const stateConfig = getPureConfig(forkVersion);
    
    const cachedState = generateCachedState(preState, stateConfig);
    const signedBlock = forkTypes.SignedBeaconBlock.deserialize(signedBlockData);

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
