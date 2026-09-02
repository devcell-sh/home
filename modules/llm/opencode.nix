# opencode.nix — OpenCode provider configs and MCP server staging.
# Merged from managed-opencode.nix + OpenCode parts of managed-mcp.nix.
{
  pkgs,
  pkgsEdge,
  lib,
  config,
  ...
}: let
  cfg = config.devcell.managedOpencode;
  mcpCfg = config.devcell.managedMcp;

  json = pkgs.formats.json {};

  providersFile = json.generate "opencode-nix-providers.json" (
    { provider = cfg.providers; }
    // lib.optionalAttrs (cfg.defaultModel != null) { model = cfg.defaultModel; }
    // lib.optionalAttrs (cfg.plugins != []) { plugin = cfg.plugins; }
  );

  hasProviders = cfg.providers != {};

  # All stdio servers — OpenCode doesn't support HTTP transport.
  # Fragments filter at runtime using DEVCELL_MCP_ENABLED env var.
  allStdioServers = lib.filterAttrs (
    _: s: ((s.type or "stdio") == "stdio") && ((s ? command) || (s ? url))
  ) mcpCfg.servers;

  toOpenCodeServer = _: s:
    {
      type = "local";
      command = [s.command] ++ (s.args or []);
      enabled = s.enabled or false;
    }
    // lib.optionalAttrs ((s.env or {}) != {}) {environment = s.env;};

  openCodeConfig = json.generate "opencode-nix-mcp-servers.json" {
    backupBeforeMerge = mcpCfg.backupBeforeMerge;
    mcp = lib.mapAttrs toOpenCodeServer allStdioServers;
  };

  hasServers = allStdioServers != {};
in {
  options.devcell.managedOpencode = {
    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        OpenCode provider configs merged into ~/opencode.json at container start.
        Each key is a provider ID; the value is the provider config object.
        Providers are only injected if the key is not already present in the
        user's existing ~/opencode.json.
      '';
    };
    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Default model in "provider/model-id" form, merged into ~/opencode.json
        as the top-level "model" key (selects it on startup instead of
        requiring /models each session). Only set if the user's existing
        config doesn't already have a "model" key — never overrides a
        hand-picked default.
      '';
    };
    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        npm package names merged into ~/opencode.json's top-level "plugin"
        array. Nix-declared entries are appended if not already present
        (by package name, ignoring any @version suffix) — existing
        user-added plugins are never removed.
      '';
    };

    # Read-only — expose the generated config derivations so the pure
    # (nix2container) image builder can stage them directly to /etc/opencode/
    # at image-build time. Activation-script-based staging (line ~85 below)
    # doesn't run on pure images because home-manager activation is skipped.
    nixMcpConfigFile = lib.mkOption {
      type = lib.types.path;
      default = openCodeConfig;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated OpenCode MCP servers JSON (empty mcp when no servers enabled, so the entrypoint cleanup still removes stale /opt/devcell/ entries).";
    };
    nixProvidersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if hasProviders then providersFile else null;
      internal = true;
      readOnly = true;
      description = "Nix-store path of the generated OpenCode providers JSON (null when no providers declared).";
    };
  };

  config = {
    home.packages = with pkgs; [
      pkgsEdge.opencode # AI coding agent for terminal (edge for latest)
    ];

    # ── Default OpenCode provider config ─────────────────────────────────
    devcell.managedOpencode.providers = {
      lmstudio = {
        npm = "@ai-sdk/openai-compatible";
        name = "LM Studio (local)";
        options.baseURL = "http://127.0.0.1:1234/v1";
        models = {
          "google/gemma-3n-e4b".name = "Gemma 3n-e4b (local)";
          "zai-org_glm-4.7-flash".name = "GLM-4.7 (local)";
        };
      };

      # Hetzner Inference API (https://inference.hetzner.com) — free/experimental,
      # EU-hosted, OpenAI-compatible Chat Completions endpoint. Unlike Codex
      # (which now requires the Responses API — see modules/llm/codex.nix),
      # @ai-sdk/openai-compatible speaks Chat Completions natively, so this
      # works directly with no translating proxy. Requires HETZNER_VLLM_API_KEY
      # in the environment (same [env]/[op] path as other MCP/provider secrets;
      # name matches Hetzner's own community tutorial convention).
      # Select with `opencode --model hetzner/<model-id>` or `/models`.
      hetzner = {
        npm = "@ai-sdk/openai-compatible";
        name = "Hetzner Inference";
        options.baseURL = "https://inference.hetzner.com/api/v1";
        options.apiKey = "{env:HETZNER_VLLM_API_KEY}";
        models = {
          "Qwen3.8-27B".name = "Qwen3.8-27B (Hetzner)";
          "Qwen/Qwen3.6-35B-A3B-FP8".name = "Qwen3.6-35B-A3B FP8 (Hetzner)";
        };
      };
    };

    devcell.managedOpencode.defaultModel = "hetzner/Qwen3.8-27B";

    # Live throughput (TPS/TTFT) + per-model cost tracking in the TUI. No
    # native TPS display exists in opencode itself as of this version —
    # https://github.com/anomalyco/opencode/issues/6096.
    #
    # NOTE: "opencode-tps-meter" (ChiR24, npm v0.3.1) was tried first — it
    # matched the described feature set best, but its published package is
    # broken: install fails with "ENOENT .../node_modules/opencode-tps-meter/
    # package.json" (confirmed live via `opencode plug opencode-tps-meter@latest`
    # in a running container — fetch succeeds, manifest read fails). Verified
    # opencode-throughput installs cleanly instead (same live test, no errors).
    devcell.managedOpencode.plugins = [ "opencode-throughput" ];

    # Always generate the fragment (self-guards at runtime)
    home.file.".config/devcell/entrypoint.d/30-opencode.sh" = {
      executable = true;
      source = ../fragments/30-opencode.sh;
    };

    # Stage providers + MCP servers when configured
    home.activation.setupManagedOpencode = lib.mkIf (hasProviders || hasServers) (
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        # /run/wrappers/bin: NixOS keeps the sudo setuid wrapper there only.
        export PATH="/usr/bin:/bin:/run/wrappers/bin:$PATH"
        if command -v sudo >/dev/null 2>&1; then
          $DRY_RUN_CMD sudo mkdir -p /etc/opencode
          ${lib.optionalString hasProviders ''
            $DRY_RUN_CMD sudo cp ${providersFile} /etc/opencode/nix-providers.json
          ''}
          # Always stage the MCP servers file (even when empty) so the
          # entrypoint cleanup removes stale /opt/devcell/ servers on stack switch.
          $DRY_RUN_CMD sudo cp ${openCodeConfig} /etc/opencode/nix-mcp-servers.json
        else
          echo "setupManagedOpencode: sudo not available — skipping /etc/opencode staging"
        fi
      ''
    );
  };
}
