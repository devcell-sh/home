#!/bin/bash
# 09-nix-packages.sh — install per-project nix packages at container start.
#
# Reads .devcell/cell.json field "nix_packages" and installs listed packages
# into a dedicated nix profile. The cell CLI populates this field by merging:
#   [cell] packages = ["jq"]           — shorthand
#   [packages.nix] packages = ["grpc"] — consistent with [packages.npm/python]
# Both sources are deduplicated into one array.
#
# Hash-cached: skips reinstall if the list hasn't changed.
# Runs between project-flake (08) and mise (10).

PROJECT_DIR="${WORKSPACE:-}"
[ -z "$PROJECT_DIR" ] && return 0

_CELL_JSON="$PROJECT_DIR/.devcell/cell.json"
[ -f "$_CELL_JSON" ] || return 0
command -v jq &>/dev/null || { log "nix-packages: jq not found, skipping"; return 0; }

_NIX_PKGS=$(jq -r '.nix_packages[]?' "$_CELL_JSON" 2>/dev/null)
[ -z "$_NIX_PKGS" ] && return 0

_PKG_COUNT=$(echo "$_NIX_PKGS" | wc -l)
log "nix-packages: found $_PKG_COUNT package(s) in cell.json"

NIX_PKG_CACHE="$HOME/.cache/devcell/nix-packages"
NIX_PKG_PROFILE="$HOME/.local/state/nix/profiles/devcell-toml"

mkdir -p "$NIX_PKG_CACHE"
chown -R "$HOST_USER" "$HOME/.cache/devcell" 2>/dev/null || true

# Hash gate: skip if package list hasn't changed.
_pkg_hash=$(echo "$_NIX_PKGS" | sha256sum | cut -d' ' -f1)
_hash_file="$NIX_PKG_CACHE/packages.hash"

if [ -f "$_hash_file" ] && [ "$(cat "$_hash_file" 2>/dev/null)" = "$_pkg_hash" ] && [ -e "$NIX_PKG_PROFILE" ]; then
    log "nix-packages: unchanged, skipping install"
    export PATH="$NIX_PKG_PROFILE/bin${PATH:+:}$PATH"
    return 0
fi

notify nix-packages.starting

export NIX_CONF_DIR="${NIX_CONF_DIR:-/opt/devcell/.config/nix}"

# Wipe previous profile to avoid stale packages.
if [ -e "$NIX_PKG_PROFILE" ]; then
    rm -f "$NIX_PKG_PROFILE" "${NIX_PKG_PROFILE}"-*
    log "nix-packages: cleared previous profile"
fi

log "nix-packages: installing..."
_install_log=$(mktemp)
_failed=0

while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    if gosu "$HOST_USER" nix profile install \
        --profile "$NIX_PKG_PROFILE" \
        "nixpkgs#$_pkg" >> "$_install_log" 2>&1; then
        log "nix-packages: installed $_pkg"
    else
        log "nix-packages: FAILED to install $_pkg"
        _failed=1
    fi
done <<< "$_NIX_PKGS"

while IFS= read -r line; do log "  $line"; done < "$_install_log"
rm -f "$_install_log"

if [ "$_failed" -eq 0 ]; then
    echo "$_pkg_hash" > "$_hash_file"
    chown -R "$HOST_USER" "$NIX_PKG_CACHE" 2>/dev/null || true
    chown -R "$HOST_USER" "$HOME/.local/state/nix/profiles" 2>/dev/null || true

    # Stamp GC root.
    _profile_store=$(readlink -f "$NIX_PKG_PROFILE" 2>/dev/null)
    if [ -n "$_profile_store" ] && [ -d /nix/var/nix/gcroots/devcell ]; then
        _profile_hash=$(basename "$_profile_store" | cut -d- -f1)
        ln -sfT "$_profile_store" "/nix/var/nix/gcroots/devcell/${_profile_hash}-nix-packages"
        log "nix-packages: GC root stamped"
    fi

    export PATH="$NIX_PKG_PROFILE/bin${PATH:+:}$PATH"
    log "nix-packages: installed $_PKG_COUNT package(s) successfully"
else
    log "nix-packages: some packages failed to install (continuing)"
    [ -e "$NIX_PKG_PROFILE" ] && export PATH="$NIX_PKG_PROFILE/bin${PATH:+:}$PATH"
fi

notify nix-packages.ready
