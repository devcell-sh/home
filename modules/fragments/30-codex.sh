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

    python3 - "$nix_file" "$providers_file" "$target_file" "$temp_file" 2>/dev/null << 'PYEOF'
import sys, tomllib, os

nix_path, providers_path, target_path, temp_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def toml_val(v):
    if isinstance(v, str):   return f'"{v}"'
    if isinstance(v, bool):  return 'true' if v else 'false'
    if isinstance(v, int):   return str(v)
    if isinstance(v, float): return repr(v)
    if isinstance(v, list):  return '[' + ', '.join(toml_val(x) for x in v) + ']'
    raise ValueError(f"unsupported type: {type(v)}")

import re
_BARE_KEY_RE = re.compile(r'^[A-Za-z0-9_-]+$')
def toml_key(k):
    # Table-header path segments must be quoted unless they're bare TOML keys
    # (dots and other punctuation — e.g. version numbers in profile names
    # like "qwehn-3.6-46b" — are not valid unquoted).
    return k if _BARE_KEY_RE.match(k) else f'"{k}"'

def write_toml(data, out):
    # Scalars first (skip internal keys and tables)
    skip = {'mcp_servers', 'model_providers', 'backupBeforeMerge',
            'devcellManagedServers', 'devcellManagedProviders'}
    for k, v in data.items():
        if k not in skip and not isinstance(v, dict):
            out.write(f'{k} = {toml_val(v)}\n')
    # mcp_servers section
    if 'mcp_servers' in data:
        for srv, sdata in data['mcp_servers'].items():
            out.write(f'\n[mcp_servers.{toml_key(srv)}]\n')
            for sk, sv in sdata.items():
                if not isinstance(sv, dict):
                    out.write(f'{sk} = {toml_val(sv)}\n')
            for sk, sv in sdata.items():
                if isinstance(sv, dict):
                    out.write(f'\n[mcp_servers.{toml_key(srv)}.{toml_key(sk)}]\n')
                    for ek, ev in sv.items():
                        out.write(f'{ek} = {toml_val(ev)}\n')
    # model_providers section
    if 'model_providers' in data:
        for pid, pdata in data['model_providers'].items():
            out.write(f'\n[model_providers.{toml_key(pid)}]\n')
            for pk, pv in pdata.items():
                if not isinstance(pv, dict):
                    out.write(f'{pk} = {toml_val(pv)}\n')
            for pk, pv in pdata.items():
                if isinstance(pv, dict):
                    out.write(f'\n[model_providers.{toml_key(pid)}.{toml_key(pk)}]\n')
                    for ek, ev in pv.items():
                        out.write(f'{ek} = {toml_val(ev)}\n')
    # Other tables
    for k, v in data.items():
        if k not in skip and isinstance(v, dict):
            out.write(f'\n[{k}]\n')
            for sk, sv in v.items():
                if not isinstance(sv, dict):
                    out.write(f'{sk} = {toml_val(sv)}\n')

try:
    with open(nix_path, 'rb') as f:
        nix = tomllib.load(f)
except FileNotFoundError:
    nix = {}

try:
    with open(providers_path, 'rb') as f:
        nix_providers_file = tomllib.load(f)
except FileNotFoundError:
    nix_providers_file = {}

try:
    with open(profiles_path, 'rb') as f:
        nix_profiles_file = tomllib.load(f)
except FileNotFoundError:
    nix_profiles_file = {}

try:
    with open(target_path, 'rb') as f:
        existing = tomllib.load(f)
except FileNotFoundError:
    existing = {}

merged = dict(existing)
def is_devcell_managed(srv):
    if not isinstance(srv, dict):
        return False
    cmd = srv.get('command')
    return (
        isinstance(cmd, str) and cmd.startswith('/opt/devcell/')
    )

def resolve_env_value(value):
    if not isinstance(value, str):
        return value, True
    if value.startswith('${') and value.endswith('}') and len(value) > 3:
        name = value[2:-1]
        resolved = os.environ.get(name)
        return resolved, bool(resolved)
    return value, True

def codex_ready_servers(servers):
    ready = {}
    skipped = []
    for name, srv in servers.items():
        if not isinstance(srv, dict):
            ready[name] = srv
            continue
        srv = dict(srv)
        env = srv.get('env')
        if isinstance(env, dict):
            resolved_env = {}
            missing = []
            for key, value in env.items():
                resolved, ok = resolve_env_value(value)
                if not ok:
                    missing.append(key)
                else:
                    resolved_env[key] = resolved
            if missing:
                skipped.append((name, missing))
                continue
            srv['env'] = resolved_env
        ready[name] = srv
    return ready, skipped

# Remove stale nix-managed servers before adding current stack. The marker handles
# generated entries whose command cannot identify the owning stack; the /opt/devcell
# prefix handles older configs.
managed_names = set(nix.get('devcellManagedServers', []))
cleaned = {k: v for k, v in existing.get('mcp_servers', {}).items()
           if k not in managed_names and not is_devcell_managed(v)}
# Include ALL servers (strip enabled field); disabled state is synced after merge
raw_nix = nix.get('mcp_servers', {})
all_nix = {}
for name, srv in raw_nix.items():
    if not isinstance(srv, dict):
        continue
    all_nix[name] = {k: v for k, v in srv.items() if k != 'enabled'}

nix_servers, skipped = codex_ready_servers(all_nix)
merged['mcp_servers'] = {**cleaned, **nix_servers}

# model_providers: nix-declared ids overwrite same-id existing entries; ids not
# declared by nix are left untouched. No stale-orphan cleanup here (unlike
# mcp_servers) — providers carry no command-path marker to tell a previously
# nix-managed entry apart from one the user added by hand.
nix_providers = nix_providers_file.get('model_providers', {})
if nix_providers:
    merged['model_providers'] = {**existing.get('model_providers', {}), **nix_providers}

# profiles: same non-destructive overlay as model_providers — nix-declared
# names overwrite same-name existing entries, everything else is untouched.
nix_profiles = nix_profiles_file.get('profiles', {})
if nix_profiles:
    merged['profiles'] = {**existing.get('profiles', {}), **nix_profiles}

with open(temp_path, 'w') as f:
    write_toml(merged, f)

print(f"merged {len(merged.get('mcp_servers', {}))} server(s), {len(nix_providers)} model provider(s), {len(nix_profiles)} profile(s)", file=sys.stderr)
for name, missing in skipped:
    print(f"skipped {name}: missing {', '.join(missing)}", file=sys.stderr)
PYEOF

    if [ $? -eq 0 ] && [ -s "$temp_file" ] && python3 -c "import tomllib; tomllib.load(open('$temp_file','rb'))" 2>/dev/null; then
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
