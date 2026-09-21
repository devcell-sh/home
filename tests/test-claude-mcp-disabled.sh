#!/bin/bash
# Test: Claude MCP merge with disabledMcpServers support
# Verifies that ALL servers (enabled + disabled) are merged into .claude.json,
# and disabled server names are managed in .claude.json projects[].disabledMcpServers.
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
source "$SCRIPT_DIR/modules/fragments/mcp-toggle.sh"

# ── jq filter: merge ALL servers into .claude.json (strip enabled field) ──
JQ_MERGE_SERVERS='
  .[0] as $existing |
  .[1].mcpServers as $nix |
  (($existing.mcpServers // {}) | to_entries |
    map(select(.value.command == null or (.value.command | startswith("/opt/devcell/") | not))) |
    from_entries) as $cleaned |
  ($nix // {} | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries) as $nixClean |
  $existing | .mcpServers = ($cleaned + $nixClean)
'

# ── jq filter: compute disabled server names from nix config ──
JQ_DISABLED_LIST='
  [(.mcpServers // {}) | to_entries[] |
    select(.value.enabled != true and ((.key as $k | $enabled_list | index($k)) == null)) |
    .key]
'

# ── Test 1: all servers (enabled + disabled) merged into .claude.json ────
echo "Test 1: all servers merged regardless of enabled flag"
result=$(jq -s "$JQ_MERGE_SERVERS" \
    <(echo '{"mcpServers":{}}') \
    <(echo '{"mcpServers":{"srv-a":{"command":"/opt/devcell/bin/a","enabled":true},"srv-b":{"command":"/opt/devcell/bin/b","enabled":false}}}'))
actual=$(echo "$result" | jq -c '.mcpServers | keys')
assert_eq "both servers present" '["srv-a","srv-b"]' "$actual"

# ── Test 2: enabled field stripped from merged servers ───────────────────
echo "Test 2: enabled field stripped"
actual=$(echo "$result" | jq '.mcpServers["srv-a"] | has("enabled")')
assert_eq "srv-a no enabled field" "false" "$actual"
actual=$(echo "$result" | jq '.mcpServers["srv-b"] | has("enabled")')
assert_eq "srv-b no enabled field" "false" "$actual"

# ── Test 3: disabled list computed correctly ─────────────────────────────
echo "Test 3: disabled list from nix config"
actual=$(jq -c --argjson enabled_list '[]' "$JQ_DISABLED_LIST" \
    <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":false},"srv-c":{}}}'))
assert_eq "disabled = srv-b, srv-c" '["srv-b","srv-c"]' "$actual"

# ── Test 4: DEVCELL_MCP_ENABLED overrides disabled ───────────────────────
echo "Test 4: DEVCELL_MCP_ENABLED makes server enabled"
actual=$(jq -c --argjson enabled_list '["srv-b"]' "$JQ_DISABLED_LIST" \
    <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":false},"srv-c":{}}}'))
assert_eq "only srv-c disabled" '["srv-c"]' "$actual"

# ── Test 5: disableMcp writes to projects[].disabledMcpServers ───────────
echo "Test 5: disableMcp targets projects[].disabledMcpServers"
cat > "$TMPDIR_TEST/claude.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"},"srv-b":{"command":"b"}},"projects":{"/test":{}}}
EOF
disableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
actual=$(jq -c '.projects["/test"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "srv-b in disabledMcpServers" '["srv-b"]' "$actual"

# ── Test 6: enableMcp removes from projects[].disabledMcpServers ─────────
echo "Test 6: enableMcp removes from disabledMcpServers"
enableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
actual=$(jq -c '.projects["/test"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "srv-b removed" '[]' "$actual"

# ── Test 7: mcpServers preserved after disable/enable ────────────────────
echo "Test 7: mcpServers preserved after toggle"
actual=$(jq -c '.mcpServers | keys' "$TMPDIR_TEST/claude.json")
assert_eq "servers intact" '["srv-a","srv-b"]' "$actual"

# ── Test 8: stale /opt/devcell/ servers still cleaned ────────────────────
echo "Test 8: stale /opt/devcell/ servers cleaned on merge"
result=$(jq -s "$JQ_MERGE_SERVERS" \
    <(echo '{"mcpServers":{"old-srv":{"command":"/opt/devcell/old/bin"},"user-srv":{"command":"/usr/bin/foo"}}}') \
    <(echo '{"mcpServers":{"new-srv":{"command":"/opt/devcell/bin/new","enabled":true}}}'))
actual=$(echo "$result" | jq -c '.mcpServers | keys')
assert_eq "old-srv removed, user+new kept" '["new-srv","user-srv"]' "$actual"

# ── Test 9: fresh .claude.json (seed path) ───────────────────────────────
echo "Test 9: seed creates .claude.json with all servers"
JQ_SEED='{mcpServers: ((.mcpServers // {}) | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries)}'
result=$(jq "$JQ_SEED" \
    <(echo '{"mcpServers":{"s1":{"command":"a","enabled":true},"s2":{"command":"b","enabled":false}}}'))
actual=$(echo "$result" | jq -c '.mcpServers | keys')
assert_eq "both servers in seed" '["s1","s2"]' "$actual"
actual=$(echo "$result" | jq '.mcpServers.s1 | has("enabled")')
assert_eq "enabled stripped in seed" "false" "$actual"

# ── Test 10: empty disabled list when all enabled ────────────────────────
echo "Test 10: all enabled means empty disabled list"
actual=$(jq -c --argjson enabled_list '[]' "$JQ_DISABLED_LIST" \
    <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":true}}}'))
assert_eq "empty disabled" '[]' "$actual"

# ── Test 11: disableMcp creates project entry if needed ──────────────────
echo "Test 11: disableMcp creates project entry"
cat > "$TMPDIR_TEST/claude2.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"}}}
EOF
disableMcp claude srv-a "$TMPDIR_TEST/claude2.json" /new-project
actual=$(jq -c '.projects["/new-project"].disabledMcpServers' "$TMPDIR_TEST/claude2.json")
assert_eq "project created with disabled" '["srv-a"]' "$actual"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
