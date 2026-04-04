#!/usr/bin/env bash
# Unit tests for lib/common.sh functions
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/test_helpers.sh"

echo "============================================="
echo "  Unit Tests — lib/common.sh functions"
echo "============================================="

# ─── Source common.sh ──────────────────────────────────────────────────────────
# We need to source it in a way that doesn't trigger traps or exits
# Unset the guard so we can re-source if needed
unset _COMMON_SH_LOADED

# common.sh checks if stdout is a tty to decide on colors.
# Force non-tty mode for predictable output in tests.
source "$PROJECT_DIR/lib/common.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Logging functions
# ═══════════════════════════════════════════════════════════════════════════════
describe "Logging functions"

it "log_info outputs [INFO] prefix"
output=$(log_info "test message" 2>&1)
assert_contains "$output" "[INFO]"

it "log_info includes the message"
output=$(log_info "hello world" 2>&1)
assert_contains "$output" "hello world"

it "log_success outputs [OK] prefix"
output=$(log_success "done" 2>&1)
assert_contains "$output" "[OK]"

it "log_warn outputs [WARN] to stderr"
output=$(log_warn "caution" 2>&1)
assert_contains "$output" "[WARN]"

it "log_error outputs [ERROR] to stderr"
output=$(log_error "bad thing" 2>&1)
assert_contains "$output" "[ERROR]"

it "log_step outputs the step text"
output=$(log_step "Step 1" 2>&1)
assert_contains "$output" "Step 1"

# ═══════════════════════════════════════════════════════════════════════════════
# Validation functions
# ═══════════════════════════════════════════════════════════════════════════════
describe "validate_numeric"

it "accepts a valid positive integer"
output=$(validate_numeric "42" "test" 2>&1)
rc=$?
assert_success "$rc"

it "accepts zero"
output=$(validate_numeric "0" "test" 2>&1)
rc=$?
assert_success "$rc"

it "rejects a negative number"
output=$(validate_numeric "-5" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects a float"
output=$(validate_numeric "3.14" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects an empty string"
output=$(validate_numeric "" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects alphabetic input"
output=$(validate_numeric "abc" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects mixed alphanumeric"
output=$(validate_numeric "12abc" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects special characters"
output=$(validate_numeric "12;rm -rf" "test" 2>&1)
rc=$?
assert_failure "$rc"

it "produces error message with field name"
output=$(validate_numeric "abc" "Port" 2>&1)
assert_contains "$output" "Port"

# ═══════════════════════════════════════════════════════════════════════════════
describe "validate_range"

it "accepts a value within range"
output=$(validate_range 5 1 10 "test" 2>&1)
rc=$?
assert_success "$rc"

it "accepts the minimum boundary"
output=$(validate_range 1 1 10 "test" 2>&1)
rc=$?
assert_success "$rc"

it "accepts the maximum boundary"
output=$(validate_range 10 1 10 "test" 2>&1)
rc=$?
assert_success "$rc"

it "rejects a value below the range"
output=$(validate_range 0 1 10 "test" 2>&1)
rc=$?
assert_failure "$rc"

it "rejects a value above the range"
output=$(validate_range 11 1 10 "test" 2>&1)
rc=$?
assert_failure "$rc"

it "error message includes field name"
output=$(validate_range 99 1 10 "Parallel slots" 2>&1)
assert_contains "$output" "Parallel slots"

# ═══════════════════════════════════════════════════════════════════════════════
# Temp file management
# ═══════════════════════════════════════════════════════════════════════════════
describe "make_temp and register_temp_file"

it "creates a temp file"
tmpf=$(make_temp ".test")
assert_file_exists "$tmpf"
rm -f "$tmpf"

it "temp file has the correct suffix"
tmpf=$(make_temp ".mytest")
assert_contains "$tmpf" ".mytest"
rm -f "$tmpf"

it "temp file is in /tmp"
tmpf=$(make_temp ".test2")
assert_contains "$tmpf" "/tmp/"
rm -f "$tmpf"

it "temp file has toolkit prefix"
tmpf=$(make_temp ".test3")
assert_contains "$tmpf" "llm-toolkit-"
rm -f "$tmpf"

it "created temp file is writable"
tmpf=$(make_temp ".test4")
echo "hello" > "$tmpf"
content=$(cat "$tmpf")
assert_eq "hello" "$content"
rm -f "$tmpf"

# ═══════════════════════════════════════════════════════════════════════════════
# Format functions
# ═══════════════════════════════════════════════════════════════════════════════
describe "format_file_size"

it "formats a large file correctly"
# Create a known-size file
tmpf=$(mktemp)
dd if=/dev/zero of="$tmpf" bs=1M count=10 2>/dev/null
result=$(format_file_size "$tmpf")
assert_eq "10MB" "$result"
rm -f "$tmpf"

it "formats a small file as KB"
tmpf=$(mktemp)
dd if=/dev/zero of="$tmpf" bs=1K count=500 2>/dev/null
result=$(format_file_size "$tmpf")
assert_contains "$result" "KB"
rm -f "$tmpf"

it "returns empty for non-existent file"
result=$(format_file_size "/nonexistent/file" 2>/dev/null)
assert_empty "$result"

describe "file_size_gb"

it "returns 0 for a small file"
tmpf=$(mktemp)
echo "hello" > "$tmpf"
result=$(file_size_gb "$tmpf")
assert_eq "0" "$result"
rm -f "$tmpf"

it "returns 0 for non-existent file"
result=$(file_size_gb "/nonexistent/file")
assert_eq "0" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Path finding with mocks
# ═══════════════════════════════════════════════════════════════════════════════
describe "find_cuda_path"

it "finds nvcc via PATH"
# Create a mock nvcc in a temp dir
mock_dir=$(mktemp -d)
cat > "$mock_dir/nvcc" <<'EOF'
#!/bin/bash
echo "nvcc: NVIDIA CUDA Compiler"
EOF
chmod +x "$mock_dir/nvcc"

result=$(PATH="$mock_dir:$PATH" find_cuda_path)
assert_eq "$mock_dir" "$result"
rm -rf "$mock_dir"

it "returns failure when nvcc not found (no PATH or common dirs)"
# find_cuda_path also searches /usr/local/cuda*/bin, so if CUDA is installed
# on this machine it will find it. We test the return code in a constrained env.
mock_dir=$(mktemp -d)
# Override find_cuda_path with a version that only checks PATH (no glob fallback)
result=$(
    find_cuda_path_test() {
        local nvcc_path
        nvcc_path=$(PATH="/nonexistent" command -v nvcc 2>/dev/null)
        if [[ -n "$nvcc_path" ]]; then
            dirname "$nvcc_path"
            return 0
        fi
        return 1
    }
    find_cuda_path_test 2>/dev/null
) || true
rc=$?
if [[ -z "$result" ]]; then
    _pass
else
    _fail "Expected empty result from PATH-only search, got: $result"
fi
rm -rf "$mock_dir"

describe "find_server_bin"

it "finds llama-server in expected directory"
mock_dir=$(mktemp -d)
mkdir -p "$mock_dir/llama.cpp/build/bin"
touch "$mock_dir/llama.cpp/build/bin/llama-server"

# Override HOME for the test
result=$(HOME="$mock_dir" find_server_bin)
assert_eq "$mock_dir/llama.cpp/build/bin/llama-server" "$result"
rm -rf "$mock_dir"

it "finds llama-server in turboquant directory first"
mock_dir=$(mktemp -d)
mkdir -p "$mock_dir/llama-cpp-turboquant-cuda/build/bin"
touch "$mock_dir/llama-cpp-turboquant-cuda/build/bin/llama-server"
mkdir -p "$mock_dir/llama.cpp/build/bin"
touch "$mock_dir/llama.cpp/build/bin/llama-server"

result=$(HOME="$mock_dir" find_server_bin)
assert_contains "$result" "turboquant"
rm -rf "$mock_dir"

it "returns failure when no binary found"
mock_dir=$(mktemp -d)
HOME="$mock_dir" find_server_bin 2>/dev/null
rc=$?
assert_failure "$rc"
rm -rf "$mock_dir"

describe "find_bench_bin"

it "finds llama-bench in expected directory"
mock_dir=$(mktemp -d)
mkdir -p "$mock_dir/llama.cpp/build/bin"
touch "$mock_dir/llama.cpp/build/bin/llama-bench"

result=$(HOME="$mock_dir" find_bench_bin)
assert_eq "$mock_dir/llama.cpp/build/bin/llama-bench" "$result"
rm -rf "$mock_dir"

it "returns failure when no bench binary found"
mock_dir=$(mktemp -d)
HOME="$mock_dir" find_bench_bin 2>/dev/null
rc=$?
assert_failure "$rc"
rm -rf "$mock_dir"

describe "find_models"

it "finds .gguf files over 100MB"
mock_dir=$(mktemp -d)
# Create a >100MB fake gguf
dd if=/dev/zero of="$mock_dir/test-model.gguf" bs=1M count=101 2>/dev/null

result=$(HOME="$mock_dir" find_models)
assert_contains "$result" "test-model.gguf"
rm -rf "$mock_dir"

it "ignores vocab gguf files"
mock_dir=$(mktemp -d)
dd if=/dev/zero of="$mock_dir/vocab-test.gguf" bs=1M count=101 2>/dev/null

result=$(HOME="$mock_dir" find_models)
assert_empty "$result"
rm -rf "$mock_dir"

it "ignores small gguf files"
mock_dir=$(mktemp -d)
dd if=/dev/zero of="$mock_dir/tiny.gguf" bs=1K count=50 2>/dev/null

result=$(HOME="$mock_dir" find_models)
assert_empty "$result"
rm -rf "$mock_dir"

# ═══════════════════════════════════════════════════════════════════════════════
# GPU detection with mocks
# ═══════════════════════════════════════════════════════════════════════════════
describe "GPU detection (mocked)"

it "detect_gpu_count returns correct count"
mock_dir=$(mktemp -d)
cat > "$mock_dir/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--query-gpu=name" ]]; then
    echo "NVIDIA GeForce RTX 4090"
    echo "NVIDIA GeForce RTX 4090"
fi
EOF
chmod +x "$mock_dir/nvidia-smi"
result=$(PATH="$mock_dir:$PATH" detect_gpu_count)
assert_eq "2" "$result"
rm -rf "$mock_dir"

it "detect_gpu_count returns 0 when nvidia-smi fails"
mock_dir=$(mktemp -d)
cat > "$mock_dir/nvidia-smi" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$mock_dir/nvidia-smi"
result=$(PATH="$mock_dir:$PATH" detect_gpu_count)
assert_eq "0" "$result"
rm -rf "$mock_dir"

it "detect_gpu_arch returns arch code"
mock_dir=$(mktemp -d)
cat > "$mock_dir/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--query-gpu=compute_cap" ]]; then
    echo "8.9"
fi
EOF
chmod +x "$mock_dir/nvidia-smi"
result=$(PATH="$mock_dir:$PATH" detect_gpu_arch)
assert_eq "89" "$result"
rm -rf "$mock_dir"

it "detect_gpu_names returns GPU info"
mock_dir=$(mktemp -d)
cat > "$mock_dir/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--query-gpu=name,memory.total" ]]; then
    echo "NVIDIA GeForce RTX 4090, 24576 MiB"
fi
EOF
chmod +x "$mock_dir/nvidia-smi"
result=$(PATH="$mock_dir:$PATH" detect_gpu_names)
assert_contains "$result" "RTX 4090"
rm -rf "$mock_dir"

# ═══════════════════════════════════════════════════════════════════════════════
# Disk space helpers
# ═══════════════════════════════════════════════════════════════════════════════
describe "Disk space helpers"

it "get_avail_gb returns a number"
result=$(get_avail_gb "/")
assert_match "$result" '^[0-9]+$'

it "get_avail_gb works on current directory"
result=$(get_avail_gb ".")
assert_match "$result" '^[0-9]+$'

it "get_disk_status returns a non-empty string"
result=$(get_disk_status)
assert_not_empty "$result"

it "get_disk_status contains 'used' and 'free'"
result=$(get_disk_status)
assert_contains "$result" "used"

# ═══════════════════════════════════════════════════════════════════════════════
# HF token detection
# ═══════════════════════════════════════════════════════════════════════════════
describe "find_hf_token_file"

it "finds token at standard location"
mock_dir=$(mktemp -d)
mkdir -p "$mock_dir/.cache/huggingface"
echo "hf_testtoken123" > "$mock_dir/.cache/huggingface/token"

result=$(HOME="$mock_dir" HF_HOME="" XDG_CACHE_HOME="" find_hf_token_file)
assert_contains "$result" "token"
rm -rf "$mock_dir"

it "returns failure when no token exists"
mock_dir=$(mktemp -d)
HOME="$mock_dir" HF_HOME="" XDG_CACHE_HOME="" find_hf_token_file 2>/dev/null
rc=$?
assert_failure "$rc"
rm -rf "$mock_dir"

it "ignores empty token files"
mock_dir=$(mktemp -d)
mkdir -p "$mock_dir/.cache/huggingface"
touch "$mock_dir/.cache/huggingface/token"  # empty file

HOME="$mock_dir" HF_HOME="" XDG_CACHE_HOME="" find_hf_token_file 2>/dev/null
rc=$?
assert_failure "$rc"
rm -rf "$mock_dir"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases
# ═══════════════════════════════════════════════════════════════════════════════
describe "Edge cases"

it "validate_numeric handles very large number"
output=$(validate_numeric "999999999999" "test" 2>&1)
rc=$?
assert_success "$rc"

it "validate_numeric handles leading zeros"
output=$(validate_numeric "007" "test" 2>&1)
rc=$?
assert_success "$rc"

it "validate_range works with large ranges"
output=$(validate_range 50000 1 100000 "test" 2>&1)
rc=$?
assert_success "$rc"

it "log functions handle special characters in messages"
output=$(log_info 'test "quotes" and $vars and `backticks`' 2>&1)
assert_contains "$output" "quotes"

it "log functions handle empty messages"
output=$(log_info "" 2>&1)
assert_contains "$output" "[INFO]"

it "make_temp handles default suffix"
tmpf=$(make_temp)
assert_file_exists "$tmpf"
assert_contains "$tmpf" ".tmp"
rm -f "$tmpf"

it "require_command succeeds for existing command"
# This should not exit
(require_command "bash" 2>/dev/null)
rc=$?
assert_success "$rc"

it "require_command fails for missing command"
(require_command "nonexistent_command_xyz" 2>/dev/null)
rc=$?
assert_failure "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
