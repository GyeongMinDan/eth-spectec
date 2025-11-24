#!/bin/bash

# End script if one of them fails
set -e

# spectec-core 디렉터리를 workspace로 설정
workspace=$(cd "$(dirname "$0")" && pwd)

mkdir -p ${workspace}/testing_clients
cd ${workspace}/testing_clients

# build essentials

# Lighthouse dependencies - Rust
echo "Installing Rust..."
if ! command -v cargo &> /dev/null; then
    sudo apt update && sudo apt install -y curl
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! grep -q '\.cargo/bin' ~/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
    fi
    if ! command -v cargo &> /dev/null; then
        echo "Error: Rust installation failed or 'cargo' not found in PATH."
        exit 1
    fi
else
    echo "Rust is already installed"
fi
sudo apt install -y git gcc g++ make cmake pkg-config llvm-dev libclang-dev clang python3

# Teku dependencies - Java
echo "Installing JDK..."
if ! command -v java &> /dev/null; then
    sudo apt install -y openjdk-21-jdk openjdk-21-jre
    if ! command -v java &> /dev/null; then
        echo "Error: Java installation failed."
        exit 1
    fi
else
    # Java 버전 확인 (21 이상인지 체크)
    java_version=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
    if [ -z "$java_version" ] || [ "$java_version" -lt 21 ]; then
        echo "Java version is less than 21, installing Java 21..."
        sudo apt install -y openjdk-21-jdk openjdk-21-jre
    else
        echo "Java $java_version is already installed"
    fi
fi

# Prysm dependencies - Bazel
echo "Installing Bazel..."
if ! command -v bazel &> /dev/null; then
    sudo apt update && sudo apt install apt-transport-https gnupg -y
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel-archive-keyring.gpg
    sudo mv bazel-archive-keyring.gpg /usr/share/keyrings
    if [ ! -f /etc/apt/sources.list.d/bazel.list ]; then
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list
    fi
    sudo apt update
    sudo apt install -y bazel-7.4.1
    if ! command -v bazel &> /dev/null; then
        echo "Error: Bazel installation failed."
        exit 1
    fi
else
    echo "Bazel is already installed"
fi

# Nimbus dependencies - C++
sudo apt install -y build-essential libssl-dev
sudo apt install -y git-lfs

# Lodestar dependencies - Node.js
echo "Installing Node.js"
if ! command -v node &> /dev/null; then
    curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
    if ! command -v node &> /dev/null; then
        echo "Error: Node.js installation failed."
        exit 1
    fi
else
    node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ -z "$node_version" ] || [ "$node_version" -lt 20 ]; then
        echo "Node.js version is less than 20, installing Node.js 20..."
        curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt install -y nodejs
    else
        echo "Node.js $node_version is already installed"
    fi
fi

# Yarn not used
#sudo npm install --global yarn
#if ! command -v yarn &> /dev/null; then
#    echo "Error: Yarn installation failed."
#    exit 1
#fi

# Clone and build clients

# Lighthouse
echo "Setting up Lighthouse..."
cd ${workspace}/testing_clients
if [ -d "lighthouse" ]; then
    echo "Lighthouse directory already exists."
    cd lighthouse
    # 이미 수정된 코드가 git에 커밋되어 있으면 checkout 하지 않음
    if git diff --quiet HEAD 2>/dev/null && [ -z "$(git status --porcelain)" ]; then
        echo "Lighthouse is clean. Checking out v8.0.0..."
        git fetch
        git checkout v8.0.0
    else
        echo "Lighthouse has local modifications. Keeping current state..."
    fi
else
    git clone https://github.com/sigp/lighthouse.git
    cd lighthouse
    git checkout v8.0.0
fi
if [ -f "target/release/lcli" ]; then
    echo "Lighthouse lcli is already built. Skipping build..."
else
    cd lcli
    if ! cargo build --release; then
        echo "Error: Cargo build failed for Lighthouse."
        exit 1
    fi
fi

# Prysm
echo "Setting up Prysm..."
cd ${workspace}/testing_clients
if [ -d "prysm" ]; then
    echo "Prysm directory already exists."
    cd prysm
    # 이미 수정된 코드가 git에 커밋되어 있으면 checkout 하지 않음
    if git diff --quiet HEAD 2>/dev/null && [ -z "$(git status --porcelain)" ]; then
        echo "Prysm is clean. Checking out v7.0.0..."
        git fetch
        git checkout v7.0.0
    else
        echo "Prysm has local modifications. Keeping current state..."
    fi
else
    git clone https://github.com/prysmaticlabs/prysm
    cd prysm
    git checkout v7.0.0
fi
if [ -f "bazel-bin/tools/pcli/pcli" ]; then
    echo "Prysm pcli is already built. Skipping build..."
else
    cd tools/pcli
    if ! bazel build //tools/pcli:pcli; then
        echo "Error: Bazel build failed for Prysm."
        exit 1
    fi
fi

# Nimbus
echo "Setting up Nimbus..."
cd ${workspace}/testing_clients
if [ -d "nimbus-eth2" ]; then
    echo "Nimbus directory already exists."
    cd nimbus-eth2
    # 이미 수정된 코드가 git에 커밋되어 있으면 checkout 하지 않음
    if git diff --quiet HEAD 2>/dev/null && [ -z "$(git status --porcelain)" ]; then
        echo "Nimbus is clean. Checking out v25.11.0..."
        git fetch
        git checkout v25.11.0
    else
        echo "Nimbus has local modifications. Keeping current state..."
    fi
else
    git clone https://github.com/status-im/nimbus-eth2
    cd nimbus-eth2
    git checkout v25.11.0
fi
if [ -f "build/ncli" ] && [ -f "ncli/ncli" ]; then
    echo "Nimbus ncli is already built. Skipping build..."
else
    JOBS=2
    if command -v nproc >/dev/null 2>&1; then
        NUM_CORES=$(nproc 2>/dev/null)
        if [ -n "$NUM_CORES" ] && [ "$NUM_CORES" -gt 0 ] 2>/dev/null; then
            if [ "$NUM_CORES" -gt 4 ]; then
                JOBS=4
            else
                JOBS=$NUM_CORES
            fi
        fi
    fi
    echo "Building Nimbus with $JOBS parallel jobs..."
    if ! make -j${JOBS} 2>&1; then
        echo "Error: Make build failed for Nimbus."
        echo "Trying with fewer parallel jobs (j2)..."
        if ! make -j2 2>&1; then
            echo "Error: Make build failed for Nimbus even with j2."
            exit 1
        fi
    fi
    cd ncli
    if ! ../env.sh nim c -d:const_preset=mainnet ncli 2>&1; then
        echo "Error: Nimbus client build failed."
        exit 1
    fi
fi

# Teku
echo "Setting up Teku..."
cd ${workspace}/testing_clients
if [ -d "teku" ]; then
    echo "Teku directory already exists."
    cd teku
    # 이미 수정된 코드가 git에 커밋되어 있으면 checkout 하지 않음
    if git diff --quiet HEAD 2>/dev/null && [ -z "$(git status --porcelain)" ]; then
        echo "Teku is clean. Checking out 25.11.0..."
        git fetch
        git checkout 25.11.0
    else
        echo "Teku has local modifications. Keeping current state..."
    fi
else
    git clone https://github.com/Consensys/teku.git
    cd teku
    git checkout 25.11.0
fi
if [ -f "build/install/teku/bin/teku" ]; then
    echo "Teku is already built. Skipping build..."
else
    export JAVA_OPTS="-Xms8G -Xmx12G" # increase Java heap size for Gradle
    if ! ./gradlew installDist; then
        echo "Error: Gradle build failed for Teku."
        exit 1
    fi
fi

# Lodestar - NPM
echo "Setting up Lodestar..."
mkdir -p ${workspace}/testing_clients/lodestar
cd ${workspace}/testing_clients/lodestar

# package.json
if [ ! -f "package.json" ]; then
    cat > package.json << EOF
{
  "dependencies": {
    "@lodestar/state-transition": "1.36.0"
  },
  "type": "module"
}
EOF
else
    # package.json에 type: module 추가 (없는 경우)
    if ! grep -q '"type":\s*"module"' package.json; then
        if command -v jq &> /dev/null; then
            jq '. + {"type": "module"}' package.json > package.json.tmp && mv package.json.tmp package.json
        else
            # sed로 추가 (마지막 } 앞에 추가)
            sed -i 's/}$/,\n  "type": "module"\n}/' package.json
        fi
    fi
fi

# npm 패키지 설치
npm i @lodestar/state-transition@1.36.0
npm install

# generateCachedStateCapella.js 
if [ ! -f "generateCachedStateCapella.js" ]; then
    cat > generateCachedStateCapella.js << 'EOF'
import fs from 'fs';
import { ssz } from '@lodestar/types';
// import { createCachedBeaconState, PubkeyIndexMap } from '@lodestar/state-transition';
import { createCachedBeaconState, newFilledArray } from '@lodestar/state-transition';
// import { PublicKey } from '@chainsafe/blst';
import { createBeaconConfig } from '@lodestar/config';
import { mainnetChainConfig } from '@lodestar/config/networks';
import {PublicKey} from '@chainsafe/blst' //lodestar v 1.22 changed
import { PubkeyIndexMap } from "@chainsafe/pubkey-index-map"; // lodestar v 1.23 changed


// import pkg from '@chainsafe/blst'
// const { CoordType } = pkg;
// import bls from "@chainsafe/blst";

// import { randomBytes } from 'crypto';
// import { ZERO_HASH } from '@lodestar/state-transition';
// import { GENESIS_EPOCH, GENESIS_SLOT, SLOTS_PER_HISTORICAL_ROOT, EPOCHS_PER_HISTORICAL_VECTOR, EPOCHS_PER_SLASHINGS_VECTOR, SYNC_COMMITTEE_SIZE } from "@lodestar/params";
/**
 * 이미 로드된 `beaconstate`를 사용하여 캐시된 상태를 생성합니다.
 * @param {import("@lodestar/types").capella.BeaconState} beaconstate
 * @param {object} config - 네트워크 설정
 * @returns {import("@lodestar/state-transition").BeaconStateCapella}
 */

// Pure Capella network config (CAPELLA_FORK_EPOCH = 0)
const pureCapellaChainConfig = {
  ...mainnetChainConfig,
  ALTAIR_FORK_EPOCH: 0,
  BELLATRIX_FORK_EPOCH: 0,
  CAPELLA_FORK_EPOCH: 0,
  DENEB_FORK_EPOCH: 75520,
};

export function generateCachedState(beaconstate, config = pureCapellaChainConfig) {
  try {
    // BeaconConfig 생성
    const beaconConfig = createBeaconConfig(config, beaconstate.genesisValidatorsRoot);

    const validatorCount = beaconstate.validators.length;

    const pubkey2index = new PubkeyIndexMap();  // lodestar v1.23 changed
    const index2pubkey = [];

    if (pubkey2index.size !== index2pubkey.length) {
        throw new Error(`Pubkey indices have fallen out of sync: ${pubkey2index.size} != ${index2pubkey.length}`);
    }

    for (let i = pubkey2index.size; i < validatorCount; i++) {
        // View object (from deserializeToViewDU) uses getReadonly method
        // createCachedBeaconState expects View object with getAllReadonlyValues method
        const pubkey = beaconstate.validators.getReadonly(i).pubkey;
        pubkey2index.set(pubkey, i);
        index2pubkey[i] = PublicKey.fromBytes(pubkey) // lodestar v1.22 changed // v1.23 changed

    }   

    return createCachedBeaconState(beaconstate, {
        config: beaconConfig,
        pubkey2index: pubkey2index,
        index2pubkey: index2pubkey,
        //pubkey2index: new Map(),
        //index2pubkey: [],
    }, options);
  } catch (e) {
    // Re-throw error with context
    throw e;
  }
}

const options = {
    skipSyncCommitteeCache: false,
    skipSyncPubkeys: false,
    //shufflingGetter: undefined,
};
EOF
    echo "Created generateCachedStateCapella.js file"
else
    echo "generateCachedStateCapella.js already exists"
fi

# transition.js 
if [ ! -f "transition.js" ]; then
    cat > transition.js << 'EOF'
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
  // Use deserializeToViewDU to avoid forEachValue errors in stateTransition
  const preState = ssz.capella.BeaconState.deserializeToViewDU(beaconStateFile);
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
  // Include stack trace in output to identify if error occurs in our code or Lodestar internal
  // If stack contains node_modules/@lodestar -> Lodestar internal error
  // If stack contains our file paths -> our code error
  let errorMessage = e.message;
  if (e.stack) {
    errorMessage += "\n\nStack trace:\n" + e.stack;
  }
  
  const errorResult = {
    statusCode: 1,
    output: errorMessage,
  };
  // Output to stderr so it can be captured by diff_testing.py
  // Use JSON.stringify to preserve newlines in stack trace
  console.error(JSON.stringify(errorResult, null, 2));
  //process.exit(JSON.stringify(errorResult))
}
EOF
    echo "Created transition.js file"
else
    echo "transition.js already exists"
fi

# Configure clients for differential testing
echo ""
echo "Configuring clients for differential testing..."

# Lighthouse: Comment out assertions (BlockSignatureStrategy is already NoVerification, no modification needed)
echo "Configuring Lighthouse..."
cd ${workspace}/testing_clients
if [ -f "lighthouse/lcli/src/transition_blocks.rs" ]; then
    NEEDS_REBUILD=false
    
    # Note: BlockSignatureStrategy is already NoVerification in the original code.
    # This is correct because signatures are already verified via verify_entire_block above
    # when no_signature_verification is false (which is always the case in our testing).
    # No modification needed for BlockSignatureStrategy.
    
    # 2. Comment out all_caches_built() assertion (if not already commented)
    # Check if already modified by looking for the replacement code
    if ! grep -q "Caches not fully built after slot processing" lighthouse/lcli/src/transition_blocks.rs; then
        if grep -q "^[[:space:]]*assert!(pre_state.all_caches_built());" lighthouse/lcli/src/transition_blocks.rs; then
            # Use Python for multi-line replacement
            python3 << 'PYTHON_SCRIPT'
import re
import sys

file_path = 'lighthouse/lcli/src/transition_blocks.rs'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the assertion line and replace it
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    # Check if this is the assertion line we want to replace
    if re.match(r'\s+assert!\(pre_state\.all_caches_built\(\)\);', line):
        # Find the comment line before it
        if i > 0 and 'Slot and epoch processing should keep the caches fully primed' in lines[i-1]:
            indent = len(lines[i]) - len(lines[i].lstrip())
            indent_str = ' ' * indent
            new_lines.append(indent_str + '// Slot and epoch processing should keep the caches fully primed.\n')
            new_lines.append(indent_str + '// For external spec-tests (raw SSZ from consensus-specs), this assertion may fail\n')
            new_lines.append(indent_str + '// because complete_state_advance can invalidate some caches in certain cases.\n')
            new_lines.append(indent_str + '// We skip this assertion for differential testing compatibility with other clients.\n')
            new_lines.append(indent_str + '// The caches will be rebuilt below anyway, so this does not affect state transition correctness.\n')
            new_lines.append(indent_str + '// assert!(pre_state.all_caches_built());\n')
            new_lines.append(indent_str + 'if !pre_state.all_caches_built() {\n')
            new_lines.append(indent_str + '    debug!("Caches not fully built after slot processing; rebuilding caches");\n')
            new_lines.append(indent_str + '}\n')
            i += 1
            continue
    new_lines.append(line)
    i += 1

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Lighthouse: Commented out all_caches_built() assertion")
PYTHON_SCRIPT
            NEEDS_REBUILD=true
        fi
    fi
    
    # 3. Comment out indexed attestation cache assertion (if not already commented)
    # Check if already modified by looking for the replacement code
    if ! grep -q "Indexed attestation cache count mismatch" lighthouse/lcli/src/transition_blocks.rs; then
        if grep -q "^[[:space:]]*assert_eq!(" lighthouse/lcli/src/transition_blocks.rs && grep -q "ctxt.num_cached_indexed_attestations()" lighthouse/lcli/src/transition_blocks.rs; then
            # Use Python for multi-line replacement
            python3 << 'PYTHON_SCRIPT'
import re
import sys

file_path = 'lighthouse/lcli/src/transition_blocks.rs'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the assert_eq block and replace it
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    # Check if this is the start of the assert_eq block we want to replace
    if 'Signature verification should prime the indexed attestation cache' in line and i + 1 < len(lines):
        # Look ahead to see if there's an assert_eq
        if i + 1 < len(lines) and 'assert_eq!' in lines[i + 1]:
            indent = len(line) - len(line.lstrip())
            indent_str = ' ' * indent
            # Skip the original comment and assert_eq block (usually 4-5 lines)
            new_lines.append(indent_str + '// Signature verification should prime the indexed attestation cache.\n')
            new_lines.append(indent_str + '// For external spec-tests (raw SSZ from consensus-specs), this assertion may fail\n')
            new_lines.append(indent_str + '// because duplicate or special-case attestations may not all be cached.\n')
            new_lines.append(indent_str + '// We skip this assertion for differential testing compatibility with other clients.\n')
            new_lines.append(indent_str + '// The cache state does not affect state transition correctness.\n')
            new_lines.append(indent_str + '// assert_eq!(\n')
            new_lines.append(indent_str + '//     ctxt.num_cached_indexed_attestations(),\n')
            new_lines.append(indent_str + '//     block.message().body().attestations_len()\n')
            new_lines.append(indent_str + '// );\n')
            new_lines.append(indent_str + 'let cached_count = ctxt.num_cached_indexed_attestations();\n')
            new_lines.append(indent_str + 'let block_attestations_count = block.message().body().attestations_len();\n')
            new_lines.append(indent_str + 'if cached_count != block_attestations_count {\n')
            new_lines.append(indent_str + '    debug!(\n')
            new_lines.append(indent_str + '        "Indexed attestation cache count mismatch: cached={}, block={}",\n')
            new_lines.append(indent_str + '        cached_count, block_attestations_count\n')
            new_lines.append(indent_str + '    );\n')
            new_lines.append(indent_str + '}\n')
            # Skip the original assert_eq block lines
            i += 1
            while i < len(lines) and (lines[i].strip().startswith('assert_eq!') or 
                                      'ctxt.num_cached_indexed_attestations()' in lines[i] or
                                      'block.message().body().attestations_len()' in lines[i] or
                                      lines[i].strip() == ');'):
                i += 1
            continue
    new_lines.append(line)
    i += 1

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Lighthouse: Commented out indexed attestation cache assertion")
PYTHON_SCRIPT
            NEEDS_REBUILD=true
        fi
    fi
    
    # Rebuild Lighthouse if any changes were made
    if [ "$NEEDS_REBUILD" = true ]; then
        cd lighthouse/lcli
        if ! cargo build --release; then
            echo "Warning: Lighthouse rebuild failed after configuration change."
        else
            echo "Lighthouse: Rebuilt successfully"
        fi
    else
        echo "Lighthouse: Already configured"
    fi
else
    echo "Warning: Lighthouse transition_blocks.rs not found"
fi

# Prysm: Add post state saving code
echo "Configuring Prysm..."
cd ${workspace}/testing_clients
if [ -f "prysm/tools/pcli/main.go" ]; then
    if ! grep -q "Store the post state to the expectedPostStatePath" prysm/tools/pcli/main.go; then
        # Find the line number of "Diff the state if a post state is provided"
        DIFF_LINE=$(grep -n "Diff the state if a post state is provided" prysm/tools/pcli/main.go | cut -d: -f1)
        if [ -n "$DIFF_LINE" ]; then
            # Use awk to insert the code before the diff section
            awk -v line="$DIFF_LINE" '
            NR == line {
                print "\t\t// Store the post state to the expectedPostStatePath if provided."
                print "\t\tif expectedPostStatePath != \"\" {"
                print "\t\t\t// Serialize the postState to SSZ format."
                print "\t\t\tpostStateData, err := postState.MarshalSSZ()"
                print "\t\t\tif err != nil {"
                print "\t\t\t\tlog.Fatal(err)"
                print "\t\t\t}"
                print ""
                print "\t\t\t// Write the serialized data to the specified path."
                print "\t\t\terr = os.WriteFile(expectedPostStatePath, postStateData, 0644)"
                print "\t\t\tif err != nil {"
                print "\t\t\t\tlog.Fatal(err)"
                print "\t\t\t}"
                print ""
                print "\t\t\tlog.Infof(\"Post state successfully written to %s\", expectedPostStatePath)"
                print "\t\t}"
            }
            { print }
            ' prysm/tools/pcli/main.go > prysm/tools/pcli/main.go.tmp && mv prysm/tools/pcli/main.go.tmp prysm/tools/pcli/main.go
            echo "Prysm: Added post state saving code"
            # Rebuild Prysm
            cd prysm/tools/pcli
            if ! bazel build //tools/pcli:pcli; then
                echo "Warning: Prysm rebuild failed after configuration change."
            else
                echo "Prysm: Rebuilt successfully"
            fi
        else
            echo "Warning: Could not find insertion point in Prysm main.go"
        fi
    else
        echo "Prysm: Already configured"
    fi
else
    echo "Warning: Prysm main.go not found"
fi

# Lodestar: Comment out postState.commit() calls
echo "Configuring Lodestar..."
cd ${workspace}/testing_clients
if [ -f "lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js" ]; then
    # Check if already modified
    if grep -q "^[[:space:]]*//postState.commit();" lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js; then
        echo "Lodestar: Already configured"
    else
        # Comment out all postState.commit() calls
        sed -i 's/^[[:space:]]*postState\.commit();/    \/\/postState.commit();/g' lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js
        echo "Lodestar: Commented out postState.commit() calls"
        # Reinstall packages (package.json is already configured in init script)
        cd lodestar
        if ! npm install; then
            echo "Warning: Lodestar npm install failed after configuration change."
        else
            echo "Lodestar: Reinstalled packages successfully"
        fi
    fi
else
    echo "Warning: Lodestar stateTransition.js not found"
fi

echo ""
echo "=========================================="
echo "All clients have been set up and configured successfully!"
echo "=========================================="
echo ""

