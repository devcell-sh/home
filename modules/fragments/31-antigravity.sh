#!/bin/bash
# 31-antigravity.sh — Antigravity CLI MCP server merge logic
# Sourced by entrypoint.sh; has access to $HOME, $HOST_USER, log()
#
# Antigravity (agy) stores MCP config in ~/.gemini/config/mcp_config.json
# with `disabled` field (inverted from gemini-cli's `enabled`).

notify antigravity.starting

_mcp_enabled_json() {
    local raw="${DEVCELL_MCP_ENABLED:-}"
    if [ -z "$raw" ]; then
        echo '[]'
    else
        echo "$raw" | tr ',' '\n' | jq -R . | jq -s .
    fi
}

merge_antigravity_mcp() {
    local target_file="$1"
    local nix_file="/etc/antigravity/nix-mcp-servers.json"

    [ -f "$nix_file" ] || return 0

    if ! jq empty "$nix_file" 2>/dev/null; then
        echo "⚠ nix-mcp-servers.json (Antigravity) is invalid JSON — skipping MCP merge"
        return 1
    fi

    local backup_before_merge
    backup_before_merge=$(jq -r '.backupBeforeMerge // true' "$nix_file")
    local enabled_json
    enabled_json=$(_mcp_enabled_json)

    # Filter nix servers: keep disabled=false OR named in DEVCELL_MCP_ENABLED, strip disabled field
    local filtered_file
    filtered_file=$(mktemp)
    jq --argjson enabled_list "$enabled_json" '
      .mcpServers = (
        (.mcpServers // {}) | to_entries |
        map(select(.value.disabled == false or (.key as $k | $enabled_list | index($k)) != null)) |
        map({key: .key, value: (.value | del(.disabled))}) |
        from_entries
      )
    ' "$nix_file" > "$filtered_file" 2>/dev/null
    if ! [ -s "$filtered_file" ] || ! jq empty "$filtered_file" 2>/dev/null; then
        rm -f "$filtered_file"
        echo "⚠ Failed to filter nix MCP servers (Antigravity) — skipping merge"
        return 1
    fi

    mkdir -p "$(dirname "$target_file")"

    # Fresh start — no existing config.
    if [ ! -f "$target_file" ]; then
        log "Creating mcp_config.json with nix MCP servers"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcpServers: (.mcpServers // {})}' "$filtered_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ mcp_config.json created ($(jq '.mcpServers | length' "$target_file") server(s))"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to create mcp_config.json from nix MCP servers"
            rm -f "$filtered_file"
            return 1
        fi
        rm -f "$filtered_file"
        return 0
    fi

    # Existing file is corrupt — back it up and recreate.
    if ! jq empty "$target_file" 2>/dev/null; then
        local corrupt_bak="${target_file}.corrupt-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$corrupt_bak"
        log "⚠ mcp_config.json was corrupt — saved to $(basename "$corrupt_bak"), recreating"
        local temp_file
        temp_file=$(mktemp)
        jq '{mcpServers: (.mcpServers // {})}' "$filtered_file" > "$temp_file"
        if [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$target_file"
            log "✓ mcp_config.json recreated"
        else
            rm -f "$temp_file"
            echo "⚠ Failed to recreate mcp_config.json"
            rm -f "$filtered_file"
            return 1
        fi
        rm -f "$filtered_file"
        return 0
    fi

    # Optional pre-merge backup.
    local backup_file=""
    if [ "$backup_before_merge" = "true" ]; then
        backup_file="${target_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$target_file" "$backup_file"
        log "✓ Created backup: $(basename "$backup_file")"
        ls -t "${target_file}.backup-"* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi

    # Merge: remove stale nix-managed servers, then add filtered servers.
    local temp_file
    temp_file=$(mktemp)
    jq -s '
      .[0] as $existing |
      .[1].mcpServers as $nix |
      (($existing.mcpServers // {}) | to_entries |
        map(select(.value.command == null or (.value.command | startswith("/opt/devcell/") | not))) |
        from_entries) as $cleaned |
      $existing | .mcpServers = ($cleaned + ($nix // {}))
    ' "$target_file" "$filtered_file" > "$temp_file" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$temp_file" ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$target_file"
        log "✓ MCP servers merged into mcp_config.json ($(jq '.mcpServers | length' "$target_file") total)"
    else
        rm -f "$temp_file"
        echo "⚠ Failed to merge MCP servers into mcp_config.json — keeping original"
        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            cp "$backup_file" "$target_file"
            echo "✓ Restored from backup"
        fi
        rm -f "$filtered_file"
        return 1
    fi
    rm -f "$filtered_file"
}

merge_antigravity_mcp "$HOME/.gemini/config/mcp_config.json"
[ -d "$HOME/.gemini/config" ] && chown -R "$HOST_USER" "$HOME/.gemini/config"

notify antigravity.ready
