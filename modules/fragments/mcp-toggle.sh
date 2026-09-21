#!/bin/bash
# mcp-toggle.sh — enable/disable MCP servers across claude, codex, opencode.
# Source this file; it provides disableMcp() and enableMcp().
#
#   disableMcp <tool> <serverName> <configFile> [projectId]
#   enableMcp  <tool> <serverName> <configFile> [projectId]
#
# tool: claude | codex | opencode
# projectId: required for claude (container working directory path)

disableMcp() {
    local tool="$1" name="$2" config="$3"
    case "$tool" in
        claude)  _claude_mcp_set "$config" "$4" "$name" disable ;;
        codex)   _codex_mcp_set "$config" "$name" disable ;;
        opencode) _opencode_mcp_set "$config" "$name" disable ;;
        *) echo "disableMcp: unknown tool: $tool" >&2; return 1 ;;
    esac
}

enableMcp() {
    local tool="$1" name="$2" config="$3"
    case "$tool" in
        claude)  _claude_mcp_set "$config" "$4" "$name" enable ;;
        codex)   _codex_mcp_set "$config" "$name" enable ;;
        opencode) _opencode_mcp_set "$config" "$name" enable ;;
        *) echo "enableMcp: unknown tool: $tool" >&2; return 1 ;;
    esac
}

_claude_mcp_set() {
    local config="$1" project_id="$2" name="$3" action="$4"
    [ -f "$config" ] || return 1
    local tmp
    tmp=$(mktemp)
    if [ "$action" = "disable" ]; then
        jq --arg pid "$project_id" --arg name "$name" '
            .projects[$pid].disabledMcpServers =
                ((.projects[$pid].disabledMcpServers // []) + [$name] | unique)
        ' "$config" > "$tmp"
    else
        jq --arg pid "$project_id" --arg name "$name" '
            .projects[$pid].disabledMcpServers =
                [(.projects[$pid].disabledMcpServers // [])[] | select(. != $name)]
        ' "$config" > "$tmp"
    fi
    if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$config"
    else
        rm -f "$tmp"
        return 1
    fi
}

_codex_mcp_set() {
    local config="$1" name="$2" action="$3"
    [ -f "$config" ] || return 1
    python3 - "$config" "$name" "$action" <<'PYEOF'
import sys, re

config_path, server_name, action = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_path) as f:
    content = f.read()

header = f"[mcp_servers.{server_name}]"
if header not in content:
    sys.exit(0)

lines = content.split("\n")
result = []
in_target = False
enabled_written = False

for line in lines:
    stripped = line.strip()
    if stripped == header:
        in_target = True
        result.append(line)
        continue
    if in_target and stripped.startswith("[") and stripped != header:
        if action == "disable" and not enabled_written:
            result.append("enabled = false")
        in_target = False
    if in_target and stripped.startswith("enabled"):
        if action == "disable":
            result.append("enabled = false")
            enabled_written = True
        # enable: drop the enabled line entirely
        continue
    result.append(line)

if in_target and action == "disable" and not enabled_written:
    result.append("enabled = false")

with open(config_path, "w") as f:
    f.write("\n".join(result))
PYEOF
}

_opencode_mcp_set() {
    local config="$1" name="$2" action="$3"
    [ -f "$config" ] || return 1
    local tmp
    tmp=$(mktemp)
    if [ "$action" = "disable" ]; then
        jq --arg name "$name" '.mcp[$name].enabled = false' "$config" > "$tmp"
    else
        jq --arg name "$name" '.mcp[$name].enabled = true' "$config" > "$tmp"
    fi
    if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$config"
    else
        rm -f "$tmp"
        return 1
    fi
}
