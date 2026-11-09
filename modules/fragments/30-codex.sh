#!/bin/bash
# 30-codex.sh — Codex CLI MCP server merge logic
# Sourced by entrypoint.sh; has access to $HOME, $HOST_USER, log()

notify codex.starting

merge_codex_mcp() {
    local target_file="$1"
    local nix_file="/etc/codex/nix-mcp-servers.toml"
    local providers_file="/etc/codex/nix-providers.toml"

    [ -f "$nix_file" ] || [ -f "$providers_file" ] || return 0

    if ! command -v python3 &>/dev/null; then
        echo "⚠ python3 not available — skipping Codex MCP/provider merge"
        return 1
    fi

    for f in "$nix_file" "$providers_file"; do
        [ -f "$f" ] || continue
        if ! python3 -c "import tomllib; tomllib.load(open('$f','rb'))" 2>/dev/null; then
            echo "⚠ $(basename "$f") (Codex) is invalid TOML — skipping merge"
            return 1
        fi
    done

    local backup_before_merge
    backup_before_merge=$(python3 -c "
import tomllib, sys
d = {}
try:
    with open('$nix_file', 'rb') as f:
        d = tomllib.load(f)
except FileNotFoundError:
    pass
print('true' if d.get('backupBeforeMerge', True) else 'false')
" 2>/dev/null || echo "true")

    mkdir -p "$(dirname "$target_file")"

    if [ -f "$target_file" ] && ! python3 -c "import tomllib; tomllib.load(open('$target_file','rb'))" 2>/dev/null; then
        local corrupt_bak="${target_file}.corrupt-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$corrupt_bak"
        log "⚠ ~/.codex/config.toml was corrupt — saved to $(basename "$corrupt_bak"), recreating"
        rm -f "$target_file"
    fi

    local backup_file=""
    if [ -f "$target_file" ] && [ "$backup_before_merge" = "true" ]; then
        backup_file="${target_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$backup_file"
        log "✓ Created backup: $(basename "$backup_file")"
        ls -t "${target_file}.backup-"* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi

    local temp_file
    temp_file=$(mktemp --suffix=.toml)

    if devcell-codex-config-merge "$nix_file" "$providers_file" "$target_file" "$temp_file" && [ -s "$temp_file" ] && python3 -c "import tomllib; tomllib.load(open('$temp_file','rb'))" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        log "✓ MCP servers + model providers merged into ~/.codex/config.toml"
    else
        rm -f "$temp_file"
        echo "⚠ Failed to merge MCP servers/providers into ~/.codex/config.toml — keeping original"
        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            cp "$backup_file" "$target_file"
            echo "✓ Restored from backup"
        fi
        return 1
    fi
}

# sync_codex_profiles — stage $CODEX_HOME/<name>.config.toml per nix-declared
# profile. Unlike mcp_servers/model_providers, this Codex version rejects
# [profiles.<name>] tables in config.toml as legacy — profiles only work as
# separate flat files. Each file is fully nix-owned (no merge needed): nix
# always overwrites same-name files, and profiles previously nix-managed but
# no longer declared are removed via a manifest diff.
sync_codex_profiles() {
    local src_dir="/etc/codex/nix-codex-profiles"
    local dest_dir="$HOME/.codex"
    local manifest="$dest_dir/.devcell-managed-profiles"

    [ -d "$src_dir" ] || return 0
    mkdir -p "$dest_dir"

    # mapfile (line-based) instead of unquoted-var word-splitting: this
    # fragment is sourced into entrypoint.sh alongside others, so IFS at
    # call time isn't guaranteed to be the default.
    local prev_names=()
    [ -f "$manifest" ] && mapfile -t prev_names < "$manifest"

    local current_names=()
    [ -f "$src_dir/.devcell-managed-profiles" ] && mapfile -t current_names < "$src_dir/.devcell-managed-profiles"

    # Remove profiles that were nix-managed before but aren't declared anymore.
    local name is_current
    for name in "${prev_names[@]}"; do
        [ -n "$name" ] || continue
        is_current=0
        for cur in "${current_names[@]}"; do
            [ "$name" = "$cur" ] && is_current=1 && break
        done
        if [ "$is_current" -eq 0 ]; then
            rm -f "$dest_dir/${name}.config.toml"
            log "✓ Removed stale Codex profile: ${name}.config.toml"
        fi
    done

    # Stage current profiles (nix always wins for its own names). --no-preserve=mode:
    # the nix-store source is read-only (0444) — without this, cp propagates
    # that mode to the destination and the *next* sync can't overwrite its own
    # previously-staged file, even as the owning user.
    local count=0
    for name in "${current_names[@]}"; do
        [ -n "$name" ] || continue
        [ -f "$src_dir/${name}.config.toml" ] || continue
        cp --no-preserve=mode "$src_dir/${name}.config.toml" "$dest_dir/${name}.config.toml"
        chmod u+w "$dest_dir/${name}.config.toml"
        count=$((count + 1))
    done
    cp --no-preserve=mode "$src_dir/.devcell-managed-profiles" "$manifest" 2>/dev/null
    chmod u+w "$manifest" 2>/dev/null

    log "✓ ${count} Codex profile(s) staged in ~/.codex/"
}

# ── Migrate: strip legacy [profiles.*] tables from config.toml ──
# An earlier version of this module wrote profiles as [profiles.<name>]
# tables in config.toml. This Codex version refuses to start with --profile
# at all while any such table exists ("legacy ... config"), regardless of
# which profile is requested — so this must be cleaned unconditionally, not
# just for names we currently manage.
strip_legacy_codex_profile_tables() {
    local target_file="$1"
    [ -f "$target_file" ] || return 0
    command -v python3 &>/dev/null || return 0
    grep -q '^\[profiles\.' "$target_file" || return 0

    python3 - "$target_file" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
original = content
# Remove one [profiles.*] table (header + body lines) per pass, re-scanning
# the updated string each time: matching all tables in one re.sub pass lets
# an earlier match's body-loop consume the blank line that would have been
# the next table's required leading "\n", so later tables get silently
# skipped. Looping one-at-a-time avoids that.
pattern = re.compile(r'\n\[profiles\.[^\]]*\]\n(?:(?!\[)[^\n]*\n?)*')
while True:
    new_content, n = pattern.subn('\n', content, count=1)
    if n == 0:
        break
    content = new_content
if content != original:
    with open(path, 'w') as f:
        f.write(content)
    print("stripped legacy [profiles.*] tables", file=sys.stderr)
PYEOF
    log "✓ Removed legacy [profiles.*] tables from ~/.codex/config.toml (unsupported by this Codex version)"
}

# ── Sync nix-managed skills ──
if [ -d "$DEVCELL_HOME/.codex/skills" ] && [ -n "$(ls -A "$DEVCELL_HOME/.codex/skills" 2>/dev/null)" ]; then
    mkdir -p "$HOME/.codex/skills"
    rsync -a --chown="$HOST_USER" "$DEVCELL_HOME/.codex/skills/" "$HOME/.codex/skills/"
    log "✓ Codex skills synced from nix"
fi

# ── Migrate: remove stale oss_provider = "lms" (set by old -p lms flag) ──
config_toml="$HOME/.codex/config.toml"
if [ -f "$config_toml" ] && grep -q '^oss_provider = "lms"' "$config_toml"; then
    sed -i '/^oss_provider = "lms"/d' "$config_toml"
    log "✓ Removed stale oss_provider = \"lms\" from ~/.codex/config.toml"
fi

strip_legacy_codex_profile_tables "$config_toml"
merge_codex_mcp "$HOME/.codex/config.toml"

# Sync MCP disabled state using mcp-toggle abstraction
_codex_mcp_enabled_json() {
    local raw="${DEVCELL_MCP_ENABLED:-}"
    if [ -z "$raw" ]; then echo '[]'
    else echo "$raw" | tr ',' '\n' | jq -R . | jq -s .
    fi
}
if [ -f "$HOME/.codex/config.toml" ] && type disableMcp >/dev/null 2>&1; then
    _nix_codex="/etc/codex/nix-mcp-servers.toml"
    if [ -f "$_nix_codex" ]; then
        _el=$(_codex_mcp_enabled_json)
        _disabled_count=0
        while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            disableMcp codex "$_name" "$HOME/.codex/config.toml"
            _disabled_count=$((_disabled_count + 1))
        done < <(python3 -c "
import tomllib, json, sys
with open('$_nix_codex', 'rb') as f:
    nix = tomllib.load(f)
el = json.loads(sys.argv[1])
for name, srv in nix.get('mcp_servers', {}).items():
    if not isinstance(srv, dict): continue
    if not srv.get('enabled', False) and name not in el:
        print(name)
" "$_el")
        while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            enableMcp codex "$_name" "$HOME/.codex/config.toml"
        done < <(python3 -c "
import tomllib, json, sys
with open('$_nix_codex', 'rb') as f:
    nix = tomllib.load(f)
el = json.loads(sys.argv[1])
for name, srv in nix.get('mcp_servers', {}).items():
    if not isinstance(srv, dict): continue
    if srv.get('enabled', False) or name in el:
        print(name)
" "$_el")
        log "✓ Codex MCP disabled state synced ($_disabled_count disabled)"
    fi
fi

sync_codex_profiles
[ -d "$HOME/.codex" ] && chown -R "$HOST_USER" "$HOME/.codex"

notify codex.ready
