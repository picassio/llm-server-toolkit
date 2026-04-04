#!/usr/bin/env bash
# Shared helper library for LLM Server Toolkit
# Source this file: source "$(dirname "$0")/lib/common.sh"

# Prevent double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ─── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ─── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}${BOLD}$*${NC}"; }

# ─── Error Handling ────────────────────────────────────────────────────────────
# Usage: call setup_traps at the top of your script after sourcing common.sh
# Override cleanup_on_exit() in your script for custom cleanup
_TEMP_FILES=()

register_temp_file() {
    _TEMP_FILES+=("$1")
}

_default_cleanup() {
    local exit_code=$?
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
    # Call script-specific cleanup if defined
    if declare -F cleanup_on_exit &>/dev/null; then
        cleanup_on_exit
    fi
    return "$exit_code"
}

_error_handler() {
    local exit_code=$?
    local line_no=$1
    log_error "Command failed at line $line_no (exit code: $exit_code)"
    exit "$exit_code"
}

setup_traps() {
    trap _default_cleanup EXIT
    trap '_error_handler ${LINENO}' ERR
    trap 'log_warn "Interrupted"; exit 130' INT TERM
}

# ─── Validation ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        if [[ -n "$install_hint" ]]; then
            log_error "'$cmd' not found. Install with: $install_hint"
        else
            log_error "'$cmd' not found. Please install it first."
        fi
        exit 1
    fi
}

validate_numeric() {
    local value="$1"
    local name="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name must be a positive integer, got: '$value'"
        return 1
    fi
}

validate_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="$4"
    if [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        log_error "$name must be between $min and $max, got: $value"
        return 1
    fi
}

# ─── Confirmation Prompts ──────────────────────────────────────────────────────
# confirm "message" [default Y/N]
# Returns 0 for yes, 1 for no
confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local reply

    if [[ "$default" =~ ^[Yy] ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "$prompt" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ─── GPU Detection ─────────────────────────────────────────────────────────────
detect_gpu_info() {
    if ! command -v lspci &>/dev/null; then
        log_warn "lspci not found — cannot detect GPU via PCI bus"
        return 1
    fi
    lspci | grep -i nvidia | head -1
}

detect_gpu_count() {
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l
}

detect_gpu_names() {
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null
}

detect_gpu_arch() {
    nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.'
}

# ─── Path Finding ──────────────────────────────────────────────────────────────
find_cuda_path() {
    # Check PATH first
    local nvcc_path
    nvcc_path=$(command -v nvcc 2>/dev/null)
    if [[ -n "$nvcc_path" ]]; then
        dirname "$nvcc_path"
        return 0
    fi
    # Search common locations with nullglob
    local old_nullglob
    old_nullglob=$(shopt -p nullglob 2>/dev/null || true)
    shopt -s nullglob
    local dirs=(/usr/local/cuda/bin /usr/local/cuda-*/bin)
    eval "$old_nullglob" 2>/dev/null || true
    for p in "${dirs[@]}"; do
        if [[ -f "$p/nvcc" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

find_server_bin() {
    # Prefer upstream llama.cpp (supports more architectures like Gemma 4)
    # then fall back to turboquant fork
    for dir in "$HOME/llama.cpp" "$HOME/llama-cpp-turboquant-cuda"; do
        if [[ -f "$dir/build/bin/llama-server" ]]; then
            echo "$dir/build/bin/llama-server"
            return 0
        fi
    done
    return 1
}

find_bench_bin() {
    for dir in "$HOME/llama.cpp" "$HOME/llama-cpp-turboquant-cuda"; do
        if [[ -f "$dir/build/bin/llama-bench" ]]; then
            echo "$dir/build/bin/llama-bench"
            return 0
        fi
    done
    return 1
}

find_models() {
    # Search common model directories and home
    find "$HOME/models" "$HOME/llama.cpp/models" "$HOME/llama-cpp-turboquant-cuda/models" "$HOME" \
        -maxdepth 3 -name "*.gguf" -size +100M 2>/dev/null | grep -v vocab | sort -u
}

# ─── HuggingFace Token Paths ──────────────────────────────────────────────────
find_hf_token_file() {
    local candidates=(
        "${HF_HOME:-$HOME/.cache/huggingface}/token"
        "${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/token"
        "$HOME/.cache/huggingface/token"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" && -s "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# ─── Disk Space ────────────────────────────────────────────────────────────────
get_avail_gb() {
    local path="${1:-.}"
    df --output=avail "$path" | tail -1 | awk '{printf "%.0f", $1/1024/1024}'
}

get_disk_status() {
    df -h / | tail -1 | awk '{print $3" used / "$2" total ("$5" full), "$4" free"}'
}

# ─── Temp File Creation ───────────────────────────────────────────────────────
make_temp() {
    local suffix="${1:-.tmp}"
    local tmp
    tmp=$(mktemp "/tmp/llm-toolkit-XXXXXX${suffix}")
    register_temp_file "$tmp"
    echo "$tmp"
}

# ─── Model Size Display ───────────────────────────────────────────────────────
format_file_size() {
    local file="$1"
    if [[ -f "$file" ]]; then
        stat --printf="%s" "$file" | awk '{
            if ($1 >= 1073741824) printf "%.1fGB", $1/1073741824
            else if ($1 >= 1048576) printf "%.0fMB", $1/1048576
            else printf "%.0fKB", $1/1024
        }'
    fi
}

file_size_gb() {
    local file="$1"
    if [[ -f "$file" ]]; then
        stat --printf="%s" "$file" | awk '{printf "%.0f", $1/1073741824}'
    else
        echo "0"
    fi
}

# ─── Host IP Detection ─────────────────────────────────────────────────────────
get_host_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ─── New API Helpers ───────────────────────────────────────────────────────────
get_new_api_port() {
    local compose_file="${HOME}/new-api/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        grep -oP '^\s+-\s+"\K[0-9]+(?=:3000")' "$compose_file" 2>/dev/null || echo "3000"
    else
        echo "3000"
    fi
}

is_new_api_running() {
    local port
    port=$(get_new_api_port)
    curl -sf "http://127.0.0.1:${port}/api/status" &>/dev/null
}
