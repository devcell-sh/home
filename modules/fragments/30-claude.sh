#!/bin/bash
# 30-claude.sh — Claude Code merge logic (nix-generated entrypoint fragment)
# Sourced by entrypoint.sh; has access to: $HOME, $HOST_USER, $USER, $DEVCELL_HOME, log()

notify claude.starting

merge_claude_settings() {
    local template_file="$1" target_file="$2"
    [ -f "$template_file" ] || return 1
    mkdir -p "$(dirname "$target_file")"
    if [ ! -f "$target_file" ]; then
        log "Creating Claude settings from template"
        cp "$template_file" "$target_file"
        return 0
    fi
    local backup_file="${target_file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$target_file" "$backup_file"
    log "✓ Created backup: $(basename "$backup_file")"
    ls -t "${target_file}.backup-"* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    log "Merging Claude settings (preserving existing configuration)"
    local temp_file=$(mktemp)
    # When routed through a third-party gateway (OpenRouter), strip the
    # PermissionRequest hook entirely: non-Anthropic models interpret hook
    # responses as user messages and abort in-flight tool calls.
    if [ "${ANTHROPIC_BASE_URL:-}" = "https://openrouter.ai/api" ]; then
        jq -s '(.[0] * .[1]) | del(.hooks.PermissionRequest)' \
            "$target_file" "$template_file" > "$temp_file" 2>/dev/null
    else
        jq -s '
          if .[0].hooks.PermissionRequest then .[0]
          else .[0] * .[1]
          end
        ' "$target_file" "$template_file" > "$temp_file" 2>/dev/null
    fi
    if [ $? -eq 0 ] && [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        grep -q "PermissionRequest" "$target_file" \
            && log "✓ Claude settings updated (PermissionRequest hook configured)" \
            || log "✓ Claude settings preserved (custom PermissionRequest hook detected)"
    else
        echo "⚠ Failed to merge Claude settings, restoring from backup"
        cp "$backup_file" "$target_file"
        rm -f "$temp_file"
    fi
}

merge_claude_nix() {
    local nix_hooks_dir="/etc/claude-code/hooks"
    local nix_settings="/etc/claude-code/nix-settings.json"
    if [ -d "$nix_hooks_dir" ] && [ -n "$(ls -A "$nix_hooks_dir" 2>/dev/null)" ]; then
        mkdir -p "$HOME/.claude/hooks"
        rsync -a --chmod=+x --chown="$HOST_USER" --delete \
            "$nix_hooks_dir/" "$HOME/.claude/hooks/"
        log "✓ Claude hooks synced from nix"
    fi
    if [ -f "$nix_settings" ]; then
        merge_claude_settings "$nix_settings" "$HOME/.claude/settings.json"
    fi
    # Sync nix-managed commands (any module can drop commands into $DEVCELL_HOME/.claude/commands/)
    if [ -d "$DEVCELL_HOME/.claude/commands" ] && [ -n "$(ls -A "$DEVCELL_HOME/.claude/commands" 2>/dev/null)" ]; then
        mkdir -p "$HOME/.claude/commands"
        rsync -a --chown="$HOST_USER" "$DEVCELL_HOME/.claude/commands/" "$HOME/.claude/commands/"
        log "✓ Claude commands synced from nix"
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

merge_claude_mcp() {
    local target_file="$1"
    local nix_file="/etc/claude-code/nix-mcp-servers.json"

    [ -f "$nix_file" ] || return 0

    if ! jq empty "$nix_file" 2>/dev/null; then
        echo "⚠ nix-mcp-servers.json is invalid JSON — skipping MCP merge"
        return 1
    fi

    local backup_before_merge
    backup_before_merge=$(jq -r '.backupBeforeMerge // true' "$nix_file")

    # Strip the enabled field from all servers (enabled/disabled state is
    # tracked via projects[].disabledMcpServers in .claude.json).
    local stripped_file
    stripped_file=$(mktemp)
    jq '.mcpServers = ((.mcpServers // {}) | to_entries |
        map({key: .key, value: (.value | del(.enabled))}) | from_entries)' \
        "$nix_file" > "$stripped_file" 2>/dev/null
    if ! [ -s "$stripped_file" ] || ! jq empty "$stripped_file" 2>/dev/null; then
        rm -f "$stripped_file"
        echo "⚠ Failed to prepare nix MCP servers — skipping merge"
        return 1
    fi

    mkdir -p "$(dirname "$target_file")"

    if [ ! -f "$target_file" ]; then
        log "Creating ~/.claude.json with nix MCP servers"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcpServers: (.mcpServers // {})}' "$stripped_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ ~/.claude.json created ($(jq '.mcpServers | length' "$target_file") server(s))"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to create ~/.claude.json from nix MCP servers"
            rm -f "$stripped_file"
            return 1
        fi
        rm -f "$stripped_file"
        return 0
    fi

    if ! jq empty "$target_file" 2>/dev/null; then
        local corrupt_bak="${target_file}.corrupt-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$corrupt_bak"
        log "⚠ ~/.claude.json was corrupt — saved to $(basename "$corrupt_bak"), recreating"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcpServers: (.mcpServers // {})}' "$stripped_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ ~/.claude.json recreated"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to recreate ~/.claude.json"
            rm -f "$stripped_file"
            return 1
        fi
        rm -f "$stripped_file"
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
      .[1].mcpServers as $nix |
      (($existing.mcpServers // {}) | to_entries |
        map(select(.value.command == null or (.value.command | startswith("/opt/devcell/") | not))) |
        from_entries) as $cleaned |
      ($nix // {} | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries) as $nixClean |
      $existing | .mcpServers = ($cleaned + $nixClean)
    ' "$target_file" "$stripped_file" > "$temp_file" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        log "✓ MCP servers merged into ~/.claude.json ($(jq '.mcpServers | length' "$target_file") total)"
    else
        rm -f "$temp_file"
        echo "⚠ Failed to merge MCP servers — keeping original"
        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            cp "$backup_file" "$target_file"
            echo "✓ Restored from backup"
        fi
        rm -f "$stripped_file"
        return 1
    fi
    rm -f "$stripped_file"
}

sync_claude_mcp_state() {
    local claude_json="$1"
    local nix_file="/etc/claude-code/nix-mcp-servers.json"
    local project_id="/${HOSTNAME#cell-}"

    [ -f "$nix_file" ] || return 0
    [ -f "$claude_json" ] || return 0
    jq empty "$claude_json" 2>/dev/null || return 0
    type disableMcp >/dev/null 2>&1 || return 1

    local enabled_json
    enabled_json=$(_mcp_enabled_json)

    if ! jq -e --arg pid "$project_id" '.projects[$pid]' "$claude_json" >/dev/null 2>&1; then
        local tmp; tmp=$(mktemp)
        jq --arg pid "$project_id" '.projects[$pid] = {}' "$claude_json" > "$tmp"
        if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
            mv "$tmp" "$claude_json"
        else
            rm -f "$tmp"
        fi
    fi

    local name disabled_count=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        disableMcp claude "$name" "$claude_json" "$project_id"
        disabled_count=$((disabled_count + 1))
    done < <(jq -r --argjson el "$enabled_json" '
        [(.mcpServers // {}) | to_entries[] |
         select(.value.enabled != true and ((.key as $k | $el | index($k)) == null)) |
         .key][]
    ' "$nix_file")

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        enableMcp claude "$name" "$claude_json" "$project_id"
    done < <(jq -r --argjson el "$enabled_json" '
        [(.mcpServers // {}) | to_entries[] |
         select(.value.enabled == true or ((.key as $k | $el | index($k)) != null)) |
         .key][]
    ' "$nix_file")

    log "✓ Claude MCP disabled state synced ($disabled_count disabled, project: $project_id)"
}

# Run nix hooks/settings merge
merge_claude_nix

# Merge nix MCP servers into user config + sync disabled state in projects
merge_claude_mcp "$HOME/.claude.json"
sync_claude_mcp_state "$HOME/.claude.json"

# Linear MCP: inject Bearer token auth when LINEAR_API_KEY is set,
# overriding the OAuth plugin entry. Falls back to plugin OAuth when unset.
if [ -n "${LINEAR_API_KEY:-}" ] && [ -f "$HOME/.claude.json" ]; then
    _tmp=$(mktemp)
    jq --arg key "$LINEAR_API_KEY" \
      '.mcpServers.linear = {type:"http", url:"https://mcp.linear.app/mcp", headers:{Authorization:("Bearer "+$key)}}' \
      "$HOME/.claude.json" > "$_tmp" 2>/dev/null \
      && mv "$_tmp" "$HOME/.claude.json" \
      && log "✓ Linear MCP: Bearer token auth (LINEAR_API_KEY set)" \
      || { rm -f "$_tmp"; log "⚠ Linear MCP: failed to inject Bearer token"; }
else
    log "Linear MCP: no LINEAR_API_KEY — using OAuth plugin"
fi

[ -f "$HOME/.claude.json" ] && chown "$HOST_USER" "$HOME/.claude.json"

notify claude.ready
