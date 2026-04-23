#!/bin/bash

# End script if one of them fails
set -e

# set spectec-core directory as workspace
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
    # Java Version check
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
    sudo ln -s /usr/bin/bazel-7.4.1 /usr/bin/bazel
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
    # Clean checkout to ensure we start from original code
    git fetch
    git checkout v8.0.1
    git reset --hard v8.0.1
    git clean -fd
else
    echo "Lighthouse is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf lighthouse
    git clone https://github.com/sigp/lighthouse.git
    cd lighthouse
    git checkout v8.0.1
fi

# Apply modified code
if [ -f "${workspace}/modified_code/lighthouse/transition_blocks.rs" ]; then
    echo "Applying modified Lighthouse code..."
    cp "${workspace}/modified_code/lighthouse/transition_blocks.rs" lcli/src/transition_blocks.rs
    echo "Lighthouse: transition_blocks.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/epoch_processing.rs" ]; then
    cp "${workspace}/modified_code/lighthouse/epoch_processing.rs" lcli/src/epoch_processing.rs
    echo "Lighthouse: epoch_processing.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/operation.rs" ]; then
    cp "${workspace}/modified_code/lighthouse/operation.rs" lcli/src/operation.rs
    echo "Lighthouse: operation.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/sanity_slots.rs" ]; then
    cp "${workspace}/modified_code/lighthouse/sanity_slots.rs" lcli/src/sanity_slots.rs
    echo "Lighthouse: sanity_slots.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/consensus/state_processing/src/per_block_processing.rs" ]; then
    cp "${workspace}/modified_code/lighthouse/consensus/state_processing/src/per_block_processing.rs" consensus/state_processing/src/per_block_processing.rs
    echo "Lighthouse: per_block_processing.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/lcli/src/main.rs" ]; then
    cp "${workspace}/modified_code/lighthouse/lcli/src/main.rs" lcli/src/main.rs
    echo "Lighthouse: main.rs applied"
fi
if [ -f "${workspace}/modified_code/lighthouse/transition_blocks.rs" ] || [ -f "${workspace}/modified_code/lighthouse/epoch_processing.rs" ] || [ -f "${workspace}/modified_code/lighthouse/operation.rs" ] || [ -f "${workspace}/modified_code/lighthouse/sanity_slots.rs" ] || [ -f "${workspace}/modified_code/lighthouse/consensus/state_processing/src/per_block_processing.rs" ] || [ -f "${workspace}/modified_code/lighthouse/lcli/src/main.rs" ]; then
    echo "Lighthouse: All modified code applied"
else
    echo "Warning: Modified Lighthouse code not found in ${workspace}/modified_code/lighthouse/"
fi

# Build Lighthouse
if [ -f "target/release/lcli" ] && [ "lcli/src/transition_blocks.rs" -ot "target/release/lcli" ] 2>/dev/null && [ "lcli/src/epoch_processing.rs" -ot "target/release/lcli" ] 2>/dev/null && [ "lcli/src/operation.rs" -ot "target/release/lcli" ] 2>/dev/null && [ "lcli/src/sanity_slots.rs" -ot "target/release/lcli" ] 2>/dev/null; then
    echo "Lighthouse lcli is already built and up-to-date. Skipping build..."
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
    # Clean checkout to ensure we start from original code
    git fetch
    git checkout v7.0.0
    git reset --hard v7.0.0
    git clean -fd
else
    echo "Prysm is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf prysm
    git clone https://github.com/prysmaticlabs/prysm
    cd prysm
    git checkout v7.0.0
fi

# Apply modified code
if [ -f "${workspace}/modified_code/prysm/main.go" ]; then
    echo "Applying modified Prysm code..."
    cp "${workspace}/modified_code/prysm/main.go" tools/pcli/main.go
    echo "Prysm: main.go applied"
fi
if [ -f "${workspace}/modified_code/prysm/beacon-chain/core/transition/transition_no_verify_sig.go" ]; then
    cp "${workspace}/modified_code/prysm/beacon-chain/core/transition/transition_no_verify_sig.go" beacon-chain/core/transition/transition_no_verify_sig.go
    echo "Prysm: transition_no_verify_sig.go applied"
fi
if [ -f "${workspace}/modified_code/prysm/main.go" ] || [ -f "${workspace}/modified_code/prysm/beacon-chain/core/transition/transition_no_verify_sig.go" ]; then
    echo "Prysm: Modified code applied"
else
    echo "Warning: Modified Prysm code not found in ${workspace}/modified_code/prysm/"
fi

# Build Prysm
if [ -f "bazel-bin/tools/pcli/pcli_/pcli" ] && [ "tools/pcli/main.go" -ot "bazel-bin/tools/pcli/pcli_/pcli" ] 2>/dev/null; then
    echo "Prysm pcli is already built and up-to-date. Skipping build..."
else
    # Create directory structure for expected path
    mkdir -p bazel-bin/tools/pcli/pcli_
    if ! go build -o bazel-bin/tools/pcli/pcli_/pcli ./tools/pcli; then
        echo "Error: Go build failed for Prysm."
        exit 1
    fi
    echo "Prysm: Binary created at bazel-bin/tools/pcli/pcli_/pcli"
fi

# Nimbus
echo "Setting up Nimbus..."
cd ${workspace}/testing_clients
if [ -d "nimbus-eth2" ] && [ -d "nimbus-eth2/.git" ]; then
    echo "Nimbus directory already exists."
    cd nimbus-eth2
    # Clean checkout to ensure we start from original code
    git fetch
    git checkout v25.11.1
    # Reset to v25.11.1 (in case of local modifications to tracked files)
    # Note: This doesn't affect submodules - they remain in their current state
    git reset --hard v25.11.1
    # Clean untracked files, but be careful with submodules
    # Submodules are tracked by .gitmodules, so they won't be deleted by git clean
    # However, if submodules are in a bad state, they might need re-initialization
    git clean -fd

else
    echo "Nimbus is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf nimbus-eth2
    git clone https://github.com/status-im/nimbus-eth2
    cd nimbus-eth2
    git checkout v25.11.1
    # Note: We do NOT initialize submodules here because:
    # 1. build_original_clients.sh doesn't initialize submodules
    # 2. The submodule commit in v25.11.0 (f80cfd8 for nim-serialization) is not
    #    compatible with Nim 1.6.20 (noxcannotraisey pragma issue)
    # 3. We'll try to use env.sh if it exists, otherwise use direct nim compilation
    # If submodules are needed, they should be initialized manually with a compatible version
fi

# Build Nimbus if not already built (make will handle submodules automatically)
if [ ! -f "build/ncli" ] && [ ! -f "ncli/ncli" ]; then
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
    echo "Building Nimbus with $JOBS parallel jobs (make will handle submodules)..."
    if ! make -j${JOBS} 2>&1; then
        echo "Error: Make build failed for Nimbus."
        echo "Trying with fewer parallel jobs (j2)..."
        if ! make -j2 2>&1; then
            echo "Error: Make build failed for Nimbus even with j2."
            exit 1
        fi
    fi
fi

# Apply modified code (after make build, so submodules are initialized)
MODIFIED_CODE_APPLIED=false

if [ -f "${workspace}/modified_code/nimbus/ncli.nim" ]; then
    echo "Applying modified Nimbus code..."
    cp "${workspace}/modified_code/nimbus/ncli.nim" ncli/ncli.nim
    echo "Nimbus: ncli.nim applied"
    MODIFIED_CODE_APPLIED=true
fi

if [ -f "${workspace}/modified_code/nimbus/beacon_chain/extras.nim" ]; then
    cp "${workspace}/modified_code/nimbus/beacon_chain/extras.nim" beacon_chain/extras.nim
    echo "Nimbus: extras.nim applied"
    MODIFIED_CODE_APPLIED=true
fi

if [ -f "${workspace}/modified_code/nimbus/beacon_chain/spec/state_transition.nim" ]; then
    cp "${workspace}/modified_code/nimbus/beacon_chain/spec/state_transition.nim" beacon_chain/spec/state_transition.nim
    echo "Nimbus: state_transition.nim applied"
    MODIFIED_CODE_APPLIED=true
fi

if [ "$MODIFIED_CODE_APPLIED" = "true" ]; then
    echo "Nimbus: Modified code applied"
else
    echo "Warning: Modified Nimbus code not found in ${workspace}/modified_code/nimbus/"
fi

# Build Nimbus with modified code (if modified code was applied, always rebuild)
if [ "$MODIFIED_CODE_APPLIED" = "true" ] || [ ! -f "ncli/ncli" ] || [ "ncli/ncli.nim" -nt "ncli/ncli" ] 2>/dev/null || [ "beacon_chain/extras.nim" -nt "ncli/ncli" ] 2>/dev/null || [ "beacon_chain/spec/state_transition.nim" -nt "ncli/ncli" ] 2>/dev/null; then
    # Clean previous build artifacts
    rm -f ncli/ncli

    # Find and use env.sh (try both locations)
    if [ -f "./env.sh" ]; then
        ENV_SH="./env.sh"
    elif [ -f "../env.sh" ]; then
        ENV_SH="../env.sh"
    else
        echo "Warning: env.sh not found in ./ or ../"
        echo "Trying direct nim compilation..."
        ENV_SH=""
    fi

    # Build ncli only
    if [ -n "$ENV_SH" ]; then
        if ! $ENV_SH nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim 2>&1; then
            echo "Error: Nimbus client build failed."
            exit 1
        fi
    else
        # Try direct nim compilation without env.sh
        if ! nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim 2>&1; then
            echo "Error: Nimbus client build failed."
            exit 1
        fi
    fi

    if [ -f "ncli/ncli" ]; then
        echo "Nimbus: ncli built successfully"
    else
        echo "Error: Nimbus binary not found after build."
        exit 1
    fi
fi

# Teku
echo "Setting up Teku..."
cd ${workspace}/testing_clients
if [ -d "teku" ] && [ -d "teku/.git" ]; then
    echo "Teku directory already exists."
    cd teku
    # Clean checkout to ensure we start from original code
    git fetch
    git checkout 25.11.1
    git reset --hard 25.11.1
    git clean -fd
else
    echo "Teku is missing or corrupt (not a git repo). Re-cloning..."
    rm -rf teku
    git clone https://github.com/Consensys/teku.git
    cd teku
    git checkout 25.11.1
fi

# Apply modified code
if [ -f "${workspace}/modified_code/teku/TransitionCommand.java" ]; then
    echo "Applying modified Teku code..."
    cp "${workspace}/modified_code/teku/TransitionCommand.java" teku/src/main/java/tech/pegasys/teku/cli/subcommand/TransitionCommand.java
    echo "Teku: TransitionCommand.java applied"
fi
if [ -f "${workspace}/modified_code/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java" ]; then
    cp "${workspace}/modified_code/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java" ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java
    echo "Teku: AbstractBlockProcessor.java applied"
fi
if [ -f "${workspace}/modified_code/teku/TransitionCommand.java" ] || [ -f "${workspace}/modified_code/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java" ]; then
    echo "Teku: Modified code applied"
else
    echo "Warning: Modified Teku code not found in ${workspace}/modified_code/teku/"
fi

# Build Teku
if [ -f "build/install/teku/bin/teku" ] && [ "teku/src/main/java/tech/pegasys/teku/cli/subcommand/TransitionCommand.java" -ot "build/install/teku/bin/teku" ] 2>/dev/null; then
    echo "Teku is already built and up-to-date. Skipping build..."
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
cat > package.json << EOF
{
  "dependencies": {
    "@lodestar/state-transition": "1.36.0",
    "@lodestar/types": "1.36.0",
    "@lodestar/config": "1.36.0",
    "@lodestar/utils": "1.36.0",
    "@lodestar/params": "1.36.0"
  },
  "type": "module"
}
EOF

# npm load
npm install

# Apply modified Lodestar code
if [ -f "${workspace}/modified_code/lodestar/transition.js" ]; then
    echo "Applying modified Lodestar code..."
    cp "${workspace}/modified_code/lodestar/transition.js" transition.js
    echo "Lodestar: transition.js applied"
fi
if [ -f "${workspace}/modified_code/lodestar/generateCachedStateCapella.js" ]; then
    cp "${workspace}/modified_code/lodestar/generateCachedStateCapella.js" generateCachedStateCapella.js
    echo "Lodestar: generateCachedStateCapella.js applied"
fi
if [ -f "${workspace}/modified_code/lodestar/transition.js" ] || [ -f "${workspace}/modified_code/lodestar/generateCachedStateCapella.js" ]; then
    echo "Lodestar: All modified code applied"
else
    echo "Warning: Modified Lodestar code not found in ${workspace}/modified_code/lodestar/"
    echo "Warning: Lodestar will not work without modified code!"
fi

# Lodestar: Comment out postState.commit() calls in node_modules
echo "Configuring Lodestar node_modules..."
cd ${workspace}/testing_clients
if [ -f "lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js" ]; then
    # Check if already modified
    if grep -q "^[[:space:]]*//postState.commit();" lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js; then
        echo "Lodestar: node_modules already configured"
    else
        # Comment out all postState.commit() calls
        sed -i 's/^[[:space:]]*postState\.commit();/    \/\/postState.commit();/g' lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js
        echo "Lodestar: Commented out postState.commit() calls in node_modules"
    fi
else
    echo "Warning: Lodestar stateTransition.js not found in node_modules"
fi

echo ""
echo "=========================================="
echo "All clients have been set up and configured successfully!"
echo "=========================================="
echo ""
