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

source_fragment() {
  local name="$1"
  source "$REPO_ROOT/modules/fragments/$name"
}

extract_function() {
  local file="$1" func="$2"
  eval "$(sed -n "/^${func}()/,/^}/p" "$file")"
}
