#!/usr/bin/env bash
# Static analysis tests — run shellcheck on all scripts
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/test_helpers.sh"

echo "============================================="
echo "  Static Analysis Tests (shellcheck)"
echo "============================================="

# ─── Check shellcheck is available ─────────────────────────────────────────────
describe "Prerequisites"

it "shellcheck is installed"
if command -v shellcheck &>/dev/null; then
    _pass
    SC_VERSION=$(shellcheck --version | grep '^version:' | awk '{print $2}')
    echo "    shellcheck version: $SC_VERSION"
else
    _fail "shellcheck not found in PATH"
    echo "Install with: sudo apt-get install -y shellcheck"
    print_summary
    exit 1
fi

# ─── Collect all shell scripts ──────────────────────────────────────────────────
SCRIPTS=()
while IFS= read -r -d '' f; do
    SCRIPTS+=("$f")
done < <(find "$PROJECT_DIR" -name "*.sh" -not -path "*/tests/*" -print0 | sort -z)

describe "Script inventory"

it "found shell scripts to check"
assert_not_empty "${SCRIPTS[*]}"
echo "    Scripts: ${#SCRIPTS[@]}"
for s in "${SCRIPTS[@]}"; do
    echo "      $(basename "$s")"
done

# ─── Run shellcheck at warning severity (catches error + warning) ──────────────
describe "shellcheck --severity=warning (errors and warnings)"

ALL_CLEAN=true
for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")
    it "$name has no errors or warnings"

    # Run shellcheck, capture output and exit code
    sc_output=$(shellcheck --severity=warning --format=gcc "$script" 2>&1) || true
    sc_exit=${PIPESTATUS[0]:-$?}

    if [[ -z "$sc_output" ]]; then
        _pass
    else
        # Count issues
        num_issues=$(echo "$sc_output" | wc -l)
        _fail "shellcheck found $num_issues issue(s)"
        echo "$sc_output" | head -10 | sed 's/^/      /'
        ALL_CLEAN=false
    fi
done

# ─── Run shellcheck at info severity (for informational purposes, no fail) ─────
describe "shellcheck --severity=info (informational, non-blocking)"

for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")
    it "$name info-level check"

    sc_output=$(shellcheck --severity=info --format=gcc "$script" 2>&1) || true

    if [[ -z "$sc_output" ]]; then
        _pass
    else
        num_issues=$(echo "$sc_output" | wc -l)
        # Info level issues are not failures
        _pass
        echo -e "    ${_T_YELLOW}(${num_issues} info-level notes)${_T_NC}"
    fi
done

# ─── Check script headers and permissions ──────────────────────────────────────
describe "Script headers and permissions"

for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")

    it "$name has bash shebang"
    first_line=$(head -1 "$script")
    if [[ "$first_line" == "#!/usr/bin/env bash" || "$first_line" == "#!/bin/bash" ]]; then
        _pass
    else
        _fail "Expected bash shebang, got: $first_line"
    fi
done

for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")
    # Only check executable permission for top-level scripts
    if [[ "$(dirname "$script")" == "$PROJECT_DIR" ]]; then
        it "$name is executable"
        if [[ -x "$script" ]]; then
            _pass
        else
            _fail "$name is not executable"
        fi
    fi
done

# ─── Check for common bash anti-patterns (beyond shellcheck) ──────────────────
describe "Additional pattern checks"

it "no scripts use 'eval' unsafely"
unsafe_eval=0
for script in "${SCRIPTS[@]}"; do
    # eval of saved shopt output is OK; look for other eval usage
    count=$(grep -cE '^\s*eval\b' "$script" 2>/dev/null || true)
    count=${count:-0}
    shopt_eval=$(grep -cE 'eval "\$old_nullglob"' "$script" 2>/dev/null || true)
    shopt_eval=${shopt_eval:-0}
    unsafe=$((count - shopt_eval))
    if [[ "$unsafe" -gt 0 ]]; then
        unsafe_eval=$((unsafe_eval + unsafe))
    fi
done
if [[ "$unsafe_eval" -eq 0 ]]; then
    _pass
else
    _fail "Found $unsafe_eval potentially unsafe eval usage(s)"
fi

it "all scripts source common.sh (except common.sh itself)"
missing_source=0
for script in "${SCRIPTS[@]}"; do
    name=$(basename "$script")
    [[ "$name" == "common.sh" ]] && continue
    if ! grep -q 'source.*common\.sh' "$script" 2>/dev/null; then
        missing_source=$((missing_source + 1))
        echo "      Missing: $name"
    fi
done
if [[ "$missing_source" -eq 0 ]]; then
    _pass
else
    _fail "$missing_source script(s) don't source common.sh"
fi

it "no TODO or FIXME markers remain"
todo_count=0
for script in "${SCRIPTS[@]}"; do
    count=$(grep -ciE '\b(TODO|FIXME|HACK|XXX)\b' "$script" 2>/dev/null || true)
    count=${count:-0}
    todo_count=$((todo_count + count))
done
if [[ "$todo_count" -eq 0 ]]; then
    _pass
else
    _fail "Found $todo_count TODO/FIXME markers"
fi

print_summary
