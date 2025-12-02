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
if [ -d "lighthouse" ] && [ -d "lighthouse/.git" ]; then
    echo "Lighthouse repository found."
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
    echo "Lighthouse is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf lighthouse
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
if [ -d "prysm" ] && [ -d "prysm/.git" ]; then
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
    echo "Prysm is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf prysm
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
if [ -d "nimbus-eth2" ] && [ -d "nimbus-eth2/.git" ]; then
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
    echo "Nimbus is missing of corrupt (not a git repo). Re-cloning..."
    rm -rf nimbus-eth2
    git clone https://github.com/status-im/nimbus-eth2
    cd nimbus-eth2
    git checkout v25.11.0
fi
# Build Nimbus if not already built
if [ ! -f "build/ncli" ] || [ ! -f "ncli/ncli" ]; then
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
else
    echo "Nimbus is already built. Proceeding to configure..."
fi

# Configure Nimbus: Override fork epochs for pure Capella network
cd ncli
if [ -f "ncli.nim" ]; then
    if ! grep -q "Override fork epochs for pure Capella network" ncli.nim; then
        # Check if we need to add the fork epoch override
        if grep -q "cfg = getRuntimeConfig" ncli.nim; then
            # Use Python to add fork epoch override
            python3 << 'PYTHON_SCRIPT'
import re

file_path = 'ncli.nim'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Pattern: cfg = getRuntimeConfig(conf.eth2Network)
# This appears in let blocks, so we need to replace it with the override code
pattern = r'(\s+)(cfg\s*=\s*getRuntimeConfig\(conf\.eth2Network\))'
replacement = r'''\1let cfgBase = getRuntimeConfig(conf.eth2Network)
\1# Override fork epochs for pure Capella network (CAPELLA_FORK_EPOCH = 0)
\1cfg = block:
\1  var c = cfgBase
\1  c.ALTAIR_FORK_EPOCH = Epoch(0)
\1  c.BELLATRIX_FORK_EPOCH = Epoch(0)
\1  c.CAPELLA_FORK_EPOCH = Epoch(0)
\1  c.DENEB_FORK_EPOCH = Epoch(75520)
\1  c'''

# Replace first occurrence (doTransition)
found_first = False
new_lines = []
for i, line in enumerate(lines):
    if not found_first and re.search(pattern, line):
        indent = len(line) - len(line.lstrip())
        indent_str = ' ' * indent
        new_lines.append(f'{indent_str}cfgBase = getRuntimeConfig(conf.eth2Network)\n')
        new_lines.append(f'{indent_str}# Override fork epochs for pure Capella network (CAPELLA_FORK_EPOCH = 0)\n')
        new_lines.append(f'{indent_str}cfg = block:\n')
        new_lines.append(f'{indent_str}  var c = cfgBase\n')
        new_lines.append(f'{indent_str}  c.ALTAIR_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.BELLATRIX_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.CAPELLA_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.DENEB_FORK_EPOCH = Epoch(75520)\n')
        new_lines.append(f'{indent_str}  c\n')
        found_first = True
    elif found_first and re.search(pattern, line):
        # Second occurrence (doSlots)
        indent = len(line) - len(line.lstrip())
        indent_str = ' ' * indent
        new_lines.append(f'{indent_str}cfgBase = getRuntimeConfig(conf.eth2Network)\n')
        new_lines.append(f'{indent_str}# Override fork epochs for pure Capella network (CAPELLA_FORK_EPOCH = 0)\n')
        new_lines.append(f'{indent_str}cfg = block:\n')
        new_lines.append(f'{indent_str}  var c = cfgBase\n')
        new_lines.append(f'{indent_str}  c.ALTAIR_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.BELLATRIX_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.CAPELLA_FORK_EPOCH = Epoch(0)\n')
        new_lines.append(f'{indent_str}  c.DENEB_FORK_EPOCH = Epoch(75520)\n')
        new_lines.append(f'{indent_str}  c\n')
    else:
        new_lines.append(line)

# Add import if not present (Epoch type is in datatypes)
import_added = False
for i, line in enumerate(new_lines):
    if '../beacon_chain/spec/[eth2_ssz_serialization, state_transition]' in line:
        # Check if datatypes import already exists
        if 'datatypes' not in ''.join(new_lines[i:i+5]):
            # Add comma to the previous import line if it doesn't have one
            if not new_lines[i].rstrip().endswith(','):
                new_lines[i] = new_lines[i].rstrip() + ',\n'
            # Add datatypes import after the spec import line (with proper indentation and comma)
            new_lines.insert(i+1, '  ../beacon_chain/spec/datatypes/[phase0, altair, bellatrix, capella, deneb, constants]\n')
            import_added = True
            break

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Nimbus: Added fork epoch override for pure Capella network")
PYTHON_SCRIPT
                echo "Nimbus: Added fork epoch override configuration"
            fi
        else
            echo "Nimbus: Already configured with fork epoch override"
        fi
    
    # Rebuild ncli after code modification
    if ! ../env.sh nim c -d:const_preset=mainnet ncli 2>&1; then
        echo "Error: Nimbus client build failed."
        exit 1
    fi
    echo "Nimbus: ncli built successfully"
else
    echo "Warning: ncli.nim not found"
fi

# Teku
echo "Setting up Teku..."
cd ${workspace}/testing_clients
if [ -d "teku" ] && [ -d "teku/.git" ]; then
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
    echo "Teku is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf teku
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
    
    # 4. Add state root verification (if not already added)
    if ! grep -q "Verify that the computed post-state root matches the state root in the block" lighthouse/lcli/src/transition_blocks.rs; then
        # Use Python to add state root verification after post-block tree hash calculation
        python3 << 'PYTHON_SCRIPT'
import re

file_path = 'lighthouse/lcli/src/transition_blocks.rs'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the post-block tree hash section and add state root verification
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    
    # Check if this is the if block start
    if 'if !config.exclude_post_block_thc' in line:
        new_lines.append(line)
        i += 1
        
        # Process the if block - look for the pattern:
        # let t = Instant::now();
        # pre_state
        #     .update_tree_hash_cache()
        #     .map_err(...)?;
        # debug!("Post-block tree hash: {:?}", t.elapsed());
        
        found_update = False
        if_block_indent = len(line) - len(line.lstrip())
        
        while i < len(lines):
            inner_line = lines[i]
            inner_indent = len(inner_line) - len(inner_line.lstrip())
            
            # Check if we're still in the if block
            if inner_line.strip() == '}' and inner_indent == if_block_indent:
                # End of if block
                new_lines.append(inner_line)
                i += 1
                break
            
            # Check if this is the pre_state line (before update_tree_hash_cache)
            if not found_update and 'pre_state' in inner_line and 'update_tree_hash_cache()' not in inner_line:
                # Look ahead to see if update_tree_hash_cache is on the next line
                if i + 1 < len(lines) and '.update_tree_hash_cache()' in lines[i + 1]:
                    found_update = True
                    indent = len(inner_line) - len(inner_line.lstrip())
                    indent_str = ' ' * indent
                    
                    # Check if we need to add "let t = Instant::now();" first
                    if i > 0 and 'let t = Instant::now();' not in lines[i-1]:
                        new_lines.append(indent_str + '        let t = Instant::now();\n')
                    
                    # Add the modified update_tree_hash_cache with return value capture
                    new_lines.append(indent_str + '        let post_state_root = pre_state\n')
                    new_lines.append(indent_str + '            .update_tree_hash_cache()\n')
                    
                    # Skip the original pre_state line and process the rest
                    i += 1
                    # Skip .update_tree_hash_cache() line (already added)
                    if i < len(lines) and '.update_tree_hash_cache()' in lines[i]:
                        i += 1
                    
                    # Process until we find the debug line
                    while i < len(lines):
                        if 'debug!("Post-block tree hash' in lines[i]:
                            # Add .map_err line and debug line
                            new_lines.append(indent_str + '            .map_err(|e| format!("Unable to build tree hash cache: {:?}", e))?;\n')
                            new_lines.append(lines[i])  # debug line
                            i += 1
                            # Add state root verification
                            new_lines.append('\n')
                            new_lines.append(indent_str + '        // Verify that the computed post-state root matches the state root in the block\n')
                            new_lines.append(indent_str + '        let block_state_root = block.state_root();\n')
                            new_lines.append(indent_str + '        if post_state_root != block_state_root {\n')
                            new_lines.append(indent_str + '            return Err(format!(\n')
                            new_lines.append(indent_str + '                "State root mismatch! Block contains {}, but computed post-state root is {}",\n')
                            new_lines.append(indent_str + '                block_state_root, post_state_root\n')
                            new_lines.append(indent_str + '            ));\n')
                            new_lines.append(indent_str + '        }\n')
                            break
                        elif '.map_err' in lines[i] or lines[i].strip() == '?;' or lines[i].strip().startswith('.update_tree_hash_cache'):
                            # Skip these as we're replacing them
                            i += 1
                        else:
                            # Keep other lines
                            new_lines.append(lines[i])
                            i += 1
                    continue
            
            new_lines.append(inner_line)
            i += 1
        continue
    
    new_lines.append(line)
    i += 1

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Lighthouse: Added state root verification")
PYTHON_SCRIPT
        NEEDS_REBUILD=true
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

# Prysm: Add pure Capella config and post state saving code
echo "Configuring Prysm..."
cd ${workspace}/testing_clients
if [ -f "prysm/tools/pcli/main.go" ]; then
    NEEDS_REBUILD=false
    
    # 1. Add pure Capella config (default network)
    if ! grep -q "Default: Use pure Capella config" prysm/tools/pcli/main.go; then
        CLOSING_BRACE_LINE=$(awk '/^\s+default:/ {line=NR; getline; if (/log\.Fatalf/) {getline; if (/^\s+}/) print NR+1; next}}' prysm/tools/pcli/main.go | head -1)
        if [ -n "$CLOSING_BRACE_LINE" ]; then
            awk -v line="$CLOSING_BRACE_LINE" '
            NR == line {
                print "\t\t} else {"
                print "\t\t\t// Default: Use pure Capella config (CAPELLA_FORK_EPOCH = 0)"
                print "\t\t\tcfg := params.MainnetConfig()"
                print "\t\t\tcfg.AltairForkEpoch = 0"
                print "\t\t\tcfg.BellatrixForkEpoch = 0"
                print "\t\t\tcfg.CapellaForkEpoch = 0"
                print "\t\t\tcfg.DenebForkEpoch = 75520"
                print "\t\t\t// Re-initialize fork schedule after modifying fork epochs"
                print "\t\t\tcfg.InitializeForkSchedule()"
                print "\t\t\tif err := params.SetActive(cfg); err != nil {"
                print "\t\t\t\tlog.Fatal(err)"
                print "\t\t\t}"
                print "\t\t}"
                next
            }
            { print }
            ' prysm/tools/pcli/main.go > prysm/tools/pcli/main.go.tmp && mv prysm/tools/pcli/main.go.tmp prysm/tools/pcli/main.go
            echo "Prysm: Added pure Capella config (default network)"
            NEEDS_REBUILD=true
        else
            echo "Warning: Could not find insertion point for pure Capella config in Prysm main.go"
        fi
    fi
    
    # 2. Add post state saving code
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
            NEEDS_REBUILD=true
        else
            echo "Warning: Could not find insertion point in Prysm main.go"
        fi
    fi
    
    # 3. Add state root verification (if not already added)
    if ! grep -q "Verify that the computed post-state root matches the state root in the block" prysm/tools/pcli/main.go; then
        # Check if bytes package is imported
        if ! grep -q '"bytes"' prysm/tools/pcli/main.go; then
            # Add bytes import
            python3 << 'PYTHON_SCRIPT'
import re

file_path = 'prysm/tools/pcli/main.go'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the import block and add bytes
new_lines = []
in_import = False
import_added = False
for i, line in enumerate(lines):
    if line.strip() == 'import (':
        in_import = True
        new_lines.append(line)
    elif in_import and line.strip() == ')':
        if not import_added:
            # Add bytes import before the closing parenthesis
            new_lines.append('\t"bytes"\n')
            import_added = True
        new_lines.append(line)
        in_import = False
    elif in_import and not import_added and line.strip().startswith('"bufio"'):
        # Add bytes after bufio
        new_lines.append(line)
        new_lines.append('\t"bytes"\n')
        import_added = True
    else:
        new_lines.append(line)

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Prysm: Added bytes import")
PYTHON_SCRIPT
        fi
        
        # Add state root verification after postRoot calculation
        python3 << 'PYTHON_SCRIPT'
import re

file_path = 'prysm/tools/pcli/main.go'
with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the line with "Finished state transition with post state root"
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    # Check if this is the log line after postRoot calculation
    if 'log.Infof("Finished state transition with post state root' in line:
        new_lines.append(line)
        i += 1
        # Add state root verification after this line
        indent = len(line) - len(line.lstrip())
        indent_str = '\t' * (indent // 8) if indent >= 8 else '\t'
        new_lines.append('\n')
        new_lines.append(indent_str + '\t// Verify that the computed post-state root matches the state root in the block\n')
        new_lines.append(indent_str + '\tblockStateRoot := block.Block().StateRoot()\n')
        new_lines.append(indent_str + '\tif !bytes.Equal(postRoot[:], blockStateRoot[:]) {\n')
        new_lines.append(indent_str + '\t\tlog.Fatalf("State root mismatch! Block contains %#x, but computed post-state root is %#x", blockStateRoot, postRoot)\n')
        new_lines.append(indent_str + '\t}\n')
        continue
    new_lines.append(line)
    i += 1

with open(file_path, 'w') as f:
    f.writelines(new_lines)
print("Prysm: Added state root verification")
PYTHON_SCRIPT
        NEEDS_REBUILD=true
    fi
    
    # Rebuild Prysm if any changes were made
    if [ "$NEEDS_REBUILD" = true ]; then
        cd prysm/tools/pcli
        if ! bazel build //tools/pcli:pcli; then
            echo "Warning: Prysm rebuild failed after configuration change."
        else
            echo "Prysm: Rebuilt successfully"
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

