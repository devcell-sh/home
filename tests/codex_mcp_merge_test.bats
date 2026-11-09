#!/usr/bin/env bats

load helper_test

# Contract sources: modules/llm/{codex,claude,mcp}.nix and both startup callers.
# The CLI check loads config only; it never starts or authenticates MCP servers.
setup_file() {
  CODEX_TEST_ENV=$(nix build --impure --no-link --print-out-paths \
    --file "$REPO_ROOT/tests/fixtures/codex-contract.nix")
  export CODEX_TEST_ENV
  export PATH="$CODEX_TEST_ENV/bin:$PATH"
}

setup() {
  TMPDIR_TEST="$(mktemp -d)"

  NIX_FILE="$TMPDIR_TEST/nix-mcp-servers.toml"
  PROVIDERS_FILE="$TMPDIR_TEST/nix-providers.toml"
  TARGET_FILE="$TMPDIR_TEST/config.toml"

  cat > "$NIX_FILE" <<'EOF'
backupBeforeMerge = false
devcellManagedServers = ["google-maps"]

[tui]
alternate_screen = "never"

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

[tui]
alternate_screen = "always"
animations = false

[mcp_servers.user-owned]
command = "/usr/bin/user-owned-mcp"
EOF

  export GOOGLE_MAPS_API_KEY="test-google-maps-key"
  unset DEVCELL_MCP_ENABLED

  FRAGMENT="$REPO_ROOT/modules/fragments/30-codex.sh"
  merge_function=$(sed -n '/^merge_codex_mcp()/,/^}/p' "$FRAGMENT")
  merge_function=$(printf '%s\n' "$merge_function" |
      sed \
          -e "s#local nix_file=\"/etc/codex/nix-mcp-servers.toml\"#local nix_file=\"$NIX_FILE\"#" \
          -e "s#local providers_file=\"/etc/codex/nix-providers.toml\"#local providers_file=\"$PROVIDERS_FILE\"#")
  eval "$merge_function"
}

load_s6_merge() {
  merge_function=$(sed -n '/^merge_codex_mcp()/,/^}/p' "$REPO_ROOT/modules/s6/codex-config/up")
  merge_function=$(printf '%s\n' "$merge_function" |
      sed -e "s#nix_file=\"/etc/codex/nix-mcp-servers.toml\"#nix_file=\"$NIX_FILE\"#" \
          -e "s#providers_file=\"/etc/codex/nix-providers.toml\"#providers_file=\"$PROVIDERS_FILE\"#")
  eval "$merge_function"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "s6 merge applies managed TUI settings and preserves user preferences" {
  load_s6_merge
  merge_codex_mcp "$TARGET_FILE"

  python3 - "$TARGET_FILE" <<'PYEOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

assert config["tui"]["alternate_screen"] == "never"
assert config["tui"]["animations"] is False
assert config["model"] == "gpt-test"
assert "user-owned" in config["mcp_servers"]
PYEOF
}

@test "staged MCP server merges into Codex config" {
  merge_codex_mcp "$TARGET_FILE"

  python3 - "$TARGET_FILE" <<'PYEOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

assert config["model"] == "gpt-test"
assert config["tui"]["alternate_screen"] == "never"
assert config["tui"]["animations"] is False
assert config["mcp_servers"]["user-owned"]["command"] == "/usr/bin/user-owned-mcp"

google = config["mcp_servers"]["google-maps"]
assert google["command"] == "/opt/devcell/bin/mcp-google-map"
assert google["args"] == ["--stdio"]
assert google["enabled"] is False
assert google["env_vars"] == ["GOOGLE_MAPS_API_KEY"]
assert "test-google-maps-key" not in open(sys.argv[1]).read()
PYEOF
}

@test "missing credentials retain servers and shell defaults handle unset and empty values" {
  load_s6_merge
  unset GOOGLE_MAPS_API_KEY CODEX_TEST_DISPLAY CODEX_TEST_ALIAS
  cat >> "$NIX_FILE" <<'EOF'

[mcp_servers.browser]
command = "/opt/devcell/bin/browser"
[mcp_servers.browser.env]
DISPLAY = "${CODEX_TEST_DISPLAY:-:99}"
TOKEN = "${CODEX_TEST_ALIAS}"
EOF
  for display_value in unset empty overridden; do
    case "$display_value" in
      unset) unset CODEX_TEST_DISPLAY; expected_display=":99" ;;
      empty) export CODEX_TEST_DISPLAY=""; expected_display=":99" ;;
      overridden) export CODEX_TEST_DISPLAY=":42"; expected_display=":42" ;;
    esac
    run merge_codex_mcp "$TARGET_FILE"
    assert_success
    assert_output --partial "definition retained"
    python3 - "$TARGET_FILE" "$expected_display" <<'PYEOF'
import sys, tomllib
c = tomllib.load(open(sys.argv[1], 'rb'))['mcp_servers']
assert c['google-maps']['env_vars'] == ['GOOGLE_MAPS_API_KEY']
assert c['browser']['env']['DISPLAY'] == sys.argv[2]
assert c['browser']['env']['TOKEN'] == ''
PYEOF
  done
}

@test "both startup paths preserve nested config and merge idempotently" {
  cat >> "$TARGET_FILE" <<'EOF'

[projects."/work/project.with.dots"]
trust_level = "trusted"
[model_providers.custom]
name = "Custom"
base_url = "https://example.invalid/v1"
[plugins."sample@test".mcp_servers.sample.tools.search]
approval_mode = "approve"
[mcp_servers.user-owned.env]
ESCAPED = "quote: \" slash: \\ newline: \n"
[mcp_servers.stale]
command = "/nix/store/old-mcp/bin/server"
EOF
  cat >> "$PROVIDERS_FILE" <<'EOF'
[model_providers.managed]
name = "Managed"
base_url = "https://example.invalid/v1"
EOF
  cp "$TARGET_FILE" "$TMPDIR_TEST/original.toml"
  merge_codex_mcp "$TARGET_FILE"
  cp "$TARGET_FILE" "$TMPDIR_TEST/fragment.toml"
  cp "$TMPDIR_TEST/original.toml" "$TARGET_FILE"
  load_s6_merge
  merge_codex_mcp "$TARGET_FILE"
  cmp "$TMPDIR_TEST/fragment.toml" "$TARGET_FILE"
  merge_codex_mcp "$TARGET_FILE"
  cmp "$TMPDIR_TEST/fragment.toml" "$TARGET_FILE"
  python3 - "$TMPDIR_TEST/original.toml" "$TARGET_FILE" <<'PYEOF'
import sys, tomllib
original, merged = [tomllib.load(open(p, 'rb')) for p in sys.argv[1:]]
for key in ('projects', 'plugins'):
    assert merged[key] == original[key]
assert merged['model_providers']['custom'] == original['model_providers']['custom']
assert 'managed' in merged['model_providers']
assert merged['mcp_servers']['user-owned'] == original['mcp_servers']['user-owned']
assert 'stale' not in merged['mcp_servers']
PYEOF
}

@test "failed merge leaves original user config untouched" {
  load_s6_merge
  cp "$TARGET_FILE" "$TMPDIR_TEST/original.toml"
  printf 'invalid = [\n' > "$PROVIDERS_FILE"
  run merge_codex_mcp "$TARGET_FILE"
  assert_failure
  cmp "$TMPDIR_TEST/original.toml" "$TARGET_FILE"
}

@test "generated Claude and Codex inventories match and the pinned CLI accepts both transports" {
  cp "$CODEX_TEST_ENV/share/codex-test/codex.toml" "$NIX_FILE"
  export DEVCELL_MCP_ENABLED="local-test,remote-test"
  unset TEST_TOKEN
  load_s6_merge
  merge_codex_mcp "$TARGET_FILE"
  # An isolated home and cwd prevent loading real user/project plugins or auth.
  mkdir "$TMPDIR_TEST/cli"
  cp "$TARGET_FILE" "$TMPDIR_TEST/cli/config.toml"
  (cd "$TMPDIR_TEST" && CODEX_HOME="$TMPDIR_TEST/cli" \
    "$CODEX_TEST_ENV/bin/codex" mcp list --json > "$TMPDIR_TEST/list.json")
  python3 - "$CODEX_TEST_ENV/share/codex-test/claude.json" "$TARGET_FILE" "$TMPDIR_TEST/list.json" <<'PYEOF'
import sys, json, tomllib
claude = json.load(open(sys.argv[1]))['mcpServers']
codex = tomllib.load(open(sys.argv[2], 'rb'))['mcp_servers']
listed = {s['name']: s for s in json.load(open(sys.argv[3]))}
assert set(codex) == set(claude) | {'user-owned'}
assert set(listed) == set(codex)
assert codex['remote-test']['url'] == claude['remote-test']['url']
assert 'command' not in codex['remote-test']
assert codex['remote-test']['http_headers']['X-Tenant'] == 'test'
assert codex['remote-test']['bearer_token_env_var'] == 'TEST_BEARER_TOKEN'
assert codex['local-test']['env_vars'] == ['TEST_TOKEN']
assert listed['remote-test']['enabled'] is True
assert listed['local-test']['enabled'] is True
assert listed['local-test']['transport']['env_vars'] == ['TEST_TOKEN']
assert listed['remote-test']['transport']['url'] == codex['remote-test']['url']
assert listed['remote-test']['transport']['bearer_token_env_var'] == 'TEST_BEARER_TOKEN'
assert listed['remote-test']['transport']['http_headers'] == {'X-Tenant': 'test'}
PYEOF
}
