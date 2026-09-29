# project-management.nix — Project management, time-tracking, and workflow-automation MCP servers
{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.devcell.modules.project-management;
  bin = config.devcell.managedMcp.nixBinPrefix;
  # hubstaff-mcp: Python MCP server for Hubstaff time tracking and project management.
  # https://github.com/cdmx-in/hubstaff-mcp
  # All deps (mcp, httpx, pydantic, python-dotenv) are in nixpkgs 25.11.
  hubstaffMcp = pkgs.python3Packages.buildPythonApplication {
    pname = "hubstaff-mcp";
    version = "0.1.3-unstable-2026-03-27";
    src = pkgs.fetchFromGitHub {
      owner = "cdmx-in";
      repo = "hubstaff-mcp";
      rev = "c6cf0860951c196e94ea829808cc56f98f79deb2";
      hash = "sha256-zV1/SGezx2ZynK+YnhCiQWIqPQFxtVyy8jiWZx/PULA=";
    };
    pyproject = true;
    build-system = [ pkgs.python3Packages.hatchling ];
    dependencies = with pkgs.python3Packages; [
      mcp
      httpx
      pydantic
      python-dotenv
    ];
    doCheck = false;
  };

  # n8n-mcp: lightweight MCP server wrapping the n8n REST API.
  # https://github.com/leonardsellem/n8n-mcp-server
  # Replaces czlonkowski/n8n-mcp (1.75G node_modules) with a 200KB API-only wrapper.
  n8nMcp = pkgs.buildNpmPackage {
    pname = "n8n-mcp-server";
    version = "0.1.8";
    src = pkgs.fetchFromGitHub {
      owner = "leonardsellem";
      repo = "n8n-mcp-server";
      rev = "v0.1.8";
      hash = "sha256-ddyDhHPGqrOpu5coldF7laLjG3eKlf4gn9FYUltE5xI=";
    };
    npmDepsHash = "sha256-rDNhtRyrNH4Rs7xOlm6nVhOkFMXE1MNKDhgKTH5iIR4=";
    nodejs = pkgs.nodejs_22;
  };
in
{
  options.devcell.modules.project-management = {
    enable = lib.mkEnableOption "Hubstaff + n8n + Linear + Atlassian MCP servers";
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "Hubstaff time tracking, n8n workflows, Linear (HTTP), Atlassian Jira/Confluence (HTTP)";
        mcpServers = [
          "hubstaff-mcp"
          "n8n"
          "linear-server"
          "atlassian"
        ];
        sizeMb = 50;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      hubstaffMcp # Hubstaff MCP server for time tracking (use: hubstaff-mcp)
      n8nMcp # n8n MCP server for workflow automation (use: n8n-mcp-server)
    ];

    devcell.managedMcp.servers."hubstaff-mcp" = {
      command = "${bin}/hubstaff-mcp";
      args = [ ];
      env.HUBSTAFF_REFRESH_TOKEN = "\${HUBSTAFF_REFRESH_TOKEN}";
    };

    # Linear — remote HTTP MCP server.
    # Auth: OAuth 2.1 flow on first use (run /mcp in Claude session to authenticate).
    devcell.managedMcp.servers."linear-server" = {
      type = "http";
      url = "https://mcp.linear.app/mcp";
    };

    # Atlassian (Jira + Confluence + Rovo) — remote HTTP MCP server.
    # Upstream config repo: https://github.com/atlassian/atlassian-mcp-server
    # Auth: OAuth 2.1 (3LO) on first use — run /mcp in Claude session to authenticate.
    # Claude-only: opencode/codex/gemini filter to stdio. For those clients, wrap
    # the URL with `npx -y mcp-remote ...` in a separate stdio entry.
    devcell.managedMcp.servers."atlassian" = {
      type = "http";
      url = "https://mcp.atlassian.com/v1/mcp/authv2";
    };

    # n8n — workflow automation. Talks to a self-hosted or cloud n8n instance via its REST API.
    # Required env vars: N8N_API_URL (e.g. https://n8n.example.com), N8N_API_KEY (instance API key).
    # The \${VAR} escape produces literal ${VAR} in the generated JSON, which Claude expands at spawn time.
    devcell.managedMcp.servers."n8n" = {
      command = "${bin}/n8n-mcp-server";
      args = [ ];
      env = {
        N8N_API_URL = "\${N8N_API_URL}";
        N8N_API_KEY = "\${N8N_API_KEY}";
      };
    };
  };
}
