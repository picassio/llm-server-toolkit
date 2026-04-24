#!/usr/bin/env bash
# Start/stop/manage Luce DFlash speculative decoding server
# Qwen3.5/3.6-27B with DDTree, ~90 tok/s on single RTX 3090
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

SERVICE_NAME="dflash-server"
PORT_FILE="/tmp/dflash-server.port"
CONFIG_FILE="/tmp/dflash-server.conf"
DEFAULT_PORT="8000"
DFLASH_DIR="${DFLASH_DIR:-$HOME/lucebox-hub/dflash}"

usage() {
    cat <<EOF
Usage: $0 {setup|start|stop|restart|status|logs|bench}

  setup    - Clone, build, and download models for DFlash
  start    - Start DFlash OpenAI-compatible server
  stop     - Stop the server
  restart  - Restart the server
  status   - Check server health
  logs     - Show server logs
  bench    - Run benchmark suite (HumanEval + GSM8K + Math500)

Options (for start):
  --model-name NAME   Model name for API (default: qwen3.5-27b)
  --max-ctx N         Max context length (default: 16384)
  --budget N          DDTree budget (default: 22)
  --port N            Server port (default: 8000)

Performance (Qwen3.5-27B Q4_K_M, single RTX 3090):
  HumanEval: 91.4 tok/s  (2.83× faster than autoregressive)
  Math500:   78.6 tok/s  (2.45×)
  GSM8K:     72.7 tok/s  (2.26×)
  128K context fits in 24GB with Q4 KV cache
EOF
    exit 1
}

# ─── Detect mode ──────────────────────────────────────────────────────────────
detect_mode() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "systemd"
    else
        echo ""
    fi
}

require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required."
        sudo true || { log_error "Cannot get sudo access."; exit 1; }
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
do_setup() {
    echo "=== DFlash Setup ==="
    echo ""

    require_command cmake "sudo apt-get install cmake"
    require_command nvcc "Run setup-cuda.sh first"

    # Clone if not present
    if [[ ! -d "$DFLASH_DIR" ]]; then
        log_step "[1/4] Cloning lucebox-hub..."
        git clone --recurse-submodules https://github.com/Luce-Org/lucebox-hub "$HOME/lucebox-hub"
    else
        log_success "[1/4] lucebox-hub already cloned"
    fi

    # Build
    log_step "[2/4] Building DFlash (this takes ~3 min)..."
    cd "$DFLASH_DIR"
    local gpu_arch
    gpu_arch=$(detect_gpu_arch)

    local cuda_compiler=""
    cuda_compiler=$(command -v nvcc 2>/dev/null || find /usr/local/cuda*/bin -name nvcc 2>/dev/null | head -1)

    cmake -B build -S . \
        -DCMAKE_CUDA_ARCHITECTURES="${gpu_arch:-86}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER="$cuda_compiler" \
        2>&1 | tail -3

    cmake --build build --target test_dflash -j"$(nproc)" 2>&1 | tail -3
    cmake --build build --target test_generate -j"$(nproc)" 2>&1 | tail -3

    if [[ ! -f build/test_dflash ]]; then
        log_error "Build failed."
        exit 1
    fi
    log_success "[2/4] Build complete"

    # Download models
    log_step "[3/4] Downloading models..."
    mkdir -p models/draft

    local target_file="models/Qwen3.5-27B-Q4_K_M.gguf"
    local draft_file="models/draft/model.safetensors"

    if [[ ! -f "$target_file" ]]; then
        log_info "Downloading Qwen3.5-27B Q4_K_M target (~16GB)..."
        if command -v hf &>/dev/null; then
            hf download unsloth/Qwen3.5-27B-GGUF Qwen3.5-27B-Q4_K_M.gguf --local-dir models/
        elif command -v huggingface-cli &>/dev/null; then
            huggingface-cli download unsloth/Qwen3.5-27B-GGUF Qwen3.5-27B-Q4_K_M.gguf --local-dir models/
        else
            log_error "HuggingFace CLI not found. Install: pip install huggingface_hub"
            exit 1
        fi
    else
        log_success "Target model already downloaded"
    fi

    if [[ ! -f "$draft_file" ]]; then
        log_info "Downloading DFlash draft model (~3.5GB)..."
        if command -v hf &>/dev/null; then
            hf download z-lab/Qwen3.5-27B-DFlash model.safetensors --local-dir models/draft/
        else
            huggingface-cli download z-lab/Qwen3.5-27B-DFlash model.safetensors --local-dir models/draft/
        fi
    else
        log_success "Draft model already downloaded"
    fi

    # Install Python deps
    log_step "[4/4] Installing Python dependencies..."
    pip install -q fastapi uvicorn transformers safetensors datasets 2>&1 | tail -2

    echo ""
    log_success "=== DFlash Setup Complete ==="
    echo ""
    echo "  Directory: $DFLASH_DIR"
    echo "  Target:    Qwen3.5-27B Q4_K_M (16GB)"
    echo "  Draft:     z-lab/Qwen3.5-27B-DFlash (3.5GB)"
    echo ""
    echo "  Start:     bash dflash-server.sh start"
    echo "  Benchmark: bash dflash-server.sh bench"
}

# ─── Start ────────────────────────────────────────────────────────────────────
do_start() {
    if [[ ! -d "$DFLASH_DIR" || ! -f "$DFLASH_DIR/build/test_dflash" ]]; then
        log_error "DFlash not set up. Run: $0 setup"
        exit 1
    fi

    require_sudo

    # Stop existing
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping existing server..."
        sudo systemctl stop "$SERVICE_NAME"
        sleep 3
    fi

    # Port
    read -r -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! validate_numeric "$PORT" "Port"; then exit 1; fi

    # Max context
    read -r -p "Max context [16384]: " MAX_CTX
    MAX_CTX="${MAX_CTX:-16384}"
    if ! validate_numeric "$MAX_CTX" "Max context"; then exit 1; fi

    # DDTree budget
    read -r -p "DDTree budget [22]: " BUDGET
    BUDGET="${BUDGET:-22}"

    # Model name for API
    read -r -p "Model name for API [qwen3.5-27b]: " MODEL_NAME
    MODEL_NAME="${MODEL_NAME:-qwen3.5-27b}"

    # Find CUDA
    local cuda_path=""
    cuda_path=$(find_cuda_path) || true
    local env_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -n "$cuda_path" ]]; then
        env_path="${cuda_path}:${env_path}"
    fi
    local ld_lib=""
    if [[ -n "$cuda_path" ]]; then
        ld_lib="Environment=LD_LIBRARY_PATH=$(dirname "$cuda_path")/lib64"
    fi

    local hf_token=""
    if [[ -f "$HOME/.cache/huggingface/token" ]]; then
        hf_token=$(cat "$HOME/.cache/huggingface/token")
    fi

    local python_bin
    python_bin=$(command -v python3)

    # Create systemd service
    log_info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=DFlash Server ($MODEL_NAME, DDTree budget=$BUDGET)
After=network.target

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$DFLASH_DIR

Environment=PATH=${env_path}
${ld_lib}
Environment=HF_TOKEN=${hf_token}
Environment=DFLASH_MODEL_NAME=${MODEL_NAME}

ExecStart=${python_bin} scripts/server.py \
  --port ${PORT} \
  --max-ctx ${MAX_CTX} \
  --budget ${BUDGET}

Restart=on-failure
RestartSec=10
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
    sudo systemctl enable "$SERVICE_NAME"

    echo "$PORT" > "$PORT_FILE"
    cat > "$CONFIG_FILE" <<CONF
DFLASH_PORT=$PORT
DFLASH_MODEL=$MODEL_NAME
DFLASH_CTX=$MAX_CTX
DFLASH_BUDGET=$BUDGET
CONF

    echo ""
    log_step "=== Starting DFlash Server ==="
    echo "  Model:   $MODEL_NAME"
    echo "  Context: $MAX_CTX"
    echo "  Budget:  $BUDGET"
    echo "  Port:    $PORT"
    echo ""

    log_info "Waiting for model to load..."
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:${PORT}/v1/models" &>/dev/null; then
            echo ""
            log_success "=== DFlash server ready at http://0.0.0.0:${PORT} ==="
            log_info "Endpoint:  http://0.0.0.0:${PORT}/v1/chat/completions"
            log_info "Logs:      journalctl -u $SERVICE_NAME -f"

            # Auto-register with New API
            if is_new_api_running; then
                local na_port
                na_port=$(get_new_api_port)
                echo ""
                _register_new_api "$na_port" "$PORT" "$MODEL_NAME"
            fi
            return 0
        fi
        if systemctl is-failed --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo ""
            log_error "Service failed. Check: journalctl -u $SERVICE_NAME -n 30"
            exit 1
        fi
        sleep 3
        printf "."
    done
    echo ""
    log_warn "Server still loading. Check: $0 logs"
}

_register_new_api() {
    local na_port="$1" backend_port="$2" model_alias="$3"

    local existing
    existing=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
        -c "SELECT COUNT(*) FROM channels WHERE base_url LIKE '%:${backend_port}' AND status = 1;" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
        # Update model name if changed
        docker exec new-api-postgres psql -U newapi -d new-api -c \
            "UPDATE channels SET models = '$model_alias' WHERE base_url LIKE '%:${backend_port}';" > /dev/null 2>&1
        docker exec new-api-postgres psql -U newapi -d new-api -c "DELETE FROM abilities;" > /dev/null 2>&1
        docker exec new-api-redis redis-cli FLUSHALL > /dev/null 2>&1
        docker restart new-api > /dev/null 2>&1 || true
        log_success "New API: updated model name to '$model_alias'"
        log_info "Proxy endpoint: http://0.0.0.0:${na_port}/v1/chat/completions"
        return
    fi

    if confirm "Register '$model_alias' with New API gateway?" "Y"; then
        local admin_pass=""
        if [[ -f "$HOME/new-api/.credentials" ]]; then
            admin_pass=$(grep NEW_API_ADMIN_PASS "$HOME/new-api/.credentials" 2>/dev/null | cut -d= -f2)
        fi
        local admin_user
        admin_user=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
            -c "SELECT username FROM users WHERE role = 100 LIMIT 1;" 2>/dev/null)
        local admin_id
        admin_id=$(docker exec new-api-postgres psql -U newapi -d new-api -t -A \
            -c "SELECT id FROM users WHERE role = 100 LIMIT 1;" 2>/dev/null)

        local cookie_jar
        cookie_jar=$(mktemp /tmp/newapi-df-XXXXXX)
        curl -s -c "$cookie_jar" "http://127.0.0.1:${na_port}/api/user/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}" > /dev/null 2>&1

        local gateway_ip
        gateway_ip=$(docker network inspect new-api_new-api-network 2>/dev/null | \
            python3 -c "import json,sys; print(json.load(sys.stdin)[0]['IPAM']['Config'][0]['Gateway'])" 2>/dev/null || echo "172.17.0.1")

        local resp
        resp=$(curl -s -b "$cookie_jar" "http://127.0.0.1:${na_port}/api/channel/" \
            -H "New-Api-User: $admin_id" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "{
                \"mode\": \"multi_to_single\",
                \"channel\": {
                    \"name\": \"DFlash Server ($model_alias)\",
                    \"type\": 1,
                    \"key\": \"no-key-needed\",
                    \"base_url\": \"http://${gateway_ip}:${backend_port}\",
                    \"models\": \"$model_alias\",
                    \"model_mapping\": \"\",
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
                -d "{\"model_name\":\"$model_alias\",\"description\":\"DFlash+DDTree speculative decoding (~90 t/s)\",\"tags\":\"local,dflash\",\"status\":1,\"name_rule\":0}" > /dev/null 2>&1 || true
            docker restart new-api > /dev/null 2>&1 || true
            log_success "Registered '$model_alias' with New API"
        else
            log_warn "Failed to register. Use: bash new-api.sh add-channel"
        fi
        rm -f "$cookie_jar"
    fi
}

# ─── Stop / Restart ───────────────────────────────────────────────────────────
do_stop() {
    require_sudo
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping DFlash server..."
        sudo systemctl stop "$SERVICE_NAME"
        rm -f "$PORT_FILE" "$CONFIG_FILE"
        log_success "DFlash server stopped"
    else
        log_info "DFlash server is not running"
    fi
}

do_restart() {
    do_stop
    sleep 3
    do_start
}

# ─── Status ───────────────────────────────────────────────────────────────────
do_status() {
    echo "=== DFlash Server Status ==="
    echo ""

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        local enabled="disabled"
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && enabled="enabled"
        log_success "Service: running (boot=$enabled)"

        local port="$DEFAULT_PORT"
        if [[ -f "$PORT_FILE" ]]; then
            port=$(cat "$PORT_FILE")
        fi

        if curl -sf "http://127.0.0.1:${port}/v1/models" &>/dev/null; then
            local model
            model=$(curl -sf "http://127.0.0.1:${port}/v1/models" | \
                python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "?")
            log_success "API: healthy (port $port, model: $model)"
        else
            log_warn "API: not responding on port $port"
        fi

        echo ""
        nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader 2>/dev/null | while read -r line; do
            echo "  GPU $line"
        done

        if is_new_api_running; then
            local na_port
            na_port=$(get_new_api_port)
            echo ""
            log_success "New API gateway: running (port $na_port)"
        fi
    else
        log_info "DFlash server: not running"
        if [[ -d "$DFLASH_DIR" && -f "$DFLASH_DIR/build/test_dflash" ]]; then
            log_info "DFlash is built. Start with: $0 start"
        else
            log_info "Run setup first: $0 setup"
        fi
    fi
}

# ─── Logs ─────────────────────────────────────────────────────────────────────
do_logs() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || \
       journalctl -u "$SERVICE_NAME" -n 1 &>/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    else
        log_info "No logs available. Is the server running?"
    fi
}

# ─── Benchmark ────────────────────────────────────────────────────────────────
do_bench() {
    if [[ ! -d "$DFLASH_DIR" || ! -f "$DFLASH_DIR/build/test_dflash" ]]; then
        log_error "DFlash not set up. Run: $0 setup"
        exit 1
    fi

    # Stop server if running (bench needs exclusive GPU access)
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_warn "Stopping server for benchmark (needs exclusive GPU)..."
        sudo systemctl stop "$SERVICE_NAME"
        sleep 3
    fi

    cd "$DFLASH_DIR"

    echo "=== DFlash Benchmark ==="
    echo ""
    echo "Running HumanEval + GSM8K + Math500 (10 prompts each, n_gen=256)"
    echo "This takes ~15 minutes..."
    echo ""

    python3 scripts/bench_llm.py --n-gen 256 2>&1 | grep -E "SUMMARY|Task|Bench|HumanEval|GSM8K|Math500|Mean|===|mean"

    echo ""
    log_info "Full results saved to /tmp/dflash_bench/"

    # Offer to restart server
    if confirm "Restart DFlash server?" "Y"; then
        sudo systemctl start "$SERVICE_NAME"
        log_success "Server restarted"
    fi
}

# ─── Parse flags and dispatch ────────────────────────────────────────────────
# Parse optional flags that override defaults
for arg in "$@"; do
    case "$arg" in
        --model-name=*) OPT_MODEL_NAME="${arg#*=}" ;;
        --max-ctx=*)    OPT_MAX_CTX="${arg#*=}" ;;
        --budget=*)     OPT_BUDGET="${arg#*=}" ;;
        --port=*)       OPT_PORT="${arg#*=}" ;;
    esac
done

case "${1:-}" in
    setup)   do_setup ;;
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    logs)    do_logs ;;
    bench)   do_bench ;;
    *)       usage ;;
esac
