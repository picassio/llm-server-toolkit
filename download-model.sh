#!/usr/bin/env bash
# Download GGUF models from HuggingFace
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

echo "=== Model Downloader ==="

# Find the HF CLI command — could be 'hf' (uv install) or 'huggingface-cli' (pip install)
HF_CMD=""
if command -v hf &>/dev/null; then
    HF_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    HF_CMD="huggingface-cli"
fi

if [[ -z "$HF_CMD" ]]; then
    log_info "HuggingFace CLI not found. Installing..."
    if command -v uv &>/dev/null; then
        log_info "Installing via uv..."
        uv tool install "huggingface_hub[hf_xet]"
        # uv installs 'hf' command
        HF_CMD="hf"
    elif command -v pip &>/dev/null; then
        log_info "Installing via pip..."
        pip install -q 'huggingface_hub[cli]'
        HF_CMD="huggingface-cli"
    else
        log_error "No package manager found. Install uv or pip first."
        exit 1
    fi

    # Verify installation worked
    if ! command -v "$HF_CMD" &>/dev/null; then
        log_error "Installation succeeded but '$HF_CMD' command not found in PATH."
        log_info "You may need to add pip's bin directory to your PATH:"
        log_info "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        exit 1
    fi
fi

log_info "Using HF CLI: $HF_CMD"

# Check HF login — check multiple possible token locations
HF_TOKEN_FILE=""
HF_TOKEN_FILE=$(find_hf_token_file) || true

if [[ -z "$HF_TOKEN_FILE" ]]; then
    echo ""
    log_info "Not logged in to HuggingFace."
    read -r -p "Enter your HuggingFace token (leave empty to skip, get one at https://huggingface.co/settings/tokens): " HF_TOKEN
    if [[ -n "$HF_TOKEN" ]]; then
        # Use environment variable to avoid exposing token in process list
        export HF_TOKEN
        if "$HF_CMD" auth login --token "$HF_TOKEN"; then
            log_success "Logged in to HuggingFace"
        else
            log_warn "Login failed — some models may require authentication."
        fi
        unset HF_TOKEN
    else
        log_info "Skipping login — some models may require authentication."
    fi
else
    log_success "HuggingFace: logged in (token at $HF_TOKEN_FILE)"
fi

# Ask for download directory
DEFAULT_DIR="$HOME/models"
read -r -p "Download directory [$DEFAULT_DIR]: " MODELS_DIR
MODELS_DIR="${MODELS_DIR:-$DEFAULT_DIR}"
mkdir -p "$MODELS_DIR"

# Model selection
echo ""
echo "=== Model Families ==="
echo "  A) Qwen3.5-27B (text-only, fast, great coding)"
echo "  B) Gemma-4-26B-A4B (multimodal MoE, 4B active params, efficient)"
echo "  C) Custom (enter repo and filename manually)"
echo ""
read -r -p "Select model family [A]: " FAMILY
FAMILY="${FAMILY:-A}"
FAMILY=$(echo "$FAMILY" | tr '[:lower:]' '[:upper:]')

# Expected sizes for disk space validation (in GB, approximate)
EXPECTED_SIZE_GB=0
HF_REPO=""
FILENAME=""

case "$FAMILY" in
    A)
        echo ""
        echo "Qwen3.5-27B GGUF models:"
        echo "  1) UD-Q4_K_XL  (~17GB, fits single 24GB GPU, recommended)"
        echo "  2) UD-Q6_K_XL  (~24GB, needs 2x GPU or 48GB+ VRAM)"
        echo "  3) UD-Q3_K_XL  (~14GB, fits single 16GB GPU)"
        echo "  4) Q8_0        (~30GB, highest quality GGUF)"
        echo ""
        read -r -p "Select quantization [1]: " CHOICE
        CHOICE="${CHOICE:-1}"
        case "$CHOICE" in
            1) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q4_K_XL.gguf"; EXPECTED_SIZE_GB=17 ;;
            2) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q6_K_XL.gguf"; EXPECTED_SIZE_GB=24 ;;
            3) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q3_K_XL.gguf"; EXPECTED_SIZE_GB=14 ;;
            4) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-Q8_0.gguf"; EXPECTED_SIZE_GB=30 ;;
            *) log_error "Invalid choice: $CHOICE"; exit 1 ;;
        esac
        ;;
    B)
        echo ""
        echo "Gemma-4-26B-A4B-it GGUF models (MoE: 26B total, 4B active):"
        echo "  1) UD-Q4_K_XL  (~17GB, fits single 24GB GPU, recommended)"
        echo "  2) Q8_0        (~27GB, highest quality, needs 2x GPU)"
        echo "  3) UD-Q6_K_XL  (~22GB, great quality, fits single 24GB GPU)"
        echo "  4) UD-Q3_K_XL  (~13GB, fits single 16GB GPU)"
        echo "  5) UD-Q8_K_XL  (~28GB, near-lossless, needs 2x GPU)"
        echo ""
        read -r -p "Select quantization [1]: " CHOICE
        CHOICE="${CHOICE:-1}"
        case "$CHOICE" in
            1) HF_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"; FILENAME="gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf"; EXPECTED_SIZE_GB=17 ;;
            2) HF_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"; FILENAME="gemma-4-26B-A4B-it-Q8_0.gguf"; EXPECTED_SIZE_GB=27 ;;
            3) HF_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"; FILENAME="gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf"; EXPECTED_SIZE_GB=22 ;;
            4) HF_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"; FILENAME="gemma-4-26B-A4B-it-UD-Q3_K_XL.gguf"; EXPECTED_SIZE_GB=13 ;;
            5) HF_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"; FILENAME="gemma-4-26B-A4B-it-UD-Q8_K_XL.gguf"; EXPECTED_SIZE_GB=28 ;;
            *) log_error "Invalid choice: $CHOICE"; exit 1 ;;
        esac
        ;;
    C)
        read -r -p "HuggingFace repo (e.g. unsloth/Qwen3.5-27B-GGUF): " HF_REPO
        read -r -p "Filename (e.g. Qwen3.5-27B-UD-Q4_K_XL.gguf): " FILENAME
        if [[ -z "$HF_REPO" || -z "$FILENAME" ]]; then
            log_error "Repo and filename are required."
            exit 1
        fi
        ;;
    *)
        log_error "Invalid choice: $CHOICE"
        exit 1
        ;;
esac

echo ""
log_info "Downloading: $HF_REPO / $FILENAME"
log_info "Destination: $MODELS_DIR/"
echo ""

if [[ -f "$MODELS_DIR/$FILENAME" ]]; then
    EXISTING_SIZE=$(format_file_size "$MODELS_DIR/$FILENAME")
    log_info "File already exists: $MODELS_DIR/$FILENAME ($EXISTING_SIZE)"
    if ! confirm "Re-download?" "N"; then
        log_info "Skipping download."
        exit 0
    fi
fi

# Check disk space
AVAIL_GB=$(get_avail_gb "$MODELS_DIR")
log_info "Available disk space: ${AVAIL_GB}GB"

if [[ "$EXPECTED_SIZE_GB" -gt 0 && "$AVAIL_GB" -lt "$EXPECTED_SIZE_GB" ]]; then
    log_error "Insufficient disk space! Need ~${EXPECTED_SIZE_GB}GB, have ${AVAIL_GB}GB available."
    log_info "Free up space with: bash cleanup.sh"
    exit 1
elif [[ "$EXPECTED_SIZE_GB" -gt 0 && "$AVAIL_GB" -lt $((EXPECTED_SIZE_GB + 5)) ]]; then
    log_warn "Low disk space. Model needs ~${EXPECTED_SIZE_GB}GB, you have ${AVAIL_GB}GB."
    if ! confirm "Continue anyway?" "N"; then
        exit 1
    fi
fi

# Download with resume support
log_step "Starting download..."
log_info "Note: hf download supports automatic resume if interrupted."
echo ""

if "$HF_CMD" download "$HF_REPO" "$FILENAME" --local-dir "$MODELS_DIR"; then
    echo ""
    log_success "=== Download complete ==="
    FINAL_SIZE=$(format_file_size "$MODELS_DIR/$FILENAME")
    echo "  File: $MODELS_DIR/$FILENAME"
    echo "  Size: $FINAL_SIZE"

    # Verify the file is a valid GGUF (check magic bytes)
    if command -v xxd &>/dev/null; then
        MAGIC=$(xxd -l 4 -p "$MODELS_DIR/$FILENAME" 2>/dev/null || true)
        if [[ "$MAGIC" == "47475546" ]]; then
            log_success "GGUF file verification: valid magic bytes"
        else
            log_warn "File does not have GGUF magic bytes — may be corrupted or not a GGUF file"
        fi
    fi
else
    log_error "Download failed. You can retry — partial downloads will be resumed automatically."
    exit 1
fi
