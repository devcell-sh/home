#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"

  JQ_MERGE='
    def pkgname:
      if type == "array" then .[0]
      elif (length > 0 and .[0:1] == "@") then ("@" + (.[1:] | split("@")[0]))
      else (split("@")[0])
      end;
    .[0] as $existing |
    .[1].provider as $nix |
    .[1].model as $nixModel |
    .[1].plugin as $nixPlugin |
    ($existing.plugin // []) as $existingPlugins |
    ($existingPlugins | map(pkgname)) as $existingNames |
    (($nixPlugin // []) | map(select((pkgname) as $n | ($existingNames | index($n)) == null))) as $toAdd |
    $existing
    | .provider = (($nix // {}) + ($existing.provider // {}))
    | (if ($existing.model == null) and ($nixModel != null) then .model = $nixModel else . end)
    | (if ($toAdd | length) > 0 then .plugin = ($existingPlugins + $toAdd) else . end)
  '

  JQ_SEED='
    {"$schema":"https://opencode.ai/config.json","provider": .provider}
    + (if .model then {model: .model} else {} end)
    + (if .plugin then {plugin: .plugin} else {} end)
  '
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

run_merge() {
  jq -s "$JQ_MERGE" "$1" "$2"
}

run_seed() {
  jq "$JQ_SEED" "$1"
}

@test "seed creates config with plugins" {
  echo '{"provider":{"x":{"npm":"@ai-sdk/x"}},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_seed "$TMPDIR_TEST/nix.json")
  assert_equal '["opencode-throughput"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "seed omits plugin key when none declared" {
  echo '{"provider":{"x":{"npm":"@ai-sdk/x"}}}' > "$TMPDIR_TEST/nix.json"
  result=$(run_seed "$TMPDIR_TEST/nix.json")
  assert_equal "false" "$(echo "$result" | jq 'has("plugin")')"
}

@test "merge appends nix plugin when user has none" {
  echo '{"provider":{}}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["opencode-throughput"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "merge skips plugin already present" {
  echo '{"provider":{},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["opencode-throughput"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "merge preserves user plugins and appends new nix plugin" {
  echo '{"provider":{},"plugin":["my-custom-plugin"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["my-custom-plugin","opencode-throughput"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "scoped package name dedup" {
  echo '{"provider":{},"plugin":["@foo/bar"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["@foo/bar"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["@foo/bar"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "version suffix ignored in dedup" {
  echo '{"provider":{},"plugin":["opencode-throughput@1.0.0"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["opencode-throughput"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["opencode-throughput@1.0.0"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "scoped package with version dedup" {
  echo '{"provider":{},"plugin":["@foo/bar@2.0.0"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{},"plugin":["@foo/bar@3.0.0"]}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["@foo/bar@2.0.0"]' "$(echo "$result" | jq -c '.plugin')"
}

@test "no nix plugins leaves user config unchanged" {
  echo '{"provider":{},"plugin":["user-plugin"]}' > "$TMPDIR_TEST/existing.json"
  echo '{"provider":{}}' > "$TMPDIR_TEST/nix.json"
  result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
  assert_equal '["user-plugin"]' "$(echo "$result" | jq -c '.plugin')"
}
