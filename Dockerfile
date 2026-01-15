# ============================================
# Ethereum 2.0 Differential Testing Environment
# ============================================
# This Dockerfile builds all Ethereum 2.0 clients (Prysm, Lighthouse, Teku, Nimbus, Lodestar)
# with modified code for differential testing and coverage instrumentation support.
#
# ============================================
# Step 1: Clone the repository
# ============================================
#   git clone --recursive https://github.com/GyeongMinDan/eth-spectec.git
#   cd eth-spectec
#
#   Or if you already cloned without --recursive:
#   git submodule update --init --recursive
#
# ============================================
# Step 2: Build Docker image with coverage binaries
# ============================================
#   # Build base environment (clones and builds original clients)
#   docker build -t eth2test:base --target base .
#
#   # Build with coverage binaries (recommended for coverage testing)
#   docker build -t eth2test:coverage --target coverage .
#
#   Note: This will take a long time (6000s in macbook pre 19) as it builds all clients.
#
# ============================================
# Step 3: Run diff_testing.py with coverage
# ============================================
#   # Basic usage (results saved to local ./results directory)
#   docker run --rm -it \
#     -v "$(pwd)/results:/workspace/spectec-core/results" \
#     eth2test:coverage \
#     bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
#       --test-suite Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
#       --test-type state-transition \
#       --workflow sequential \
#       --fork-version capella \
#       --output-base ./results/coverage_sanity_block_test \
#       --enable-coverage \
#       --cleanup-after-report'
#
#   # Example with different test suite
#   docker run --rm -it \
#     -v "$(pwd)/results:/workspace/spectec-core/results" \
#     eth2test:coverage \
#     bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
#       --test-suite Converter/OfficialTestSuite/capella/sanity/slots/pyspec_tests \
#       --test-type sanity-slots \
#       --fork-version capella \
#       --output-base ./results/coverage_sanity_slot_test \
#       --enable-coverage \
#       --cleanup-after-report'
#
#   Important Notes:
#   - Do NOT mount the entire project directory (e.g., -v "$(pwd):/workspace/spectec-core")
#     This will hide the testing_clients/ binaries built inside the Docker image.
#   - Only mount the results directory to save output files.
#   - All test cases and binaries are already inside the Docker image.
#
# ============================================
# Step 4: Generate final accumulated coverage report (optional)
# ============================================
#   # After running multiple test suites, generate a combined coverage report
#   docker run --rm -it \
#     -v "$(pwd)/results:/workspace/spectec-core/results" \
#     eth2test:coverage \
#     bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
#       --generate-final-coverage \
#       ./results/coverage_suite1 \
#       ./results/coverage_suite2 \
#       --final-output-dir ./results/final_coverage_report'
#
# ============================================
# Output Files Location
# ============================================
#   All output files will be saved to: ./results/ (local directory)
#   - Client outputs: ./results/<test_name>/<client>/output/
#   - Coverage data: ./results/<test_name>/<client>/cov_output_*/
#   - Reports: ./results/<test_name>/report_*.md
#   - CSV logs: ./results/<test_name>/*.csv

ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION} AS base

# Avoid interactive prompts during package installation
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# Set working directory
WORKDIR /workspace

# ============================================
# Stage 1: Install system dependencies
# ============================================
RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        wget \
        build-essential \
        gcc \
        g++ \
        make \
        cmake \
        pkg-config \
        llvm-dev \
        libclang-dev \
        clang \
        python3 \
        python3-pip \
        python3-dev \
        libssl-dev \
        libsnappy-dev \
        lcov \
        git-lfs \
        apt-transport-https \
        gnupg \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 2: Install Rust (for Lighthouse)
# ============================================
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . $HOME/.cargo/env && \
    rustup default stable && \
    rustup toolchain install nightly --component llvm-tools-preview && \
    cargo install grcov

ENV PATH="/root/.cargo/bin:${PATH}"

# ============================================
# Stage 3: Install Go (for Prysm)
# ============================================
ARG GO_VERSION=1.24.2
RUN wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz && \
    rm go${GO_VERSION}.linux-amd64.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# ============================================
# Stage 4: Install Java 21 (for Teku)
# ============================================
RUN apt-get update && \
    apt-get install -y openjdk-21-jdk openjdk-21-jre && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# ============================================
# Stage 5: Install Bazel (for Prysm)
# ============================================
RUN curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel-archive-keyring.gpg && \
    mv bazel-archive-keyring.gpg /usr/share/keyrings && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" > /etc/apt/sources.list.d/bazel.list && \
    apt-get update && \
    apt-get install -y bazel-7.4.1 && \
    ln -s /usr/bin/bazel-7.4.1 /usr/bin/bazel && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 6: Install Node.js 20 (for Lodestar)
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 7: Install Nim (for Nimbus)
# ============================================
ARG NIM_VERSION=1.6.20
RUN wget -q https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz && \
    tar -xJf nim-${NIM_VERSION}-linux_x64.tar.xz && \
    mv nim-${NIM_VERSION} /opt/nim && \
    rm nim-${NIM_VERSION}-linux_x64.tar.xz && \
    cd /opt/nim && \
    ./install.sh /opt/nim && \
    rm -rf /opt/nim/nimcache

ENV PATH="/opt/nim/bin:${PATH}"

# ============================================
# Stage 8: Copy project files and install Python dependencies
# ============================================
COPY . /workspace/spectec-core
WORKDIR /workspace/spectec-core

# Install Python dependencies (including snappy for decompression)
RUN pip3 install --no-cache-dir -r requirements.txt

# Create testing_clients directory
RUN mkdir -p testing_clients

# ============================================
# Stage 9: Clone and setup clients
# ============================================
WORKDIR /workspace/spectec-core/testing_clients

# Clone Lighthouse (v8.0.0)
RUN git clone https://github.com/sigp/lighthouse.git && \
    cd lighthouse && \
    git checkout v8.0.0 && \
    git reset --hard v8.0.0 && \
    git clean -fd

# Clone Prysm (v7.0.0)
RUN git clone https://github.com/prysmaticlabs/prysm.git && \
    cd prysm && \
    git checkout v7.0.0 && \
    git reset --hard v7.0.0 && \
    git clean -fd

# Clone Teku (25.11.0)
RUN git clone https://github.com/ConsenSys/teku.git && \
    cd teku && \
    git checkout 25.11.0 && \
    git reset --hard 25.11.0 && \
    git clean -fd

# Clone Nimbus (v25.11.0)
RUN git clone https://github.com/status-im/nimbus-eth2.git && \
    cd nimbus-eth2 && \
    git checkout v25.11.0 && \
    git reset --hard v25.11.0 && \
    git clean -fd

# Setup Lodestar (create package.json and install dependencies)
WORKDIR /workspace/spectec-core/testing_clients
RUN mkdir -p lodestar && \
    cd lodestar && \
    echo '{\n  "dependencies": {\n    "@lodestar/state-transition": "1.36.0"\n  },\n  "type": "module"\n}' > package.json && \
    npm i @lodestar/state-transition@1.36.0 && \
    npm install

# ============================================
# Stage 10: Apply modified code
# ============================================
WORKDIR /workspace/spectec-core

# Apply Lighthouse modifications
RUN if [ -f "modified_code/lighthouse/transition_blocks.rs" ]; then \
        cp modified_code/lighthouse/transition_blocks.rs testing_clients/lighthouse/lcli/src/transition_blocks.rs; \
    fi && \
    if [ -f "modified_code/lighthouse/epoch_processing.rs" ]; then \
        cp modified_code/lighthouse/epoch_processing.rs testing_clients/lighthouse/lcli/src/epoch_processing.rs; \
    fi && \
    if [ -f "modified_code/lighthouse/operation.rs" ]; then \
        cp modified_code/lighthouse/operation.rs testing_clients/lighthouse/lcli/src/operation.rs; \
    fi && \
    if [ -f "modified_code/lighthouse/sanity_slots.rs" ]; then \
        cp modified_code/lighthouse/sanity_slots.rs testing_clients/lighthouse/lcli/src/sanity_slots.rs; \
    fi && \
    if [ -f "modified_code/lighthouse/consensus/state_processing/src/per_block_processing.rs" ]; then \
        mkdir -p testing_clients/lighthouse/consensus/state_processing/src && \
        cp modified_code/lighthouse/consensus/state_processing/src/per_block_processing.rs testing_clients/lighthouse/consensus/state_processing/src/per_block_processing.rs; \
    fi && \
    if [ -f "modified_code/lighthouse/lcli/src/main.rs" ]; then \
        cp modified_code/lighthouse/lcli/src/main.rs testing_clients/lighthouse/lcli/src/main.rs; \
    fi

# Apply Prysm modifications
RUN if [ -f "modified_code/prysm/main.go" ]; then \
        cp modified_code/prysm/main.go testing_clients/prysm/tools/pcli/main.go; \
    fi && \
    if [ -f "modified_code/prysm/beacon-chain/core/transition/transition_no_verify_sig.go" ]; then \
        mkdir -p testing_clients/prysm/beacon-chain/core/transition && \
        cp modified_code/prysm/beacon-chain/core/transition/transition_no_verify_sig.go testing_clients/prysm/beacon-chain/core/transition/transition_no_verify_sig.go; \
    fi

# Apply Teku modifications
RUN if [ -f "modified_code/teku/TransitionCommand.java" ]; then \
        cp modified_code/teku/TransitionCommand.java testing_clients/teku/teku/src/main/java/tech/pegasys/teku/cli/subcommand/TransitionCommand.java; \
    fi && \
    if [ -f "modified_code/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java" ]; then \
        mkdir -p testing_clients/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block && \
        cp modified_code/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java testing_clients/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java; \
    fi

# Apply Nimbus modifications (after initial build)
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN JOBS=4 && \
    make -j${JOBS} || make -j2 || make

WORKDIR /workspace/spectec-core
RUN if [ -f "modified_code/nimbus/ncli.nim" ]; then \
        cp modified_code/nimbus/ncli.nim testing_clients/nimbus-eth2/ncli/ncli.nim; \
    fi

# Apply Lodestar modifications
RUN if [ -f "modified_code/lodestar/transition.js" ]; then \
        cp modified_code/lodestar/transition.js testing_clients/lodestar/transition.js; \
    fi && \
    if [ -f "modified_code/lodestar/generateCachedStateCapella.js" ]; then \
        cp modified_code/lodestar/generateCachedStateCapella.js testing_clients/lodestar/generateCachedStateCapella.js; \
    fi

# Comment out postState.commit() calls in Lodestar node_modules
RUN if [ -f "testing_clients/lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js" ]; then \
        sed -i 's/^[[:space:]]*postState\.commit();/    \/\/postState.commit();/g' testing_clients/lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js; \
    fi

# ============================================
# Stage 11: Build original clients (no coverage)
# ============================================
WORKDIR /workspace/spectec-core/testing_clients

# Build Lighthouse
WORKDIR /workspace/spectec-core/testing_clients/lighthouse
RUN cargo build --release --bin lcli

# Build Prysm
WORKDIR /workspace/spectec-core/testing_clients/prysm
RUN mkdir -p bazel-bin/tools/pcli/pcli_ && \
    go build -o bazel-bin/tools/pcli/pcli_/pcli ./tools/pcli

# Build Teku
WORKDIR /workspace/spectec-core/testing_clients/teku
RUN ./gradlew installDist

# Build Nimbus
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN if [ -f "./env.sh" ]; then \
        ./env.sh nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim; \
    else \
        nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim; \
    fi

# Verify Lodestar (no build needed)
WORKDIR /workspace/spectec-core/testing_clients/lodestar
RUN test -f transition.js || test -f transition || echo "Warning: Lodestar transition.js not found"

# ============================================
# Stage 12: Coverage build stage
# ============================================
FROM base AS coverage

WORKDIR /workspace/spectec-core

# Build Lighthouse with coverage
WORKDIR /workspace/spectec-core/testing_clients/lighthouse
RUN RUSTFLAGS="-Cinstrument-coverage -Z coverage-options=branch" \
    cargo +nightly build --release --bin lcli && \
    cp target/release/lcli target/release/lcli-cov

# Build Prysm with coverage
WORKDIR /workspace/spectec-core/testing_clients/prysm
RUN go build -cover -o pcli-cov ./tools/pcli

# Build Teku with coverage (download JaCoCo agent)
WORKDIR /workspace/spectec-core/testing_clients/teku
RUN ./gradlew installDist && \
    cp -r build/install/teku build/install/teku-cov

# Download JaCoCo agent to the expected location (matching build_coverage_clients.sh)
WORKDIR /workspace/spectec-core/testing_clients
RUN mkdir -p jacoco && \
    wget -q -O jacoco/jacocoagent.jar https://repo1.maven.org/maven2/org/jacoco/org.jacoco.agent/0.8.11/org.jacoco.agent-0.8.11-runtime.jar && \
    wget -q -O jacoco/jacococli.jar https://repo1.maven.org/maven2/org/jacoco/org.jacoco.cli/0.8.11/org.jacoco.cli-0.8.11-nodeps.jar

# Build Nimbus with coverage
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN if [ -f "./env.sh" ]; then \
        ./env.sh nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov ncli/ncli.nim; \
    else \
        nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov ncli/ncli.nim; \
    fi

# Verify Lodestar c8 availability
WORKDIR /workspace/spectec-core/testing_clients/lodestar
RUN npx --yes c8 --version || echo "c8 will be installed on first use"

# ============================================
# Final stage: Set working directory
# ============================================
WORKDIR /workspace/spectec-core

# Default command
CMD ["/bin/bash"]
