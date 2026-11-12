#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  source_s6_functions "mcp-toggle/up"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

setup_claude() {
  cat > "$TMPDIR_TEST/claude.json" <<'EOF'
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

setup_codex() {
  cat > "$TMPDIR_TEST/codex.toml" <<'EOF'
[mcp_servers.playwright]
command = "/opt/devcell/bin/pw"
args = ["--browser", "chromium"]

[mcp_servers.opentofu]
command = "/opt/devcell/bin/ot"
args = []
EOF
}

setup_opencode() {
  cat > "$TMPDIR_TEST/opencode.json" <<'EOF'
{
  "mcp": {
    "playwright": {"type": "local", "command": ["/opt/devcell/bin/pw"]},
    "opentofu": {"type": "local", "command": ["/opt/devcell/bin/ot"]}
  }
}
EOF
}

# ── Claude ──

@test "claude: disable adds to disabledMcpServers" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '["opentofu"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "claude: disable is idempotent" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '["opentofu"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "claude: disable multiple servers" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  disableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '["opentofu","playwright"]' "$(jq -c '.projects["/test-project"].disabledMcpServers | sort' "$TMPDIR_TEST/claude.json")"
}

@test "claude: enable removes from disabledMcpServers" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  disableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
  enableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '["opentofu"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "claude: enable is idempotent" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  enableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
  enableMcp claude playwright "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '["opentofu"]' "$(jq -c '.projects["/test-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "claude: disable creates project entry if missing" {
  setup_claude
  jq 'del(.projects)' "$TMPDIR_TEST/claude.json" > "$TMPDIR_TEST/tmp.json" && mv "$TMPDIR_TEST/tmp.json" "$TMPDIR_TEST/claude.json"
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /new-project
  assert_equal '["opentofu"]' "$(jq -c '.projects["/new-project"].disabledMcpServers' "$TMPDIR_TEST/claude.json")"
}

@test "claude: preserves other project data" {
  setup_claude
  disableMcp claude opentofu "$TMPDIR_TEST/claude.json" /test-project
  assert_equal '[]' "$(jq -c '.projects["/test-project"].allowedTools' "$TMPDIR_TEST/claude.json")"
  assert_equal '["opentofu","playwright"]' "$(jq -c '.mcpServers | keys | sort' "$TMPDIR_TEST/claude.json")"
}

# ── Codex ──

@test "codex: disable sets enabled = false" {
  setup_codex
  disableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
  assert_equal "False" "$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print(d['mcp_servers']['opentofu']['enabled'])")"
}

@test "codex: disable leaves other servers alone" {
  setup_codex
  disableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
  assert_equal "False" "$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print('enabled' in d['mcp_servers']['playwright'])")"
}

@test "codex: enable removes enabled = false" {
  setup_codex
  disableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
  enableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
  assert_equal "False" "$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print('enabled' in d['mcp_servers']['opentofu'])")"
}

@test "codex: enable on already-enabled is idempotent" {
  setup_codex
  enableMcp codex opentofu "$TMPDIR_TEST/codex.toml"
  assert_equal "/opt/devcell/bin/ot" "$(python3 -c "import tomllib; d=tomllib.load(open('$TMPDIR_TEST/codex.toml','rb')); print(d['mcp_servers']['opentofu']['command'])")"
}

# ── OpenCode ──

@test "opencode: disable sets enabled = false" {
  setup_opencode
  disableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
  assert_equal 'false' "$(jq -c '.mcp.opentofu.enabled' "$TMPDIR_TEST/opencode.json")"
}

@test "opencode: disable leaves other servers alone" {
  setup_opencode
  disableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
  assert_equal 'false' "$(jq -c '.mcp.playwright | has("enabled")' "$TMPDIR_TEST/opencode.json")"
}

@test "opencode: enable sets enabled = true" {
  setup_opencode
  disableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
  enableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
  assert_equal 'true' "$(jq -c '.mcp.opentofu.enabled' "$TMPDIR_TEST/opencode.json")"
}

@test "opencode: preserves other fields" {
  setup_opencode
  disableMcp opencode opentofu "$TMPDIR_TEST/opencode.json"
  assert_equal '"local"' "$(jq -c '.mcp.opentofu.type' "$TMPDIR_TEST/opencode.json")"
}
