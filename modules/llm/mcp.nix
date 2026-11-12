# mcp.nix — shared MCP server option definition.
# Individual tool modules (claude.nix, opencode.nix, codex.nix, gemini.nix) each
# build their own config derivation from config.devcell.managedMcp.servers,
# retaining definitions and applying opt-in enablement at startup.
{
  lib,
  config,
  ...
}: let
  cfg = config.devcell.managedMcp;

  # A server is "phantom" if something set enabled=true on a name that no
  # module actually registered with real connection info (command or url) —
  # the tell-tale sign of a typo in a per-repo .devcell.toml [mcp]
  # enabled=[...] override (attrsOf anything merges partial definitions
  # across files silently, so a typo'd name creates a new empty entry
  # instead of erroring at the TOML layer).
  isPhantom = _: s: (s.enabled or false) && !(s ? command) && !(s ? url);
  phantomNames = builtins.attrNames (lib.filterAttrs isPhantom cfg.servers);
  knownNames = builtins.attrNames (lib.filterAttrs (_: s: (s ? command) || (s ? url)) cfg.servers);
in {
  options.devcell.managedMcp = {
    nixBinPrefix = lib.mkOption {
      type = lib.types.str;
      default = "/opt/devcell/.local/state/nix/profiles/profile/bin";
      readOnly = true;
      description = "Stable path to nix-managed binaries. Used as command prefix for MCP servers and as discriminator during config merge (servers with this prefix are cleaned on stack switch).";
    };
    servers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        Canonical MCP server definitions. Each entry:
          { command, args?, env? }            # stdio (default)
          { type = "http"; url; }             # http (Claude and Codex)
          { ...; enabled = true; }            # opt in: enable at startup

        Registered servers are staged into client configs even when disabled.
        `enabled` defaults to false; set it on the entry or select the name
        through .devcell.toml's [mcp] enabled=[...] list. The latter is passed
        as DEVCELL_MCP_ENABLED and applied by the startup services.
      '';
    };
    backupBeforeMerge = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether s6 config services should back up user config files before merging nix MCP servers (Claude, OpenCode, Codex).";
    };
  };

  config.assertions = [
    {
      assertion = phantomNames == [];
      message = ''
        devcell.managedMcp.servers: enabled=true set on unknown server name(s): ${toString phantomNames}.
        These have neither `command` (stdio) nor `url` (http) — likely a typo in a
        nix module's managedMcp.servers definition. Note: .devcell.toml [mcp] enabled=[...]
        is resolved at container start via DEVCELL_MCP_ENABLED, not at nix build time.
        Known registered server names: ${toString knownNames}
      '';
    }
  ];
}
