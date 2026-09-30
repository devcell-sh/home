#!/bin/bash
# 11-mise-packages.sh — install [packages.python] / [packages.node] tools.
# Sourced by entrypoint.sh after 10-mise.sh.
#
# cell renders both tables as a mise [tools] table ("pipx:<name>", one venv
# per tool; "npm:<name>") and passes it in DEVCELL_MISE_PACKAGES. The file is
# written to mise's system conf.d, which is container-local, so each project
# in a shared cell gets its own tool set, while installs persist in the cell
# home's ~/.local/share/mise and are downloaded only once.

command -v mise &>/dev/null || return 0

setup_mise_packages() {
    local conf_dir="${MISE_SYSTEM_CONFIG_DIR:-/etc/mise}/conf.d"
    local conf="$conf_dir/devcell-packages.toml"
    local user_mise="$HOME/.local/share/mise"
    local sha_file="$user_mise/.devcell-packages.sha"

    if [ -z "${DEVCELL_MISE_PACKAGES:-}" ]; then
        rm -f "$conf"
        return 0
    fi
    mkdir -p "$conf_dir"
    printf '%s\n' "$DEVCELL_MISE_PACKAGES" > "$conf"

    local sha
    sha=$(printf '%s' "$DEVCELL_MISE_PACKAGES" | sha256sum | cut -d' ' -f1)
    if [ "$(cat "$sha_file" 2>/dev/null)" = "$sha" ]; then
        log "[packages.python]/[packages.node] unchanged, skipping install"
        return 0
    fi

    # Install only these tools, so a failure is attributed correctly.
    local tools
    tools=$(printf '%s\n' "$DEVCELL_MISE_PACKAGES" | sed -n 's/^"\([^"]*\)" = .*/\1/p' | tr '\n' ' ')
    log "Installing [packages.python]/[packages.node]: $tools"
    local out
    # shellcheck disable=SC2086 # tools is a space-separated list of mise tool names
    if out=$(cd / && MISE_DATA_DIR="$user_mise" HOME="$HOME" USER="$HOST_USER" mise install -y $tools 2>&1); then
        mkdir -p "$user_mise"
        echo "$sha" > "$sha_file"
    else
        # A container start can't be failed usefully; make the failure loud.
        # No sha is written, so the next start retries.
        log "⚠ [packages.python]/[packages.node] install failed; these tools are missing."
        log "  pipx: tools need the python module (uv), npm: tools need the node module."
        printf '%s\n' "$out" | while IFS= read -r line; do log "  $line"; done
    fi
    [ -d "$user_mise" ] && chown -R "$HOST_USER" "$user_mise" 2>/dev/null
    return 0
}
setup_mise_packages
