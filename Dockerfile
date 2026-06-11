# ============================================
# SpecTrum Docker Image Build script
# ============================================

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
        llvm \
        python3 \
        python3-pip \
        python3-dev \
        libssl-dev \
        libsnappy-dev \
        libgmp-dev \
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
# Pin nightly for reproducible coverage builds (Lighthouse uses -Z coverage-options=branch)
ARG RUST_NIGHTLY_DATE=2026-01-15
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . $HOME/.cargo/env && \
    rustup default stable && \
    rustup component add llvm-tools-preview && \
    rustup toolchain install nightly-${RUST_NIGHTLY_DATE} --component llvm-tools-preview

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

# Install go-bcov for Prysm branch coverage
RUN go install github.com/alx99/go-bcov@v1

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
# Stage 7.5: Install OCaml and opam (for Spectec)
# ============================================
RUN apt-get update && \
    apt-get install -y \
        opam \
        m4 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Initialize opam and create OCaml switch (name must match Makefile SWITCH=eth-spectec)
# Pin menhir to 20211012: newer menhir drops MenhirLib.General used by spectec parser_debug.ml
RUN opam init --disable-sandboxing -y && \
    opam switch create eth-spectec ocaml-base-compiler.5.1.0 && \
    eval $(opam env --switch=eth-spectec) && \
    opam install -y dune bignum menhir.20211012 core core_unix bisect_ppx yojson digestif bls12-381 bls12-381-signature

ENV OPAM_SWITCH_PREFIX="/root/.opam/eth-spectec"
ENV CAML_LD_LIBRARY_PATH="/root/.opam/eth-spectec/lib/stublibs:/root/.opam/default/lib/stublibs"
ENV OCAML_TOPLEVEL_PATH="/root/.opam/eth-spectec/lib/toplevel"
ENV PATH="/root/.opam/eth-spectec/bin:/root/.opam/default/bin:${PATH}"

# ============================================
# Stage 8: Copy project files and install Python dependencies
# ============================================
COPY . /workspace/spectec-core
WORKDIR /workspace/spectec-core

# Initialize git submodules (consensus-specs, consensus-spec-tests)
RUN git submodule update --init --recursive

# Configure sparse-checkout for consensus-specs (required for eth2spec)
WORKDIR /workspace/spectec-core/consensus-specs
RUN git sparse-checkout init --cone && \
    git sparse-checkout set tests/core/pyspec specs/ configs/ presets/ pysetup/ sync/ .

# Install uv (Python package manager for eth2spec)
# uv install script may install to ~/.cargo/bin (already in PATH from Rust) or ~/.local/bin
WORKDIR /workspace/spectec-core
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Add /root/.local/bin to PATH (uv may install here if not in .cargo/bin)
# Note: /root/.cargo/bin is already in PATH from Rust installation (line 57)
ENV PATH="/root/.local/bin:${PATH}"

# Build Python specification files (mainnet.py, minimal.py)
# Note: make _pyspec automatically runs uv sync first (see Makefile _pyspec: _sync dependency)
WORKDIR /workspace/spectec-core/consensus-specs
RUN make _pyspec

# Install Python dependencies (including snappy for decompression)
WORKDIR /workspace/spectec-core
RUN pip3 install --no-cache-dir -r requirements.txt

# Build spectec-core executable
WORKDIR /workspace/spectec-core
RUN eval $(opam env) && \
    make exe

# Create testing_clients directory
RUN mkdir -p testing_clients

# ============================================
# Stage 9: Clone and setup clients
# ============================================
WORKDIR /workspace/spectec-core/testing_clients

# Clone Lighthouse (v8.0.1)
RUN git clone https://github.com/sigp/lighthouse.git && \
    cd lighthouse && \
    git checkout v8.0.1 && \
    git reset --hard v8.0.1 && \
    git clean -fd

# Clone Prysm (v7.0.0)
RUN git clone https://github.com/prysmaticlabs/prysm.git && \
    cd prysm && \
    git checkout v7.0.0 && \
    git reset --hard v7.0.0 && \
    git clean -fd

# Clone Teku (25.11.1)
RUN git clone https://github.com/ConsenSys/teku.git && \
    cd teku && \
    git checkout 25.11.1 && \
    git reset --hard 25.11.1 && \
    git clean -fd

# Clone Nimbus (v25.11.1)
RUN git clone https://github.com/status-im/nimbus-eth2.git && \
    cd nimbus-eth2 && \
    git checkout v25.11.1 && \
    git reset --hard v25.11.1 && \
    git clean -fd

# Setup Lodestar (create package.json and install dependencies)
WORKDIR /workspace/spectec-core/testing_clients
RUN mkdir -p lodestar && \
    cd lodestar && \
    echo '{\n  "dependencies": {\n    "@lodestar/state-transition": "1.36.0",\n    "@lodestar/types": "1.36.0",\n    "@lodestar/config": "1.36.0",\n    "@lodestar/utils": "1.36.0",\n    "@lodestar/params": "1.36.0",\n    "@chainsafe/blst": "2.2.0",\n    "@chainsafe/pubkey-index-map": "3.0.0"\n  },\n  "type": "module"\n}' > package.json && \
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
    fi && \
    if [ -f "modified_code/nimbus/beacon_chain/extras.nim" ]; then \
        mkdir -p testing_clients/nimbus-eth2/beacon_chain && \
        cp modified_code/nimbus/beacon_chain/extras.nim testing_clients/nimbus-eth2/beacon_chain/extras.nim; \
    fi && \
    if [ -f "modified_code/nimbus/beacon_chain/spec/state_transition.nim" ]; then \
        mkdir -p testing_clients/nimbus-eth2/beacon_chain/spec && \
        cp modified_code/nimbus/beacon_chain/spec/state_transition.nim testing_clients/nimbus-eth2/beacon_chain/spec/state_transition.nim; \
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
# Note: This stage inherits from base, so spectec-core executable,
# consensus-specs (eth2spec), and all other dependencies are already available.
FROM base AS coverage

WORKDIR /workspace/spectec-core

# Build Lighthouse with coverage (use same pinned nightly as Stage 2)
ARG RUST_NIGHTLY_DATE=2026-01-15
WORKDIR /workspace/spectec-core/testing_clients/lighthouse
RUN RUSTFLAGS="-Cinstrument-coverage -Z coverage-options=branch" \
    cargo +nightly-${RUST_NIGHTLY_DATE} build --release --bin lcli && \
    cp target/release/lcli target/release/lcli-cov

# Build Prysm with coverage
WORKDIR /workspace/spectec-core/testing_clients/prysm
RUN PRYSM_COVERPKG="$(go list -deps ./tools/pcli | grep -E '^github.com/OffchainLabs/prysm/v7/(beacon-chain/core|beacon-chain/state|consensus-types|encoding/ssz|encoding/bytesutil|crypto/bls|config/params|tools/pcli|math|time/slots|beacon-chain/blockchain/kzg|proto/engine/v1)' | grep -Ev '/(testing|mock)$' | paste -sd, -)" && \
    go build -cover -coverpkg="${PRYSM_COVERPKG}" -o pcli-cov ./tools/pcli

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
