#!/bin/bash
# Test: disableMcp / enableMcp abstraction across claude, codex, opencode
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

source "$SCRIPT_DIR/modules/fragments/mcp-toggle.sh"

# ── Claude ───────────────────────────────────────────────────────────────

setup_claude() {
    rm -f "$TMPDIR_TEST/claude.json"
    cat > "$TMPDIR_TEST/claude.json" <<EOF
{
  "mcpServers": {
    "playwright": {"command": "/opt/devcell/bin/pw"},
    "opentofu": {"command": "/opt/devcell/bin/ot"}
  },
  "projects": {
    "/test-project": {
      "allowedTools": []
    }
  }
}
EOF
}

echo "Test 1: claude disable adds to disabledMcpServers"
setup_claude
disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "opentofu disabled" '["opentofu"]' "$actual"

echo "Test 2: claude disable is idempotent"
disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "no duplicate" '["opentofu"]' "$actual"

echo "Test 3: claude disable multiple servers"
disableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].disabledMcpServers | sort' "$TMPDIR_TEST/claude.json")
assert_eq "both disabled" '["opentofu","playwright"]' "$actual"

echo "Test 4: claude enable removes from disabledMcpServers"
enableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "only opentofu remains" '["opentofu"]' "$actual"

echo "Test 5: claude enable is idempotent"
enableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "still only opentofu" '["opentofu"]' "$actual"

echo "Test 6: claude disable creates project entry if missing"
setup_claude
jq 'del(.projects)' "$TMPDIR_TEST/claude.json" > "$TMPDIR_TEST/tmp.json" && mv "$TMPDIR_TEST/tmp.json" "$TMPDIR_TEST/claude.json"
disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /new-project
actual=$(jq -c '.projects["/new-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")
assert_eq "created project entry" '["opentofu"]' "$actual"

echo "Test 7: claude preserves other project data"
setup_claude
disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
actual=$(jq -c '.projects["/test-project"].allowedTools' "$TMPDIR_TEST/claude.json")
assert_eq "allowedTools preserved" '[]' "$actual"
actual=$(jq -c '.mcpServers | keys | sort' "$TMPDIR_TEST/claude.json")
assert_eq "mcpServers preserved" '["opentofu","playwright"]' "$actual"

# ── Codex ────────────────────────────────────────────────────────────────

setup_codex() {
    rm -f "$TMPDIR_TEST/codex.toml"
    cat > "$TMPDIR_TEST/codex.toml" <<'EOF'
[mcp_servers.playwright]
command = "/opt/devcell/bin/pw"
args = ["--browser", "chromium"]

[mcp_servers.opentofu]
command = "/opt/devcell/bin/ot"
args = []
EOF
}

echo "Test 8: codex disable sets enabled = false"
setup_codex
disableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
actual=$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print(d['mcp_servers']['opentofu']['enabled'])")
assert_eq "enabled = False" "False" "$actual"

echo "Test 9: codex disable leaves other servers alone"
actual=$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print('enabled' in d['mcp_servers']['playwright'])")
assert_eq "playwright untouched" "False" "$actual"

echo "Test 10: codex enable removes enabled = false"
enableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
actual=$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print('enabled' in d['mcp_servers']['opentofu'])")
assert_eq "enabled key removed" "False" "$actual"

echo "Test 11: codex enable on already-enabled is idempotent"
enableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
actual=$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print(d['mcp_servers']['opentofu']['command'])")
assert_eq "command preserved" "/opt/devcell/bin/ot" "$actual"

# ── OpenCode ─────────────────────────────────────────────────────────────

setup_opencode() {
    rm -f "$TMPDIR_TEST/opencode.json"
    cat > "$TMPDIR_TEST/opencode.json" <<'EOF'
{
  "mcp": {
    "playwright": {"type": "local", "command": ["/opt/devcell/bin/pw"]},
    "opentofu": {"type": "local", "command": ["/opt/devcell/bin/ot"]}
  }
}
EOF
}

echo "Test 12: opencode disable sets enabled = false"
setup_opencode
disableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
actual=$(jq -c '.mcp.opentofu.enabled' "$TMPDIR_TEST/opencode.json")
assert_eq "enabled = false" 'false' "$actual"

echo "Test 13: opencode disable leaves other servers alone"
actual=$(jq -c '.mcp.playwright | has("enabled")' "$TMPDIR_TEST/opencode.json")
assert_eq "playwright no enabled key" 'false' "$actual"

echo "Test 14: opencode enable sets enabled = true"
enableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
actual=$(jq -c '.mcp.opentofu.enabled' "$TMPDIR_TEST/opencode.json")
assert_eq "enabled = true" 'true' "$actual"

echo "Test 15: opencode preserves other fields"
actual=$(jq -c '.mcp.opentofu.type' "$TMPDIR_TEST/opencode.json")
assert_eq "type preserved" '"local"' "$actual"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
