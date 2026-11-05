#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  extract_function "$REPO_ROOT/modules/fragments/30-claude.sh" seed_claude_trust
  log() { :; }
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "missing project entry is created as trusted" {
  local cj="$TMPDIR_TEST/1.json"
  echo '{"mcpServers":{}}' > "$cj"
  seed_claude_trust "$cj" "/devcell-83"
  assert_equal "true" "$(jq '.projects["/devcell-83"].hasTrustDialogAccepted' "$cj")"
  assert_equal "{}" "$(jq -c '.mcpServers' "$cj")"
}

@test "existing project entry keeps its other keys" {
  local cj="$TMPDIR_TEST/2.json"
  echo '{"projects":{"/devcell-83":{"disabledMcpServers":["x"],"hasTrustDialogAccepted":false}}}' > "$cj"
  seed_claude_trust "$cj" "/devcell-83"
  assert_equal "true" "$(jq '.projects["/devcell-83"].hasTrustDialogAccepted' "$cj")"
  assert_equal '["x"]' "$(jq -c '.projects["/devcell-83"].disabledMcpServers' "$cj")"
}

@test "already trusted entry is left untouched" {
  local cj="$TMPDIR_TEST/3.json"
  echo '{"projects":{"/devcell-83":{"hasTrustDialogAccepted":true}}}' > "$cj"
  local before
  before=$(stat -c %Y "$cj" 2>/dev/null || stat -f %m "$cj")
  sleep 1
  seed_claude_trust "$cj" "/devcell-83"
  local after
  after=$(stat -c %Y "$cj" 2>/dev/null || stat -f %m "$cj")
  assert_equal "$before" "$after"
}

@test "missing or corrupt file is skipped" {
  local cj="$TMPDIR_TEST/4.json"
  seed_claude_trust "$cj" "/devcell-83"
  [ ! -f "$cj" ]

  echo '{not json' > "$cj"
  seed_claude_trust "$cj" "/devcell-83"
  assert_equal "{not json" "$(cat "$cj")"
}
