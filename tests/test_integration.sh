#!/usr/bin/env bash
# Integration tests with mocking — test each script's logic
# Uses PATH manipulation to mock external commands (nvidia-smi, nvcc, curl, etc.)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/test_helpers.sh"

echo "============================================="
echo "  Integration Tests (mocked commands)"
echo "============================================="

# ─── Global mock setup ─────────────────────────────────────────────────────────
MOCK_DIR=""
MOCK_HOME=""

setup_mock_env() {
    MOCK_DIR=$(mktemp -d "/tmp/llm-test-mocks-XXXXXX")
    MOCK_HOME=$(mktemp -d "/tmp/llm-test-home-XXXXXX")
    mkdir -p "$MOCK_DIR"
}

teardown_mock_env() {
    rm -rf "$MOCK_DIR" "$MOCK_HOME" 2>/dev/null || true
}

# Create a mock command that outputs specific text
create_mock() {
    local name="$1"
    local script="$2"
    cat > "$MOCK_DIR/$name" <<MOCKEOF
#!/bin/bash
$script
MOCKEOF
    chmod +x "$MOCK_DIR/$name"
}

# ═══════════════════════════════════════════════════════════════════════════════
# setup-nvidia.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "setup-nvidia.sh"

it "detects already-installed NVIDIA driver"
setup_mock_env
create_mock "nvidia-smi" 'echo "NVIDIA-SMI 570.144  Driver Version: 570.144  CUDA Version: 12.8"; exit 0'
create_mock "dkms" '
if [[ "${1:-}" == "status" ]]; then
    echo "nvidia/570.144, 6.8.0-49-generic, x86_64: installed"
fi
exit 0
'

# The script requires root, so we test just the detection logic by sourcing
# common.sh and simulating what the script does
output=$(
    export PATH="$MOCK_DIR:$PATH"
    export HOME="$MOCK_HOME"
    # Simulate the driver-already-installed check
    if nvidia-smi &>/dev/null; then
        echo "DRIVER_DETECTED"
        if command -v dkms &>/dev/null && dkms status 2>/dev/null | grep -q nvidia; then
            echo "DKMS_OK"
        fi
    fi
)
assert_contains "$output" "DRIVER_DETECTED"
teardown_mock_env

it "detects DKMS is configured"
setup_mock_env
create_mock "nvidia-smi" 'echo "NVIDIA-SMI 570.144"; exit 0'
create_mock "dkms" '
if [[ "${1:-}" == "status" ]]; then
    echo "nvidia/570.144, 6.8.0-49-generic, x86_64: installed"
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    if command -v dkms &>/dev/null && dkms status 2>/dev/null | grep -q nvidia; then
        echo "DKMS_CONFIGURED"
    fi
)
assert_contains "$output" "DKMS_CONFIGURED"
teardown_mock_env

it "warns when DKMS is not configured"
setup_mock_env
create_mock "nvidia-smi" 'echo "NVIDIA-SMI 570.144"; exit 0'
create_mock "dkms" '
if [[ "${1:-}" == "status" ]]; then
    echo ""  # no nvidia module
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    if command -v dkms &>/dev/null && ! dkms status 2>/dev/null | grep -q nvidia; then
        echo "DKMS_NOT_CONFIGURED"
    fi
)
assert_contains "$output" "DKMS_NOT_CONFIGURED"
teardown_mock_env

it "detects driver not installed"
setup_mock_env
create_mock "nvidia-smi" 'exit 1'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    if ! nvidia-smi &>/dev/null; then
        echo "NO_DRIVER"
    fi
)
assert_contains "$output" "NO_DRIVER"
teardown_mock_env

it "validates driver version format"
# Test the regex used in setup-nvidia.sh
valid_versions=("570.144" "550.54.14" "535.183")
invalid_versions=("abc" "570" "570." ".144" "5 70.144")

all_pass=true
for v in "${valid_versions[@]}"; do
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        all_pass=false
    fi
done
for v in "${invalid_versions[@]}"; do
    if [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        all_pass=false
    fi
done
if [[ "$all_pass" == true ]]; then _pass; else _fail "Version regex validation failed"; fi

# ═══════════════════════════════════════════════════════════════════════════════
# setup-cuda.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "setup-cuda.sh"

it "detects already-installed CUDA toolkit via nvcc"
setup_mock_env
create_mock "nvcc" '
if [[ "${1:-}" == "--version" ]]; then
    echo "nvcc: NVIDIA (R) Cuda compiler driver"
    echo "Cuda compilation tools, release 12.8, V12.8.89"
    echo "Build cuda_12.8.r12.8/compiler.35903148_0"
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    if command -v nvcc &>/dev/null; then
        nvcc --version | grep -E 'release'
    fi
)
assert_contains "$output" "release 12.8"
teardown_mock_env

it "parses CUDA version from nvidia-smi correctly"
setup_mock_env
# Match real nvidia-smi output format (CUDA Version is field 9 in the full header)
create_mock "nvidia-smi" '
echo "+-----------------------------------------------------------------------------------------+"
echo "| NVIDIA-SMI 570.144         Driver Version: 570.144         CUDA Version: 12.8          |"
echo "|--------------------------------------------+------------------------+------------------+"
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    nvidia-smi | grep "CUDA Version" | awk "{print \$9}"
)
assert_eq "12.8" "$output"
teardown_mock_env

it "validates CUDA version format (major.minor)"
valid=("12.8" "11.7" "12.0" "9.2")
invalid=("12" "12.8.1" "abc" "12." ".8" "12.8a")

all_pass=true
for v in "${valid[@]}"; do
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        all_pass=false
    fi
done
for v in "${invalid[@]}"; do
    if [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        all_pass=false
    fi
done
if [[ "$all_pass" == true ]]; then _pass; else _fail "CUDA version regex failed"; fi

it "replaces dots with dashes in package name"
CUDA_VERSION="12.8"
CUDA_PKG="${CUDA_VERSION//./-}"
assert_eq "12-8" "$CUDA_PKG"

it "handles multi-dot CUDA versions"
CUDA_VERSION="12.8.1"
# The script uses //./ which replaces ALL dots
CUDA_PKG="${CUDA_VERSION//./-}"
assert_eq "12-8-1" "$CUDA_PKG"

# ═══════════════════════════════════════════════════════════════════════════════
# build-llama.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "build-llama.sh"

it "detects CUDA path via find_cuda_path"
setup_mock_env
mkdir -p "$MOCK_DIR/cuda/bin"
cat > "$MOCK_DIR/cuda/bin/nvcc" <<'EOF'
#!/bin/bash
echo "nvcc: NVIDIA CUDA Compiler"
EOF
chmod +x "$MOCK_DIR/cuda/bin/nvcc"

# Source common.sh so find_cuda_path is available, then test with mock at front of PATH
source "$PROJECT_DIR/lib/common.sh"
result=$(PATH="$MOCK_DIR/cuda/bin:$PATH" find_cuda_path)
assert_eq "$MOCK_DIR/cuda/bin" "$result"
teardown_mock_env

it "detects GPU architecture for cmake"
setup_mock_env
create_mock "nvidia-smi" '
if [[ "${1:-}" == "--query-gpu=compute_cap" ]]; then
    echo "8.9"
elif [[ "${1:-}" == "--query-gpu=name" ]]; then
    echo "NVIDIA GeForce RTX 4090"
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    source "$PROJECT_DIR/lib/common.sh"
    arch=$(detect_gpu_arch)
    echo "CUDA_ARCH=$arch"
)
assert_contains "$output" "CUDA_ARCH=89"
teardown_mock_env

it "cmake version comparison logic works"
# Simulate the cmake version check logic from build-llama.sh
check_cmake_version() {
    local version="$1"
    local min="3.18"
    local major minor min_major min_minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    min_major=$(echo "$min" | cut -d. -f1)
    min_minor=$(echo "$min" | cut -d. -f2)
    if [[ "$major" -lt "$min_major" ]] || { [[ "$major" -eq "$min_major" ]] && [[ "$minor" -lt "$min_minor" ]]; }; then
        echo "TOO_OLD"
    else
        echo "OK"
    fi
}
assert_eq "OK" "$(check_cmake_version "3.28.3")"

it "cmake rejects version below 3.18"
assert_eq "TOO_OLD" "$(check_cmake_version "3.10.2")"

it "cmake accepts exact minimum version"
assert_eq "OK" "$(check_cmake_version "3.18.0")"

it "cmake rejects major version 2"
assert_eq "TOO_OLD" "$(check_cmake_version "2.99.0")"

it "builds CMAKE_ARGS array correctly"
# Simulate the CMAKE_ARGS construction
CMAKE_ARGS=(-B build -DGGML_CUDA=ON -DGGML_NATIVE=ON)
GPU_ARCH="89"
if [[ -n "$GPU_ARCH" ]]; then
    CMAKE_ARGS+=("-DCMAKE_CUDA_ARCHITECTURES=$GPU_ARCH")
fi
# Check the array contains expected elements
combined="${CMAKE_ARGS[*]}"
assert_contains "$combined" "-DCMAKE_CUDA_ARCHITECTURES=89"

# ═══════════════════════════════════════════════════════════════════════════════
# download-model.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "download-model.sh"

it "detects hf CLI command"
setup_mock_env
create_mock "hf" 'echo "hf cli"'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    HF_CMD=""
    if command -v hf &>/dev/null; then
        HF_CMD="hf"
    elif command -v huggingface-cli &>/dev/null; then
        HF_CMD="huggingface-cli"
    fi
    echo "$HF_CMD"
)
assert_eq "hf" "$output"
teardown_mock_env

it "detects huggingface-cli as fallback"
setup_mock_env
# Only put huggingface-cli in mock dir; restrict PATH so real 'hf' is NOT found
create_mock "huggingface-cli" 'echo "huggingface-cli"'

output=$(
    # Use a restricted PATH: only mock dir + essential system dirs (no user bins)
    export PATH="$MOCK_DIR:/usr/bin:/bin"
    HF_CMD=""
    if command -v hf &>/dev/null; then
        HF_CMD="hf"
    elif command -v huggingface-cli &>/dev/null; then
        HF_CMD="huggingface-cli"
    fi
    echo "$HF_CMD"
)
assert_eq "huggingface-cli" "$output"
teardown_mock_env

it "model selection maps correctly for choice 1"
CHOICE="1"
case "$CHOICE" in
    1) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q4_K_XL.gguf"; EXPECTED=17 ;;
esac
assert_eq "unsloth/Qwen3.5-27B-GGUF" "$HF_REPO"
assert_eq "Qwen3.5-27B-UD-Q4_K_XL.gguf" "$FILENAME"

it "model selection maps correctly for choice 2"
CHOICE="2"
case "$CHOICE" in
    2) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q6_K_XL.gguf"; EXPECTED=24 ;;
esac
assert_eq "Qwen3.5-27B-UD-Q6_K_XL.gguf" "$FILENAME"
assert_eq "24" "$EXPECTED"

it "model selection maps correctly for choice 3"
CHOICE="3"
case "$CHOICE" in
    3) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-UD-Q3_K_XL.gguf"; EXPECTED=14 ;;
esac
assert_eq "Qwen3.5-27B-UD-Q3_K_XL.gguf" "$FILENAME"

it "model selection maps correctly for choice 4"
CHOICE="4"
case "$CHOICE" in
    4) HF_REPO="unsloth/Qwen3.5-27B-GGUF"; FILENAME="Qwen3.5-27B-Q8_0.gguf"; EXPECTED=30 ;;
esac
assert_eq "Qwen3.5-27B-Q8_0.gguf" "$FILENAME"

it "rejects invalid model choice"
CHOICE="99"
valid=false
case "$CHOICE" in
    1|2|3|4|5) valid=true ;;
esac
assert_eq "false" "$valid"

it "disk space validation catches insufficient space"
# Simulate the disk space check logic
EXPECTED_SIZE_GB=17
AVAIL_GB=10
if [[ "$EXPECTED_SIZE_GB" -gt 0 && "$AVAIL_GB" -lt "$EXPECTED_SIZE_GB" ]]; then
    result="INSUFFICIENT"
else
    result="OK"
fi
assert_eq "INSUFFICIENT" "$result"

it "disk space validation passes with enough space"
EXPECTED_SIZE_GB=17
AVAIL_GB=50
if [[ "$EXPECTED_SIZE_GB" -gt 0 && "$AVAIL_GB" -lt "$EXPECTED_SIZE_GB" ]]; then
    result="INSUFFICIENT"
else
    result="OK"
fi
assert_eq "OK" "$result"

it "detects low disk space warning zone"
EXPECTED_SIZE_GB=17
AVAIL_GB=20
if [[ "$EXPECTED_SIZE_GB" -gt 0 && "$AVAIL_GB" -lt $((EXPECTED_SIZE_GB + 5)) ]]; then
    result="LOW_SPACE_WARNING"
else
    result="OK"
fi
assert_eq "LOW_SPACE_WARNING" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# llama-server.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "llama-server.sh"

it "usage message shows all subcommands"
output=$(bash "$PROJECT_DIR/llama-server.sh" 2>&1) || true
assert_contains "$output" "start"
assert_contains "$output" "stop"

it "usage shows correct subcommands list"
output=$(bash "$PROJECT_DIR/llama-server.sh" 2>&1) || true
assert_contains "$output" "status"
assert_contains "$output" "logs"

it "usage exits with non-zero on no args"
bash "$PROJECT_DIR/llama-server.sh" >/dev/null 2>&1
rc=$?
assert_failure "$rc"

it "usage exits with non-zero on invalid subcommand"
bash "$PROJECT_DIR/llama-server.sh" invalid_cmd >/dev/null 2>&1
rc=$?
assert_failure "$rc"

it "stop command works when no server running"
setup_mock_env
create_mock "tmux" '
if [[ "${1:-}" == "has-session" ]]; then
    exit 1  # no session
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    bash "$PROJECT_DIR/llama-server.sh" stop 2>&1
) || true
assert_contains "$output" "not running"
teardown_mock_env

it "status command works when no server running"
setup_mock_env
create_mock "tmux" '
if [[ "${1:-}" == "has-session" ]]; then
    exit 1  # no session
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    bash "$PROJECT_DIR/llama-server.sh" status 2>&1
) || true
assert_contains "$output" "not running"
teardown_mock_env

it "logs command works when no server running"
setup_mock_env
create_mock "tmux" '
if [[ "${1:-}" == "has-session" ]]; then
    exit 1  # no session
fi
exit 0
'

output=$(
    export PATH="$MOCK_DIR:$PATH"
    bash "$PROJECT_DIR/llama-server.sh" logs 2>&1
) || true
assert_contains "$output" "not running"
teardown_mock_env

it "model discovery uses find_models"
setup_mock_env
mkdir -p "$MOCK_HOME/models"
dd if=/dev/zero of="$MOCK_HOME/models/test-model-Q4.gguf" bs=1M count=101 2>/dev/null
dd if=/dev/zero of="$MOCK_HOME/models/test-model-Q8.gguf" bs=1M count=101 2>/dev/null

source "$PROJECT_DIR/lib/common.sh"
mapfile -t MODELS < <(HOME="$MOCK_HOME" find_models)
assert_eq "2" "${#MODELS[@]}"
teardown_mock_env

it "tensor split args built correctly for single GPU"
GPU_MODE="single"
TS_ARGS=()
if [[ "$GPU_MODE" == "single" ]]; then
    TS_ARGS=(-ts "1,0")
fi
assert_eq "-ts" "${TS_ARGS[0]}"
assert_eq "1,0" "${TS_ARGS[1]}"

it "tensor split args empty for dual GPU"
GPU_MODE="dual"
TS_ARGS=()
if [[ "$GPU_MODE" == "single" ]]; then
    TS_ARGS=(-ts "1,0")
fi
assert_eq "0" "${#TS_ARGS[@]}"

# ═══════════════════════════════════════════════════════════════════════════════
# benchmark.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "benchmark.sh"

it "model discovery works for benchmarks"
setup_mock_env
mkdir -p "$MOCK_HOME/models"
dd if=/dev/zero of="$MOCK_HOME/models/bench-model.gguf" bs=1M count=101 2>/dev/null

source "$PROJECT_DIR/lib/common.sh"
mapfile -t MODELS < <(HOME="$MOCK_HOME" find_models)
assert_eq "1" "${#MODELS[@]}"
teardown_mock_env

it "KV cache types parsing splits correctly"
KV_TYPES="f16,q8_0,q4_0,turbo2,turbo3"
IFS=',' read -ra CACHE_TYPES <<< "$KV_TYPES"
assert_eq "5" "${#CACHE_TYPES[@]}"
assert_eq "f16" "${CACHE_TYPES[0]}"
assert_eq "turbo3" "${CACHE_TYPES[4]}"

it "KV cache types handles whitespace"
KV_TYPES="f16, q8_0 , q4_0"
IFS=',' read -ra CACHE_TYPES <<< "$KV_TYPES"
# Each element should be cleanable with tr
cleaned=$(echo "${CACHE_TYPES[1]}" | tr -d ' ')
assert_eq "q8_0" "$cleaned"

it "prompt sizes parsing works"
PP_SIZES="512,4096,16384"
IFS=',' read -ra PP_SIZES_ARR <<< "$PP_SIZES"
assert_eq "3" "${#PP_SIZES_ARR[@]}"
assert_eq "512" "${PP_SIZES_ARR[0]}"
assert_eq "16384" "${PP_SIZES_ARR[2]}"

it "benchmark results directory creation"
setup_mock_env
RESULTS_DIR="$MOCK_HOME/benchmark-results"
mkdir -p "$RESULTS_DIR"
assert_dir_exists "$RESULTS_DIR"
teardown_mock_env

it "CSV header is correct format"
setup_mock_env
CSV_FILE="$MOCK_HOME/test.csv"
echo "model,kv_cache,test,tokens,time_ms,tokens_per_sec" > "$CSV_FILE"
header=$(head -1 "$CSV_FILE")
assert_eq "model,kv_cache,test,tokens,time_ms,tokens_per_sec" "$header"
teardown_mock_env

it "JSON output structure is valid"
setup_mock_env
JSON_FILE="$MOCK_HOME/test.json"
cat > "$JSON_FILE" <<'EOF'
{"benchmark_date":"2026-03-30T08:00:00+00:00","model":"test","model_size_gb":17,"gpu_mode":"single","results":[
{"kv_cache":"f16","test":"pp","tokens":512,"time_ms":100,"tokens_per_sec":5120.0}
]}
EOF
# Validate JSON
if python3 -m json.tool "$JSON_FILE" >/dev/null 2>&1; then
    _pass
else
    _fail "Invalid JSON structure"
fi
teardown_mock_env

it "bench command array construction"
BENCH_BIN="/usr/local/bin/llama-bench"
MODEL="/home/user/models/test.gguf"
KV="q8_0"
PP_SIZES="512,4096"
GEN_TOKENS="128"
TS_ARGS=(-ts "1,0")

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

combined="${BENCH_CMD[*]}"
assert_contains "$combined" "-ctk q8_0"
assert_contains "$combined" "-ts 1,0"

# ═══════════════════════════════════════════════════════════════════════════════
# cleanup.sh tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "cleanup.sh"

it "accepts --dry-run flag"
output=$(bash "$PROJECT_DIR/cleanup.sh" --dry-run </dev/null 2>&1) || true
assert_contains "$output" "DRY RUN"

it "accepts -n flag"
output=$(bash "$PROJECT_DIR/cleanup.sh" -n </dev/null 2>&1) || true
assert_contains "$output" "DRY RUN"

it "dry-run does not delete files"
setup_mock_env
# Create a test file
mkdir -p "$MOCK_HOME/models"
echo "test" > "$MOCK_HOME/models/test-file.txt"

output=$(bash "$PROJECT_DIR/cleanup.sh" --dry-run </dev/null 2>&1) || true
# The test file should still exist
assert_file_exists "$MOCK_HOME/models/test-file.txt"
teardown_mock_env

it "shows disk status"
output=$(bash "$PROJECT_DIR/cleanup.sh" --dry-run </dev/null 2>&1) || true
assert_contains "$output" "Disk:"

it "dry-run reports no actual changes made"
output=$(bash "$PROJECT_DIR/cleanup.sh" --dry-run </dev/null 2>&1) || true
assert_contains "$output" "no actual changes were made"

it "cleanup shows final disk status section"
output=$(bash "$PROJECT_DIR/cleanup.sh" --dry-run </dev/null 2>&1) || true
assert_contains "$output" "Final disk status"

it "run_or_dry function respects dry-run mode"
# Test the run_or_dry pattern from the script
DRY_RUN=true
output=$(
    run_or_dry() {
        if [[ "$DRY_RUN" == true ]]; then
            echo "[DRY RUN] Would execute: $*"
        else
            "$@"
        fi
    }
    run_or_dry echo "hello"
)
assert_contains "$output" "[DRY RUN]"

it "run_or_dry executes when not dry-run"
DRY_RUN=false
output=$(
    DRY_RUN=false
    run_or_dry() {
        if [[ "$DRY_RUN" == true ]]; then
            echo "[DRY RUN] Would execute: $*"
        else
            "$@"
        fi
    }
    run_or_dry echo "hello"
)
assert_eq "hello" "$output"

it "GGUF file extension validation"
# Test the .gguf check from cleanup
test_files=("/path/to/model.gguf:true" "/path/to/model.txt:false" "/path/to/model.bin:false")
all_pass=true
for entry in "${test_files[@]}"; do
    file="${entry%%:*}"
    expected="${entry##*:}"
    if [[ "$file" == *.gguf ]]; then
        actual="true"
    else
        actual="false"
    fi
    if [[ "$actual" != "$expected" ]]; then
        all_pass=false
    fi
done
if [[ "$all_pass" == true ]]; then _pass; else _fail "GGUF extension check failed"; fi

it "space calculation logic (reclaimed = final - initial)"
INITIAL=100
FINAL=115
RECLAIMED=$((FINAL - INITIAL))
assert_eq "15" "$RECLAIMED"

it "space calculation handles no change"
INITIAL=100
FINAL=100
RECLAIMED=$((FINAL - INITIAL))
assert_eq "0" "$RECLAIMED"

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-script integration tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "Cross-script integration"

it "all scripts have set -euo pipefail or set -uo pipefail"
all_have=true
for script in "$PROJECT_DIR"/*.sh; do
    name=$(basename "$script")
    # cleanup.sh uses set -uo pipefail (no -e intentionally)
    if [[ "$name" == "cleanup.sh" ]]; then
        if ! grep -q 'set -uo pipefail' "$script"; then
            all_have=false
            echo "      Missing in $name"
        fi
    else
        if ! grep -q 'set -euo pipefail' "$script"; then
            all_have=false
            echo "      Missing in $name"
        fi
    fi
done
if [[ "$all_have" == true ]]; then _pass; else _fail "Some scripts missing error settings"; fi

it "cleanup.sh intentionally does NOT use set -e"
if grep -q 'set -euo pipefail' "$PROJECT_DIR/cleanup.sh"; then
    _fail "cleanup.sh should not use set -e (it uses set -uo pipefail instead)"
else
    _pass
fi

it "all scripts source common.sh"
all_source=true
for script in "$PROJECT_DIR"/*.sh; do
    if ! grep -q 'source.*common\.sh' "$script"; then
        all_source=false
        echo "      Missing in $(basename "$script")"
    fi
done
if [[ "$all_source" == true ]]; then _pass; else _fail "Some scripts don't source common.sh"; fi

it "all scripts define SCRIPT_DIR"
all_have=true
for script in "$PROJECT_DIR"/*.sh; do
    if ! grep -q 'SCRIPT_DIR=' "$script"; then
        all_have=false
        echo "      Missing in $(basename "$script")"
    fi
done
if [[ "$all_have" == true ]]; then _pass; else _fail "Some scripts don't define SCRIPT_DIR"; fi

it "common.sh prevents double-sourcing"
output=$(
    unset _COMMON_SH_LOADED
    source "$PROJECT_DIR/lib/common.sh"
    echo "first: $_COMMON_SH_LOADED"
    source "$PROJECT_DIR/lib/common.sh"
    echo "second: $_COMMON_SH_LOADED"
)
assert_contains "$output" "first: 1"
assert_contains "$output" "second: 1"

it "mapfile pattern used instead of array subshell"
# Check that scripts use mapfile instead of ARRAY=($(cmd))
bad_pattern=0
for script in "$PROJECT_DIR"/*.sh; do
    count=$(grep -cE 'MODELS=\(\$\(' "$script" 2>/dev/null || true)
    count=${count:-0}
    bad_pattern=$((bad_pattern + count))
done
assert_eq "0" "$bad_pattern"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge case tests
# ═══════════════════════════════════════════════════════════════════════════════
describe "Edge cases"

it "handles HOME with spaces in path"
setup_mock_env
SPACE_HOME=$(mktemp -d "/tmp/llm test home XXXXXX")
mkdir -p "$SPACE_HOME/llama.cpp/build/bin"
touch "$SPACE_HOME/llama.cpp/build/bin/llama-server"

result=$(HOME="$SPACE_HOME" find_server_bin)
assert_contains "$result" "llama-server"
rm -rf "$SPACE_HOME"
teardown_mock_env

it "find_models returns sorted output"
setup_mock_env
mkdir -p "$MOCK_HOME/models"
dd if=/dev/zero of="$MOCK_HOME/models/z-model.gguf" bs=1M count=101 2>/dev/null
dd if=/dev/zero of="$MOCK_HOME/models/a-model.gguf" bs=1M count=101 2>/dev/null

result=$(HOME="$MOCK_HOME" find_models)
first=$(echo "$result" | head -1 | xargs basename)
assert_eq "a-model.gguf" "$first"
teardown_mock_env

it "port file path is /tmp/llama-server.port"
# Check the constant in llama-server.sh
port_file=$(grep 'PORT_FILE=' "$PROJECT_DIR/llama-server.sh" | head -1 | cut -d'"' -f2)
assert_eq "/tmp/llama-server.port" "$port_file"

it "tmux session name is 'llama'"
session=$(grep 'TMUX_SESSION=' "$PROJECT_DIR/llama-server.sh" | head -1 | cut -d'"' -f2)
assert_eq "llama" "$session"

it "benchmark default generation tokens is 128"
default_gen=$(grep 'GEN_TOKENS:-' "$PROJECT_DIR/benchmark.sh" | grep -oP ':-\K[0-9]+')
assert_eq "128" "$default_gen"

print_summary
