# hosts/macos/home.nix — home-manager config for the devcell user on the devcell macOS VM
# Reuses the devcell base stack (tmux, jq, ripgrep, go-task, git-lfs, etc.)
{ mcp-nixos, pkgs, lib, ... }:
let
  wallpaperSvg = ../../modules/desktop/themes/main/svg/wallpaper.svg;
  wallpaper = pkgs.runCommand "devcell-wallpaper" {
    nativeBuildInputs = [ pkgs.librsvg ];
  } ''
    sed 's/{{CELL_ID}}//g' ${wallpaperSvg} > clean.svg
    rsvg-convert -w 3840 -h 2160 clean.svg -o $out
  '';
in {
  imports = [
    ../../stacks/base.nix
  ];

  home.username = "devcell";
  home.homeDirectory = "/Users/devcell";
  home.stateVersion = "25.11";

  home.packages = [ pkgs.librsvg ];

  home.file = {
    ".config/devcell/wallpaper-template.svg".source = wallpaperSvg;
    ".config/devcell/wallpaper-static.png".source = wallpaper;
    ".config/devcell/set-wallpaper.sh" = {
      executable = true;
      text = ''
        #!/bin/bash
        CELL_ID="$(hostname -s 2>/dev/null || echo "")"
        WP_DIR="$HOME/.config/devcell"
        WP="/tmp/devcell-wallpaper.png"
        if [ -f "$WP_DIR/wallpaper-template.svg" ]; then
          sed "s|{{CELL_ID}}|$CELL_ID|g" "$WP_DIR/wallpaper-template.svg" \
            | ${pkgs.librsvg}/bin/rsvg-convert -w 3840 -h 2160 -o "$WP" 2>/dev/null || true
        fi
        [ -f "$WP" ] || cp "$WP_DIR/wallpaper-static.png" "$WP" 2>/dev/null || true
        if [ -f "$WP" ]; then
          osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$WP\"" 2>/dev/null || true
        fi
      '';
    };
  };

  home.activation.setWallpaper = lib.hm.dag.entryAfter ["writeBoundary"] ''
    "$HOME/.config/devcell/set-wallpaper.sh" || true
  '';
}
