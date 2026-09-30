# bbb: beyond bloated baseline. Keep the short name on the public surface.
# Retains the specialist capabilities previously included in ultimate.
{pkgs, ...}: let
  # Preserve the downloader pin previously supplied by base.
  ytDlpLatest = pkgs.yt-dlp.overridePythonAttrs (_: rec {
    version = "2026.08.19";
    src = pkgs.fetchFromGitHub {
      owner = "yt-dlp";
      repo = "yt-dlp";
      tag = version;
      hash = "sha256-BM5ZeGTmHq+1xH6G/zsuCtjLgYgfRA11ya0zIHK5p4g=";
    };
  });
in {
  imports = [
    ./ultimate.nix
    ../modules/any-chat.nix
    ../modules/apple.nix
    ../modules/electronics.nix
    ../modules/media
    ../modules/news.nix
    ../modules/publishing.nix
    ../modules/qa-tools.nix
    ../modules/security.nix
    ../modules/social.nix
    ../modules/travel.nix
    ../modules/vm.nix
    ../modules/wine.nix
    ../modules/wireguard.nix
  ];

  devcell.modules = {
    any-chat.enable = true;
    apple.enable = true;
    electronics.enable = true;
    desktop = {
      nativeUi.enable = true;
      rdpClient.enable = true;
      kitty.enable = true;
      wxWidgets.enable = true;
    };
    graphics = {
      drawio.enable = true;
      inkscape.enable = true;
      gimp.enable = true;
    };
    plex.enable = true;
    news.enable = true;
    publishing.enable = true;
    qa-tools.enable = true;
    security.enable = true;
    social.enable = true;
    travel.enable = true;
    vm.enable = true;
    wine.enable = true;
    wireguard.enable = true;
  };

  home.packages = [pkgs.ffmpeg ytDlpLatest pkgs.iosevka-bin pkgs.cascadia-code pkgs.terraform-plugin-docs];

  # Financial remains opt-in: its uncached upstream build was already
  # excluded from the previous ultimate stack (CELL-293).
}
