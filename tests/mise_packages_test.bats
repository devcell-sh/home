#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export HOME="$TMPDIR_TEST/home"
  export HOST_USER="$(id -un)"
  export MISE_SYSTEM_CONFIG_DIR="$TMPDIR_TEST/etc-mise"
  mkdir -p "$HOME"

  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/mise" <<FAKEMISE
#!/bin/bash
echo "\$*" >> "$TMPDIR_TEST/mise.calls"
[ "\${FAKE_MISE_EXIT:-0}" = 0 ] || { echo "error: pipx:nope not found" >&2; exit 1; }
FAKEMISE
  chmod +x "$TMPDIR_TEST/bin/mise"

  CONF="$TMPDIR_TEST/etc-mise/conf.d/devcell-packages.toml"
  TOOLS='[tools]
"npm:prettier" = "^3"
"pipx:ruff" = "latest"'
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

run_fragment() {
  (
    export PATH="$TMPDIR_TEST/bin:$PATH"
    log() { echo "$*" >> "$TMPDIR_TEST/log"; }
    source "$REPO_ROOT/modules/fragments/11-mise-packages.sh"
  )
}

@test "writes conf.d file and installs tools" {
  DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
  assert_equal "$TOOLS" "$(cat "$CONF")"
  assert_equal "install -y npm:prettier pipx:ruff" "$(cat "$TMPDIR_TEST/mise.calls")"
}

@test "unchanged tools skip the install" {
  DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
  rm -f "$TMPDIR_TEST/mise.calls"
  DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
  [ ! -s "$TMPDIR_TEST/mise.calls" ]
}

@test "failed install is logged and retried next start" {
  rm -f "$TMPDIR_TEST/mise.calls" "$TMPDIR_TEST/log"
  BAD='[tools]
"pipx:nope" = "latest"'
  DEVCELL_MISE_PACKAGES="$BAD" FAKE_MISE_EXIT=1 run_fragment
  run grep -c '⚠ \[packages.python\]/\[packages.node\] install failed' "$TMPDIR_TEST/log"
  assert_output "1"
  run grep -c 'pipx:nope not found' "$TMPDIR_TEST/log"
  assert_output "1"

  rm -f "$TMPDIR_TEST/mise.calls"
  DEVCELL_MISE_PACKAGES="$BAD" FAKE_MISE_EXIT=1 run_fragment
  assert_equal "install -y pipx:nope" "$(cat "$TMPDIR_TEST/mise.calls")"
}

@test "no packages removes stale conf.d file" {
  DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
  unset DEVCELL_MISE_PACKAGES
  run_fragment
  [ ! -e "$CONF" ]
}
