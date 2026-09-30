#!/bin/bash
# Test: notify() writes a .warn sentinel with the message as its body
set -euo pipefail
PASS=0; FAIL=0
TMPDIR_TEST=$(mktemp -d); trap 'rm -rf "$TMPDIR_TEST"' EXIT
assert_eq() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; echo "    expected: $2"; echo "    actual:   $3"; FAIL=$((FAIL+1)); fi; }
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/modules/fragments/00-notify.sh"

export DEVCELL_BOOT_DIR="$TMPDIR_TEST/boot"; mkdir -p "$DEVCELL_BOOT_DIR"
echo "Test 1: plain sentinel is an empty file"
notify mise.ready
assert_eq "exists" "true" "$([ -f "$DEVCELL_BOOT_DIR/mise.ready" ] && echo true || echo false)"
assert_eq "empty" "0" "$(wc -c < "$DEVCELL_BOOT_DIR/mise.ready" | tr -d ' ')"

echo "Test 2: warn sentinel carries the message"
notify gcroot.warn "Nix config drift: 3 variants"
assert_eq "body" "Nix config drift: 3 variants" "$(cat "$DEVCELL_BOOT_DIR/gcroot.warn")"

echo "Test 3: no boot dir is a silent no-op"
DEVCELL_BOOT_DIR="$TMPDIR_TEST/missing" notify x.warn "msg"
assert_eq "nothing created" "false" "$([ -e "$TMPDIR_TEST/missing" ] && echo true || echo false)"

echo; echo "Passed: $PASS, Failed: $FAIL"; [ "$FAIL" -eq 0 ]
