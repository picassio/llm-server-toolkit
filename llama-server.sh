#!/usr/bin/env bash
# Start/stop/manage llama-server via tmux or systemd
# Supports both inference (chat) and embedding modes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

# ─── Server role config ───────────────────────────────────────────────────────
# These get set based on --embedding flag
SERVER_ROLE=""  # "inference" or "embedding"

set_role() {
    local role="${1:-inference}"
    SERVER_ROLE="$role"
    if [[ "$role" == "embedding" ]]; then
        TMUX_SESSION="llama-embed"
        SERVICE_NAME="llama-embedding"
        PORT_FILE="/tmp/llama-embedding.port"
        CONFIG_FILE="/tmp/llama-embedding.conf"
        DEFAULT_PORT="8001"
        DEFAULT_CONTEXT="32768"
    else
        TMUX_SESSION="llama"
        SERVICE_NAME="llama-server"
        PORT_FILE="/tmp/llama-server.port"
        CONFIG_FILE="/tmp/llama-server.conf"
        DEFAULT_PORT="8000"
        DEFAULT_CONTEXT="262144"
    fi
    UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
}

# Default to inference
set_role "inference"

# ─── Detect run mode ──────────────────────────────────────────────────────────
detect_mode() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo "${LLAMA_MODE:-tmux}"
    elif systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "systemd"
    elif tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo "tmux"
    else
        echo ""
    fi
}

is_running() {
    local mode
    mode=$(detect_mode)
    case "$mode" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null ;;
        tmux)    tmux has-session -t "$TMUX_SESSION" 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|logs|enable|disable}

  start    - Interactive setup and start llama-server
  stop     - Gracefully stop the running server
  restart  - Stop then start the server
  status   - Check server health (shows both inference & embedding)
  logs     - Show server logs
  enable   - Enable systemd auto-start on boot (systemd mode only)
  disable  - Disable systemd auto-start on boot (systemd mode only)

Options (for start):
  --tmux        Run in tmux session (default)
  --systemd     Run as systemd service (survives reboots, auto-restarts)
  --embedding   Start an embedding server instead of inference server

Examples:
  $0 start                        # interactive inference server
  $0 start --systemd              # inference via systemd
  $0 start --embedding --systemd  # embedding server via systemd
  $0 stop --embedding             # stop embedding server
  $0 status                       # show all servers
EOF
    exit 1
}

# ─── Embedding model definitions ──────────────────────────────────────────────
# Model name → dimensions, context, pooling
declare -A EMBED_DIMS=(
    ["Qwen3-Embedding-0.6B"]=1024
    ["Qwen3-Embedding-4B"]=2560
    ["Qwen3-Embedding-8B"]=4096
)
declare -A EMBED_CTX=(
    ["Qwen3-Embedding-0.6B"]=32768
    ["Qwen3-Embedding-4B"]=32768
    ["Qwen3-Embedding-8B"]=32768
)
declare -A EMBED_POOLING=(
    ["Qwen3-Embedding-0.6B"]="last"
    ["Qwen3-Embedding-4B"]="last"
    ["Qwen3-Embedding-8B"]="last"
)
declare -A EMBED_HF_REPO=(
    ["Qwen3-Embedding-0.6B"]="Qwen/Qwen3-Embedding-0.6B-GGUF"
    ["Qwen3-Embedding-4B"]="Qwen/Qwen3-Embedding-4B-GGUF"
    ["Qwen3-Embedding-8B"]="Qwen/Qwen3-Embedding-8B-GGUF"
)
declare -A EMBED_HF_FILE=(
    ["Qwen3-Embedding-0.6B"]="Qwen3-Embedding-0.6B-Q8_0.gguf"
    ["Qwen3-Embedding-4B"]="Qwen3-Embedding-4B-Q8_0.gguf"
    ["Qwen3-Embedding-8B"]="Qwen3-Embedding-8B-Q8_0.gguf"
)
declare -A EMBED_SIZE=(
    ["Qwen3-Embedding-0.6B"]="640MB"
    ["Qwen3-Embedding-4B"]="4.1GB"
    ["Qwen3-Embedding-8B"]="8.1GB"
)

# ─── Interactive configuration ─────────────────────────────────────────────────
gather_config() {
    # Find server binary
    SERVER_BIN=""
    SERVER_BIN=$(find_server_bin) || true
    if [[ -z "$SERVER_BIN" ]]; then
        read -r -p "Path to llama-server binary: " SERVER_BIN
        if [[ ! -f "$SERVER_BIN" ]]; then
            log_error "Not found. Run build-llama.sh first."
            exit 1
        fi
    fi
    log_info "Server binary: $SERVER_BIN"

    if [[ "$SERVER_ROLE" == "embedding" ]]; then
        gather_embedding_config
    else
        gather_inference_config
    fi
}

gather_embedding_config() {
    echo ""
    echo "=== Embedding Model Setup ==="
    echo ""
    echo "Available embedding models:"
    echo "  1) Qwen3-Embedding-0.6B  (${EMBED_SIZE[Qwen3-Embedding-0.6B]}, dim=${EMBED_DIMS[Qwen3-Embedding-0.6B]}, fast)"
    echo "  2) Qwen3-Embedding-4B    (${EMBED_SIZE[Qwen3-Embedding-4B]}, dim=${EMBED_DIMS[Qwen3-Embedding-4B]}, better quality)"
    echo "  3) Qwen3-Embedding-8B    (${EMBED_SIZE[Qwen3-Embedding-8B]}, dim=${EMBED_DIMS[Qwen3-Embedding-8B]}, best quality)"
    echo "  4) Custom GGUF file"
    echo ""
    read -r -p "Select embedding model [1]: " EMBED_CHOICE
    EMBED_CHOICE="${EMBED_CHOICE:-1}"

    local embed_key=""
    case "$EMBED_CHOICE" in
        1) embed_key="Qwen3-Embedding-0.6B" ;;
        2) embed_key="Qwen3-Embedding-4B" ;;
        3) embed_key="Qwen3-Embedding-8B" ;;
        4)
            # Custom model — fall through to manual config
            gather_embedding_config_custom
            return
            ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac

    MODEL_NAME="$embed_key"
    EMBED_DIM="${EMBED_DIMS[$embed_key]}"
    CONTEXT="${EMBED_CTX[$embed_key]}"
    POOLING="${EMBED_POOLING[$embed_key]}"

    local gguf_file="${EMBED_HF_FILE[$embed_key]}"
    MODEL="$HOME/models/$gguf_file"

    # Download if not present
    if [[ ! -f "$MODEL" ]]; then
        log_info "Model not found locally. Downloading..."
        local hf_repo="${EMBED_HF_REPO[$embed_key]}"
        mkdir -p "$HOME/models"

        if command -v hf &>/dev/null; then
            hf download "$hf_repo" "$gguf_file" --local-dir "$HOME/models"
        elif command -v huggingface-cli &>/dev/null; then
            huggingface-cli download "$hf_repo" "$gguf_file" --local-dir "$HOME/models"
        else
            log_error "HuggingFace CLI not found. Install: pip install huggingface_hub"
            exit 1
        fi

        if [[ ! -f "$MODEL" ]]; then
            log_error "Download failed."
            exit 1
        fi
        log_success "Downloaded: $gguf_file"
    else
        log_success "Model found: $MODEL"
    fi

    # Port
    read -r -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    # Parallel slots
    read -r -p "Parallel slots [4]: " PARALLEL
    PARALLEL="${PARALLEL:-4}"
    if ! validate_numeric "$PARALLEL" "Parallel slots"; then exit 1; fi

    # GPU detection
    NUM_GPUS=$(detect_gpu_count)
    TS_ARGS=()
    if [[ "$NUM_GPUS" -gt 1 ]]; then
        TS_ARGS=(-ts "1,0")  # Embedding model is small, single GPU is fine
    fi
    GPU_MODE="single"

    # Build command
    CMD_ARGS=(
        "$SERVER_BIN"
        -m "$MODEL"
        -ngl 99
        -c "$CONTEXT"
        -np "$PARALLEL"
        --embedding
        --pooling "$POOLING"
        --alias "$MODEL_NAME"
        --host 0.0.0.0
        --port "$PORT"
    )
    if [[ ${#TS_ARGS[@]} -gt 0 ]]; then
        CMD_ARGS+=("${TS_ARGS[@]}")
    fi

    KV_CACHE="n/a"

    echo ""
    log_info "Embedding config:"
    echo "  Model:      $MODEL_NAME"
    echo "  Dimensions: $EMBED_DIM"
    echo "  Context:    $CONTEXT"
    echo "  Pooling:    $POOLING"
}

gather_embedding_config_custom() {
    echo ""
    log_info "Scanning for models..."
    mapfile -t MODELS < <(find_models)
    if [[ ${#MODELS[@]} -eq 0 ]]; then
        log_error "No GGUF models found. Download one first."
        exit 1
    fi

    echo "Available models:"
    for i in "${!MODELS[@]}"; do
        SIZE=$(format_file_size "${MODELS[$i]}")
        NAME=$(basename "${MODELS[$i]}")
        echo "  $((i+1))) $NAME ($SIZE)"
    done
    echo ""
    read -r -p "Select model: " MODEL_CHOICE
    if ! validate_numeric "$MODEL_CHOICE" "Model selection"; then exit 1; fi
    if ! validate_range "$MODEL_CHOICE" 1 "${#MODELS[@]}" "Model selection"; then exit 1; fi

    MODEL="${MODELS[$((MODEL_CHOICE-1))]}"
    MODEL_NAME=$(basename "$MODEL" .gguf)

    read -r -p "Embedding dimensions [1024]: " EMBED_DIM
    EMBED_DIM="${EMBED_DIM:-1024}"

    read -r -p "Context length [32768]: " CONTEXT
    CONTEXT="${CONTEXT:-32768}"

    echo "Pooling types: mean, cls, last"
    read -r -p "Pooling type [last]: " POOLING
    POOLING="${POOLING:-last}"

    read -r -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    read -r -p "Parallel slots [4]: " PARALLEL
    PARALLEL="${PARALLEL:-4}"

    NUM_GPUS=$(detect_gpu_count)
    TS_ARGS=()
    if [[ "$NUM_GPUS" -gt 1 ]]; then
        TS_ARGS=(-ts "1,0")
    fi
    GPU_MODE="single"
    KV_CACHE="n/a"

    CMD_ARGS=(
        "$SERVER_BIN"
        -m "$MODEL"
        -ngl 99
        -c "$CONTEXT"
        -np "$PARALLEL"
        --embedding
        --pooling "$POOLING"
        --alias "$MODEL_NAME"
        --host 0.0.0.0
        --port "$PORT"
    )
    if [[ ${#TS_ARGS[@]} -gt 0 ]]; then
        CMD_ARGS+=("${TS_ARGS[@]}")
    fi
}

gather_inference_config() {
    # Find and select model
    echo ""
    log_info "Scanning for models..."
    mapfile -t MODELS < <(find_models)
    if [[ ${#MODELS[@]} -eq 0 ]]; then
        log_error "No models found. Run download-model.sh first."
        exit 1
    fi

    echo "Available models:"
    for i in "${!MODELS[@]}"; do
        SIZE=$(format_file_size "${MODELS[$i]}")
        NAME=$(basename "${MODELS[$i]}")
        echo "  $((i+1))) $NAME ($SIZE)"
    done
    echo ""
    read -r -p "Select model [1]: " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-1}"

    if ! validate_numeric "$MODEL_CHOICE" "Model selection"; then exit 1; fi
    if ! validate_range "$MODEL_CHOICE" 1 "${#MODELS[@]}" "Model selection"; then exit 1; fi

    MODEL="${MODELS[$((MODEL_CHOICE-1))]}"
    if [[ ! -f "$MODEL" ]]; then
        log_error "Model file not found: $MODEL"
        exit 1
    fi
    MODEL_NAME=$(basename "$MODEL" .gguf)
    MODEL_SIZE_GB=$(file_size_gb "$MODEL")
    log_info "Selected: $MODEL_NAME (${MODEL_SIZE_GB}GB)"

    # Detect GPUs
    echo ""
    echo "GPUs:"
    detect_gpu_names
    NUM_GPUS=$(detect_gpu_count)

    # GPU mode
    TS_ARGS=()
    if [[ "$NUM_GPUS" -gt 1 ]]; then
        if [[ "$MODEL_SIZE_GB" -le 20 ]]; then
            DEFAULT_GPU="single"
        else
            DEFAULT_GPU="dual"
        fi
        read -r -p "GPU mode (single/dual) [$DEFAULT_GPU]: " GPU_MODE
        GPU_MODE="${GPU_MODE:-$DEFAULT_GPU}"
    else
        GPU_MODE="single"
    fi
    if [[ "$GPU_MODE" == "single" ]]; then
        TS_ARGS=(-ts "1,0")
    fi

    # Context size
    read -r -p "Context size [$DEFAULT_CONTEXT]: " CONTEXT
    CONTEXT="${CONTEXT:-$DEFAULT_CONTEXT}"
    if ! validate_numeric "$CONTEXT" "Context size"; then exit 1; fi

    # KV cache type
    echo ""
    echo "KV cache types: f16, q8_0, q4_0, turbo2, turbo3"
    read -r -p "KV cache type [q8_0]: " KV_CACHE
    KV_CACHE="${KV_CACHE:-q8_0}"

    # Port
    read -r -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    # Parallel slots
    read -r -p "Parallel slots [1]: " PARALLEL
    PARALLEL="${PARALLEL:-1}"
    if ! validate_numeric "$PARALLEL" "Parallel slots"; then exit 1; fi

    # Build command args array
    CMD_ARGS=(
        "$SERVER_BIN"
        -m "$MODEL"
        -ngl 99
        -c "$CONTEXT"
        -np "$PARALLEL"
        -fa on
        --cache-type-k "$KV_CACHE"
        --cache-type-v "$KV_CACHE"
        --alias "$MODEL_NAME"
        --host 0.0.0.0
        --port "$PORT"
    )
    if [[ ${#TS_ARGS[@]} -gt 0 ]]; then
        CMD_ARGS+=("${TS_ARGS[@]}")
    fi
}

# ─── Config persistence ───────────────────────────────────────────────────────
save_config() {
    local mode="$1"
    cat > "$CONFIG_FILE" <<EOF
LLAMA_MODE=$mode
LLAMA_PORT=$PORT
LLAMA_MODEL=$MODEL_NAME
LLAMA_SERVER_BIN=$SERVER_BIN
LLAMA_ROLE=$SERVER_ROLE
EOF
}

print_summary() {
    echo ""
    if [[ "$SERVER_ROLE" == "embedding" ]]; then
        echo "=== Starting Embedding Server ==="
        echo "Model:      $MODEL_NAME"
        echo "Dimensions: ${EMBED_DIM:-auto}"
        echo "Context:    $CONTEXT"
        echo "Pooling:    ${POOLING:-last}"
        echo "Port:       $PORT"
        echo "Mode:       $RUN_MODE"
    else
        echo "=== Starting Inference Server ==="
        echo "Model:    $MODEL_NAME"
        echo "GPU:      $GPU_MODE"
        echo "Context:  $CONTEXT"
        echo "KV cache: $KV_CACHE"
        echo "Port:     $PORT"
        echo "Mode:     $RUN_MODE"
    fi
    echo ""
}

show_post_start_info() {
    local mode="$1"

    if [[ "$SERVER_ROLE" == "embedding" ]]; then
        log_success "=== Embedding server ready at http://0.0.0.0:${PORT} ==="
        log_info "Endpoint:  http://0.0.0.0:${PORT}/v1/embeddings"
    else
        log_success "=== Server ready at http://0.0.0.0:${PORT} ==="
        log_info "Endpoint:  http://0.0.0.0:${PORT}/v1/chat/completions"
    fi
    log_info "Health:    http://0.0.0.0:${PORT}/health"

    if [[ "$mode" == "tmux" ]]; then
        log_info "Logs:      tmux attach -t $TMUX_SESSION"
    else
        log_info "Logs:      journalctl -u $SERVICE_NAME -f"
        log_info "Auto-boot: bash llama-server.sh enable${SERVER_ROLE:+ --$SERVER_ROLE}"
    fi

    # New API gateway info
    if is_new_api_running; then
        local na_port
        na_port=$(get_new_api_port)
        echo ""
        log_info "New API gateway detected on port $na_port"
        if [[ "$SERVER_ROLE" == "embedding" ]]; then
            log_info "Proxy endpoint: http://0.0.0.0:${na_port}/v1/embeddings"
        else
            log_info "Proxy endpoint: http://0.0.0.0:${na_port}/v1/chat/completions"
        fi
        log_info "Manage channels: bash new-api.sh add-channel"
    fi
}

wait_for_health() {
    local mode="$1"
    log_info "Waiting for server to start..."
    local wait_secs=1 max_wait=180 elapsed=0

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        # Check if process is still alive
        if [[ "$mode" == "tmux" ]]; then
            if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
                echo ""
                log_error "Server process exited unexpectedly."
                log_info "Possible causes: invalid model, out of VRAM, missing CUDA libraries"
                exit 1
            fi
        elif [[ "$mode" == "systemd" ]]; then
            if systemctl is-failed --quiet "$SERVICE_NAME" 2>/dev/null; then
                echo ""
                log_error "Server process failed. Check: journalctl -u $SERVICE_NAME -n 50"
                exit 1
            fi
        fi

        if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
            echo ""
            show_post_start_info "$mode"
            return 0
        fi

        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs))
        wait_secs=$((wait_secs * 2))
        [[ "$wait_secs" -gt 10 ]] && wait_secs=10
        printf "."
    done

    echo ""
    log_warn "Server did not respond within ${max_wait}s. It may still be loading a large model."
    if [[ "$mode" == "tmux" ]]; then
        log_info "Check: tmux attach -t $TMUX_SESSION"
    else
        log_info "Check: journalctl -u $SERVICE_NAME -f"
    fi
}

# ─── tmux mode ─────────────────────────────────────────────────────────────────
start_tmux() {
    require_command tmux "sudo apt-get install tmux"

    # Stop existing tmux session
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_info "Stopping existing tmux server..."
        stop_tmux
        sleep 2
    fi

    # Build escaped command string for tmux
    local tmux_cmd=""
    for arg in "${CMD_ARGS[@]}"; do
        local escaped
        escaped=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
        tmux_cmd+="'${escaped}' "
    done
    tmux_cmd+="2>&1; echo 'SERVER EXITED - press enter to close'; read -r"

    tmux new-session -d -s "$TMUX_SESSION" "bash -c ${tmux_cmd}"
    echo "$PORT" > "$PORT_FILE"
    save_config "tmux"
}

stop_tmux() {
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux send-keys -t "$TMUX_SESSION" C-c 2>/dev/null || true
        for _ in $(seq 1 10); do
            if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then break; fi
            sleep 1
        done
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        fi
    fi
    rm -f "$PORT_FILE"
}

# ─── systemd mode ─────────────────────────────────────────────────────────────
require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required for systemd service management."
        sudo true || { log_error "Cannot get sudo access."; exit 1; }
    fi
}

start_systemd() {
    require_sudo

    # Stop existing (either tmux or systemd)
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_info "Stopping existing tmux server first..."
        stop_tmux
        sleep 2
    fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping existing systemd service..."
        sudo systemctl stop "$SERVICE_NAME"
        sleep 2
    fi

    # Build ExecStart command string
    local exec_start=""
    for arg in "${CMD_ARGS[@]}"; do
        if [[ "$arg" == *" "* || "$arg" == *"'"* ]]; then
            exec_start+="\"$arg\" "
        else
            exec_start+="$arg "
        fi
    done

    # Find CUDA path for environment
    local cuda_path=""
    cuda_path=$(find_cuda_path) || true
    local env_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -n "$cuda_path" ]]; then
        env_path="${cuda_path}:${env_path}"
    fi

    local ld_lib_path=""
    if [[ -n "$cuda_path" ]]; then
        ld_lib_path="Environment=LD_LIBRARY_PATH=$(dirname "$cuda_path")/lib64"
    fi

    local description="llama.cpp Inference Server ($MODEL_NAME)"
    [[ "$SERVER_ROLE" == "embedding" ]] && description="llama.cpp Embedding Server ($MODEL_NAME)"

    # Write systemd unit file
    log_info "Creating systemd service: $SERVICE_NAME"
    sudo tee "$UNIT_FILE" > /dev/null <<EOF
[Unit]
Description=$description
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$HOME

# Environment
Environment=PATH=${env_path}
${ld_lib_path}

# Server command
ExecStart=${exec_start}

# Restart policy
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5

# Resource limits
LimitNOFILE=65536
LimitMEMLOCK=infinity

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# GPU access
SupplementaryGroups=video render

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start "$SERVICE_NAME"

    echo "$PORT" > "$PORT_FILE"
    save_config "systemd"

    log_success "Systemd service '$SERVICE_NAME' created and started"
}

stop_systemd() {
    require_sudo
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$SERVICE_NAME"
    fi
    rm -f "$PORT_FILE"
}

enable_systemd() {
    require_sudo
    if [[ ! -f "$UNIT_FILE" ]]; then
        log_error "No systemd service '$SERVICE_NAME' found. Start with: $0 start --${SERVER_ROLE} --systemd"
        exit 1
    fi
    sudo systemctl enable "$SERVICE_NAME"
    log_success "$SERVICE_NAME will auto-start on boot"
}

disable_systemd() {
    require_sudo
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    log_success "$SERVICE_NAME auto-start disabled"
}

# ─── Unified commands ─────────────────────────────────────────────────────────
start_server() {
    gather_config

    # Ask for run mode if not specified via flag
    if [[ -z "$RUN_MODE" ]]; then
        echo ""
        echo "Run mode:"
        echo "  1) tmux    — foreground session, easy to attach and see output"
        echo "  2) systemd — background service, survives reboots, auto-restarts on crash"
        read -r -p "Select run mode [1]: " mode_choice
        mode_choice="${mode_choice:-1}"
        case "$mode_choice" in
            1) RUN_MODE="tmux" ;;
            2) RUN_MODE="systemd" ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    fi

    print_summary

    case "$RUN_MODE" in
        tmux)    start_tmux ;;
        systemd) start_systemd ;;
    esac

    wait_for_health "$RUN_MODE"
}

stop_server() {
    local mode
    mode=$(detect_mode)

    if [[ -z "$mode" ]]; then
        log_info "$SERVICE_NAME is not running"
        return
    fi

    log_info "Stopping $SERVICE_NAME ($mode mode)..."

    case "$mode" in
        tmux)    stop_tmux ;;
        systemd) stop_systemd ;;
    esac

    rm -f "$CONFIG_FILE"
    log_success "$SERVICE_NAME stopped"
}

restart_server() {
    local prev_mode
    prev_mode=$(detect_mode)

    if [[ -n "$prev_mode" && -z "$RUN_MODE" ]]; then
        RUN_MODE="$prev_mode"
    fi

    stop_server
    sleep 2
    start_server
}

show_single_status() {
    local role="$1" svc_name="$2" session="$3" pfile="$4" cfile="$5"
    local mode=""
    local label="Inference"
    [[ "$role" == "embedding" ]] && label="Embedding"

    # Detect mode for this service
    if [[ -f "$cfile" ]]; then
        # shellcheck source=/dev/null
        source "$cfile"
        mode="${LLAMA_MODE:-}"
    fi
    if [[ -z "$mode" ]] && systemctl is-active --quiet "$svc_name" 2>/dev/null; then
        mode="systemd"
    fi
    if [[ -z "$mode" ]] && tmux has-session -t "$session" 2>/dev/null; then
        mode="tmux"
    fi

    if [[ -z "$mode" ]]; then
        log_info "$label server: not running"
        return
    fi

    local mode_detail=""
    if [[ "$mode" == "systemd" ]]; then
        local enabled="disabled"
        systemctl is-enabled --quiet "$svc_name" 2>/dev/null && enabled="enabled"
        mode_detail="systemd, boot=$enabled"
    else
        mode_detail="tmux session: $session"
    fi

    # Find port
    local port=""
    if [[ -f "$pfile" ]]; then
        port=$(cat "$pfile")
    fi
    # Fallback ports
    if [[ -z "$port" ]]; then
        [[ "$role" == "embedding" ]] && port="8001" || port="8000"
    fi

    if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
        log_success "$label server: running ($mode_detail, port $port)"
    else
        log_warn "$label server: process active but not responding ($mode_detail, port $port)"
    fi
}

show_status() {
    echo "=== llama-server status ==="
    echo ""

    # Show inference server status
    show_single_status "inference" "llama-server" "llama" "/tmp/llama-server.port" "/tmp/llama-server.conf"

    # Show embedding server status
    show_single_status "embedding" "llama-embedding" "llama-embed" "/tmp/llama-embedding.port" "/tmp/llama-embedding.conf"

    # New API gateway
    echo ""
    if is_new_api_running; then
        local na_port
        na_port=$(get_new_api_port)
        log_success "New API gateway: running (port $na_port)"
    else
        log_info "New API gateway: not running"
    fi
}

show_logs() {
    local mode
    mode=$(detect_mode)

    case "$mode" in
        tmux)
            tmux capture-pane -t "$TMUX_SESSION" -p -S -50 | tail -50
            ;;
        systemd)
            journalctl -u "$SERVICE_NAME" -n 50 --no-pager
            ;;
        *)
            log_info "$SERVICE_NAME is not running"
            ;;
    esac
}

# ─── Parse flags and dispatch ──────────────────────────────────────────────────
RUN_MODE=""
ACTION=""

for arg in "$@"; do
    case "$arg" in
        --tmux)      RUN_MODE="tmux" ;;
        --systemd)   RUN_MODE="systemd" ;;
        --embedding) set_role "embedding" ;;
        start|stop|restart|status|logs|enable|disable)
            ACTION="$arg" ;;
        *)
            log_error "Unknown argument: $arg"
            usage ;;
    esac
done

case "${ACTION:-}" in
    start)   start_server ;;
    stop)    stop_server ;;
    restart) restart_server ;;
    status)  show_status ;;
    logs)    show_logs ;;
    enable)  enable_systemd ;;
    disable) disable_systemd ;;
    *)       usage ;;
esac
