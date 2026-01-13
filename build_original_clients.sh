#!/bin/bash
# 
# Ethereum Consensus Clients - Original Build Script
# 
# 
# Usage:
#   ./build_original_clients.sh [client_name]
#   
#   client_name: prysm, lighthouse, teku, nimbus, lodestar, all (default: all)
#
# Note : This script is used to build the original clients without coverage instrumentation.

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

# Prysm (Go) - Build using go build (no coverage instrumentation)
build_prysm() {
    print_info "Building Prysm (original binary, no coverage)..."
    
    cd "${TESTING_CLIENTS_DIR}/prysm"
    
    if [ ! -f "go.mod" ]; then
        print_error "go.mod not found. Are you in the Prysm directory?"
        return 1
    fi
    
    # Build pcli without coverage support (using go build, same as build_coverage_clients.sh but without -cover)
    print_info "Running: go build -o bazel-bin/tools/pcli/pcli_/pcli ./tools/pcli"
    
    # Create directory structure for expected path
    mkdir -p bazel-bin/tools/pcli/pcli_
    
    go build -o bazel-bin/tools/pcli/pcli_/pcli ./tools/pcli
    
    if [ -f "bazel-bin/tools/pcli/pcli_/pcli" ]; then
        print_info "✓ Prysm binary created: ${TESTING_CLIENTS_DIR}/prysm/bazel-bin/tools/pcli/pcli_/pcli"
    else
        print_error "✗ Failed to create Prysm binary"
        return 1
    fi
}

# Lighthouse (Rust) - Build without coverage instrumentation
build_lighthouse() {
    print_info "Building Lighthouse (original binary, no coverage)..."
    
    cd "${TESTING_CLIENTS_DIR}/lighthouse"
    
    if [ ! -f "Cargo.toml" ]; then
        print_error "Cargo.toml not found. Are you in the Lighthouse directory?"
        return 1
    fi
    
    # Build without coverage instrumentation
    print_info "Running: cargo build --release --bin lcli"
    unset RUSTFLAGS  # Ensure no coverage flags
    cargo build --release --bin lcli
    
    if [ -f "target/release/lcli" ]; then
        print_info "✓ Lighthouse binary created: ${TESTING_CLIENTS_DIR}/lighthouse/target/release/lcli"
    else
        print_error "✗ Failed to create Lighthouse binary"
        return 1
    fi
}

# Teku (Java) - Build without coverage setup
build_teku() {
    print_info "Building Teku (original binary, no coverage)..."
    
    cd "${TESTING_CLIENTS_DIR}/teku"
    
    if [ ! -f "build.gradle" ]; then
        print_error "build.gradle not found. Are you in the Teku directory?"
        return 1
    fi
    
    # Build Teku normally
    print_info "Running: ./gradlew installDist"
    ./gradlew installDist
    
    if [ -d "build/install/teku" ]; then
        print_info "✓ Teku installation created: ${TESTING_CLIENTS_DIR}/teku/build/install/teku/bin/teku"
    else
        print_error "✗ Failed to build Teku"
        return 1
    fi
}

# Nimbus (Nim) - Build without coverage instrumentation
build_nimbus() {
    print_info "Building Nimbus (original binary, no coverage)..."
    
    cd "${TESTING_CLIENTS_DIR}/nimbus-eth2"
    
    if [ ! -f "ncli/ncli.nim" ]; then
        print_error "ncli.nim not found. Are you in the Nimbus directory?"
        return 1
    fi
    
    # Build without gcov flags
    print_info "Running: nim c (output: ncli)"
    
    # Clean previous build artifacts
    rm -f ncli/ncli
    
    # Find and use env.sh (try both locations)
    if [ -f "./env.sh" ]; then
        ENV_SH="./env.sh"
    elif [ -f "../env.sh" ]; then
        ENV_SH="../env.sh"
    else
        print_warn "env.sh not found in ./ or ../"
        print_info "Trying direct nim compilation..."
        ENV_SH=""
    fi
    
    # Build without coverage flags to ncli
    if [ -n "$ENV_SH" ]; then
        $ENV_SH nim c -d:const_preset=mainnet \
            -o:ncli/ncli \
            ncli/ncli.nim
    else
        # Try direct nim compilation without env.sh
        nim c -d:const_preset=mainnet \
            -o:ncli/ncli \
            ncli/ncli.nim
    fi
    
    if [ -f "ncli/ncli" ]; then
        print_info "✓ Nimbus binary created: ${TESTING_CLIENTS_DIR}/nimbus-eth2/ncli/ncli"
    else
        print_error "✗ Failed to create Nimbus binary"
        return 1
    fi
}

# Lodestar (TypeScript/Node.js) - No build needed, just verify setup
build_lodestar() {
    print_info "Checking Lodestar setup..."
    
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
    
    # Check if transition.js exists
    if [ -f "transition.js" ]; then
        print_info "✓ Lodestar transition.js found"
    elif [ -f "transition" ]; then
        print_info "✓ Lodestar transition found"
    else
        print_warn "transition.js or transition not found. Make sure Lodestar is properly set up."
    fi
    
    print_info "✓ Lodestar setup verified (no build needed for Node.js)"
}

# Main script
main() {
    local target="all"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            prysm|lighthouse|teku|nimbus|lodestar|all)
                target="$1"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Usage: $0 [prysm|lighthouse|teku|nimbus|lodestar|all]"
                exit 1
                ;;
        esac
    done
    
    echo "======================================"
    echo "Building Original Clients (No Coverage)"
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
    echo "  1. Run diff_testing.py without --enable-coverage flag"
    echo "  2. These binaries will be used for regular testing"
    echo ""
}

main "$@"
