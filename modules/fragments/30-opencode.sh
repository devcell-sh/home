#!/bin/bash
# 30-opencode.sh — merge nix-declared OpenCode providers + MCP servers
# Sourced by entrypoint.sh; has access to $HOME, $HOST_USER, log()

notify opencode.starting

merge_opencode_providers() {
    local target_file="$1"
    local nix_file="/etc/opencode/nix-providers.json"

    [ -f "$nix_file" ] || return 0

    if ! jq empty "$nix_file" 2>/dev/null; then
        echo "⚠ nix-providers.json (OpenCode) is invalid JSON — skipping provider merge"
        return 1
    fi

    mkdir -p "$(dirname "$target_file")"

    if [ ! -f "$target_file" ]; then
        # No user config yet — seed it from nix providers (+ default model/plugins, if set)
        local temp_file
        temp_file=$(mktemp)
        jq '{"$schema":"https://opencode.ai/config.json","provider": .provider}
            + (if .model then {model: .model} else {} end)
            + (if .plugin then {plugin: .plugin} else {} end)' "$nix_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ ~/opencode.json created with $(jq '.provider | length' "$target_file") nix provider(s)"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to create ~/opencode.json"
        fi
        return 0
    fi

    if ! jq empty "$target_file" 2>/dev/null; then
        echo "⚠ ~/opencode.json is invalid JSON — skipping provider merge"
        return 1
    fi

    # Merge: inject nix providers only where the key is absent in user config.
    # Same non-destructive rule for "model": only set from nix if the user's
    # config doesn't already have a default model chosen. Plugins are
    # appended (not replaced) — dedup by package name, ignoring any
    # trailing @version and preserving a leading @scope.
    local temp_file
    temp_file=$(mktemp)
    jq -s '
      def pkgname:
        if type == "array" then .[0]
        elif (length > 0 and .[0:1] == "@") then ("@" + (.[1:] | split("@")[0]))
        else (split("@")[0])
        end;
      .[0] as $existing |
      .[1].provider as $nix |
      .[1].model as $nixModel |
      .[1].plugin as $nixPlugin |
      ($existing.plugin // []) as $existingPlugins |
      ($existingPlugins | map(pkgname)) as $existingNames |
      (($nixPlugin // []) | map(select((pkgname) as $n | ($existingNames | index($n)) == null))) as $toAdd |
      $existing
      | .provider = (($nix // {}) + ($existing.provider // {}))
      | (if ($existing.model == null) and ($nixModel != null) then .model = $nixModel else . end)
      | (if ($toAdd | length) > 0 then .plugin = ($existingPlugins + $toAdd) else . end)
    ' "$target_file" "$nix_file" > "$temp_file" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        log "✓ OpenCode providers merged into ~/opencode.json"
    else
        rm -f "$temp_file"
        echo "⚠ Failed to merge OpenCode providers — keeping original"
    fi
}

_mcp_enabled_json() {
    local raw="${DEVCELL_MCP_ENABLED:-}"
    if [ -z "$raw" ]; then
        echo '[]'
    else
        echo "$raw" | tr ',' '\n' | jq -R . | jq -s .
    fi
}

merge_opencode_mcp() {
    local target_file="$1"
    local nix_file="/etc/opencode/nix-mcp-servers.json"

    [ -f "$nix_file" ] || return 0

    if ! jq empty "$nix_file" 2>/dev/null; then
        echo "⚠ nix-mcp-servers.json (OpenCode) is invalid JSON — skipping MCP merge"
        return 1
    fi

    local backup_before_merge
    backup_before_merge=$(jq -r '.backupBeforeMerge // true' "$nix_file")
    local enabled_json
    enabled_json=$(_mcp_enabled_json 2>/dev/null || echo '[]')

    # Include ALL servers (strip enabled field); disabled state is synced after merge
    local filtered_file
    filtered_file=$(mktemp)
    jq '
      .mcp = (
        (.mcp // {}) | to_entries |
        map({key: .key, value: (.value | del(.enabled))}) |
        from_entries
      )
    ' "$nix_file" > "$filtered_file" 2>/dev/null
    if ! [ -s "$filtered_file" ] || ! jq empty "$filtered_file" 2>/dev/null; then
        rm -f "$filtered_file"
        echo "⚠ Failed to prepare nix MCP servers (OpenCode) — skipping merge"
        return 1
    fi

    mkdir -p "$(dirname "$target_file")"

    if [ ! -f "$target_file" ]; then
        log "Creating ~/.opencode.json with nix MCP servers"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcp: (.mcp // {})}' "$filtered_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ ~/.opencode.json created ($(jq '.mcp | length' "$target_file") server(s))"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to create ~/.opencode.json"
            rm -f "$filtered_file"
            return 1
        fi
        rm -f "$filtered_file"
        return 0
    fi

    if ! jq empty "$target_file" 2>/dev/null; then
        local corrupt_bak="${target_file}.corrupt-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$corrupt_bak"
        log "⚠ ~/.opencode.json was corrupt — saved to $(basename "$corrupt_bak"), recreating"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcp: (.mcp // {})}' "$filtered_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
        else
            rm -f "$temp_file"
            rm -f "$filtered_file"
            return 1
        fi
        rm -f "$filtered_file"
        return 0
    fi

    local backup_file=""
    if [ "$backup_before_merge" = "true" ]; then
        backup_file="${target_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$backup_file"
        log "✓ Created backup: $(basename "$backup_file")"
        ls -t "${target_file}.backup-"* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi

    local temp_file
    temp_file=$(mktemp)
    jq -s '
      .[0] as $existing |
      .[1].mcp as $nix |
      (($existing.mcp // {}) | to_entries |
        map(select(.value.command == null or (.value.command[0] == null) or (.value.command[0] | startswith("/opt/devcell/") | not))) |
        from_entries) as $cleaned |
      $existing | .mcp = ($cleaned + ($nix // {}))
    ' "$target_file" "$filtered_file" > "$temp_file" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        log "✓ MCP servers merged into ~/.opencode.json ($(jq '.mcp | length' "$target_file") total)"
    else
        rm -f "$temp_file"
        echo "⚠ Failed to merge MCP servers into ~/.opencode.json — keeping original"
        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            cp "$backup_file" "$target_file"
            echo "✓ Restored from backup"
        fi
        rm -f "$filtered_file"
        return 1
    fi
    rm -f "$filtered_file"
}

# ── Sync nix-managed commands ──
if [ -d "$DEVCELL_HOME/.config/opencode/commands" ] && [ -n "$(ls -A "$DEVCELL_HOME/.config/opencode/commands" 2>/dev/null)" ]; then
    mkdir -p "$HOME/.config/opencode/commands"
    rsync -a --chown="$HOST_USER" "$DEVCELL_HOME/.config/opencode/commands/" "$HOME/.config/opencode/commands/"
    log "✓ OpenCode commands synced from nix"
fi

# ── Run merges ──
# OpenCode reads global config from ~/.config/opencode/opencode.jsonc (priority)
# or ~/.config/opencode/opencode.json. Providers, plugins, and MCP all go there
# so they resolve regardless of CWD.
_oc_global="$HOME/.config/opencode/opencode.json"
[ -f "$HOME/.config/opencode/opencode.jsonc" ] && _oc_global="$HOME/.config/opencode/opencode.jsonc"

merge_opencode_providers "$_oc_global"
merge_opencode_mcp "$_oc_global"

# Sync MCP disabled state using mcp-toggle abstraction
if [ -f "$_oc_global" ] && type disableMcp >/dev/null 2>&1; then
    _nix_oc="/etc/opencode/nix-mcp-servers.json"
    if [ -f "$_nix_oc" ]; then
        _el=$(_mcp_enabled_json)
        _disabled_count=0
        while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            disableMcp opencode "$_name" "$_oc_global"
            _disabled_count=$((_disabled_count + 1))
        done < <(jq -r --argjson el "$_el" '
            [(.mcp // {}) | to_entries[] |
             select(.value.enabled != true and ((.key as $k | $el | index($k)) == null)) |
             .key][]
        ' "$_nix_oc")
        while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            enableMcp opencode "$_name" "$_oc_global"
        done < <(jq -r --argjson el "$_el" '
            [(.mcp // {}) | to_entries[] |
             select(.value.enabled == true or ((.key as $k | $el | index($k)) != null)) |
             .key][]
        ' "$_nix_oc")
        log "✓ OpenCode MCP disabled state synced ($_disabled_count disabled)"
    fi
fi

[ -f "$_oc_global" ] && chown $HOST_USER "$_oc_global"

notify opencode.ready
