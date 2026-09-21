#!/bin/bash
# Test: opencode provider/plugin/MCP merge targets the global config path
# so that plugins and servers resolve regardless of CWD.
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

# Stub entrypoint helpers
log() { :; }
notify() { :; }
export -f log notify
export HOME="$TMPDIR_TEST/home"
export HOST_USER="testuser"
export DEVCELL_HOME="$TMPDIR_TEST/devcell"
export HOSTNAME="cell-test-project"

mkdir -p "$HOME/.config/opencode" "$DEVCELL_HOME"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/modules/fragments/mcp-toggle.sh"

FRAGMENT="$SCRIPT_DIR/modules/fragments/30-opencode.sh"
eval "$(sed -n '/^_mcp_enabled_json()/,/^}/p' "$FRAGMENT")"
eval "$(sed -n '/^merge_opencode_providers()/,/^}/p' "$FRAGMENT")"
eval "$(sed -n '/^merge_opencode_mcp()/,/^}/p' "$FRAGMENT")"

# ── Fixture: nix provider config with plugin ──
setup_nix_provider() {
    sudo mkdir -p /etc/opencode
    cat > /tmp/test-opencode-providers.json <<'EOF'
{
  "provider": {
    "test-provider": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Test Provider",
      "options": {"baseURL": "http://localhost:1234/v1"}
    }
  },
  "plugin": ["opencode-throughput"]
}
EOF
    sudo cp /tmp/test-opencode-providers.json /etc/opencode/nix-providers.json
}

setup_nix_mcp() {
    cat > /tmp/test-opencode-mcp.json <<'EOF'
{
  "backupBeforeMerge": false,
  "mcp": {
    "playwright": {"type": "local", "command": ["/opt/devcell/bin/pw"], "enabled": true}
  }
}
EOF
    sudo cp /tmp/test-opencode-mcp.json /etc/opencode/nix-mcp-servers.json
}

setup_nix_provider
setup_nix_mcp

OC_GLOBAL="$HOME/.config/opencode/opencode.json"

# ── Test 1: providers merge into global config path ──────────────────────
echo "Test 1: providers merge into global config"
merge_opencode_providers "$OC_GLOBAL"
actual=$(jq -c '.provider | keys' "$OC_GLOBAL")
assert_eq "provider in global config" '["test-provider"]' "$actual"

# ── Test 2: plugins merge into global config path ────────────────────────
echo "Test 2: plugins in global config"
actual=$(jq -c '.plugin' "$OC_GLOBAL")
assert_eq "plugin in global config" '["opencode-throughput"]' "$actual"

# ── Test 3: MCP servers merge into global config (not ~/.opencode.json) ──
echo "Test 3: MCP servers in global config"
merge_opencode_mcp "$OC_GLOBAL"
actual=$(jq -c '.mcp | keys' "$OC_GLOBAL")
assert_eq "mcp in global config" '["playwright"]' "$actual"

# ── Test 4: no stale ~/opencode.json or ~/.opencode.json created ─────────
echo "Test 4: no stale home-dir configs"
assert_eq "no ~/opencode.json" "false" "$([ -f "$HOME/opencode.json" ] && echo true || echo false)"
assert_eq "no ~/.opencode.json" "false" "$([ -f "$HOME/.opencode.json" ] && echo true || echo false)"

# ── Test 5: providers + MCP coexist in same file ─────────────────────────
echo "Test 5: providers and MCP coexist"
actual=$(jq -c '{p: (.provider | keys), m: (.mcp | keys)}' "$OC_GLOBAL")
assert_eq "both sections present" '{"p":["test-provider"],"m":["playwright"]}' "$actual"

# ── Test 6: re-merge is idempotent ───────────────────────────────────────
echo "Test 6: idempotent merge"
before=$(jq -cS '.' "$OC_GLOBAL")
merge_opencode_providers "$OC_GLOBAL"
merge_opencode_mcp "$OC_GLOBAL"
after=$(jq -cS '.' "$OC_GLOBAL")
assert_eq "config unchanged after re-merge" "$before" "$after"

# ── Test 7: prefers .jsonc when it exists ─────────────────────────────────
echo "Test 7: prefers .jsonc over .json"
rm -f "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"
echo '{"$schema":"https://opencode.ai/config.json"}' > "$HOME/.config/opencode/opencode.jsonc"
OC_JSONC="$HOME/.config/opencode/opencode.jsonc"
merge_opencode_providers "$OC_JSONC"
actual=$(jq -c '.provider | keys' "$OC_JSONC")
assert_eq "provider in jsonc" '["test-provider"]' "$actual"
assert_eq "no .json created" "false" "$([ -f "$HOME/.config/opencode/opencode.json" ] && echo true || echo false)"

# ── Cleanup ──────────────────────────────────────────────────────────────
rm -f /tmp/test-opencode-providers.json /tmp/test-opencode-mcp.json

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
