#!/bin/bash
# End-to-end test: exercises merge_claude_mcp + sync_claude_mcp_state
# from 30-claude.sh against fixture files in a temp directory.
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

# Stub out entrypoint helpers the fragment expects
log() { :; }
notify() { :; }
export -f log notify
export HOME="$TMPDIR_TEST/home"
export HOST_USER="testuser"
export DEVCELL_HOME="$TMPDIR_TEST/devcell"
export HOSTNAME="cell-test-project"

mkdir -p "$HOME/.claude" "$DEVCELL_HOME"

# Source mcp-toggle.sh first (as 29-mcp-toggle.sh would be sourced before 30-claude.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/modules/fragments/mcp-toggle.sh"

# Source only the functions from 30-claude.sh (skip the execution at the bottom)
FRAGMENT="$SCRIPT_DIR/modules/fragments/30-claude.sh"
eval "$(sed -n '/^_mcp_enabled_json()/,/^}/p' "$FRAGMENT")"
eval "$(sed -n '/^merge_claude_mcp()/,/^}/p' "$FRAGMENT")"
eval "$(sed -n '/^sync_claude_mcp_state()/,/^}/p' "$FRAGMENT")"

# ── Fixture: nix MCP config with 3 servers (2 enabled, 1 disabled) ───────
setup_nix_config() {
    mkdir -p /tmp/test-claude-code
    cat > /tmp/test-claude-code/nix-mcp-servers.json <<'EOF'
{
  "backupBeforeMerge": false,
  "mcpServers": {
    "playwright": {"command": "/opt/devcell/bin/playwright-mcp", "args": [], "enabled": true},
    "linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "enabled": true},
    "gimp": {"command": "/opt/devcell/bin/gimp-mcp", "args": [], "enabled": false}
  }
}
EOF
}

# Override the nix file path used by the functions
override_nix_path() {
    if [ -d /etc/claude-code ]; then
        sudo cp /tmp/test-claude-code/nix-mcp-servers.json /etc/claude-code/nix-mcp-servers.json
        return 0
    fi
    sudo mkdir -p /etc/claude-code
    sudo cp /tmp/test-claude-code/nix-mcp-servers.json /etc/claude-code/nix-mcp-servers.json
}

setup_nix_config
override_nix_path

# ── Test 1: fresh start — all 3 servers in .claude.json ──────────────────
echo "Test 1: fresh start merges all servers"
rm -f "$HOME/.claude.json"
unset DEVCELL_MCP_ENABLED
merge_claude_mcp "$HOME/.claude.json"

actual=$(jq -c '.mcpServers | keys | sort' "$HOME/.claude.json")
assert_eq "all 3 servers present" '["gimp","linear","playwright"]' "$actual"
actual=$(jq '.mcpServers.gimp | has("enabled")' "$HOME/.claude.json")
assert_eq "enabled field stripped" "false" "$actual"

# ── Test 2: sync disabled into .claude.json projects ─────────────────────
echo "Test 2: disabled server in projects[].disabledMcpServers"
sync_claude_mcp_state "$HOME/.claude.json"

actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")
assert_eq "gimp disabled" '["gimp"]' "$actual"
actual=$(jq -c '.mcpServers | keys | sort' "$HOME/.claude.json")
assert_eq "all servers still present" '["gimp","linear","playwright"]' "$actual"

# ── Test 3: DEVCELL_MCP_ENABLED overrides ────────────────────────────────
echo "Test 3: DEVCELL_MCP_ENABLED enables gimp"
export DEVCELL_MCP_ENABLED="gimp"
sync_claude_mcp_state "$HOME/.claude.json"

actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")
assert_eq "empty disabled (all enabled)" '[]' "$actual"
unset DEVCELL_MCP_ENABLED

# ── Test 4: re-sync restores disabled state ──────────────────────────────
echo "Test 4: re-sync restores disabled state"
sync_claude_mcp_state "$HOME/.claude.json"
actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")
assert_eq "gimp disabled again" '["gimp"]' "$actual"

# ── Test 5: re-merge is idempotent ───────────────────────────────────────
echo "Test 5: idempotent merge"
local_before=$(jq -cS '.' "$HOME/.claude.json")
merge_claude_mcp "$HOME/.claude.json"
local_after=$(jq -cS '.' "$HOME/.claude.json")
assert_eq "claude.json unchanged" "$local_before" "$local_after"

sync_claude_mcp_state "$HOME/.claude.json"
state_after=$(jq -cS '.' "$HOME/.claude.json")
assert_eq "state unchanged after re-sync" "$local_before" "$state_after"

# ── Test 6: stale /opt/devcell/ server removed on re-merge ──────────────
echo "Test 6: stale server cleanup"
jq '.mcpServers["old-stale"] = {"command":"/opt/devcell/old/bin","args":[]}' \
    "$HOME/.claude.json" > "$HOME/.claude.json.tmp"
mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
merge_claude_mcp "$HOME/.claude.json"
actual=$(jq '.mcpServers | has("old-stale")' "$HOME/.claude.json")
assert_eq "stale server removed" "false" "$actual"

# ── Cleanup ──────────────────────────────────────────────────────────────
rm -rf /tmp/test-claude-code

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
