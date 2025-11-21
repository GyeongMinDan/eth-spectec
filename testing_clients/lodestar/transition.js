import fs from "node:fs";
import { ssz } from "@lodestar/types";
import { isCachedBeaconState, stateTransition, DataAvailabilityStatus, ExecutionPayloadStatus } from "@lodestar/state-transition";
import { generateCachedState } from "./generateCachedStateCapella.js";
import * as config from "@lodestar/config";

// Override config for pure Capella network (CAPELLA_FORK_EPOCH = 0)
const pureCapellaConfig = {
  ...config.mainnet,
  ALTAIR_FORK_EPOCH: 0,
  BELLATRIX_FORK_EPOCH: 0,
  CAPELLA_FORK_EPOCH: 0,
  DENEB_FORK_EPOCH: 75520,
};

// Define default options for state transition
const defaultOptions = {
  verifyProposer: true,
  verifyStateRoot: true,
  executionPayloadStatus: ExecutionPayloadStatus.valid,
  dataAvailabilityStatus: DataAvailabilityStatus.Available,
};

// Function to parse user input
function parseInput(args) {
  if (args.length < 5) {
    console.error(
      "Usage: node transition <state-path> <block-path> <output-path> [additional-options]"
    );
    process.exit(2);
  }

  const statePath = args[2];
  const blockPath = args[3];
  const outputPath = args[4];
  const additionalOptions = args.slice(5).reduce((acc, opt) => {
    const [key, value] = opt.split("=");
    if (key && value) {
      acc[key] = value;
    }
    return acc;
  }, {});

  return {
    statePath,
    blockPath,
    outputPath,
    additionalOptions,
  };
}

// Function to update options based on user input
function updateOptions(defaultOpts, additionalOpts) {
  const updatedOptions = { ...defaultOpts };

  for (const [key, value] of Object.entries(additionalOpts)) {
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
    } else {
      console.warn(`Warning: Unknown option "${key}" is ignored.`);
    }
  }

  return updatedOptions;
}

// Parse command-line arguments
const userInput = parseInput(process.argv);
console.log(userInput)

// Update options based on user input
const options = updateOptions(defaultOptions, userInput.additionalOptions);

// Log the final options for debugging
//console.log("Final Options:", options);

try {
  // Read state and block files
  const signedBlockData = fs.readFileSync(userInput.blockPath);
  const beaconStateFile = fs.readFileSync(userInput.statePath);

  // Deserialize pre-state and block
  const preState = ssz.capella.BeaconState.deserializeToView(beaconStateFile);
  const cachedState = generateCachedState(preState);
  const signedBlock = ssz.capella.SignedBeaconBlock.deserialize(signedBlockData);

  // Perform state transition
  const postState_deserialized = stateTransition(cachedState, signedBlock, options);
  const postState = postState_deserialized.serialize()
  //const postState = postState_deserialized.serialize()

  //const buffer = Buffer.from(postState_deserialized)
  //console.log(buffer.toString('hex'))
  //console.log(postState)
  
  //const temp = buffer.toString('hex')
  fs.writeFileSync(userInput.outputPath, postState);

  // Output the process result
  const processResult = {
    statusCode: 0,
    output: "Post state successful, written to " + userInput.outputPath,
  };
  console.log(processResult);
  //process.exit(JSON.stringify(processResult))

} catch (e) {
  // Handle errors
  const errorResult = {
    statusCode: 1,
    output: e.message,
  };
  console.error(errorResult);
  //process.exit(JSON.stringify(errorResult))
}
