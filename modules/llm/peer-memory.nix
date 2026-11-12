# peer-memory.nix — MCP server for cross-agent memory sharing.
# Uses the peer-memory-mcp Go binary from the devcell CLI flake.
{ pkgs, config, devcell, ... }:
let
  bin = config.devcell.managedMcp.nixBinPrefix;
  cellPkg = devcell.packages.${pkgs.stdenv.hostPlatform.system}.cell;
  peerMemory = pkgs.runCommand "peer-memory-mcp" {} ''
    mkdir -p $out/bin
    ln -s ${cellPkg}/bin/peer-memory-mcp $out/bin/peer-memory-mcp
  '';
in {
  home.packages = [ peerMemory ];

  devcell.managedMcp.servers."peer-memory" = {
    command = "${bin}/peer-memory-mcp";
    args = [ "--source=codex" ];
  };
}
