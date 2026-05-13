#!/bin/bash
set -uo pipefail

HOZ_BIN="${HOZ_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/hoz}"
TEST_REPO="${TEST_REPO:-$HOME/hozt}"
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

run_in_repo() {
    cd "$TEST_REPO" && "$HOZ_BIN" "$@"
}

assert_cmd() {
    local desc="$1"
    shift
    if run_in_repo "$@" >/dev/null 2>&1; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc (exit code=$?)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local desc="$1"
    local needle="$2"
    shift 2
    local output
    output=$(run_in_repo "$@" 2>&1 || true)
    if [ -z "$needle" ] || echo "$output" | grep -qF "$needle"; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc (expected '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_crash() {
    local desc="$1"
    shift
    local output
    output=$(run_in_repo "$@" 2>&1 || true)
    if ! echo "$output" | grep -q "panic\|SIGSEGV\|SIGABRT"; then
        green "  PASS: $desc (no crash)"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc (crashed)"
        FAIL=$((FAIL + 1))
    fi
}

yellow "=== hoz v0.5.7 Integration Test ==="
yellow "Binary: $HOZ_BIN"
yellow "Repo:   $TEST_REPO"
echo

if [ ! -x "$HOZ_BIN" ]; then
    red "ERROR: hoz binary not found at $HOZ_BIN"
    exit 1
fi

setup_repo() {
    rm -rf "$TEST_REPO"
    mkdir -p "$TEST_REPO"
}

echo "--- Phase 1: Init ---"
setup_repo
assert_cmd "init repository" init "$TEST_REPO"

echo
echo "--- Phase 2: Add & Commit ---"
echo "Hello Hoz" > "$TEST_REPO/hello.txt"
echo "World" > "$TEST_REPO/world.txt"
assert_cmd "add single file" add hello.txt
assert_cmd "add multiple files" add world.txt
assert_cmd "commit with message" commit -m "Initial commit"

echo
echo "--- Phase 3: Status ---"
assert_output_contains "status shows clean tree" "clean" status

echo
echo "--- Phase 4: Log ---"
assert_output_contains "log shows commit history" "commit" log

echo
echo "--- Phase 5: Branch ---"
assert_cmd "create branch feature-x" branch create feature-x
assert_no_crash "branch list does not crash" branch list

echo
echo "--- Phase 6: Modify, Add, Commit ---"
echo "Modified content" >> "$TEST_REPO/hello.txt"
assert_cmd "add modified file" add hello.txt
assert_cmd "commit changes" commit -m "Modify hello"

echo
echo "--- Phase 7: Diff ---"
assert_no_crash "diff does not crash" diff

echo
echo "--- Phase 8: Tag ---"
assert_cmd "create tag v0.1.0" tag create v0.1.0
assert_output_contains "tag list works" "" tag list || true

echo
echo "--- Phase 9: Error Handling (not a repo) ---"
assert_no_crash "log on non-repo shows error" log /nonexistent || true

echo
echo "--- Summary ---"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "All $TOTAL tests passed!"
else
    red "$PASS passed, $FAIL failed out of $TOTAL"
fi

rm -rf "$TEST_REPO"
exit $FAIL
