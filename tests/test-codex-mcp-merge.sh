#!/bin/bash
# L1 regression test for the Codex entrypoint MCP merge.
#
# Contract surface source of truth:
#   modules/fragments/30-codex.sh: merge_codex_mcp()
#
# Proves: a staged stdio MCP definition is merged into an existing Codex
# config, its environment placeholder is resolved, and user config survives.
# Does not prove: Nix staging, container entrypoint ordering, or Codex startup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

NIX_FILE="$TMPDIR_TEST/nix-mcp-servers.toml"
PROVIDERS_FILE="$TMPDIR_TEST/nix-providers.toml"
TARGET_FILE="$TMPDIR_TEST/config.toml"

cat > "$NIX_FILE" <<'EOF'
backupBeforeMerge = false
devcellManagedServers = ["google-maps"]

[mcp_servers.google-maps]
args = ["--stdio"]
command = "/opt/devcell/bin/mcp-google-map"
enabled = false

[mcp_servers.google-maps.env]
GOOGLE_MAPS_API_KEY = "${GOOGLE_MAPS_API_KEY}"
EOF

cat > "$PROVIDERS_FILE" <<'EOF'
devcellManagedProviders = []
EOF

cat > "$TARGET_FILE" <<'EOF'
model = "gpt-test"

[mcp_servers.user-owned]
command = "/usr/bin/user-owned-mcp"
EOF

log() { :; }
export GOOGLE_MAPS_API_KEY="test-google-maps-key"

# Load the production function while redirecting its two read-only /etc inputs
# to hermetic fixtures. The function body and target-file behavior are unchanged.
FRAGMENT="$SCRIPT_DIR/modules/fragments/30-codex.sh"
merge_function=$(sed -n '/^merge_codex_mcp()/,/^}/p' "$FRAGMENT")
merge_function=$(printf '%s\n' "$merge_function" |
    sed \
        -e "s#local nix_file=\"/etc/codex/nix-mcp-servers.toml\"#local nix_file=\"$NIX_FILE\"#" \
        -e "s#local providers_file=\"/etc/codex/nix-providers.toml\"#local providers_file=\"$PROVIDERS_FILE\"#")
eval "$merge_function"

echo "Test 1: staged MCP server merges into Codex config"
if ! merge_codex_mcp "$TARGET_FILE"; then
    echo "  ✗ merge_codex_mcp failed"
    exit 1
fi

python3 - "$TARGET_FILE" <<'PYEOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

assert config["model"] == "gpt-test"
assert config["mcp_servers"]["user-owned"]["command"] == "/usr/bin/user-owned-mcp"

google = config["mcp_servers"]["google-maps"]
assert google["command"] == "/opt/devcell/bin/mcp-google-map"
assert google["args"] == ["--stdio"]
assert "enabled" not in google
assert google["env"]["GOOGLE_MAPS_API_KEY"] == "test-google-maps-key"
PYEOF

echo "  ✓ staged server merged, placeholder resolved, user config preserved"
