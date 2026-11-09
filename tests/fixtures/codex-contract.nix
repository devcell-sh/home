# Minimal production-module evaluation: no MCP servers are installed or started.
# Tests build the pinned CLI and merger so version bumps exercise both together.
let
  root = ../..;
  flake = builtins.getFlake (toString root);
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  home = flake.lib.mkHome system [
    (root + "/modules/llm/mcp.nix")
    (root + "/modules/llm/claude.nix")
    (root + "/modules/llm/codex.nix")
    {
      devcell.managedMcp.backupBeforeMerge = false;
      devcell.managedMcp.servers = {
        local-test = {
          command = "/opt/devcell/bin/example-mcp";
          args = [ "--stdio" ];
          env = {
            TEST_TOKEN = "\${TEST_TOKEN}";
            DISPLAY = "\${DISPLAY:-:99}";
          };
        };
        remote-test = {
          type = "http";
          url = "https://example.invalid/mcp";
          headers.X-Tenant = "test";
          bearer_token_env_var = "TEST_BEARER_TOKEN";
        };
      };
    }
  ];
  packages = builtins.filter (p:
    builtins.elem (p.pname or p.name) [ "codex" "devcell-codex-config-merge" ]
  ) home.config.home.packages;
  fixtures = pkgs.runCommand "codex-config-fixtures" {} ''
    mkdir -p $out/share/codex-test
    cp ${home.config.devcell.managedCodex.nixMcpConfigFile} $out/share/codex-test/codex.toml
    cp ${home.config.devcell.managedClaude.nixMcpConfigFile} $out/share/codex-test/claude.json
  '';
in
pkgs.buildEnv {
  name = "codex-config-test-env";
  paths = packages ++ [ pkgs.python3 pkgs.diffutils fixtures ];
  pathsToLink = [ "/bin" "/share/codex-test" ];
}
