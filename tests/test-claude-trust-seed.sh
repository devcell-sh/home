#!/bin/bash
# Test: Claude Code trust seeding for the cell's project mount
# Every cell start mounts the project at /<cell>-<n>, a path Claude Code has
# never seen, so it asks "Is this a project you trust?" again. The fragment
# marks the mount as trusted in ~/.claude.json projects[] before Claude runs.
set -euo pipefail

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The fragment runs merges on source; load only the function under test.
eval "$(sed -n '/^seed_claude_trust()/,/^}/p' "$SCRIPT_DIR/modules/fragments/30-claude.sh")"
log() { :; }

echo "Test 1: missing project entry is created as trusted"
cj="$TMPDIR_TEST/1.json"
echo '{"mcpServers":{}}' > "$cj"
seed_claude_trust "$cj" "/devcell-83"
assert_eq "trusted" "true" "$(jq '.projects["/devcell-83"].hasTrustDialogAccepted' "$cj")"
assert_eq "mcpServers kept" "{}" "$(jq -c '.mcpServers' "$cj")"

echo "Test 2: existing project entry keeps its other keys"
cj="$TMPDIR_TEST/2.json"
echo '{"projects":{"/devcell-83":{"disabledMcpServers":["x"],"hasTrustDialogAccepted":false}}}' > "$cj"
seed_claude_trust "$cj" "/devcell-83"
assert_eq "trusted" "true" "$(jq '.projects["/devcell-83"].hasTrustDialogAccepted' "$cj")"
assert_eq "disabled list kept" '["x"]' "$(jq -c '.projects["/devcell-83"].disabledMcpServers' "$cj")"

echo "Test 3: already trusted entry is left untouched"
cj="$TMPDIR_TEST/3.json"
echo '{"projects":{"/devcell-83":{"hasTrustDialogAccepted":true}}}' > "$cj"
before=$(stat -c %Y "$cj" 2>/dev/null || stat -f %m "$cj")
sleep 1
seed_claude_trust "$cj" "/devcell-83"
after=$(stat -c %Y "$cj" 2>/dev/null || stat -f %m "$cj")
assert_eq "file not rewritten" "$before" "$after"

echo "Test 4: missing or corrupt file is skipped"
cj="$TMPDIR_TEST/4.json"
seed_claude_trust "$cj" "/devcell-83"
assert_eq "no file created" "false" "$([ -f "$cj" ] && echo true || echo false)"
echo '{not json' > "$cj"
seed_claude_trust "$cj" "/devcell-83"
assert_eq "corrupt left as is" "{not json" "$(cat "$cj")"

echo
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
