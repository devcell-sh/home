#!/usr/bin/env bats

load ../helper_test

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export HOME="$TMPDIR_TEST/home"
  export HOST_USER="testuser"
  export DEVCELL_HOME="$TMPDIR_TEST/devcell"
  export HOSTNAME="cell-test-project"
  mkdir -p "$HOME/.claude" "$DEVCELL_HOME"

  source "$REPO_ROOT/modules/fragments/mcp-toggle.sh"

  FRAGMENT="$REPO_ROOT/modules/fragments/30-claude.sh"
  eval "$(sed -n '/^_mcp_enabled_json()/,/^}/p' "$FRAGMENT")"
  eval "$(sed -n '/^merge_claude_mcp()/,/^}/p' "$FRAGMENT")"
  eval "$(sed -n '/^sync_claude_mcp_state()/,/^}/p' "$FRAGMENT")"

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
  if [ -d /etc/claude-code ]; then
    sudo cp /tmp/test-claude-code/nix-mcp-servers.json /etc/claude-code/nix-mcp-servers.json
  else
    sudo mkdir -p /etc/claude-code
    sudo cp /tmp/test-claude-code/nix-mcp-servers.json /etc/claude-code/nix-mcp-servers.json
  fi
}

teardown() {
  rm -rf "$TMPDIR_TEST" /tmp/test-claude-code
}

@test "fresh start merges all servers" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"
  assert_equal '["gimp","linear","playwright"]' "$(jq -c '.mcpServers | keys | sort' "$HOME/.claude.json")"
  assert_equal "false" "$(jq '.mcpServers.gimp | has("enabled")' "$HOME/.claude.json")"
}

@test "disabled server in projects[].disabledMcpServers" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"
  sync_claude_mcp_state "$HOME/.claude.json"
  assert_equal '["gimp"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")"
  assert_equal '["gimp","linear","playwright"]' "$(jq -c '.mcpServers | keys | sort' "$HOME/.claude.json")"
}

@test "DEVCELL_MCP_ENABLED enables gimp" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"
  sync_claude_mcp_state "$HOME/.claude.json"

  export DEVCELL_MCP_ENABLED="gimp"
  sync_claude_mcp_state "$HOME/.claude.json"
  assert_equal '[]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")"
  unset DEVCELL_MCP_ENABLED
}

@test "re-sync restores disabled state" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"

  export DEVCELL_MCP_ENABLED="gimp"
  sync_claude_mcp_state "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED

  sync_claude_mcp_state "$HOME/.claude.json"
  assert_equal '["gimp"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$HOME/.claude.json")"
}

@test "idempotent merge" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"
  sync_claude_mcp_state "$HOME/.claude.json"

  local before after
  before=$(jq -cS '.' "$HOME/.claude.json")
  merge_claude_mcp "$HOME/.claude.json"
  after=$(jq -cS '.' "$HOME/.claude.json")
  assert_equal "$before" "$after"

  sync_claude_mcp_state "$HOME/.claude.json"
  after=$(jq -cS '.' "$HOME/.claude.json")
  assert_equal "$before" "$after"
}

@test "stale server cleanup" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"

  jq '.mcpServers["old-stale"] = {"command":"/opt/devcell/old/bin","args":[]}' \
      "$HOME/.claude.json" > "$HOME/.claude.json.tmp"
  mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
  merge_claude_mcp "$HOME/.claude.json"
  assert_equal "false" "$(jq '.mcpServers | has("old-stale")' "$HOME/.claude.json")"
}

@test "stale /nix/store/ wrapper cleanup" {
  rm -f "$HOME/.claude.json"
  unset DEVCELL_MCP_ENABLED
  merge_claude_mcp "$HOME/.claude.json"

  jq '.mcpServers["gimp-mcp"] = {"command":"/nix/store/abc123-gimp-mcp-wrapper","args":[],"env":{}}
    | .mcpServers["user-local"] = {"command":"/home/user/bin/my-mcp","args":[]}' \
      "$HOME/.claude.json" > "$HOME/.claude.json.tmp"
  mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
  merge_claude_mcp "$HOME/.claude.json"
  assert_equal "false" "$(jq '.mcpServers | has("gimp-mcp")' "$HOME/.claude.json")"
  assert_equal "true" "$(jq '.mcpServers | has("user-local")' "$HOME/.claude.json")"
}
