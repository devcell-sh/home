#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  source "$REPO_ROOT/modules/fragments/mcp-toggle.sh"

  JQ_MERGE_SERVERS='
    .[0] as $existing |
    .[1].mcpServers as $nix |
    (($existing.mcpServers // {}) | to_entries |
      map(select(.value.command == null or (.value.command | startswith("/opt/devcell/") | not))) |
      from_entries) as $cleaned |
    ($nix // {} | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries) as $nixClean |
    $existing | .mcpServers = ($cleaned + $nixClean)
  '

  JQ_DISABLED_LIST='
    [(.mcpServers // {}) | to_entries[] |
      select(.value.enabled != true and ((.key as $k | $enabled_list | index($k)) == null)) |
      .key]
  '
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "all servers merged regardless of enabled flag" {
  result=$(jq -s "$JQ_MERGE_SERVERS" \
      <(echo '{"mcpServers":{}}') \
      <(echo '{"mcpServers":{"srv-a":{"command":"/opt/devcell/bin/a","enabled":true},"srv-b":{"command":"/opt/devcell/bin/b","enabled":false}}}'))
  actual=$(echo "$result" | jq -c '.mcpServers | keys')
  assert_equal '["srv-a","srv-b"]' "$actual"
}

@test "enabled field stripped from merged servers" {
  result=$(jq -s "$JQ_MERGE_SERVERS" \
      <(echo '{"mcpServers":{}}') \
      <(echo '{"mcpServers":{"srv-a":{"command":"/opt/devcell/bin/a","enabled":true},"srv-b":{"command":"/opt/devcell/bin/b","enabled":false}}}'))
  assert_equal "false" "$(echo "$result" | jq '.mcpServers["srv-a"] | has("enabled")')"
  assert_equal "false" "$(echo "$result" | jq '.mcpServers["srv-b"] | has("enabled")')"
}

@test "disabled list computed correctly" {
  actual=$(jq -c --argjson enabled_list '[]' "$JQ_DISABLED_LIST" \
      <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":false},"srv-c":{}}}'))
  assert_equal '["srv-b","srv-c"]' "$actual"
}

@test "DEVCELL_MCP_ENABLED makes server enabled" {
  actual=$(jq -c --argjson enabled_list '["srv-b"]' "$JQ_DISABLED_LIST" \
      <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":false},"srv-c":{}}}'))
  assert_equal '["srv-c"]' "$actual"
}

@test "disableMcp targets projects[].disabledMcpServers" {
  cat > "$TMPDIR_TEST/claude.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"},"srv-b":{"command":"b"}},"projects":{"/test":{}}}
EOF
  disableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
  assert_equal '["srv-b"]' "$(jq -c '.projects["/test"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "enableMcp removes from disabledMcpServers" {
  cat > "$TMPDIR_TEST/claude.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"},"srv-b":{"command":"b"}},"projects":{"/test":{"disabledMcpServers":["srv-b"]}}}
EOF
  enableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
  assert_equal '[]' "$(jq -c '.projects["/test"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "mcpServers preserved after disable/enable" {
  cat > "$TMPDIR_TEST/claude.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"},"srv-b":{"command":"b"}},"projects":{"/test":{}}}
EOF
  disableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
  enableMcp claude srv-b "$TMPDIR_TEST/claude.json" /test
  assert_equal '["srv-a","srv-b"]' "$(jq -c '.mcpServers | keys' "$TMPDIR_TEST/claude.json")"
}

@test "stale /opt/devcell/ servers cleaned on merge" {
  result=$(jq -s "$JQ_MERGE_SERVERS" \
      <(echo '{"mcpServers":{"old-srv":{"command":"/opt/devcell/old/bin"},"user-srv":{"command":"/usr/bin/foo"}}}') \
      <(echo '{"mcpServers":{"new-srv":{"command":"/opt/devcell/bin/new","enabled":true}}}'))
  assert_equal '["new-srv","user-srv"]' "$(echo "$result" | jq -c '.mcpServers | keys')"
}

@test "seed creates .claude.json with all servers" {
  JQ_SEED='{mcpServers: ((.mcpServers // {}) | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries)}'
  result=$(jq "$JQ_SEED" \
      <(echo '{"mcpServers":{"s1":{"command":"a","enabled":true},"s2":{"command":"b","enabled":false}}}'))
  assert_equal '["s1","s2"]' "$(echo "$result" | jq -c '.mcpServers | keys')"
  assert_equal "false" "$(echo "$result" | jq '.mcpServers.s1 | has("enabled")')"
}

@test "all enabled means empty disabled list" {
  actual=$(jq -c --argjson enabled_list '[]' "$JQ_DISABLED_LIST" \
      <(echo '{"mcpServers":{"srv-a":{"enabled":true},"srv-b":{"enabled":true}}}'))
  assert_equal '[]' "$actual"
}

@test "disableMcp creates project entry if needed" {
  cat > "$TMPDIR_TEST/claude.json" <<'EOF'
{"mcpServers":{"srv-a":{"command":"a"}}}
EOF
  disableMcp claude srv-a "$TMPDIR_TEST/claude.json" /new-project
  assert_equal '["srv-a"]' "$(jq -c '.projects["/new-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}
