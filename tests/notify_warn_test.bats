#!/usr/bin/env bats

load helper_test

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export DEVCELL_BOOT_DIR="$TMPDIR_TEST/boot"
  mkdir -p "$DEVCELL_BOOT_DIR"
  source_fragment 00-notify.sh
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "plain sentinel is an empty file" {
  notify mise.ready
  [ -f "$DEVCELL_BOOT_DIR/mise.ready" ]
  [ "$(wc -c < "$DEVCELL_BOOT_DIR/mise.ready" | tr -d ' ')" = "0" ]
}

@test "warn sentinel carries the message" {
  notify gcroot.warn "Nix config drift: 3 variants"
  assert_equal "Nix config drift: 3 variants" "$(cat "$DEVCELL_BOOT_DIR/gcroot.warn")"
}

@test "no boot dir is a silent no-op" {
  DEVCELL_BOOT_DIR="$TMPDIR_TEST/missing" notify x.warn "msg"
  [ ! -e "$TMPDIR_TEST/missing" ]
}
