#!/usr/bin/env bash
# Setup NVIDIA driver with DKMS so it survives kernel upgrades
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

echo "=== NVIDIA Driver Setup ==="

# Must run as root
require_root

# Check if driver is already working
if nvidia-smi &>/dev/null; then
    log_success "NVIDIA driver is already installed and working:"
    nvidia-smi | head -4
    echo ""

    # Check DKMS
    if command -v dkms &>/dev/null && dkms status 2>/dev/null | grep -q nvidia; then
        log_success "DKMS is configured - driver will survive kernel upgrades"
    else
        log_warn "DKMS not configured. Driver may break after kernel upgrade."
        if confirm "Install DKMS support?" "Y"; then
            apt-get install -y dkms
            log_success "DKMS installed. Re-run the NVIDIA installer with --dkms to register."
        fi
    fi
    exit 0
fi

log_info "NVIDIA driver not detected. Installing..."
echo ""

# Detect GPU — check lspci availability first
if command -v lspci &>/dev/null; then
    GPU_INFO=$(lspci | grep -i nvidia | head -1)
    if [[ -n "$GPU_INFO" ]]; then
        log_info "Detected GPU: $GPU_INFO"
    else
        log_warn "No NVIDIA GPU detected via lspci. Proceeding anyway..."
    fi
else
    log_warn "lspci not available. Cannot detect GPU. Install pciutils if needed."
fi
echo ""

# Kernel version compatibility check
KERNEL_VERSION="$(uname -r)"
log_info "Running kernel: $KERNEL_VERSION"
if [[ ! -d "/lib/modules/$KERNEL_VERSION/build" ]] && [[ ! -d "/usr/src/linux-headers-$KERNEL_VERSION" ]]; then
    log_warn "Kernel headers for $KERNEL_VERSION not found. They will be installed."
fi

# Ask for driver version with validation
read -r -p "NVIDIA driver version to install [570.144]: " DRIVER_VERSION
DRIVER_VERSION="${DRIVER_VERSION:-570.144}"

# Validate driver version format
if [[ ! "$DRIVER_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "Invalid driver version format: '$DRIVER_VERSION'. Expected format: NNN.NN or NNN.NN.NN"
    exit 1
fi

DRIVER_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
DRIVER_FILE=$(make_temp "-NVIDIA-${DRIVER_VERSION}.run")

# Install DKMS first
log_step "[1/4] Installing DKMS and build tools..."
apt-get update -qq
apt-get install -y dkms build-essential "linux-headers-$(uname -r)"

# Download driver
log_step "[2/4] Downloading NVIDIA driver $DRIVER_VERSION..."
if wget -q --show-progress "$DRIVER_URL" -O "$DRIVER_FILE"; then
    chmod +x "$DRIVER_FILE"
    log_success "Driver downloaded: $DRIVER_FILE"
else
    log_error "Failed to download driver from $DRIVER_URL"
    log_error "Check that driver version $DRIVER_VERSION exists."
    exit 1
fi

# Verify download integrity (file size check — .run files are typically >100MB)
FILE_SIZE=$(stat --printf="%s" "$DRIVER_FILE")
if [[ "$FILE_SIZE" -lt 1000000 ]]; then
    log_error "Downloaded file is suspiciously small ($(format_file_size "$DRIVER_FILE")). Download may be corrupted."
    exit 1
fi
log_info "Download size: $(format_file_size "$DRIVER_FILE")"

# Install driver — capture output for debugging
log_step "[3/4] Installing NVIDIA driver with DKMS..."
INSTALL_LOG=$(make_temp "-nvidia-install.log")
if bash "$DRIVER_FILE" --dkms --silent 2>&1 | tee "$INSTALL_LOG"; then
    log_success "Driver installation completed"
else
    log_error "Driver installation failed. Log output:"
    tail -20 "$INSTALL_LOG"
    log_error "Full log: $INSTALL_LOG"
    exit 1
fi

# Verify
log_step "[4/4] Verifying installation..."
if nvidia-smi; then
    echo ""
    dkms status | grep nvidia || true
    log_success "NVIDIA driver installed successfully"
else
    log_error "nvidia-smi failed after installation. A reboot may be required."
    exit 1
fi

# Blacklist kernel auto-upgrades
UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "$UNATTENDED_CONF" ]]; then
    # Use a more flexible pattern to match the commented-out linux line
    if grep -qE '^\s*//\s*"linux-"' "$UNATTENDED_CONF"; then
        if confirm "Blacklist kernel auto-upgrades in unattended-upgrades?" "Y"; then
            if sed -i 's|^\(\s*\)//\(\s*"linux-"\)|\1\2|' "$UNATTENDED_CONF"; then
                log_success "Kernel packages blacklisted in unattended-upgrades"
            else
                log_warn "Could not modify $UNATTENDED_CONF — edit manually if needed."
            fi
        fi
    fi
fi

echo ""
echo "=== Done ==="
