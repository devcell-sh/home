#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"

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

  export GOOGLE_MAPS_API_KEY="test-google-maps-key"

  FRAGMENT="$REPO_ROOT/modules/fragments/30-codex.sh"
  merge_function=$(sed -n '/^merge_codex_mcp()/,/^}/p' "$FRAGMENT")
  merge_function=$(printf '%s\n' "$merge_function" |
      sed \
          -e "s#local nix_file=\"/etc/codex/nix-mcp-servers.toml\"#local nix_file=\"$NIX_FILE\"#" \
          -e "s#local providers_file=\"/etc/codex/nix-providers.toml\"#local providers_file=\"$PROVIDERS_FILE\"#")
  eval "$merge_function"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "staged MCP server merges into Codex config" {
  merge_codex_mcp "$TARGET_FILE"

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
}
