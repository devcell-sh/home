# mcp.nix — shared MCP server option definition.
# Individual tool modules (claude.nix, opencode.nix, codex.nix, gemini.nix) each
# build their own config derivation from config.devcell.managedMcp.servers,
# filtering to `enabled or false` (opt-in — see `servers` option doc below).
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
          { type = "http"; url; }             # http (Claude only)
          { ...; enabled = true; }            # opt in: stage into Claude/OpenCode/Codex/Gemini

        `enabled` defaults to false — a registered server is installed
        (home.packages) but NOT injected into any agent config unless
        `enabled = true` is set, either directly on the entry or via a
        per-repo override merged in from .devcell.toml's [mcp]
        enabled=[...] list (see the `devcell` CLI's GenerateFlakeNix, which
        emits `devcell.managedMcp.servers."<name>".enabled = true;` lines —
        these deep-merge with the module's own partial definition of the
        same name via the standard attrsOf-anything module merge).
      '';
    };
    backupBeforeMerge = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether entrypoint.sh should back up user config files before merging nix MCP servers (Claude, OpenCode, Codex).";
    };
  };

  config.home.file.".config/devcell/entrypoint.d/29-mcp-toggle.sh" = {
    executable = true;
    source = ../fragments/mcp-toggle.sh;
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
