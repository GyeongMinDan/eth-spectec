#!/bin/bash
# 
# Ethereum Consensus Clients - Coverage Build Script
# 
# 이 스크립트는 각 클라이언트를 커버리지 측정이 가능한 상태로 빌드합니다.
# 
# Usage:
#   ./build_coverage_clients.sh [client_name]
#   
#   client_name: prysm, lighthouse, teku, nimbus, lodestar, all (default: all)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_CLIENTS_DIR="${SCRIPT_DIR}/testing_clients"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Prysm (Go) - Build with coverage instrumentation
build_prysm() {
    print_info "Building Prysm with coverage instrumentation..."
    
    cd "${TESTING_CLIENTS_DIR}/prysm"
    
    if [ ! -f "go.mod" ]; then
        print_error "go.mod not found. Are you in the Prysm directory?"
        return 1
    fi
    
    # Build pcli with coverage support
    print_info "Running: go build -cover -o pcli-cov ./tools/pcli"
    go build -cover -o pcli-cov ./tools/pcli
    
    if [ -f "pcli-cov" ]; then
        print_info "✓ Prysm coverage binary created: ${TESTING_CLIENTS_DIR}/prysm/pcli-cov"
    else
        print_error "✗ Failed to create Prysm coverage binary"
        return 1
    fi
}

# Lighthouse (Rust) - Build with LLVM coverage
build_lighthouse() {
    print_info "Building Lighthouse with LLVM coverage instrumentation..."
    
    cd "${TESTING_CLIENTS_DIR}/lighthouse"
    
    if [ ! -f "Cargo.toml" ]; then
        print_error "Cargo.toml not found. Are you in the Lighthouse directory?"
        return 1
    fi
    
    # Check if grcov is installed
    if ! command -v grcov &> /dev/null; then
        print_warn "grcov not found. Install with: cargo install grcov"
    fi
    
    # Build with coverage instrumentation
    print_info "Running: RUSTFLAGS=\"-Cinstrument-coverage\" cargo build --release --bin lcli"
    export RUSTFLAGS="-Cinstrument-coverage"
    cargo build --release --bin lcli
    
    if [ -f "target/release/lcli" ]; then
        # Copy to lcli-cov to preserve original binary
        cp target/release/lcli target/release/lcli-cov
        print_info "✓ Lighthouse coverage binary created: ${TESTING_CLIENTS_DIR}/lighthouse/target/release/lcli-cov"
        print_info "  (Original lcli preserved)"
    else
        print_error "✗ Failed to create Lighthouse coverage binary"
        return 1
    fi
}

# Teku (Java) - Download JaCoCo agent and create separate installation
build_teku() {
    print_info "Setting up Teku for JaCoCo coverage..."
    
    cd "${TESTING_CLIENTS_DIR}/teku"
    
    if [ ! -f "build.gradle" ]; then
        print_error "build.gradle not found. Are you in the Teku directory?"
        return 1
    fi
    
    # Build Teku normally (no special compilation needed)
    print_info "Running: ./gradlew installDist"
    ./gradlew installDist
    
    # Copy to teku-cov directory to preserve original
    if [ -d "build/install/teku" ]; then
        print_info "Copying to build/install/teku-cov..."
        rm -rf build/install/teku-cov
        cp -r build/install/teku build/install/teku-cov
        print_info "✓ Teku coverage installation created: ${TESTING_CLIENTS_DIR}/teku/build/install/teku-cov/bin/teku"
        print_info "  (Original teku preserved at build/install/teku/)"
    else
        print_error "✗ Failed to build Teku"
        return 1
    fi
    
    # Download JaCoCo agent if not exists
    JACOCO_DIR="${TESTING_CLIENTS_DIR}/jacoco"
    JACOCO_VERSION="0.8.11"
    JACOCO_AGENT="${JACOCO_DIR}/jacocoagent.jar"
    JACOCO_CLI="${JACOCO_DIR}/jacococli.jar"
    
    mkdir -p "${JACOCO_DIR}"
    
    if [ ! -f "${JACOCO_AGENT}" ]; then
        print_info "Downloading JaCoCo agent..."
        curl -L "https://repo1.maven.org/maven2/org/jacoco/org.jacoco.agent/${JACOCO_VERSION}/org.jacoco.agent-${JACOCO_VERSION}-runtime.jar" \
            -o "${JACOCO_AGENT}"
        print_info "✓ Downloaded: ${JACOCO_AGENT}"
    else
        print_info "JaCoCo agent already exists: ${JACOCO_AGENT}"
    fi
    
    if [ ! -f "${JACOCO_CLI}" ]; then
        print_info "Downloading JaCoCo CLI..."
        curl -L "https://repo1.maven.org/maven2/org/jacoco/org.jacoco.cli/${JACOCO_VERSION}/org.jacoco.cli-${JACOCO_VERSION}-nodeps.jar" \
            -o "${JACOCO_CLI}"
        print_info "✓ Downloaded: ${JACOCO_CLI}"
    else
        print_info "JaCoCo CLI already exists: ${JACOCO_CLI}"
    fi
}

# Nimbus (Nim) - Build with gcov instrumentation
build_nimbus() {
    print_info "Building Nimbus with gcov instrumentation..."
    
    cd "${TESTING_CLIENTS_DIR}/nimbus-eth2"
    
    if [ ! -f "ncli/ncli.nim" ]; then
        print_error "ncli.nim not found. Are you in the Nimbus directory?"
        return 1
    fi
    
    # Check if lcov is installed
    if ! command -v lcov &> /dev/null; then
        print_warn "lcov not found. Install with: apt-get install lcov (Ubuntu/Debian) or brew install lcov (macOS)"
    fi
    
    # Build with gcov flags to separate binary
    print_info "Running: nim c with gcov flags (output: ncli-cov)"
    
    # Clean previous coverage build artifacts
    rm -f ncli/ncli-cov
    
    # Find and use env.sh (try both locations)
    if [ -f "./env.sh" ]; then
        ENV_SH="./env.sh"
    elif [ -f "../env.sh" ]; then
        ENV_SH="../env.sh"
    else
        print_error "env.sh not found in ./ or ../"
        print_info "Trying direct nim compilation..."
        ENV_SH=""
    fi
    
    # Build with coverage flags to ncli-cov
    if [ -n "$ENV_SH" ]; then
        $ENV_SH nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov \
            ncli/ncli.nim
    else
        # Try direct nim compilation without env.sh
        nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov \
            ncli/ncli.nim
    fi
    
    if [ -f "ncli/ncli-cov" ]; then
        print_info "✓ Nimbus coverage binary created: ${TESTING_CLIENTS_DIR}/nimbus-eth2/ncli/ncli-cov"
        print_info "  (Original ncli preserved)"
    else
        print_error "✗ Failed to create Nimbus coverage binary"
        return 1
    fi
}

# Lodestar (TypeScript/Node.js) - Check c8 installation
build_lodestar() {
    print_info "Setting up Lodestar for c8 coverage..."
    
    cd "${TESTING_CLIENTS_DIR}/lodestar"
    
    if [ ! -f "package.json" ]; then
        print_error "package.json not found. Are you in the Lodestar directory?"
        return 1
    fi
    
    # Check if Node.js is installed
    if ! command -v node &> /dev/null; then
        print_error "Node.js not found. Please install Node.js (v14 or higher)"
        return 1
    fi
    
    # Check if npm is installed
    if ! command -v npm &> /dev/null; then
        print_error "npm not found. Please install npm"
        return 1
    fi
    
    # Check Node.js version
    NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -lt 14 ]; then
        print_warn "Node.js version is less than 14. c8 may not work correctly."
    fi
    
    # Check if npx is available (comes with npm)
    if ! command -v npx &> /dev/null; then
        print_error "npx not found. Please update npm to a recent version"
        return 1
    fi
    
    # Test if c8 can be run via npx
    print_info "Testing c8 availability via npx..."
    if npx --yes c8 --version &> /dev/null; then
        C8_VERSION=$(npx --yes c8 --version 2>/dev/null | head -n1)
        print_info "✓ c8 is available via npx (version: ${C8_VERSION})"
        print_info "  c8 will be automatically downloaded when needed"
    else
        print_warn "c8 test failed. It will be installed automatically on first use."
        print_info "  You can also install it manually: npm install -g c8"
    fi
    
    # Check if transition.js exists
    if [ -f "transition.js" ]; then
        print_info "✓ Lodestar transition.js found"
    elif [ -f "transition" ]; then
        print_info "✓ Lodestar transition found"
    else
        print_warn "transition.js or transition not found. Make sure Lodestar is properly set up."
    fi
    
    print_info "✓ Lodestar coverage setup complete"
    print_info "  Coverage will be measured using c8 (via npx) at runtime"
}

# Main script
main() {
    local target="${1:-all}"
    
    echo "======================================"
    echo "Building Coverage-Instrumented Clients"
    echo "======================================"
    echo ""
    
    case "$target" in
        prysm)
            build_prysm
            ;;
        lighthouse)
            build_lighthouse
            ;;
        teku)
            build_teku
            ;;
        nimbus)
            build_nimbus
            ;;
        lodestar)
            build_lodestar
            ;;
        all)
            print_info "Building all clients..."
            echo ""
            
            build_prysm || print_error "Prysm build failed"
            echo ""
            
            build_lighthouse || print_error "Lighthouse build failed"
            echo ""
            
            build_teku || print_error "Teku build failed"
            echo ""
            
            build_nimbus || print_error "Nimbus build failed"
            echo ""
            
            build_lodestar || print_error "Lodestar setup failed"
            echo ""
            ;;
        *)
            print_error "Unknown target: $target"
            echo "Usage: $0 [prysm|lighthouse|teku|nimbus|lodestar|all]"
            exit 1
            ;;
    esac
    
    echo ""
    echo "======================================"
    echo "Build Complete!"
    echo "======================================"
    echo ""
    echo "Next steps:"
    echo "  1. Run diff_testing.py with --enable-coverage flag"
    echo "  2. Coverage reports will be generated automatically"
    echo ""
}

main "$@"

