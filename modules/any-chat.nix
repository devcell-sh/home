# any-chat.nix — Any Chat Completions MCP (chat with any OpenAI-compatible API)
{pkgs, config, lib, ...}: let
  cfg = config.devcell.modules.any-chat;
  bin = config.devcell.managedMcp.nixBinPrefix;
  # any-chat-completions-mcp: single `chat` tool relaying to any OpenAI SDK
  # compatible Chat Completions endpoint (OpenAI, Perplexity, Groq, xAI, ollama, ...)
  # https://github.com/pyroprompts/any-chat-completions-mcp
  anyChatMcp = pkgs.buildNpmPackage {
    pname = "any-chat-completions-mcp";
    version = "0.1.1-unstable-2026-08-30";
    src = pkgs.fetchFromGitHub {
      owner = "pyroprompts";
      repo = "any-chat-completions-mcp";
      rev = "20f715e85fe19917ff02cd8d7cfcd4667a52a146";
      hash = "sha256-lTJryQR4gBpZh4sKvgdWQp05bQnuYq6CjHy1z8t+XIA=";
    };
    npmDepsHash = "sha256-Hc+1kns/XoeAzlRsu4ek0tIeRqmF7T/fEHyAXvZO7Kk=";
    nodejs = pkgs.nodejs_22;
    nativeBuildInputs = [pkgs.makeWrapper];
    # cli.js spawns a bare `node` for index.js — ensure it resolves in a pure env
    postInstall = ''
      wrapProgram $out/bin/any-chat-completions-mcp \
        --prefix PATH : ${pkgs.nodejs_22}/bin
    '';
  };
in {
  options.devcell.modules.any-chat = {
    enable = lib.mkEnableOption "Any Chat Completions MCP";
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "Relay chat to any OpenAI-compatible Chat Completions API";
        mcpServers = [ "any-chat-completions" ];
        sizeMb = 30;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      anyChatMcp # Any Chat Completions MCP server (use: any-chat-completions-mcp)
    ];

    # One `chat` tool per configured provider. Requires at runtime:
    #   AI_CHAT_KEY      — API key for the provider
    #   AI_CHAT_NAME     — display name (e.g. "OpenAI", "Groq")
    #   AI_CHAT_MODEL    — model id (e.g. "gpt-4o")
    #   AI_CHAT_BASE_URL — endpoint (e.g. "https://api.openai.com/v1")
    devcell.managedMcp.servers."any-chat-completions" = {
      command = "${bin}/any-chat-completions-mcp";
      args = [];
      env = {
        AI_CHAT_KEY = "\${AI_CHAT_KEY}";
        AI_CHAT_NAME = "\${AI_CHAT_NAME}";
        AI_CHAT_MODEL = "\${AI_CHAT_MODEL}";
        AI_CHAT_BASE_URL = "\${AI_CHAT_BASE_URL}";
      };
    };
  };
}
