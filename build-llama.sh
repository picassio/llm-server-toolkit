#!/usr/bin/env bash
# Clone and build llama.cpp (or turboquant fork) with CUDA support
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

echo "=== Build llama.cpp with CUDA ==="

# Find CUDA (using nullglob-safe helper)
CUDA_PATH=""
CUDA_PATH=$(find_cuda_path) || true
if [[ -z "$CUDA_PATH" ]]; then
    log_error "CUDA toolkit not found. Run setup-cuda.sh first."
    exit 1
fi
export PATH="$CUDA_PATH:$PATH"
log_info "Using CUDA: $(nvcc --version | grep release)"

# Check cmake version
CMAKE_MIN_VERSION="3.18"
if command -v cmake &>/dev/null; then
    CMAKE_VERSION=$(cmake --version | head -1 | grep -oP '\d+\.\d+(\.\d+)?')
    CMAKE_MAJOR=$(echo "$CMAKE_VERSION" | cut -d. -f1)
    CMAKE_MINOR=$(echo "$CMAKE_VERSION" | cut -d. -f2)
    MIN_MAJOR=$(echo "$CMAKE_MIN_VERSION" | cut -d. -f1)
    MIN_MINOR=$(echo "$CMAKE_MIN_VERSION" | cut -d. -f2)
    if [[ "$CMAKE_MAJOR" -lt "$MIN_MAJOR" ]] || { [[ "$CMAKE_MAJOR" -eq "$MIN_MAJOR" ]] && [[ "$CMAKE_MINOR" -lt "$MIN_MINOR" ]]; }; then
        log_error "cmake $CMAKE_VERSION is too old. Need >= $CMAKE_MIN_VERSION for CUDA support."
        log_info "Install newer cmake: sudo apt-get install -y cmake or use pip install cmake"
        exit 1
    fi
    log_info "cmake version: $CMAKE_VERSION"
else
    log_info "cmake not found — will install"
fi

# Check sudo access upfront (for apt-get installs)
if ! command -v cmake &>/dev/null || ! command -v g++ &>/dev/null; then
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access needed to install build dependencies (cmake, build-essential)"
        sudo true || { log_error "Cannot get sudo access. Install cmake and g++ manually."; exit 1; }
    fi
fi

# Ask for repo
echo ""
echo "Repository options:"
echo "  1) Upstream llama.cpp (recommended — supports all models incl. Gemma 4)"
echo "  2) Turboquant fork (adds turbo2/turbo3 KV cache types)"
echo "  3) Custom URL"
read -r -p "Select repository [1]: " REPO_CHOICE
REPO_CHOICE="${REPO_CHOICE:-1}"

case "$REPO_CHOICE" in
    1)
        DEFAULT_REPO="https://github.com/ggml-org/llama.cpp"
        DEFAULT_BRANCH="master"
        ;;
    2)
        DEFAULT_REPO="https://github.com/spiritbuun/llama-cpp-turboquant-cuda"
        DEFAULT_BRANCH="feature/turboquant-kv-cache"
        ;;
    3)
        read -r -p "Git repository URL: " DEFAULT_REPO
        DEFAULT_BRANCH="master"
        if [[ -z "$DEFAULT_REPO" ]]; then
            log_error "Repository URL is required."
            exit 1
        fi
        ;;
    *)
        log_error "Invalid choice: $REPO_CHOICE"
        exit 1
        ;;
esac

REPO_URL="$DEFAULT_REPO"
log_info "Repository: $REPO_URL"

# Ask for install directory
DEFAULT_DIR="$HOME/$(basename "$REPO_URL" .git)"
read -r -p "Install directory [$DEFAULT_DIR]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"

# Ask for branch
read -r -p "Branch [$DEFAULT_BRANCH]: " BRANCH
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

# Install build deps
echo ""
log_step "[1/4] Checking build dependencies..."
command -v cmake &>/dev/null || { log_info "Installing cmake..."; sudo apt-get install -y cmake; }
command -v g++ &>/dev/null || { log_info "Installing build-essential..."; sudo apt-get install -y build-essential; }
require_command cmake
require_command g++

# Clone or update
if [[ ! -d "$INSTALL_DIR" ]]; then
    log_step "[2/4] Cloning $REPO_URL..."
    if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
        log_error "git clone failed. Check the repository URL."
        exit 1
    fi
else
    log_step "[2/4] Repository already exists at $INSTALL_DIR"
    if confirm "Pull latest changes?" "Y"; then
        git -C "$INSTALL_DIR" fetch --all
    fi
fi

cd "$INSTALL_DIR"
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null || log_warn "Using current branch: $(git branch --show-current)"

# Detect GPU architecture — build cmake args as array
CMAKE_ARGS=(-B build -DGGML_CUDA=ON -DGGML_NATIVE=ON)

GPU_ARCH=$(detect_gpu_arch)
if [[ -n "$GPU_ARCH" ]]; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    log_info "[3/4] Detected GPU: $GPU_NAME (SM $GPU_ARCH)"
    CMAKE_ARGS+=("-DCMAKE_CUDA_ARCHITECTURES=$GPU_ARCH")
else
    log_warn "[3/4] Could not detect GPU arch, using cmake defaults"
fi

# Build with retry logic
log_step "[4/4] Building..."
MAX_RETRIES=2
BUILD_SUCCESS=false

for attempt in $(seq 0 "$MAX_RETRIES"); do
    if [[ "$attempt" -gt 0 ]]; then
        log_warn "Build attempt $((attempt + 1)) of $((MAX_RETRIES + 1))..."
        sleep 2
    fi

    # Clean build directory
    if [[ -d build ]]; then
        if [[ "$attempt" -eq 0 ]]; then
            log_info "Removing existing build directory..."
        fi
        rm -rf build
    fi

    # Configure
    if ! cmake "${CMAKE_ARGS[@]}"; then
        log_warn "cmake configuration failed"
        continue
    fi

    # Build
    if cmake --build build --config Release -j"$(nproc)"; then
        BUILD_SUCCESS=true
        break
    else
        log_warn "Build failed (attempt $((attempt + 1)))"
    fi
done

if [[ "$BUILD_SUCCESS" != true ]]; then
    log_error "Build failed after $((MAX_RETRIES + 1)) attempts."
    log_error "Check the build output above for errors."
    log_info "Common fixes:"
    log_info "  - Ensure CUDA toolkit version matches your driver"
    log_info "  - Try: sudo apt-get install -y build-essential cmake"
    exit 1
fi

# Verify
echo ""
if [[ -f build/bin/llama-server ]]; then
    log_success "=== Build successful ==="
    echo "Server: $INSTALL_DIR/build/bin/llama-server"
    echo "Bench:  $INSTALL_DIR/build/bin/llama-bench"
    echo "CLI:    $INSTALL_DIR/build/bin/llama-cli"
else
    log_error "Build completed but llama-server binary not found"
    exit 1
fi
