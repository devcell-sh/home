# General development, browser automation, desktop and graphics.
# Specialist tools live in bbb; individual modules remain opt-in.
{lib, pkgs, ...}: {
  imports = [
    ./dev.nix
    ../modules/build.nix
    ../modules/go.nix
    ../modules/node.nix
    ../modules/project-management.nix
    ../modules/python.nix
    ../modules/desktop
    ../modules/graphics.nix
    ../modules/mise.nix
    ../modules/nixos.nix
  ];

  devcell.modules = {
    build.enable = true;
    go.enable = true;
    node.enable = true;
    project-management.enable = true;
    python.enable = true;
    desktop = {
      enable = true;
      nativeUi.enable = lib.mkDefault false;
      rdpClient.enable = lib.mkDefault false;
      kitty.enable = lib.mkDefault false;
      wxWidgets.enable = lib.mkDefault false;
    };
    graphics = {
      enable = true;
      drawio.enable = lib.mkDefault false;
      inkscape.enable = lib.mkDefault false;
      gimp.enable = lib.mkDefault false;
    };
    nixos.enable = true;
  };

  home.packages = with pkgs; [
    poppler-utils # PDF utilities: pdftotext, pdfinfo, pdfimages (use: pdftotext file.pdf -)
  ];
}
