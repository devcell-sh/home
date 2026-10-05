# wireguard.nix — WireGuard VPN tunnel support for country-specific exit IPs
{pkgs, config, lib, ...}: let
  cfg = config.devcell.modules.wireguard;
in {
  options.devcell.modules.wireguard = {
    enable = lib.mkEnableOption "WireGuard VPN tunnel with boringtun userspace fallback";
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "WireGuard VPN tunnel + boringtun userspace fallback";
        mcpServers = [];
        sizeMb = 15;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      wireguard-tools  # wg, wg-quick (use: wg-quick up <conf>)
      boringtun        # userspace WireGuard (use: WG_QUICK_USERSPACE_IMPLEMENTATION=boringtun-cli)
    ];
  };
}
