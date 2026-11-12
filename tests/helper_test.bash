bats_load_library bats-support
bats_load_library bats-assert

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export HOME="$TMPDIR_TEST/home"
  mkdir -p "$HOME"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

log() { :; }
notify() { :; }
export -f log notify

source_s6_functions() {
  local script="$1"
  local full="$REPO_ROOT/modules/s6/$script"
  [ -f "$full" ] || { echo "source_s6_functions: $full not found" >&2; return 1; }
  eval "$(sed -n '/^[a-zA-Z_][a-zA-Z_0-9]*()/,/^}/p' "$full")"
}

extract_function() {
  local file="$1" func="$2"
  eval "$(sed -n "/^${func}()/,/^}/p" "$file")"
}
