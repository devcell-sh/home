#!/usr/bin/env bats

load helper_test

# Extract the version-detection + UA-building logic from the wrapper script
# and test it against mock chrome binaries to verify:
#   1. Detected version propagates into the UA string
#   2. When _EXEC_PATH_OVERRIDE is set, version is re-detected from that binary
#   3. Google Chrome brand is included in the generated brands

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export HOME="$TMPDIR_TEST/home"
  mkdir -p "$HOME"

  # Create mock chrome binary reporting version 141
  MOCK_CHROME_141="$TMPDIR_TEST/chrome-141"
  cat > "$MOCK_CHROME_141" <<'SH'
#!/bin/sh
echo "Chromium 141.0.7390.37"
SH
  chmod +x "$MOCK_CHROME_141"

  # Create mock chrome binary reporting version 149
  MOCK_CHROME_149="$TMPDIR_TEST/chrome-149"
  cat > "$MOCK_CHROME_149" <<'SH'
#!/bin/sh
echo "Chromium 149.0.7827.196"
SH
  chmod +x "$MOCK_CHROME_149"

  # Create a browsers dir with chrome at a findable path
  BROWSERS="$TMPDIR_TEST/browsers"
  mkdir -p "$BROWSERS/chromium-1223/chrome-linux"
  cp "$MOCK_CHROME_141" "$BROWSERS/chromium-1223/chrome-linux/chrome"

  # Minimal config.json
  CONFIG="$TMPDIR_TEST/config.json"
  cat > "$CONFIG" <<'JSON'
{"browser":{"launchOptions":{"args":["--no-sandbox"]},"contextOptions":{}}}
JSON

  JQ="$(command -v jq)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# Extracts the version-detection + UA-building logic from the real wrapper
# and runs it in a subshell with controlled inputs.
run_version_detect() {
  local browsers_path="$1"
  local stealth_arch="$2"
  local stealth_platform="$3"
  local exec_path_override="${4:-}"

  (
    PLAYWRIGHT_BROWSERS_PATH="$browsers_path"
    _STEALTH_ARCH="$stealth_arch"
    _STEALTH_PLATFORM="$stealth_platform"
    _EXEC_PATH_OVERRIDE="$exec_path_override"

    # --- Version detection (from wrapper) ---
    _CHROME_BIN=$(find "${PLAYWRIGHT_BROWSERS_PATH:-/dev/null}" -name 'chrome' -type f 2>/dev/null | tail -1)
    _CHROME_FULL_VER="141.0.0.0"
    if [ -n "$_CHROME_BIN" ] && [ -x "$_CHROME_BIN" ]; then
      _CHROME_FULL_VER=$("$_CHROME_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' || echo "141.0.0.0")
    fi
    # Re-detect from the override binary when set (the actual executable may
    # be a different version than the bundled patchright-browsers chrome).
    if [ -n "$_EXEC_PATH_OVERRIDE" ] && [ -x "$_EXEC_PATH_OVERRIDE" ]; then
      _CHROME_FULL_VER=$("$_EXEC_PATH_OVERRIDE" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' || echo "$_CHROME_FULL_VER")
    fi
    _CHROME_MAJOR="${_CHROME_FULL_VER%%.*}"

    # --- Build UA ---
    case "$_STEALTH_PLATFORM" in
      macOS)   _STEALTH_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_CHROME_FULL_VER Safari/537.36" ;;
      *)
        if [ "$_STEALTH_ARCH" = "arm" ]; then
          _STEALTH_UA="Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_CHROME_FULL_VER Safari/537.36"
        else
          _STEALTH_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_CHROME_FULL_VER Safari/537.36"
        fi ;;
    esac

    # Output for assertions
    printf 'FULL_VER=%s\n' "$_CHROME_FULL_VER"
    printf 'MAJOR=%s\n' "$_CHROME_MAJOR"
    printf 'UA=%s\n' "$_STEALTH_UA"

    # Generate config via jq (same as wrapper)
    _brands=$("$JQ" -c -n \
      --arg arch "$_STEALTH_ARCH" \
      --arg plat "$_STEALTH_PLATFORM" \
      --arg ua "$_STEALTH_UA" \
      --arg cmajor "$_CHROME_MAJOR" \
      --arg cfull "$_CHROME_FULL_VER" \
      --arg execpath "$_EXEC_PATH_OVERRIDE" \
      '{
        brands: [
          {"brand": "Google Chrome", "version": $cmajor},
          {"brand": "Chromium", "version": $cmajor},
          {"brand": "Not?A_Brand", "version": "8"}
        ],
        fullVersionList: [
          {"brand": "Google Chrome", "version": $cfull},
          {"brand": "Chromium", "version": $cfull},
          {"brand": "Not?A_Brand", "version": "8.0.0.0"}
        ]
      }')
    printf 'BRANDS_JSON=%s\n' "$_brands"
  )
}

@test "version detected from patchright-browsers chrome binary" {
  run run_version_detect "$BROWSERS" "arm" "Linux" ""
  assert_success
  assert_line "FULL_VER=141.0.7390.37"
  assert_line "MAJOR=141"
  assert_line --partial "Chrome/141.0.7390.37"
}

@test "exec_path_override causes version re-detection from override binary" {
  run run_version_detect "$BROWSERS" "x86_64" "Linux" "$MOCK_CHROME_149"
  assert_success
  # When exec_path_override is set to chromium 149, the version should be 149
  assert_line "FULL_VER=149.0.7827.196"
  assert_line "MAJOR=149"
  assert_line --partial "Chrome/149.0.7827.196"
}

@test "Google Chrome brand is included in generated brands" {
  run run_version_detect "$BROWSERS" "arm" "Linux" ""
  assert_success
  # Extract the BRANDS_JSON line
  brands_line="$(echo "$output" | grep '^BRANDS_JSON=')"
  brands_json="${brands_line#BRANDS_JSON=}"
  # Check Google Chrome brand is present
  echo "$brands_json" | "$JQ" -e '.brands[] | select(.brand == "Google Chrome")' >/dev/null
}
