#!/bin/bash
# Test: 11-mise-packages.sh installs [packages.python] / [packages.node] tools
# that cell passes as a mise [tools] table in DEVCELL_MISE_PACKAGES.
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# Fake mise: records argv; exits with $FAKE_MISE_EXIT.
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/mise" <<EOF
#!/bin/bash
echo "\$*" >> "$TMPDIR_TEST/mise.calls"
[ "\${FAKE_MISE_EXIT:-0}" = 0 ] || { echo "error: pipx:nope not found" >&2; exit 1; }
EOF
chmod +x "$TMPDIR_TEST/bin/mise"

run_fragment() {
    (
        export PATH="$TMPDIR_TEST/bin:$PATH"
        export HOME="$TMPDIR_TEST/home" HOST_USER="$(id -un)"
        export MISE_SYSTEM_CONFIG_DIR="$TMPDIR_TEST/etc-mise"
        log() { echo "$*" >> "$TMPDIR_TEST/log"; }
        mkdir -p "$HOME"
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/modules/fragments/11-mise-packages.sh"
    )
}

CONF="$TMPDIR_TEST/etc-mise/conf.d/devcell-packages.toml"
TOOLS='[tools]
"npm:prettier" = "^3"
"pipx:ruff" = "latest"'

echo "Test 1: writes the conf.d file and installs only those tools"
DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
assert_eq "conf.d file" "$TOOLS" "$(cat "$CONF")"
assert_eq "mise install args" "install -y npm:prettier pipx:ruff" "$(cat "$TMPDIR_TEST/mise.calls")"

echo "Test 2: unchanged tools skip the install"
rm -f "$TMPDIR_TEST/mise.calls"
DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
assert_eq "no mise call" "" "$(cat "$TMPDIR_TEST/mise.calls" 2>/dev/null)"

echo "Test 3: a failed install is logged loudly and retried next start"
rm -f "$TMPDIR_TEST/mise.calls" "$TMPDIR_TEST/log"
BAD='[tools]
"pipx:nope" = "latest"'
DEVCELL_MISE_PACKAGES="$BAD" FAKE_MISE_EXIT=1 run_fragment
assert_eq "warning logged" "1" "$(grep -c '⚠ \[packages.python\]/\[packages.node\] install failed' "$TMPDIR_TEST/log")"
assert_eq "mise error shown" "1" "$(grep -c 'pipx:nope not found' "$TMPDIR_TEST/log")"
rm -f "$TMPDIR_TEST/mise.calls"
DEVCELL_MISE_PACKAGES="$BAD" FAKE_MISE_EXIT=1 run_fragment
assert_eq "retried after failure" "install -y pipx:nope" "$(cat "$TMPDIR_TEST/mise.calls")"

echo "Test 4: no packages removes a stale conf.d file"
DEVCELL_MISE_PACKAGES="$TOOLS" run_fragment
unset DEVCELL_MISE_PACKAGES
run_fragment
assert_eq "conf.d file removed" "no" "$([ -e "$CONF" ] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
