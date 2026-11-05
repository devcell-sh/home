#!/usr/bin/env bats

load ../helper_test

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export HOME="$TMPDIR_TEST/home"
  export HOST_USER="testuser"
  export DEVCELL_HOME="$TMPDIR_TEST/devcell"
  export HOSTNAME="cell-test-project"
  mkdir -p "$HOME/.config/opencode" "$DEVCELL_HOME"

  source "$REPO_ROOT/modules/fragments/mcp-toggle.sh"

  FRAGMENT="$REPO_ROOT/modules/fragments/30-opencode.sh"
  eval "$(sed -n '/^_mcp_enabled_json()/,/^}/p' "$FRAGMENT")"
  eval "$(sed -n '/^merge_opencode_providers()/,/^}/p' "$FRAGMENT")"
  eval "$(sed -n '/^merge_opencode_mcp()/,/^}/p' "$FRAGMENT")"

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

  cat > /tmp/test-opencode-mcp.json <<'EOF'
{
  "backupBeforeMerge": false,
  "mcp": {
    "playwright": {"type": "local", "command": ["/opt/devcell/bin/pw"], "enabled": true}
  }
}
EOF
  sudo cp /tmp/test-opencode-mcp.json /etc/opencode/nix-mcp-servers.json

  OC_GLOBAL="$HOME/.config/opencode/opencode.json"
}

teardown() {
  rm -rf "$TMPDIR_TEST" /tmp/test-opencode-providers.json /tmp/test-opencode-mcp.json
}

@test "providers merge into global config" {
  merge_opencode_providers "$OC_GLOBAL"
  assert_equal '["test-provider"]' "$(jq -c '.provider | keys' "$OC_GLOBAL")"
}

@test "plugins in global config" {
  merge_opencode_providers "$OC_GLOBAL"
  assert_equal '["opencode-throughput"]' "$(jq -c '.plugin' "$OC_GLOBAL")"
}

@test "MCP servers in global config" {
  merge_opencode_providers "$OC_GLOBAL"
  merge_opencode_mcp "$OC_GLOBAL"
  assert_equal '["playwright"]' "$(jq -c '.mcp | keys' "$OC_GLOBAL")"
}

@test "no stale home-dir configs" {
  merge_opencode_providers "$OC_GLOBAL"
  merge_opencode_mcp "$OC_GLOBAL"
  [ ! -f "$HOME/opencode.json" ]
  [ ! -f "$HOME/.opencode.json" ]
}

@test "providers and MCP coexist" {
  merge_opencode_providers "$OC_GLOBAL"
  merge_opencode_mcp "$OC_GLOBAL"
  assert_equal '{"p":["test-provider"],"m":["playwright"]}' "$(jq -c '{p: (.provider | keys), m: (.mcp | keys)}' "$OC_GLOBAL")"
}

@test "idempotent merge" {
  merge_opencode_providers "$OC_GLOBAL"
  merge_opencode_mcp "$OC_GLOBAL"
  local before after
  before=$(jq -cS '.' "$OC_GLOBAL")
  merge_opencode_providers "$OC_GLOBAL"
  merge_opencode_mcp "$OC_GLOBAL"
  after=$(jq -cS '.' "$OC_GLOBAL")
  assert_equal "$before" "$after"
}

@test "prefers .jsonc over .json" {
  rm -f "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"
  echo '{"$schema":"https://opencode.ai/config.json"}' > "$HOME/.config/opencode/opencode.jsonc"
  local oc_jsonc="$HOME/.config/opencode/opencode.jsonc"
  merge_opencode_providers "$oc_jsonc"
  assert_equal '["test-provider"]' "$(jq -c '.provider | keys' "$oc_jsonc")"
  [ ! -f "$HOME/.config/opencode/opencode.json" ]
}
