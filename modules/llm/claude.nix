# claude.nix — Claude Code hook scripts, settings, and MCP server staging.
# Merged from managed-claude.nix + Claude parts of managed-mcp.nix.
{
  pkgs,
  pkgsEdge,
  lib,
  config,
  ...
}: let
  cfg = config.devcell.managedClaude;
  mcpCfg = config.devcell.managedMcp;

  json = pkgs.formats.json {};

  settingsFile = json.generate "claude-nix-settings.json" cfg.settings;

  hookDerivations = lib.mapAttrs (
    name: content: pkgs.writeShellScript name content
  ) cfg.hookScripts;

  hasHooks = cfg.hookScripts != {};
  hasSettings = cfg.settings != {};

  # Claude MCP config derivation (from mcp.nix servers)
  toClaudeServer = _: s: let
    t = s.type or "stdio";
  in
    if t == "http" then {
      type = "http";
      url = s.url;
    }
    else {
      type = t;
      command = s.command;
      args = s.args or [];
      env = s.env or {};
    };

  # All registered servers (have command or url) — fragments filter at runtime
  # using DEVCELL_MCP_ENABLED env var from .devcell.toml [mcp] enabled=[...].
  allServers = lib.filterAttrs (_: s: (s ? command) || (s ? url)) mcpCfg.servers;

  claudeConfig = json.generate "claude-nix-mcp-servers.json" {
    backupBeforeMerge = mcpCfg.backupBeforeMerge;
    mcpServers = lib.mapAttrs (name: s:
      (toClaudeServer name s) // { enabled = s.enabled or false; }
    ) allServers;
  };

  hasServers = allServers != {};
in {
  options.devcell.managedClaude = {
    settings = lib.mkOption {
      type = lib.types.anything;
      default = {};
      description = ''
        Claude Code settings merged into ~/.claude/settings.json at container
        start. User's existing configuration is preserved; nix settings are
        merged in only where the user has no value (same semantics as MCP merge).
      '';
    };

    hookScripts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Shell scripts staged to /etc/claude-code/hooks/<name> at image build
        time and copied to ~/.claude/hooks/<name> by entrypoint.sh on start.
      '';
    };

    # Read-only — exposes the generated config derivation so the pure
    # (nix2container) image builder can stage it directly to /etc/claude-code/
    # at image-build time. Activation-script-based staging (line ~118 below)
    # doesn't run on pure images because home-manager activation is skipped.
    nixMcpConfigFile = lib.mkOption {
      type = lib.types.path;
      default = claudeConfig;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Claude MCP servers JSON (empty mcpServers when no servers enabled, so the entrypoint cleanup still removes stale /opt/devcell/ entries).";
    };
  };

  config = {
    home.packages = [
      pkgsEdge.claude-code # AI coding assistant CLI (edge for latest features)
    ];

    # ── Default Claude Code settings ───────────────────────────────────────
    devcell.managedClaude = {
      hookScripts."auto-approve-all.sh" = ''
        #!/bin/bash
        # Auto-approve all permission requests (unrestricted mode for background agents)
        echo '{"decision":"allow","applyPermissionRule":true}'
      '';
      settings = {
        model = "claude-opus-4-6";
        autoCompactWindow = 500000;
        hooks.PermissionRequest = [
          {
            matcher = "*";
            hooks = [
              {
                type = "command";
                command = "bash ~/.claude/hooks/auto-approve-all.sh";
              }
            ];
          }
        ];
      };
    };

    # Always generate the entrypoint fragment (self-guards at runtime)
    home.file.".config/devcell/entrypoint.d/30-claude.sh" = {
      executable = true;
      source = ../fragments/30-claude.sh;
    };

    # Stage hooks + settings + MCP servers when configured
    home.activation.setupManagedClaude = lib.mkIf (hasHooks || hasSettings || hasServers) (
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        # /run/wrappers/bin: where NixOS (and NixOS-WSL) put the sudo setuid
        # wrapper — it is never in /usr/bin there.
        export PATH="/usr/bin:/bin:/run/wrappers/bin:$PATH"
        # Staging /etc/claude-code is a convenience; a host without sudo must
        # skip it, not abort the whole activation (NixOS-WSL, run 20260804).
        if command -v sudo >/dev/null 2>&1; then
          $DRY_RUN_CMD sudo mkdir -p /etc/claude-code/hooks
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: drv: ''
            $DRY_RUN_CMD sudo cp ${drv} /etc/claude-code/hooks/${name}
            $DRY_RUN_CMD sudo chmod +x /etc/claude-code/hooks/${name}
          '') hookDerivations)}
          ${lib.optionalString hasSettings ''
            $DRY_RUN_CMD sudo cp ${settingsFile} /etc/claude-code/nix-settings.json
          ''}
          # Always stage the MCP servers file (even when empty) so the
          # entrypoint cleanup removes stale /opt/devcell/ servers on stack switch.
          $DRY_RUN_CMD sudo rm -f /etc/claude-code/managed-mcp.json
          $DRY_RUN_CMD sudo cp ${claudeConfig} /etc/claude-code/nix-mcp-servers.json
        else
          echo "setupManagedClaude: sudo not available — skipping /etc/claude-code staging"
        fi
        # Live-merge into ~/.claude.json so mid-session home-manager switch picks up
        # new MCP server paths without requiring container restart. Always runs
        # (even with zero enabled servers) to clean stale /opt/devcell/ entries.
        # Filters by DEVCELL_MCP_ENABLED env var + nix-side enabled defaults.
        _nix_file="/etc/claude-code/nix-mcp-servers.json"
        _mcp_enabled_json() {
          local _raw="''${DEVCELL_MCP_ENABLED:-}"
          if [ -z "$_raw" ]; then echo '[]'
          else echo "$_raw" | tr ',' '\n' | jq -R . | jq -s .
          fi
        }
        _merge_claude_mcp() {
          local _target="$1"
          local _stripped; _stripped=$(mktemp)
          jq '.mcpServers = ((.mcpServers // {}) | to_entries |
              map({key: .key, value: (.value | del(.enabled))}) | from_entries)' \
              "$_nix_file" > "$_stripped" 2>/dev/null
          if ! [ -s "$_stripped" ] || ! jq empty "$_stripped" 2>/dev/null; then
            rm -f "$_stripped"; return
          fi
          if [ -f "$_target" ] && jq empty "$_target" 2>/dev/null; then
            local _tmp; _tmp=$(mktemp)
            jq -s '
              .[0] as $existing |
              .[1].mcpServers as $nix |
              (($existing.mcpServers // {}) | to_entries |
                map(select(.value.command == null or (.value.command | startswith("/opt/devcell/") | not))) |
                from_entries) as $cleaned |
              ($nix // {} | to_entries | map({key: .key, value: (.value | del(.enabled))}) | from_entries) as $nixClean |
              $existing | .mcpServers = ($cleaned + $nixClean)
            ' "$_target" "$_stripped" > "$_tmp" 2>/dev/null
            if [ $? -eq 0 ] && [ -s "$_tmp" ] && jq empty "$_tmp" 2>/dev/null; then
              mv "$_tmp" "$_target"
              echo "setupManagedClaude: merged MCP servers into $_target"
            else
              rm -f "$_tmp"
            fi
          elif [ ! -f "$_target" ]; then
            jq '{mcpServers: (.mcpServers // {})}' "$_stripped" > "$_target" 2>/dev/null
            echo "setupManagedClaude: created $_target with MCP servers"
          fi
          rm -f "$_stripped"
        }
        _sync_claude_mcp_state() {
          local _claude_json="$1"
          local _project_id="/''${HOSTNAME#cell-}"
          [ -f "$_claude_json" ] || return 0
          jq empty "$_claude_json" 2>/dev/null || return 0
          local _toggle="/etc/devcell/entrypoint.d/29-mcp-toggle.sh"
          if [ -f "$_toggle" ]; then
            . "$_toggle"
          elif [ -f "$HOME/.config/devcell/entrypoint.d/29-mcp-toggle.sh" ]; then
            . "$HOME/.config/devcell/entrypoint.d/29-mcp-toggle.sh"
          else
            return 0
          fi
          if ! jq -e --arg pid "$_project_id" '.projects[$pid]' "$_claude_json" >/dev/null 2>&1; then
            local _tmp; _tmp=$(mktemp)
            jq --arg pid "$_project_id" '.projects[$pid] = {}' "$_claude_json" > "$_tmp"
            if [ -s "$_tmp" ] && jq empty "$_tmp" 2>/dev/null; then
              mv "$_tmp" "$_claude_json"
            else
              rm -f "$_tmp"
            fi
          fi
          local _enabled_json; _enabled_json=$(_mcp_enabled_json)
          local _name
          while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            disableMcp claude "$_name" "$_claude_json" "$_project_id"
          done < <(jq -r --argjson el "$_enabled_json" '
            [(.mcpServers // {}) | to_entries[] |
             select(.value.enabled != true and ((.key as $k | $el | index($k)) == null)) |
             .key][]
          ' "$_nix_file")
          while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            enableMcp claude "$_name" "$_claude_json" "$_project_id"
          done < <(jq -r --argjson el "$_enabled_json" '
            [(.mcpServers // {}) | to_entries[] |
             select(.value.enabled == true or ((.key as $k | $el | index($k)) != null)) |
             .key][]
          ' "$_nix_file")
        }
        if [ -f "$_nix_file" ] && command -v jq &>/dev/null; then
          _merge_claude_mcp "$HOME/.claude.json"
          _sync_claude_mcp_state "$HOME/.claude.json"
          for _user_home in /home/*; do
            [ -d "$_user_home/.claude" ] && [ "$_user_home" != "$HOME" ] && \
              _merge_claude_mcp "$_user_home/.claude.json" && \
              _sync_claude_mcp_state "$_user_home/.claude.json"
          done
        fi
      ''
    );
  };
}
