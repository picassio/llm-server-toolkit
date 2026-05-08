#!/usr/bin/env bash
# Start/stop/manage vLLM inference server via Docker or systemd
# Supports FP8, FP16, AWQ, GPTQ models with high-throughput batched inference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

SERVICE_NAME="vllm-server"
CONTAINER_NAME="vllm-server"
PORT_FILE="/tmp/vllm-server.port"
CONFIG_FILE="/tmp/vllm-server.conf"
DEFAULT_PORT="8000"
DEFAULT_IMAGE="vllm/vllm-openai:latest"

# Turbo mode (club-3090 Docker + Genesis + TurboQuant)
TURBO_CONTAINER_NAME="vllm-qwen36-27b-dual-turbo"
TURBO_COMPOSE_DIR="$HOME/club-3090/models/qwen3.6-27b/vllm/compose"
TURBO_COMPOSE_FILE="docker-compose.dual-turbo.yml"
TURBO_DEFAULT_PORT="8011"

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|logs}

  start    - Interactive setup and start vLLM server
  stop     - Stop the running server
  restart  - Stop then start the server
  status   - Check server health
  logs     - Show server logs

Options:
  --docker    Run via Docker (default, recommended)
  --native    Run via pip-installed vLLM (requires manual install)
  --turbo     Run via club-3090 Docker + Genesis + TurboQuant (RTX 3090)

Model presets:
  The script includes optimized presets for common models.
  Custom HuggingFace models are also supported.

Examples:
  $0 start                          # interactive setup
  $0 start --docker                 # Docker mode
  $0 start --turbo                  # Turbo mode (RTX 3090)
  $0 stop                           # stop server
  $0 status                         # check health

Performance reference (Qwen3.6-27B-FP8 on GB10):
  - 256K context, 10 concurrent agents
  - ~200 tokens/sec max decode
  - ~136 t/s average at 49W
  - Requires: Dflash + DDTree optimizations

Performance reference (Qwen3.6-27B-TurboQuant on 2x RTX 3090):
  - 262K context, 4 concurrent streams
  - ~73 t/s code / ~54 t/s narrative per stream
  - TurboQuant 3bit KV + MTP n=3 + Genesis patches
  - AutoRound INT4 quantization
EOF
    exit 1
}

# ─── Model Presets ────────────────────────────────────────────────────────────
# Format: "display_name|hf_repo|max_ctx|dtype|extra_args|reasoning_parser|description"
PRESETS=(
    "Qwen3.6-27B-AWQ|cyankiwi/Qwen3.6-27B-AWQ-INT4|131072|auto|--enable-prefix-caching --enable-chunked-prefill --quantization compressed-tensors|qwen3|MoE AWQ-INT4, 131K ctx (recommended for Ampere)"
    "Qwen3.6-27B-FP8|Qwen/Qwen3-30B-A3B-FP8|262144|auto|--enable-prefix-caching --enable-chunked-prefill|qwen3|MoE 30B/3B, FP8, 256K ctx (needs Hopper/Blackwell)"
    "Qwen3.6-27B-BF16|Qwen/Qwen3-30B-A3B|131072|bfloat16|--enable-prefix-caching --enable-chunked-prefill|qwen3|MoE 30B/3B, BF16, 131K ctx"
    "Qwen3.5-27B-FP8|Qwen/Qwen3.5-32B-FP8|131072|auto|--enable-prefix-caching|qwen3|Dense 32B, FP8 (needs Hopper/Blackwell)"
    "Qwen3.5-27B-BF16|Qwen/Qwen3.5-32B|65536|bfloat16|--enable-prefix-caching|qwen3|Dense 32B, BF16"
    "Gemma-4-26B-A4B|google/gemma-4-26B-A4B-it|131072|bfloat16|--enable-prefix-caching --enable-chunked-prefill|gemma4|MoE 26B/4B, BF16"
    "Gemma-4-31B|google/gemma-4-31B-it|131072|bfloat16|--enable-prefix-caching|gemma4|Dense 31B, BF16"
    "Qwen3.6-27B-TurboQuant|Lorbus/Qwen3.6-27B-int4-AutoRound|196608|float16||qwen3|AutoRound INT4 + TurboQuant 3bit KV + MTP n=3 (Turbo mode only, recommended for 2x RTX 3090)"
    "Custom|custom|0|auto|||Enter a custom HuggingFace model"
)

# Reasoning parsers: maps model family to vLLM reasoning parser name
# These separate <think>...</think> into reasoning_content field
# Available: qwen3, deepseek_r1, deepseek_v3, gemma4, granite, mistral, etc.

# ─── Detect GPU capabilities ─────────────────────────────────────────────────
get_gpu_arch() {
    local cc
    cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
    echo "$cc"
}

supports_fp8() {
    local cc
    cc=$(get_gpu_arch)
    # FP8 requires SM 89+ (Ada Lovelace) or SM 90+ (Hopper)
    [[ "$cc" -ge 89 ]] 2>/dev/null
}

get_gpu_mem_gb() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{printf "%.0f", $1/1024}'
}

# ─── Gather Configuration ────────────────────────────────────────────────────
gather_config() {
    echo "=== vLLM Server Setup ==="
    echo ""

    # GPU info
    echo "GPUs:"
    detect_gpu_names
    NUM_GPUS=$(detect_gpu_count)
    local gpu_arch
    gpu_arch=$(get_gpu_arch)
    local gpu_mem
    gpu_mem=$(get_gpu_mem_gb)
    log_info "GPU memory: ${gpu_mem}GB per GPU, ${NUM_GPUS} GPU(s)"

    if supports_fp8; then
        log_info "GPU supports FP8 (SM $gpu_arch) — all presets available"
    else
        log_warn "GPU does not support native FP8 (SM $gpu_arch) — use BF16/FP16 models"
    fi
    echo ""

    # HuggingFace token
    HF_TOKEN=""
    if [[ -f "$HOME/.cache/huggingface/token" ]]; then
        HF_TOKEN=$(cat "$HOME/.cache/huggingface/token")
        log_success "HuggingFace token found"
    else
        read -r -p "HuggingFace token (for gated models, leave empty to skip): " HF_TOKEN
    fi

    # Model selection
    echo ""
    echo "Available model presets:"
    for i in "${!PRESETS[@]}"; do
        IFS='|' read -r name _ _ dtype _ _ desc <<< "${PRESETS[$i]}"
        local fp8_note=""
        if [[ "$desc" == *"FP8"* ]] && ! supports_fp8; then
            fp8_note=" ⚠️  (needs Hopper/Blackwell GPU)"
        fi
        printf "  %d) %-25s %s%s\n" "$((i+1))" "$name" "$desc" "$fp8_note"
    done
    echo ""
    read -r -p "Select model [2]: " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-2}"

    if ! validate_numeric "$MODEL_CHOICE" "Model selection"; then exit 1; fi
    if ! validate_range "$MODEL_CHOICE" 1 "${#PRESETS[@]}" "Model selection"; then exit 1; fi

    local preset="${PRESETS[$((MODEL_CHOICE-1))]}"
    IFS='|' read -r PRESET_NAME HF_MODEL MAX_CTX DTYPE EXTRA_ARGS REASONING_PARSER PRESET_DESC <<< "$preset"

    # Custom model
    if [[ "$HF_MODEL" == "custom" ]]; then
        read -r -p "HuggingFace model (e.g., Qwen/Qwen3-30B-A3B): " HF_MODEL
        if [[ -z "$HF_MODEL" ]]; then
            log_error "Model name required."
            exit 1
        fi
        read -r -p "Max context length [131072]: " MAX_CTX
        MAX_CTX="${MAX_CTX:-131072}"
        echo "Data type: auto, bfloat16, float16"
        read -r -p "Data type [bfloat16]: " DTYPE
        DTYPE="${DTYPE:-bfloat16}"
        EXTRA_ARGS="--enable-prefix-caching"
        echo "Reasoning parser (separates thinking from response):"
        echo "  qwen3, deepseek_r1, gemma4, granite, mistral, or empty for none"
        read -r -p "Reasoning parser []: " REASONING_PARSER
        REASONING_PARSER="${REASONING_PARSER:-}"
        PRESET_NAME="$HF_MODEL"
    fi

    log_info "Model: $HF_MODEL ($PRESET_DESC)"

    # Context size
    echo ""
    read -r -p "Context length [$MAX_CTX]: " CONTEXT
    CONTEXT="${CONTEXT:-$MAX_CTX}"
    if ! validate_numeric "$CONTEXT" "Context length"; then exit 1; fi

    # Tensor parallelism
    local default_tp=1
    if [[ "$NUM_GPUS" -gt 1 ]]; then
        default_tp="$NUM_GPUS"
    fi
    read -r -p "Tensor parallel GPUs [$default_tp]: " TP_SIZE
    TP_SIZE="${TP_SIZE:-$default_tp}"

    # Max concurrent sequences (agents)
    read -r -p "Max concurrent sequences [10]: " MAX_SEQS
    MAX_SEQS="${MAX_SEQS:-10}"

    # GPU memory utilization
    read -r -p "GPU memory utilization (0.0-1.0) [0.90]: " GPU_UTIL
    GPU_UTIL="${GPU_UTIL:-0.90}"

    # Port
    read -r -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    # Model alias for API
    MODEL_ALIAS="${PRESET_NAME}"
    read -r -p "Model alias for API [$MODEL_ALIAS]: " alias_input
    MODEL_ALIAS="${alias_input:-$MODEL_ALIAS}"

    echo ""
    log_info "Configuration:"
    echo "  Model:       $HF_MODEL"
    echo "  Context:     $CONTEXT"
    echo "  TP:          $TP_SIZE GPUs"
    echo "  Max seqs:    $MAX_SEQS"
    echo "  GPU util:    $GPU_UTIL"
    echo "  Dtype:       $DTYPE"
    echo "  Port:        $PORT"
    echo "  Alias:       $MODEL_ALIAS"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
VLLM_MODE=$RUN_MODE
VLLM_PORT=$PORT
VLLM_MODEL=$HF_MODEL
VLLM_ALIAS=$MODEL_ALIAS
EOF
}

# ─── Turbo Config ─────────────────────────────────────────────────────────────
gather_turbo_config() {
    echo "=== vLLM TurboQuant Server Setup ==="
    echo ""
    echo "Mode: Turbo (club-3090 Docker + Genesis + TurboQuant KV + MTP)"
    echo "Model: Lorbus/Qwen3.6-27B-int4-AutoRound (fixed)"
    echo ""

    # GPU info
    echo "GPUs:"
    detect_gpu_names
    NUM_GPUS=$(detect_gpu_count)
    if [[ "$NUM_GPUS" -lt 2 ]]; then
        log_warn "Turbo mode is designed for 2 GPUs (detected: $NUM_GPUS)"
        log_warn "Continuing anyway — compose will use available GPUs"
    fi

    # HuggingFace token
    HF_TOKEN=""
    if [[ -f "$HOME/.cache/huggingface/token" ]]; then
        HF_TOKEN=$(cat "$HOME/.cache/huggingface/token")
        log_success "HuggingFace token found"
    else
        read -r -p "HuggingFace token (leave empty to skip): " HF_TOKEN
    fi

    # Fixed model settings (controlled by compose file)
    HF_MODEL="Lorbus/Qwen3.6-27B-int4-AutoRound"
    PRESET_NAME="Qwen3.6-27B-TurboQuant"
    REASONING_PARSER="qwen3"
    DTYPE="float16"
    TP_SIZE="2"
    MAX_SEQS="4"
    EXTRA_ARGS=""

    # User-configurable settings
    echo ""
    read -r -p "Max context length [196608]: " ctx_input
    CONTEXT="${ctx_input:-196608}"
    if ! validate_numeric "$CONTEXT" "Context length"; then exit 1; fi

    read -r -p "GPU memory utilization (0.0-1.0) [0.85]: " GPU_UTIL
    GPU_UTIL="${GPU_UTIL:-0.85}"

    read -r -p "Port [$TURBO_DEFAULT_PORT]: " PORT
    PORT="${PORT:-$TURBO_DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    MODEL_ALIAS="qwen3.6-27b"
    read -r -p "Model alias for API [$MODEL_ALIAS]: " alias_input
    MODEL_ALIAS="${alias_input:-$MODEL_ALIAS}"

    echo ""
    log_info "Turbo configuration:"
    echo "  Model:       $HF_MODEL"
    echo "  Context:     $CONTEXT"
    echo "  TP:          2 GPUs (fixed)"
    echo "  Max seqs:    4 (fixed)"
    echo "  GPU util:    $GPU_UTIL"
    echo "  KV cache:    turboquant_3bit_nc"
    echo "  MTP:         n=3 speculative tokens"
    echo "  Port:        $PORT"
    echo "  Alias:       $MODEL_ALIAS"
}

# ─── Docker Mode ──────────────────────────────────────────────────────────────
start_docker() {
    require_command docker "Install Docker: https://docs.docker.com/engine/install/"

    # Stop existing container
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "Removing existing container..."
        docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1
        sleep 2
    fi

    # Pull latest image
    local image="$DEFAULT_IMAGE"
    log_info "Using image: $image"
    docker pull "$image" 2>&1 | tail -3

    # Build docker run command
    local docker_args=(
        docker run -d
        --name "$CONTAINER_NAME"
        --restart unless-stopped
        --gpus all
        --ipc host
        -p "${PORT}:8000"
        -v "$HOME/.cache/huggingface:/root/.cache/huggingface"
    )

    # Add HF token if available
    if [[ -n "$HF_TOKEN" ]]; then
        docker_args+=(-e "HF_TOKEN=$HF_TOKEN")
    fi

    # vLLM arguments
    local vllm_args=(
        --model "$HF_MODEL"
        --served-model-name "$MODEL_ALIAS"
        --max-model-len "$CONTEXT"
        --tensor-parallel-size "$TP_SIZE"
        --max-num-seqs "$MAX_SEQS"
        --gpu-memory-utilization "$GPU_UTIL"
        --dtype "$DTYPE"
        --trust-remote-code
        --host 0.0.0.0
        --port 8000
    )

    # Add extra args from preset
    if [[ -n "$EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        vllm_args+=($EXTRA_ARGS)
    fi

    # Add reasoning parser (separates <think> into reasoning_content)
    if [[ -n "${REASONING_PARSER:-}" ]]; then
        vllm_args+=(--reasoning-parser "$REASONING_PARSER")
    fi

    # Run
    echo ""
    log_step "Starting vLLM container..."
    "${docker_args[@]}" "$image" "${vllm_args[@]}" 2>&1

    echo "$PORT" > "$PORT_FILE"
    save_config
}

stop_docker() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" > /dev/null 2>&1
        docker rm "$CONTAINER_NAME" > /dev/null 2>&1
    fi
    rm -f "$PORT_FILE"
}

# ─── Native Mode ─────────────────────────────────────────────────────────────
start_native() {
    if ! python3 -c "import vllm" 2>/dev/null; then
        log_error "vLLM not installed. Install with:"
        echo "  pip install vllm"
        echo "  # or use --docker mode instead"
        exit 1
    fi

    # Stop existing
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping existing service..."
        sudo systemctl stop "$SERVICE_NAME"
        sleep 2
    fi

    # Build ExecStart
    local exec_start="$(command -v vllm) serve $HF_MODEL"
    exec_start+=" --served-model-name $MODEL_ALIAS"
    exec_start+=" --max-model-len $CONTEXT"
    exec_start+=" --tensor-parallel-size $TP_SIZE"
    exec_start+=" --max-num-seqs $MAX_SEQS"
    exec_start+=" --gpu-memory-utilization $GPU_UTIL"
    exec_start+=" --dtype $DTYPE"
    exec_start+=" --trust-remote-code"
    exec_start+=" --host 0.0.0.0 --port $PORT"
    if [[ -n "$EXTRA_ARGS" ]]; then
        exec_start+=" $EXTRA_ARGS"
    fi
    if [[ -n "${REASONING_PARSER:-}" ]]; then
        exec_start+=" --reasoning-parser $REASONING_PARSER"
    fi

    # Find CUDA path
    local cuda_path=""
    cuda_path=$(find_cuda_path) || true
    local env_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -n "$cuda_path" ]]; then
        env_path="${cuda_path}:${env_path}"
    fi

    local hf_env=""
    if [[ -n "$HF_TOKEN" ]]; then
        hf_env="Environment=HF_TOKEN=$HF_TOKEN"
    fi

    # Write systemd unit
    log_info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=vLLM Inference Server ($MODEL_ALIAS)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$HOME

Environment=PATH=${env_path}
${hf_env}

ExecStart=${exec_start}

Restart=on-failure
RestartSec=15
StartLimitIntervalSec=300
StartLimitBurst=3

LimitNOFILE=65536
LimitMEMLOCK=infinity

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

SupplementaryGroups=video render

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start "$SERVICE_NAME"
    echo "$PORT" > "$PORT_FILE"
    save_config
}

stop_native() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$SERVICE_NAME"
    fi
    rm -f "$PORT_FILE"
}

# ─── Turbo Mode (club-3090 Docker + Genesis + TurboQuant) ─────────────────
start_turbo() {
    require_command docker "Install Docker: https://docs.docker.com/engine/install/"
    require_command git "Install git: sudo apt install git"

    local club_repo="$HOME/club-3090"
    local model_dir="$HOME/models"
    local model_path="$model_dir/qwen3.6-27b-autoround-int4"
    local genesis_path="$club_repo/models/qwen3.6-27b/vllm/patches/genesis/vllm/_genesis"
    local compose_dir="$TURBO_COMPOSE_DIR"

    # Check club-3090 repo
    if [[ ! -d "$club_repo" ]]; then
        log_info "Cloning club-3090 repository..."
        git clone https://github.com/club-3090/club-3090.git "$club_repo"
    fi

    # Check Genesis patches
    if [[ ! -d "$genesis_path" ]]; then
        log_info "Genesis patches not found. Running setup..."
        (cd "$club_repo" && bash scripts/setup.sh qwen3.6-27b)
    fi

    # Check model
    if [[ ! -d "$model_path" ]]; then
        log_info "Model not found at $model_path"
        log_info "Downloading Lorbus/Qwen3.6-27B-int4-AutoRound via setup.sh..."
        (cd "$club_repo" && MODEL_DIR="$model_dir" bash scripts/setup.sh qwen3.6-27b)
    fi

    # Stop existing turbo container
    if docker ps -a --format '{{.Names}}' | grep -q "^${TURBO_CONTAINER_NAME}$"; then
        log_info "Removing existing turbo container..."
        (cd "$compose_dir" && docker compose -f "$TURBO_COMPOSE_FILE" down 2>/dev/null) || \
            docker rm -f "$TURBO_CONTAINER_NAME" > /dev/null 2>&1
        sleep 2
    fi

    # Create .env file for compose
    log_info "Writing compose .env file..."
    cat > "$compose_dir/.env" <<ENVEOF
HF_TOKEN=${HF_TOKEN:-}
MODEL_DIR=${model_dir}
PORT=${PORT}
GPU_MEMORY_UTILIZATION=${GPU_UTIL}
MAX_MODEL_LEN=${CONTEXT}
ENVEOF

    # Start via docker compose
    echo ""
    log_step "Starting TurboQuant container..."
    (cd "$compose_dir" && docker compose -f "$TURBO_COMPOSE_FILE" up -d) 2>&1

    echo "$PORT" > "$PORT_FILE"
    save_config
}

stop_turbo() {
    local compose_dir="$TURBO_COMPOSE_DIR"
    if docker ps -a --format '{{.Names}}' | grep -q "^${TURBO_CONTAINER_NAME}$"; then
        if [[ -d "$compose_dir" && -f "$compose_dir/$TURBO_COMPOSE_FILE" ]]; then
            (cd "$compose_dir" && docker compose -f "$TURBO_COMPOSE_FILE" down) 2>/dev/null || true
        else
            docker stop "$TURBO_CONTAINER_NAME" > /dev/null 2>&1
            docker rm "$TURBO_CONTAINER_NAME" > /dev/null 2>&1
        fi
    fi
    rm -f "$PORT_FILE"
}

# ─── Detect mode ──────────────────────────────────────────────────────────────
detect_mode() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo "${VLLM_MODE:-docker}"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${TURBO_CONTAINER_NAME}$"; then
        echo "turbo"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo "docker"
    elif systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "native"
    else
        echo ""
    fi
}

# ─── Unified Commands ────────────────────────────────────────────────────────
start_server() {
    # Ask for run mode if not specified via flag
    if [[ -z "$RUN_MODE" ]]; then
        echo ""
        echo "Run mode:"
        echo "  1) Docker  — containerized, generic vLLM image (recommended)"
        echo "  2) Native  — pip-installed vLLM, requires manual setup"
        echo "  3) Turbo   — club-3090 Docker + Genesis patches + TurboQuant KV + MTP (recommended for RTX 3090)"
        read -r -p "Select run mode [1]: " mode_choice
        mode_choice="${mode_choice:-1}"
        case "$mode_choice" in
            1) RUN_MODE="docker" ;;
            2) RUN_MODE="native" ;;
            3) RUN_MODE="turbo" ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    fi

    # Gather config based on mode
    if [[ "$RUN_MODE" == "turbo" ]]; then
        gather_turbo_config
    else
        gather_config
    fi

    echo ""
    log_step "=== Starting vLLM Server ==="
    echo "  Model:     $HF_MODEL"
    echo "  Alias:     $MODEL_ALIAS"
    echo "  Context:   $CONTEXT"
    if [[ "$RUN_MODE" != "turbo" ]]; then
        echo "  TP:        $TP_SIZE GPUs"
        echo "  Max seqs:  $MAX_SEQS"
    fi
    echo "  Port:      $PORT"
    echo "  Mode:      $RUN_MODE"
    echo ""

    case "$RUN_MODE" in
        docker) start_docker ;;
        native) start_native ;;
        turbo)  start_turbo ;;
    esac

    # Wait for health
    log_info "Waiting for vLLM to load model (this can take a few minutes)..."
    local wait_secs=5 max_wait=600 elapsed=0
    local check_container="$CONTAINER_NAME"
    [[ "$RUN_MODE" == "turbo" ]] && check_container="$TURBO_CONTAINER_NAME"

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        # Check if process died
        if [[ "$RUN_MODE" == "docker" || "$RUN_MODE" == "turbo" ]]; then
            if ! docker ps --format '{{.Names}}' | grep -q "^${check_container}$"; then
                echo ""
                log_error "Container exited. Check logs: $0 logs"
                exit 1
            fi
        elif [[ "$RUN_MODE" == "native" ]]; then
            if systemctl is-failed --quiet "$SERVICE_NAME" 2>/dev/null; then
                echo ""
                log_error "Service failed. Check: journalctl -u $SERVICE_NAME -n 50"
                exit 1
            fi
        fi

        if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
            echo ""
            log_success "=== vLLM Server ready at http://0.0.0.0:${PORT} ==="
            log_info "API endpoint: http://0.0.0.0:${PORT}/v1/chat/completions"
            log_info "Models:       http://0.0.0.0:${PORT}/v1/models"

            if [[ "$RUN_MODE" == "docker" ]]; then
                log_info "Logs: docker logs -f $CONTAINER_NAME"
            elif [[ "$RUN_MODE" == "turbo" ]]; then
                log_info "Logs: docker logs -f $TURBO_CONTAINER_NAME"
            else
                log_info "Logs: journalctl -u $SERVICE_NAME -f"
            fi

            # Register with New API
            if is_new_api_running; then
                local na_port
                na_port=$(get_new_api_port)
                echo ""
                register_with_new_api "$na_port"
            fi
            return 0
        fi

        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs))
        printf "."
    done

    echo ""
    log_warn "Server did not respond within ${max_wait}s. Model may still be loading."
    log_info "Check: $0 logs"
}

stop_server() {
    local mode
    mode=$(detect_mode)

    if [[ -z "$mode" ]]; then
        log_info "vLLM server is not running"
        return
    fi

    log_info "Stopping vLLM server ($mode mode)..."
    case "$mode" in
        docker) stop_docker ;;
        native) stop_native ;;
        turbo)  stop_turbo ;;
    esac

    rm -f "$CONFIG_FILE"
    log_success "vLLM server stopped"
}

restart_server() {
    stop_server
    sleep 3
    start_server
}

show_status() {
    local mode
    mode=$(detect_mode)

    echo "=== vLLM Server Status ==="
    echo ""

    if [[ -z "$mode" ]]; then
        log_info "vLLM server: not running"
        return
    fi

    if [[ "$mode" == "docker" ]]; then
        log_success "vLLM server: running (Docker container: $CONTAINER_NAME)"
        docker ps --filter "name=$CONTAINER_NAME" --format "  Image: {{.Image}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
    elif [[ "$mode" == "turbo" ]]; then
        log_success "vLLM server: running (Turbo container: $TURBO_CONTAINER_NAME)"
        docker ps --filter "name=$TURBO_CONTAINER_NAME" --format "  Image: {{.Image}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
    else
        log_success "vLLM server: running (systemd service: $SERVICE_NAME)"
        local enabled="disabled"
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && enabled="enabled"
        echo "  Auto-start: $enabled"
    fi

    # Health check
    local port="${DEFAULT_PORT}"
    if [[ -f "$PORT_FILE" ]]; then
        port=$(cat "$PORT_FILE")
    fi

    echo ""
    if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
        log_success "Health: OK (port $port)"

        # Show loaded models
        local models
        models=$(curl -sf "http://127.0.0.1:${port}/v1/models" 2>/dev/null | \
            python3 -c "import json,sys; [print(f'  - {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true)
        if [[ -n "$models" ]]; then
            echo "  Models:"
            echo "$models"
        fi
    else
        log_warn "Health: not responding on port $port"
    fi

    # GPU usage
    echo ""
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | while read -r line; do
        echo "  GPU $line"
    done

    # New API
    echo ""
    if is_new_api_running; then
        local na_port
        na_port=$(get_new_api_port)
        log_success "New API gateway: running (port $na_port)"
    fi
}

show_logs() {
    local mode
    mode=$(detect_mode)

    case "$mode" in
        docker)
            docker logs --tail 50 "$CONTAINER_NAME" 2>&1
            ;;
        turbo)
            docker logs --tail 50 "$TURBO_CONTAINER_NAME" 2>&1
            ;;
        native)
            journalctl -u "$SERVICE_NAME" -n 50 --no-pager
            ;;
        *)
            log_info "vLLM server is not running"
            ;;
    esac
}

# ─── New API Registration ────────────────────────────────────────────────────
register_with_new_api() {
    local na_port="$1"

    # Check if already registered by port
    local existing
    existing=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
        -c "SELECT COUNT(*) FROM channels WHERE base_url LIKE '%:${PORT}' AND status = 1;" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
        log_success "New API: already registered on port $PORT"
        log_info "Proxy endpoint: http://0.0.0.0:${na_port}/v1/chat/completions"
        return
    fi

    if confirm "Register '$MODEL_ALIAS' with New API gateway?" "Y"; then
        local admin_pass=""
        if [[ -f "$HOME/new-api/.credentials" ]]; then
            admin_pass=$(grep NEW_API_ADMIN_PASS "$HOME/new-api/.credentials" 2>/dev/null | cut -d= -f2)
        fi
        if [[ -z "$admin_pass" ]]; then
            read -r -s -p "New API admin password: " admin_pass
            echo ""
        fi

        local admin_user
        admin_user=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
            -c "SELECT username FROM users WHERE role = 100 LIMIT 1;" 2>/dev/null)

        local cookie_jar
        cookie_jar=$(mktemp /tmp/newapi-vllm-XXXXXX)
        curl -s -c "$cookie_jar" "http://127.0.0.1:${na_port}/api/user/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}" > /dev/null 2>&1

        local admin_id
        admin_id=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
            -c "SELECT id FROM users WHERE role = 100 LIMIT 1;" 2>/dev/null)

        local gateway_ip
        gateway_ip=$(docker network inspect new-api_new-api-network 2>/dev/null | \
            python3 -c "import json,sys; print(json.load(sys.stdin)[0]['IPAM']['Config'][0]['Gateway'])" 2>/dev/null || echo "172.17.0.1")

        # For turbo mode, the backend model name differs from the alias
        local model_mapping=""
        if [[ "${RUN_MODE:-}" == "turbo" ]]; then
            model_mapping='{"qwen3.6-27b":"qwen3.6-27b-autoround"}'
        fi

        local resp
        resp=$(curl -s -b "$cookie_jar" "http://127.0.0.1:${na_port}/api/channel/" \
            -H "New-Api-User: $admin_id" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "{
                \"mode\": \"multi_to_single\",
                \"channel\": {
                    \"name\": \"vLLM Server ($MODEL_ALIAS)\",
                    \"type\": 1,
                    \"key\": \"no-key-needed\",
                    \"base_url\": \"http://${gateway_ip}:${PORT}\",
                    \"models\": \"$MODEL_ALIAS\",
                    \"model_mapping\": \"${model_mapping}\",
                    \"group\": \"default,vip,svip\",
                    \"priority\": 1,
                    \"status\": 1,
                    \"weight\": 1
                }
            }")

        if echo "$resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
            curl -s -b "$cookie_jar" "http://127.0.0.1:${na_port}/api/models/" \
                -H "New-Api-User: $admin_id" \
                -H "Content-Type: application/json" \
                -X POST \
                -d "{\"model_name\":\"$MODEL_ALIAS\",\"description\":\"vLLM: $HF_MODEL\",\"tags\":\"local,vllm\",\"status\":1,\"name_rule\":0}" > /dev/null 2>&1 || true
            docker restart new-api > /dev/null 2>&1 || true
            log_success "Registered '$MODEL_ALIAS' with New API"
            log_info "Proxy endpoint: http://0.0.0.0:${na_port}/v1/chat/completions"
        else
            log_warn "Failed to register. Use: bash new-api.sh add-channel"
        fi
        rm -f "$cookie_jar"
    fi
}

# ─── Parse flags and dispatch ────────────────────────────────────────────────
RUN_MODE=""
ACTION=""

for arg in "$@"; do
    case "$arg" in
        --docker) RUN_MODE="docker" ;;
        --native) RUN_MODE="native" ;;
        --turbo) RUN_MODE="turbo" ;;
        start|stop|restart|status|logs)
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
    *)       usage ;;
esac
