#!/usr/bin/env bash
# Simple bash test framework
# Source this in test files for assert functions, counters, and summary output.

_TEST_PASS=0
_TEST_FAIL=0
_TEST_SKIP=0
_TEST_CURRENT=""
_TEST_FAILURES=()

# Colors (only when stdout is a terminal, or forced for test output)
_T_RED='\033[0;31m'
_T_GREEN='\033[0;32m'
_T_YELLOW='\033[1;33m'
_T_CYAN='\033[0;36m'
_T_BOLD='\033[1m'
_T_NC='\033[0m'

# ── Describe / It ─────────────────────────────────────────────────────────────
describe() {
    echo -e "\n${_T_CYAN}${_T_BOLD}▸ $1${_T_NC}"
}

it() {
    _TEST_CURRENT="$1"
}

# ── Assertions ─────────────────────────────────────────────────────────────────
_pass() {
    _TEST_PASS=$((_TEST_PASS + 1))
    echo -e "  ${_T_GREEN}✓${_T_NC} $_TEST_CURRENT"
}

_fail() {
    local msg="$1"
    _TEST_FAIL=$((_TEST_FAIL + 1))
    _TEST_FAILURES+=("$_TEST_CURRENT: $msg")
    echo -e "  ${_T_RED}✗${_T_NC} $_TEST_CURRENT"
    echo -e "    ${_T_RED}$msg${_T_NC}"
}

_skip() {
    local reason="${1:-}"
    _TEST_SKIP=$((_TEST_SKIP + 1))
    echo -e "  ${_T_YELLOW}○${_T_NC} $_TEST_CURRENT (SKIPPED${reason:+: $reason})"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        _pass
    else
        _fail "Expected '$expected', got '$actual'${msg:+ ($msg)}"
    fi
}

assert_neq() {
    local unexpected="$1"
    local actual="$2"
    if [[ "$unexpected" != "$actual" ]]; then
        _pass
    else
        _fail "Expected value to differ from '$unexpected'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass
    else
        _fail "Expected output to contain '$needle', got: '${haystack:0:200}'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass
    else
        _fail "Expected output NOT to contain '$needle'"
    fi
}

assert_match() {
    local text="$1"
    local pattern="$2"
    if [[ "$text" =~ $pattern ]]; then
        _pass
    else
        _fail "Expected '$text' to match pattern '$pattern'"
    fi
}

assert_success() {
    local exit_code="$1"
    if [[ "$exit_code" -eq 0 ]]; then
        _pass
    else
        _fail "Expected exit code 0, got $exit_code"
    fi
}

assert_failure() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 ]]; then
        _pass
    else
        _fail "Expected non-zero exit code, got 0"
    fi
}

assert_file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        _pass
    else
        _fail "Expected file to exist: $path"
    fi
}

assert_dir_exists() {
    local path="$1"
    if [[ -d "$path" ]]; then
        _pass
    else
        _fail "Expected directory to exist: $path"
    fi
}

assert_empty() {
    local val="$1"
    if [[ -z "$val" ]]; then
        _pass
    else
        _fail "Expected empty string, got: '$val'"
    fi
}

assert_not_empty() {
    local val="$1"
    if [[ -n "$val" ]]; then
        _pass
    else
        _fail "Expected non-empty string"
    fi
}

skip_test() {
    _skip "${1:-}"
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
    local total=$((_TEST_PASS + _TEST_FAIL + _TEST_SKIP))
    echo ""
    echo -e "${_T_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_T_NC}"
    echo -e "${_T_BOLD}Test Summary${_T_NC}"
    echo -e "  Total:   $total"
    echo -e "  ${_T_GREEN}Passed:  $_TEST_PASS${_T_NC}"
    if [[ $_TEST_FAIL -gt 0 ]]; then
        echo -e "  ${_T_RED}Failed:  $_TEST_FAIL${_T_NC}"
    else
        echo -e "  Failed:  0"
    fi
    if [[ $_TEST_SKIP -gt 0 ]]; then
        echo -e "  ${_T_YELLOW}Skipped: $_TEST_SKIP${_T_NC}"
    fi
    echo -e "${_T_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_T_NC}"

    if [[ ${#_TEST_FAILURES[@]} -gt 0 ]]; then
        echo ""
        echo -e "${_T_RED}Failures:${_T_NC}"
        for f in "${_TEST_FAILURES[@]}"; do
            echo -e "  ${_T_RED}• $f${_T_NC}"
        done
    fi

    if [[ $_TEST_FAIL -gt 0 ]]; then
        echo ""
        echo -e "${_T_RED}${_T_BOLD}FAIL${_T_NC}"
        return 1
    else
        echo ""
        echo -e "${_T_GREEN}${_T_BOLD}PASS${_T_NC}"
        return 0
    fi
}
