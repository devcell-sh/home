# gemini.nix — Gemini CLI MCP server staging and entrypoint merge logic.
# Mirrors codex.nix; emits Claude-shape JSON instead of TOML because Gemini's
# ~/.gemini/settings.json holds `mcpServers` at top level (same shape as
# Claude's ~/.claude.json).
{
  pkgs,
  pkgsEdge,
  lib,
  config,
  ...
}: let
  mcpCfg = config.devcell.managedMcp;

  json = pkgs.formats.json {};

  # All stdio servers — Gemini stdio MCP support is the established path.
  # Fragments filter at runtime using DEVCELL_MCP_ENABLED env var.
  allStdioServers = lib.filterAttrs (
    _: s: ((s.type or "stdio") == "stdio") && ((s ? command) || (s ? url))
  ) mcpCfg.servers;

  toGeminiServer = _: s:
    {
      command = s.command;
      args = s.args or [];
      enabled = s.enabled or false;
    }
    // lib.optionalAttrs ((s.env or {}) != {}) {env = s.env;};

  geminiConfig = json.generate "gemini-nix-mcp-servers.json" {
    backupBeforeMerge = mcpCfg.backupBeforeMerge;
    mcpServers = lib.mapAttrs toGeminiServer allStdioServers;
  };

  hasServers = allStdioServers != {};
in {
  options.devcell.managedGemini = {
    # Read-only — exposes the generated config derivation so the pure
    # (nix2container) image builder can stage it directly to /etc/gemini/ at
    # image-build time. Activation-script-based staging (line ~50 below)
    # doesn't run on pure images because home-manager activation is skipped.
    nixMcpConfigFile = lib.mkOption {
      type = lib.types.path;
      default = geminiConfig;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Gemini MCP servers JSON (empty mcpServers when no servers enabled, so the entrypoint cleanup still removes stale /opt/devcell/ entries).";
    };
  };

  config = {
    home.packages = [pkgsEdge.gemini-cli];

    # Always generate the Gemini merge fragment (self-guards at runtime)
    home.file.".config/devcell/entrypoint.d/30-gemini.sh" = {
      executable = true;
      source = ../fragments/30-gemini.sh;
    };

    # Always stage the MCP servers file (even when empty) so the
    # entrypoint cleanup removes stale /opt/devcell/ servers on stack switch.
    home.activation.setupManagedGemini =
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        # /run/wrappers/bin: NixOS keeps the sudo setuid wrapper there only.
        export PATH="/usr/bin:/bin:/run/wrappers/bin:$PATH"
        if command -v sudo >/dev/null 2>&1; then
          $DRY_RUN_CMD sudo mkdir -p /etc/gemini
          $DRY_RUN_CMD sudo cp ${geminiConfig} /etc/gemini/nix-mcp-servers.json
        else
          echo "setupManagedGemini: sudo not available — skipping /etc/gemini staging"
        fi
      '';
  };
}
