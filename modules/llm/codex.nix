# codex.nix — Codex CLI from npm + MCP server staging and entrypoint merge logic.
{
  pkgs,
  pkgsEdge,
  lib,
  config,
  ...
}:
let
  mcpCfg = config.devcell.managedMcp;

  toml = pkgs.formats.toml { };

  # ── Codex CLI from npm ──────────────────────────────────────────────
  # Fetches the platform-specific prebuilt binary directly from the npm
  # registry. The npm package ships a Node.js shim that spawns a static
  # musl-linked Rust binary — we skip the shim and install the binary.
  codexVersion = "0.144.4";
  codexPlatforms = {
    "aarch64-linux" = {
      triple = "aarch64-unknown-linux-musl";
      url = "https://registry.npmjs.org/@openai/codex/-/codex-${codexVersion}-linux-arm64.tgz";
      hash = "sha256-OEYcdpzpXnNKQgC7Xnqsi76KgFJgPWSOrkr6omrAZqc=";
    };
    "x86_64-linux" = {
      triple = "x86_64-unknown-linux-musl";
      url = "https://registry.npmjs.org/@openai/codex/-/codex-${codexVersion}-linux-x64.tgz";
      hash = "sha256-mkpFMU6AtTxHYbgAZ+OmjCMC+akCYFm19U8i3sjzQyM=";
    };
  };
  codexPlatform = codexPlatforms.${pkgs.stdenv.hostPlatform.system} or null;

  codex = if codexPlatform != null then pkgs.stdenv.mkDerivation {
    pname = "codex";
    version = codexVersion;
    src = pkgs.fetchurl {
      url = codexPlatform.url;
      hash = codexPlatform.hash;
    };
    sourceRoot = ".";
    unpackPhase = ''
      tar xzf $src
    '';
    installPhase = ''
      local vendor="package/vendor/${codexPlatform.triple}"
      mkdir -p $out/bin $out/lib/codex
      cp $vendor/bin/codex          $out/bin/codex
      cp $vendor/bin/codex-code-mode-host $out/bin/codex-code-mode-host
      cp -r $vendor/codex-path      $out/lib/codex/codex-path
      cp -r $vendor/codex-resources $out/lib/codex/codex-resources
    '';
    dontFixup = true;
  } else null;

  # All stdio servers — Codex doesn't support HTTP transport.
  # Fragments filter at runtime using DEVCELL_MCP_ENABLED env var.
  allStdioServers = lib.filterAttrs (
    _: s: ((s.type or "stdio") == "stdio") && ((s ? command) || (s ? url))
  ) mcpCfg.servers;

  toCodexServer =
    _: s:
    ({
      command = s.command;
      args = s.args or [ ];
      enabled = s.enabled or false;
    }
    // lib.optionalAttrs ((s.env or { }) != { }) { env = s.env; });

  codexConfig = toml.generate "codex-nix-mcp-servers.toml" {
    backupBeforeMerge = mcpCfg.backupBeforeMerge;
    devcellManagedServers = builtins.attrNames mcpCfg.servers;
    mcp_servers = lib.mapAttrs toCodexServer allStdioServers;
  };

  hasServers = allStdioServers != { };

  # ── model_providers: OpenAI-compatible endpoints, merged into
  # ~/.codex/config.toml as [model_providers.<id>]. Each entry:
  #   { name, base_url, env_key, wire_api? }
  # wire_api defaults to "responses" if omitted. Codex removed "chat" support
  # in Feb 2026 — providers that only speak Chat Completions need a
  # translating proxy (e.g. LiteLLM) in front, or requests to /v1/responses
  # will 404 against them directly.
  cfgProviders = config.devcell.managedCodex.providers;
  hasProviders = cfgProviders != { };

  codexProvidersConfig = toml.generate "codex-nix-providers.toml" {
    devcellManagedProviders = builtins.attrNames cfgProviders;
    model_providers = cfgProviders;
  };

  # ── profiles: named model + model_provider (+ other overrides) bundles.
  # Confirmed against the pinned binary: this Codex version does NOT support
  # [profiles.<name>] tables in config.toml — it rejects them as "legacy" and
  # refuses to start with --profile <name> while any such table exists. The
  # supported mechanism is one flat file per profile at
  # $CODEX_HOME/<name>.config.toml (top-level keys, no [profiles.*] wrapper).
  # Activate with `codex --profile <name>`.
  cfgProfiles = config.devcell.managedCodex.profiles;
  hasProfiles = cfgProfiles != { };

  # One <name>.config.toml per profile, plus a manifest listing nix-managed
  # names (read by 30-codex.sh to stage/overwrite current profiles and clean
  # up ones no longer declared).
  codexProfilesDir = pkgs.runCommand "codex-nix-profiles" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (lib.mapAttrsToList (name: attrs: ''
      cp ${toml.generate "codex-profile-${name}.toml" attrs} $out/${lib.escapeShellArg name}.config.toml
    '') cfgProfiles)
    + ''
      printf '%s\n' ${lib.concatMapStringsSep " " lib.escapeShellArg (builtins.attrNames cfgProfiles)} > $out/.devcell-managed-profiles
    ''
  );
in
{
  options.devcell.managedCodex = {
    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        model_providers entries merged into ~/.codex/config.toml as
        [model_providers.<id>]. Each entry: { name, base_url, env_key, wire_api? }.
        env_key names an environment variable Codex reads at request time — it is
        never a secret value itself; supply the value via .devcell.toml [env] or
        [op] the same way other MCP server secrets are forwarded.
      '';
    };
    nixMcpConfigFile = lib.mkOption {
      type = lib.types.path;
      default = codexConfig;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Codex MCP servers TOML (empty mcp_servers when no servers enabled, so the entrypoint cleanup still removes stale /opt/devcell/ entries).";
    };
    nixProvidersConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if hasProviders then codexProvidersConfig else null;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Codex model_providers TOML (null when no providers declared).";
    };
    profiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        profiles staged as individual $CODEX_HOME/<name>.config.toml files
        (this Codex version rejects [profiles.<name>] tables in config.toml
        as legacy). Each entry's attrs become that file's flat top-level keys
        — e.g. { model, model_provider, model_reasoning_effort }. Activate
        with `codex --profile <name>`. Profile names must not contain dots —
        `codex --profile` rejects them at the CLI arg-parsing stage.
      '';
    };
    nixProfilesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if hasProfiles then codexProfilesDir else null;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated Codex per-profile files directory (null when no profiles declared).";
    };
  };

  config = {
    home.packages = lib.optional (codex != null) codex;

    # ── Default model_providers ─────────────────────────────────────────
    # Hetzner Inference API (https://inference.hetzner.com) — free/experimental
    # OpenAI-compatible endpoint, EU-hosted (Germany/Finland). Docs confirm it
    # only ever exposes /v1/models, /v1/completions, /v1/chat/completions — no
    # Responses API. wire_api = "chat" is the technically-correct value for
    # that surface, but Codex removed "chat" support entirely in Feb 2026 —
    # confirmed directly against the pinned binary: an invalid wire_api value
    # anywhere in config.toml fails to load the ENTIRE file (not just this
    # provider), breaking every codex invocation, profile or not. So this
    # MUST stay "responses" even though it means Hetzner itself 404s until a
    # Chat Completions -> Responses translating proxy (e.g. LiteLLM) sits in
    # front — that's a narrower, contained failure (only this provider is
    # unusable) versus a config.toml-wide outage.
    devcell.managedCodex.providers.hetzner = {
      name = "Hetzner Inference";
      base_url = "https://inference.hetzner.com/api/v1";
      env_key = "HETZNER_VLLM_API_KEY";
      wire_api = "responses";
    };

    # ── Default profiles ──────────────────────────────────────────────
    # Both route through the hetzner provider above — inert until either
    # Hetzner ships a Responses API or a translating proxy sits in front
    # (see the wire_api note on the provider block).
    #
    # Profile names must not contain dots — confirmed against the pinned
    # binary: `codex --profile` rejects any value with a `.` at the CLI
    # arg-parsing stage ("invalid --profile value ...; pass a plain name"),
    # before config.toml is even read. Hyphens substitute for the version
    # dots (3.8 -> 3-8, 3.6 -> 3-6).
    devcell.managedCodex.profiles."hetzner-qwen-3-8-27b" = {
      model_provider = "hetzner";
      model = "Qwen3.8-27B";
    };
    devcell.managedCodex.profiles."qwehn-3-6-46b" = {
      model_provider = "hetzner";
      model = "Qwen/Qwen3.6-35B-A3B-FP8";
    };

    # Always generate the Codex merge fragment (self-guards at runtime)
    home.file.".config/devcell/entrypoint.d/30-codex.sh" = {
      executable = true;
      source = ../fragments/30-codex.sh;
    };

    # Stage Codex MCP + provider + profile config when any is defined
    home.activation.setupManagedCodex = lib.mkIf (hasServers || hasProviders || hasProfiles) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # /run/wrappers/bin: NixOS keeps the sudo setuid wrapper there only.
        export PATH="/usr/bin:/bin:/run/wrappers/bin:$PATH"
        if command -v sudo >/dev/null 2>&1; then
          $DRY_RUN_CMD sudo mkdir -p /etc/codex
          $DRY_RUN_CMD sudo rm -f /etc/codex/managed_config.toml
          # Always stage the MCP servers file (even when empty) so the
          # entrypoint cleanup removes stale /opt/devcell/ servers on stack switch.
          $DRY_RUN_CMD sudo cp ${codexConfig} /etc/codex/nix-mcp-servers.toml
          ${lib.optionalString hasProviders ''
            $DRY_RUN_CMD sudo cp ${codexProvidersConfig} /etc/codex/nix-providers.toml
          ''}
          ${lib.optionalString hasProfiles ''
            $DRY_RUN_CMD sudo rm -rf /etc/codex/nix-codex-profiles
            $DRY_RUN_CMD sudo cp -r ${codexProfilesDir} /etc/codex/nix-codex-profiles
          ''}
        else
          echo "setupManagedCodex: sudo not available — skipping /etc/codex staging"
        fi
      ''
    );
  };
}
