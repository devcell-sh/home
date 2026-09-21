#!/bin/bash
# Test: opencode plugin injection via merge_opencode_providers
# Exercises the jq merge logic from 30-opencode.sh in isolation.
set -euo pipefail

PASS=0
FAIL=0
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

# Extract the merge jq filter from 30-opencode.sh so we test the real logic.
# The filter takes: .[0]=existing config, .[1]=nix config
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

# The seed jq filter for when no user config exists
JQ_SEED='
  {"$schema":"https://opencode.ai/config.json","provider": .provider}
  + (if .model then {model: .model} else {} end)
  + (if .plugin then {plugin: .plugin} else {} end)
'

run_merge() {
    jq -s "$JQ_MERGE" "$1" "$2"
}

run_seed() {
    jq "$JQ_SEED" "$1"
}

# ── Test 1: Seed — plugins appear in fresh config ────────────────────────
echo "Test 1: seed creates config with plugins"
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{"x":{"npm":"@ai-sdk/x"}},"plugin":["opencode-throughput"]}
EOF
result=$(run_seed "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "plugin array present" '["opencode-throughput"]' "$actual"

# ── Test 2: Seed — no plugins key when empty ─────────────────────────────
echo "Test 2: seed omits plugin key when none declared"
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{"x":{"npm":"@ai-sdk/x"}}}
EOF
result=$(run_seed "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq 'has("plugin")')
assert_eq "no plugin key" "false" "$actual"

# ── Test 3: Merge — nix plugin appended to empty user config ─────────────
echo "Test 3: merge appends nix plugin when user has none"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{}}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "plugin added" '["opencode-throughput"]' "$actual"

# ── Test 4: Merge — duplicate plugin not re-added ────────────────────────
echo "Test 4: merge skips plugin already present"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "no duplicate" '["opencode-throughput"]' "$actual"

# ── Test 5: Merge — user plugins preserved, nix plugin appended ──────────
echo "Test 5: merge preserves user plugins and appends new nix plugin"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["my-custom-plugin"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "user + nix plugins" '["my-custom-plugin","opencode-throughput"]' "$actual"

# ── Test 6: Merge — scoped package dedup (@scope/pkg) ────────────────────
echo "Test 6: scoped package name dedup"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["@foo/bar"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["@foo/bar"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "scoped dedup" '["@foo/bar"]' "$actual"

# ── Test 7: Merge — version suffix ignored during dedup ──────────────────
echo "Test 7: version suffix ignored in dedup"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput@1.0.0"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["opencode-throughput"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "version ignored" '["opencode-throughput@1.0.0"]' "$actual"

# ── Test 8: Merge — scoped package with version suffix dedup ─────────────
echo "Test 8: scoped package with version dedup"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["@foo/bar@2.0.0"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{},"plugin":["@foo/bar@3.0.0"]}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "scoped+version dedup" '["@foo/bar@2.0.0"]' "$actual"

# ── Test 9: Merge — no nix plugins leaves user config unchanged ──────────
echo "Test 9: no nix plugins means no plugin key change"
cat > "$TMPDIR_TEST/existing.json" <<'EOF'
{"provider":{},"plugin":["user-plugin"]}
EOF
cat > "$TMPDIR_TEST/nix.json" <<'EOF'
{"provider":{}}
EOF
result=$(run_merge "$TMPDIR_TEST/existing.json" "$TMPDIR_TEST/nix.json")
actual=$(echo "$result" | jq -c '.plugin')
assert_eq "user plugins unchanged" '["user-plugin"]' "$actual"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
