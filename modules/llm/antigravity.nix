# antigravity.nix — Antigravity CLI (Google's successor to gemini-cli).
# MCP server staging and entrypoint merge logic, mirroring gemini.nix.
# Config lives in ~/.gemini/config/mcp_config.json (same ~/.gemini/ tree,
# different sub-path and field polarity: `disabled` instead of `enabled`).
{
  pkgs,
  pkgsEdge,
  lib,
  config,
  ...
}: let
  mcpCfg = config.devcell.managedMcp;

  json = pkgs.formats.json {};

  allStdioServers = lib.filterAttrs (
    _: s: ((s.type or "stdio") == "stdio") && ((s ? command) || (s ? url))
  ) mcpCfg.servers;

  toAntigravityServer = _: s:
    {
      command = s.command;
      args = s.args or [];
      disabled = !(s.enabled or false);
    }
    // lib.optionalAttrs ((s.env or {}) != {}) {env = s.env;};

  antigravityConfig = json.generate "antigravity-nix-mcp-servers.json" {
    backupBeforeMerge = mcpCfg.backupBeforeMerge;
    mcpServers = lib.mapAttrs toAntigravityServer allStdioServers;
  };
in {
  options.devcell.managedAntigravity = {
    nixMcpConfigFile = lib.mkOption {
      type = lib.types.path;
      default = antigravityConfig;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Antigravity MCP servers JSON.";
    };
  };

  config = {
    home.packages = [pkgsEdge.antigravity-cli];

    home.activation.setupManagedAntigravity =
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        export PATH="/usr/bin:/bin:/run/wrappers/bin:$PATH"
        if command -v sudo >/dev/null 2>&1; then
          $DRY_RUN_CMD sudo mkdir -p /etc/antigravity
          $DRY_RUN_CMD sudo cp ${antigravityConfig} /etc/antigravity/nix-mcp-servers.json
        else
          echo "setupManagedAntigravity: sudo not available — skipping staging"
        fi
      '';
  };
}
