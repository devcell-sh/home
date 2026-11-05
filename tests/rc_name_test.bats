#!/usr/bin/env bats

load helper_test

S6_DIR="$REPO_ROOT/modules/s6"

@test "no service script sets RC_NAME" {
  for svc_dir in "$S6_DIR"/*/; do
    svc_name=$(basename "$svc_dir")
    [ "$svc_name" = "user" ] && continue
    for script in "$svc_dir/up" "$svc_dir/run" "$svc_dir/linux/up" "$svc_dir/darwin/up"; do
      [ -f "$script" ] || continue
      run grep -q 'RC_NAME' "$script"
      assert_failure
    done
  done
}

@test "linux renderer injects RC_NAME for oneshots" {
  run grep -q 'export RC_NAME' "$REPO_ROOT/modules/s6-linux-renderer.nix"
  assert_success
}

@test "darwin renderer injects RC_NAME for oneshots" {
  run grep -q 'export RC_NAME' "$REPO_ROOT/modules/s6-darwin-renderer.nix"
  assert_success
}

@test "devcell-event has pwd fallback for longruns" {
  run grep -q 'basename.*pwd' "$REPO_ROOT/modules/base.nix"
  assert_success
}

@test "simulated oneshot: RC_NAME set by renderer via env" {
  mkdir -p "$BATS_TEST_TMPDIR/source/test-svc"
  cat > "$BATS_TEST_TMPDIR/source/test-svc/up.sh" <<'SCRIPT'
#!/bin/sh
echo "$RC_NAME"
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/source/test-svc/up.sh"
  run env RC_NAME=test-svc "$BATS_TEST_TMPDIR/source/test-svc/up.sh"
  assert_output "test-svc"
}

@test "simulated longrun: pwd-derived, no RC_NAME in env" {
  mkdir -p "$BATS_TEST_TMPDIR/servicedirs/test-daemon"
  cat > "$BATS_TEST_TMPDIR/servicedirs/test-daemon/run" <<'SCRIPT'
#!/bin/sh
echo "$(basename "$(pwd)")"
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/servicedirs/test-daemon/run"
  run bash -c 'cd "$1" && ./run' _ "$BATS_TEST_TMPDIR/servicedirs/test-daemon"
  assert_output "test-daemon"
}

@test "dirname \$0 gives '.' under s6-supervise (confirming pwd is needed)" {
  mkdir -p "$BATS_TEST_TMPDIR/servicedirs/test-daemon"
  cat > "$BATS_TEST_TMPDIR/servicedirs/test-daemon/run2" <<'SCRIPT'
#!/bin/sh
echo "$(basename "$(dirname "$0")")"
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/servicedirs/test-daemon/run2"
  run bash -c 'cd "$1" && ./run2' _ "$BATS_TEST_TMPDIR/servicedirs/test-daemon"
  assert_output "."
}
