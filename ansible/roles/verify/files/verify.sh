#!/usr/bin/env bash
# devhost verification harness.
#
#   bash ~/.devhost-verify/verify.sh [test-name ...]
#
# Exit codes: 0 all tests passed (skips allowed), 1 at least one failure.
# A test exits 2 to signal SKIP (environment not ready, e.g. Tailscale not
# authenticated yet); that never fails the run.
set -uo pipefail

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${DEVHOST_VERIFY_LOG_DIR:-/var/log/devhost-verify}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$(mktemp -d)"

green="\033[0;32m"; red="\033[0;31m"; yellow="\033[0;33m"; reset="\033[0m"
pass() { printf "${green}PASS${reset} %s\n" "$1"; }
fail() { printf "${red}FAIL${reset} %s\n" "$1"; FAILED=$((FAILED + 1)); }
skip() { printf "${yellow}SKIP${reset} %s\n" "$1"; SKIPPED=$((SKIPPED + 1)); }

FAILED=0
SKIPPED=0
PASSED=0
START=$(date +%s)

echo "=========================================="
echo "devhost verification — $(hostname) — $(date)"
echo "=========================================="

if [ $# -gt 0 ]; then
    TESTS=()
    for name in "$@"; do
        match=("$VERIFY_DIR"/tests/*"$name"*.sh)
        TESTS+=("${match[@]}")
    done
else
    TESTS=("$VERIFY_DIR"/tests/*.sh)
fi

for test in "${TESTS[@]}"; do
    [ -f "$test" ] || continue
    name="$(basename "$test" .sh)"
    echo
    echo "--- $name ---"
    log="$LOG_DIR/${name}.$(date +%Y%m%d-%H%M%S).log"

    bash "$test" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"

    case "$rc" in
        0) PASSED=$((PASSED + 1)); pass "$name" ;;
        2) skip "$name" ;;
        *) fail "$name" ;;
    esac
done

END=$(date +%s)
echo
echo "=========================================="
echo "passed: $PASSED  skipped: $SKIPPED  failed: $FAILED  elapsed: $((END - START))s"
echo "logs: $LOG_DIR"
echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
    printf "${green}all tests passed${reset}\n"
    exit 0
fi
printf "${red}%d test(s) failed${reset}\n" "$FAILED"
exit 1
