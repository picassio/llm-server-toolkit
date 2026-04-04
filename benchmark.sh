#!/usr/bin/env bash
# Benchmark llama.cpp with various KV cache types and context sizes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

echo "=== llama.cpp Benchmark ==="

# Find CUDA
CUDA_PATH=""
CUDA_PATH=$(find_cuda_path) || true
if [[ -n "$CUDA_PATH" ]]; then
    export PATH="$CUDA_PATH:$PATH"
fi

# Find llama-bench
BENCH_BIN=""
BENCH_BIN=$(find_bench_bin) || true

if [[ -z "$BENCH_BIN" ]]; then
    read -r -p "Path to llama-bench binary: " BENCH_BIN
fi
if [[ ! -f "$BENCH_BIN" ]]; then
    log_error "llama-bench not found. Build llama.cpp first (build-llama.sh)."
    exit 1
fi
log_info "Using: $BENCH_BIN"

# Find models
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
read -r -p "Select model [1]: " CHOICE
CHOICE="${CHOICE:-1}"

# Validate selection
if ! validate_numeric "$CHOICE" "Model selection"; then
    exit 1
fi
if ! validate_range "$CHOICE" 1 "${#MODELS[@]}" "Model selection"; then
    exit 1
fi

MODEL="${MODELS[$((CHOICE-1))]}"
MODEL_NAME=$(basename "$MODEL" .gguf)
MODEL_SIZE_GB=$(file_size_gb "$MODEL")

# GPU mode
NUM_GPUS=$(detect_gpu_count)
TS_ARGS=()
if [[ "$NUM_GPUS" -gt 1 ]]; then
    [[ "$MODEL_SIZE_GB" -le 20 ]] && DEFAULT_GPU="single" || DEFAULT_GPU="dual"
    read -r -p "GPU mode (single/dual) [$DEFAULT_GPU]: " GPU_MODE
    GPU_MODE="${GPU_MODE:-$DEFAULT_GPU}"
else
    GPU_MODE="single"
fi
[[ "$GPU_MODE" == "single" ]] && TS_ARGS=(-ts "1,0")

# KV cache types to test
echo ""
echo "KV cache types to benchmark (comma-separated)"
read -r -p "Types [f16,q8_0,q4_0,turbo2,turbo3]: " KV_TYPES
KV_TYPES="${KV_TYPES:-f16,q8_0,q4_0,turbo2,turbo3}"

# Prompt sizes
read -r -p "Prompt sizes [512,4096,16384]: " PP_SIZES
PP_SIZES="${PP_SIZES:-512,4096,16384}"

# Generation tokens
read -r -p "Generation tokens [128]: " GEN_TOKENS
GEN_TOKENS="${GEN_TOKENS:-128}"

# Stop server if running
if tmux has-session -t llama 2>/dev/null; then
    echo ""
    if confirm "llama-server is running. Stop it for accurate results?" "Y"; then
        # Graceful stop
        tmux send-keys -t llama C-c 2>/dev/null || true
        sleep 3
        tmux kill-session -t llama 2>/dev/null || true
        sleep 2
    fi
fi

# Setup output files
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"
LOG_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.log"
CSV_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.csv"
JSON_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.json"

# CSV header
echo "model,kv_cache,test,tokens,time_ms,tokens_per_sec" > "$CSV_FILE"

# Start JSON
echo '{"benchmark_date":"'"$(date -Iseconds)"'","model":"'"$MODEL_NAME"'","model_size_gb":'"$MODEL_SIZE_GB"',"gpu_mode":"'"$GPU_MODE"'","results":[' > "$JSON_FILE"

echo ""
echo "=== Benchmarking $MODEL_NAME (${MODEL_SIZE_GB}GB, $GPU_MODE GPU) ===" | tee "$LOG_FILE"
echo "Results will be saved to:" | tee -a "$LOG_FILE"
echo "  Log:  $LOG_FILE" | tee -a "$LOG_FILE"
echo "  CSV:  $CSV_FILE" | tee -a "$LOG_FILE"
echo "  JSON: $JSON_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

IFS=',' read -ra CACHE_TYPES <<< "$KV_TYPES"
FIRST_JSON_ENTRY=true

for KV in "${CACHE_TYPES[@]}"; do
    KV=$(echo "$KV" | tr -d ' ')
    echo "--- KV cache: $KV ---" | tee -a "$LOG_FILE"

    # Build bench command as array
    BENCH_CMD=(
        "$BENCH_BIN"
        -m "$MODEL"
        -ngl 99 -fa 1
        -ctk "$KV" -ctv "$KV"
        -p "$PP_SIZES" -n "$GEN_TOKENS"
    )
    if [[ ${#TS_ARGS[@]} -gt 0 ]]; then
        BENCH_CMD+=("${TS_ARGS[@]}")
    fi

    # Run benchmark and capture output
    BENCH_OUTPUT=$("${BENCH_CMD[@]}" 2>&1) || true
    TABLE_OUTPUT=$(echo "$BENCH_OUTPUT" | grep -E '^\|' || true)

    if [[ -n "$TABLE_OUTPUT" ]]; then
        echo "$TABLE_OUTPUT" | tee -a "$LOG_FILE"

        # Parse benchmark output into CSV/JSON
        # llama-bench output format: | model | size | params | backend | ngl | ... | t/s |
        while IFS='|' read -r _ _ _ _ _ _ _ test tokens _ time_ms speed _; do
            # Clean up fields
            test=$(echo "$test" | tr -d ' ')
            tokens=$(echo "$tokens" | tr -d ' ')
            time_ms=$(echo "$time_ms" | tr -d ' ')
            speed=$(echo "$speed" | tr -d ' ')

            if [[ -n "$speed" && "$speed" != "t/s" && "$test" =~ ^(pp|tg) ]]; then
                echo "$MODEL_NAME,$KV,$test,$tokens,$time_ms,$speed" >> "$CSV_FILE"

                if [[ "$FIRST_JSON_ENTRY" == true ]]; then
                    FIRST_JSON_ENTRY=false
                else
                    echo "," >> "$JSON_FILE"
                fi
                printf '{"kv_cache":"%s","test":"%s","tokens":%s,"time_ms":%s,"tokens_per_sec":%s}' \
                    "$KV" "$test" "${tokens:-0}" "${time_ms:-0}" "${speed:-0}" >> "$JSON_FILE"
            fi
        done <<< "$TABLE_OUTPUT"
    else
        log_warn "No benchmark output for KV cache type: $KV" | tee -a "$LOG_FILE"
    fi
    echo "" | tee -a "$LOG_FILE"
done

# Close JSON
echo ']}'  >> "$JSON_FILE"

# Print comparison summary
echo "=== Comparison Summary ===" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [[ -s "$CSV_FILE" ]]; then
    # Show a table of results grouped by test type
    echo "Prompt Processing (pp) - tokens/sec:" | tee -a "$LOG_FILE"
    printf "  %-12s" "KV Type" | tee -a "$LOG_FILE"
    IFS=',' read -ra PP_SIZES_ARR <<< "$PP_SIZES"
    for ps in "${PP_SIZES_ARR[@]}"; do
        printf "  %-10s" "pp${ps}" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"

    for KV in "${CACHE_TYPES[@]}"; do
        KV=$(echo "$KV" | tr -d ' ')
        printf "  %-12s" "$KV" | tee -a "$LOG_FILE"
        for ps in "${PP_SIZES_ARR[@]}"; do
            speed=$(grep "^$MODEL_NAME,$KV,pp,$ps," "$CSV_FILE" 2>/dev/null | tail -1 | cut -d, -f6)
            printf "  %-10s" "${speed:-n/a}" | tee -a "$LOG_FILE"
        done
        echo "" | tee -a "$LOG_FILE"
    done

    echo "" | tee -a "$LOG_FILE"
    echo "Text Generation (tg) - tokens/sec:" | tee -a "$LOG_FILE"
    for KV in "${CACHE_TYPES[@]}"; do
        KV=$(echo "$KV" | tr -d ' ')
        speed=$(grep "^$MODEL_NAME,$KV,tg," "$CSV_FILE" 2>/dev/null | tail -1 | cut -d, -f6)
        printf "  %-12s %s t/s\n" "$KV" "${speed:-n/a}" | tee -a "$LOG_FILE"
    done
fi

echo "" | tee -a "$LOG_FILE"
log_success "=== Benchmark complete ===" | tee -a "$LOG_FILE"
log_info "Results saved to: $RESULTS_DIR/"
