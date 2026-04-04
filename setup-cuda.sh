#!/usr/bin/env bash
# Install CUDA toolkit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

echo "=== CUDA Toolkit Setup ==="

# Must run as root
require_root

# Check if already installed (search common paths too, using nullglob)
NVCC_BIN=""
NVCC_BIN=$(command -v nvcc 2>/dev/null || true)
if [[ -z "$NVCC_BIN" ]]; then
    NVCC_BIN=$(find_cuda_path 2>/dev/null || true)
    if [[ -n "$NVCC_BIN" ]]; then
        NVCC_BIN="$NVCC_BIN/nvcc"
    fi
fi

if [[ -n "$NVCC_BIN" && -f "$NVCC_BIN" ]]; then
    log_success "CUDA toolkit already installed:"
    "$NVCC_BIN" --version | grep -E 'release|Build'
    exit 0
fi

# Detect driver CUDA version
DRIVER_CUDA=""
if nvidia-smi &>/dev/null; then
    DRIVER_CUDA=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}')
    log_info "Driver supports CUDA: $DRIVER_CUDA"
else
    log_warn "nvidia-smi not found. Install NVIDIA driver first (setup-nvidia.sh)."
fi

# Detect OS
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null || true
OS_ID="${ID:-ubuntu}"
OS_VERSION="${VERSION_ID:-22.04}"
log_info "OS: $OS_ID $OS_VERSION"

# Detect architecture
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) ARCH_URL="x86_64" ;;
    arm64|aarch64) ARCH_URL="sbsa" ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac
log_info "Architecture: $ARCH ($ARCH_URL)"

# Ask for CUDA version
DEFAULT_CUDA="${DRIVER_CUDA:-12.8}"
# Only keep major.minor (strip any patch version)
DEFAULT_CUDA=$(echo "$DEFAULT_CUDA" | grep -oP '^\d+\.\d+' || echo "$DEFAULT_CUDA")

read -r -p "CUDA toolkit version to install [$DEFAULT_CUDA]: " CUDA_VERSION
CUDA_VERSION="${CUDA_VERSION:-$DEFAULT_CUDA}"

# Validate CUDA version format (major.minor only)
if [[ ! "$CUDA_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid CUDA version format: '$CUDA_VERSION'. Expected format: major.minor (e.g., 12.8)"
    exit 1
fi

# Replace ALL dots with dashes for package name
CUDA_PKG="${CUDA_VERSION//./-}"

echo ""
log_step "[1/3] Adding CUDA repository..."
DISTRO="${OS_ID}${OS_VERSION//./}"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/${ARCH_URL}/cuda-keyring_1.1-1_all.deb"

log_info "Keyring URL: $KEYRING_URL"
KEYRING_FILE=$(make_temp "-cuda-keyring.deb")

if ! wget -q "$KEYRING_URL" -O "$KEYRING_FILE"; then
    log_error "Failed to download CUDA keyring from: $KEYRING_URL"
    log_error "Check that your OS ($OS_ID $OS_VERSION) and architecture ($ARCH_URL) are supported."
    exit 1
fi

# Verify the download is a real .deb file
if ! dpkg-deb --info "$KEYRING_FILE" &>/dev/null; then
    log_error "Downloaded keyring file is not a valid .deb package. URL may be wrong."
    exit 1
fi

dpkg -i "$KEYRING_FILE"
apt-get update -qq

log_step "[2/3] Installing cuda-toolkit-${CUDA_PKG}..."
if ! apt-get install -y "cuda-toolkit-${CUDA_PKG}"; then
    log_error "Failed to install cuda-toolkit-${CUDA_PKG}"
    log_error "Available CUDA toolkit versions:"
    apt-cache search 'cuda-toolkit-[0-9]' 2>/dev/null | head -10 || true
    exit 1
fi

log_step "[3/3] Verifying..."
export PATH="/usr/local/cuda-${CUDA_VERSION}/bin:$PATH"
if nvcc --version; then
    log_success "CUDA toolkit installed successfully"
else
    log_error "nvcc verification failed"
    exit 1
fi

# Offer to configure PATH and LD_LIBRARY_PATH persistently
echo ""
PROFILE_LINE_PATH="export PATH=/usr/local/cuda-${CUDA_VERSION}/bin:\$PATH"
PROFILE_LINE_LD="export LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_VERSION}/lib64:\${LD_LIBRARY_PATH:-}"
PROFILE_FILE="/etc/profile.d/cuda.sh"

if confirm "Add CUDA to system PATH (writes to $PROFILE_FILE)?" "Y"; then
    {
        echo "# CUDA ${CUDA_VERSION} environment"
        echo "$PROFILE_LINE_PATH"
        echo "$PROFILE_LINE_LD"
    } > "$PROFILE_FILE"
    chmod +r "$PROFILE_FILE"
    log_success "CUDA paths written to $PROFILE_FILE"
    log_info "Run 'source $PROFILE_FILE' or log out/in to apply."
else
    echo ""
    log_info "Add to your shell profile manually:"
    echo "  $PROFILE_LINE_PATH"
    echo "  $PROFILE_LINE_LD"
fi

echo ""
echo "=== Done ==="
