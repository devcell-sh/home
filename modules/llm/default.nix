# llm/default.nix — LLM coding tools: module imports + s6 services.
{...}: {
  imports = [
    ./mcp.nix
    ./claude.nix
    ./opencode.nix
    ./codex.nix
    ./gemini.nix
    ./antigravity.nix
    ./peer-memory.nix
  ];

  devcell.s6.services = {
    claude-config  = ../s6/claude-config;
    codex-config   = ../s6/codex-config;
    gemini-config  = ../s6/gemini-config;
    opencode-config = ../s6/opencode-config;
    mcp-toggle     = ../s6/mcp-toggle;
    antigravity    = ../s6/antigravity;
    peer-memory    = ../s6/peer-memory;
  };
}
