#!/usr/bin/env bash
# Test runner — runs all test suites and produces a summary
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     LLM Server Toolkit — Test Suite           ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"
echo ""
echo "Project: $PROJECT_DIR"
echo "Date:    $(date -Iseconds)"
echo "Host:    $(hostname)"
echo "Bash:    ${BASH_VERSION}"
echo ""

# ─── Prerequisites ─────────────────────────────────────────────────────────────
echo -e "${CYAN}Checking prerequisites...${NC}"

# Install shellcheck if not present
if ! command -v shellcheck &>/dev/null; then
    echo "Installing shellcheck..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y shellcheck
    elif command -v brew &>/dev/null; then
        brew install shellcheck
    else
        echo -e "${RED}Cannot install shellcheck automatically. Please install it manually.${NC}"
        exit 1
    fi
fi
echo "  shellcheck: $(shellcheck --version 2>/dev/null | grep '^version:' | awk '{print $2}')"
echo "  bash: ${BASH_VERSION}"
echo ""

# ─── Test suites to run ───────────────────────────────────────────────────────
SUITES=(
    "test_shellcheck.sh:Static Analysis"
    "test_functions.sh:Unit Tests"
    "test_integration.sh:Integration Tests"
)

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SUITE_RESULTS=()

# ─── Run each suite ───────────────────────────────────────────────────────────
for entry in "${SUITES[@]}"; do
    suite_file="${entry%%:*}"
    suite_name="${entry##*:}"
    suite_path="$TESTS_DIR/$suite_file"

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Running: $suite_name ($suite_file)${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    if [[ ! -f "$suite_path" ]]; then
        echo -e "${RED}Suite file not found: $suite_path${NC}"
        FAILED_SUITES=$((FAILED_SUITES + 1))
        SUITE_RESULTS+=("${RED}✗ $suite_name — file not found${NC}")
        continue
    fi

    # Run the test suite and capture exit code
    start_time=$(date +%s%N)
    bash "$suite_path"
    suite_rc=$?
    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo ""

    if [[ "$suite_rc" -eq 0 ]]; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        SUITE_RESULTS+=("${GREEN}✓ $suite_name${NC} (${elapsed_ms}ms)")
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        SUITE_RESULTS+=("${RED}✗ $suite_name${NC} (${elapsed_ms}ms)")
    fi

    echo ""
done

# ─── Overall summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          Overall Test Results                 ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Suites run: $TOTAL_SUITES"
echo ""

for result in "${SUITE_RESULTS[@]}"; do
    echo -e "  $result"
done

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "$FAILED_SUITES" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}ALL $TOTAL_SUITES SUITES PASSED${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}$FAILED_SUITES of $TOTAL_SUITES SUITES FAILED${NC}"
    echo ""
    exit 1
fi
