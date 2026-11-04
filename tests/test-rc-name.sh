#!/bin/bash
# Test: RC_NAME is reliably resolved for every service via two mechanisms:
#
# Oneshots: the renderer writes an execline `export RC_NAME <name> ...` wrapper,
#   so RC_NAME is set before the shell script runs.
#
# Longruns: devcell-event auto-detects from pwd (s6-supervise chdirs to service dir).
#
# No service script should set RC_NAME itself.
set -euo pipefail
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; echo "    expected: $2"; echo "    actual:   $3"; FAIL=$((FAIL+1)); fi; }

S6_DIR="$(cd "$(dirname "$0")/../modules/s6" && pwd)"

echo "Test 1: no service script sets RC_NAME (renderer and devcell-event handle it)"
for svc_dir in "$S6_DIR"/*/; do
    svc_name=$(basename "$svc_dir")
    [ "$svc_name" = "user" ] && continue
    for script in "$svc_dir/up" "$svc_dir/run" "$svc_dir/linux/up" "$svc_dir/darwin/up"; do
        [ -f "$script" ] || continue
        if grep -q 'RC_NAME' "$script"; then
            echo "  ✗ $svc_name/$(basename "$script") still sets RC_NAME"
            FAIL=$((FAIL+1))
        else
            PASS=$((PASS+1))
        fi
    done
done
echo "  (no-boilerplate check done)"

echo "Test 2: renderer injects RC_NAME for oneshots"
RENDERER="$(cd "$(dirname "$0")/.." && pwd)/modules/s6-linux-renderer.nix"
if grep -q 'export RC_NAME' "$RENDERER"; then
    assert_eq "linux renderer injects RC_NAME" "true" "true"
else
    assert_eq "linux renderer injects RC_NAME" "true" "false"
fi
RENDERER_DARWIN="$(cd "$(dirname "$0")/.." && pwd)/modules/s6-darwin-renderer.nix"
if grep -q 'export RC_NAME' "$RENDERER_DARWIN"; then
    assert_eq "darwin renderer injects RC_NAME" "true" "true"
else
    assert_eq "darwin renderer injects RC_NAME" "true" "false"
fi

echo "Test 3: devcell-event falls back to pwd when RC_NAME is unset"
HELPER="$(cd "$(dirname "$0")/.." && pwd)/modules/base.nix"
if grep -q 'basename.*pwd' "$HELPER"; then
    assert_eq "devcell-event has pwd fallback" "true" "true"
else
    assert_eq "devcell-event has pwd fallback" "true" "false"
fi

echo "Test 4: simulated oneshot (RC_NAME set by renderer via env)"
TMPDIR_TEST=$(mktemp -d); trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/source/test-svc"
cat > "$TMPDIR_TEST/source/test-svc/up.sh" <<'SCRIPT'
#!/bin/sh
echo "$RC_NAME"
SCRIPT
chmod +x "$TMPDIR_TEST/source/test-svc/up.sh"
result=$(RC_NAME=test-svc "$TMPDIR_TEST/source/test-svc/up.sh")
assert_eq "oneshot RC_NAME=test-svc (from env)" "test-svc" "$result"

echo "Test 5: simulated longrun (pwd-derived, no RC_NAME in env)"
mkdir -p "$TMPDIR_TEST/servicedirs/test-daemon"
cat > "$TMPDIR_TEST/servicedirs/test-daemon/run" <<'SCRIPT'
#!/bin/sh
echo "$(basename "$(pwd)")"
SCRIPT
chmod +x "$TMPDIR_TEST/servicedirs/test-daemon/run"
result=$(cd "$TMPDIR_TEST/servicedirs/test-daemon" && ./run)
assert_eq "longrun pwd=test-daemon" "test-daemon" "$result"

echo "Test 6: dirname \$0 gives '.' under s6-supervise (confirming pwd is needed)"
cat > "$TMPDIR_TEST/servicedirs/test-daemon/run2" <<'SCRIPT'
#!/bin/sh
echo "$(basename "$(dirname "$0")")"
SCRIPT
chmod +x "$TMPDIR_TEST/servicedirs/test-daemon/run2"
result=$(cd "$TMPDIR_TEST/servicedirs/test-daemon" && ./run2)
assert_eq "dirname \$0 gives '.'" "." "$result"

echo; echo "Passed: $PASS, Failed: $FAIL"; [ "$FAIL" -eq 0 ]
