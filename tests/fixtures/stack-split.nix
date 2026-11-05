# Evaluation-only regression checks. No builds, activation or store cleanup.
# Uses actual module evaluation and the actual image layer planner with a
# recording nix2container implementation. Does not test boot/runtime behavior.
{flake}: let
  inherit (flake.inputs.nixpkgs) lib;
  configs = flake.homeConfigurations;
  specialistModules = [
    "any-chat" "apple" "electronics" "news" "plex" "publishing"
    "security" "social" "travel" "vm" "wine" "wireguard" "qa-tools"
  ];
  movedPackages = [
    "kicad-small" "wine64-staging" "winetricks" "qemu" "jadx" "ghidra"
    "swift-wrapper" "inkscape" "inkscape-mcp" "mastodon-mcp-server"
    "texlive-combined-medium" "tripit-mcp" "inoreader-mcp" "plex-mcp-server"
    "webkitgtk" "freerdp" "ffmpeg" "gimp" "gimp-mcp"
    "kitty" "wxwidgets" "yt-dlp" "Iosevka-bin" "cascadia-code"
    "mailslurp-mcp" "terraform-plugin-docs" "drawio-headless"
  ];
  movedMcps = ["kicad-mcp" "inkscape-mcp" "gimp-mcp" "mastodon" "tripit" "inoreader" "plex" "mailslurp"];
  hasPackage = prefix: packages: lib.any (p:
    p.name == prefix || lib.hasPrefix (prefix + "-") p.name
  ) packages;
  enabledModules = h: builtins.attrNames (lib.filterAttrs (_: value:
    value.enable or false
  ) h.config.devcell.modules);
  checkLinux = suffix: let
    ultimate = configs."devcell-ultimate${suffix}";
    bbb = configs."devcell-bbb${suffix}";
    up = ultimate.config.home.packages;
    bp = bbb.config.home.packages;
    um = ultimate.config.devcell.managedMcp.servers;
    bm = bbb.config.devcell.managedMcp.servers;
    chromium = lib.findFirst (p: p.name == "chromium") null up;
    browserBundle = builtins.unsafeDiscardStringContext ultimate.config.home.sessionVariables.PLAYWRIGHT_BROWSERS_PATH;
    fluxboxUltimate = ultimate.extendModules {
      modules = [{devcell.modules.desktop.windowManager = "fluxbox";}];
    };
    fluxboxBbb = bbb.extendModules {
      modules = [{devcell.modules.desktop.windowManager = "fluxbox";}];
    };
  in
    assert lib.all (p: !hasPackage p up && hasPackage p bp) movedPackages;
    assert lib.all (m: !(builtins.hasAttr m um) && builtins.hasAttr m bm) movedMcps;
    assert lib.all (p: hasPackage p up && hasPackage p bp) ["codex" "chromium" "clang-wrapper" "xrdp" "x11vnc" "terraform-docs" "awscli2"];
    assert !(builtins.elem (toString ultimate.pkgs.gtk4.dev) (map toString up));
    assert builtins.elem (toString bbb.pkgs.gtk4.dev) (map toString bp);
    assert !ultimate.config.programs.kitty.enable && bbb.config.programs.kitty.enable;
    assert !(lib.hasInfix "Kitty" ultimate.config.home.file.".icewm/menu".text);
    assert lib.hasInfix "Kitty" bbb.config.home.file.".icewm/menu".text;
    assert !(lib.hasInfix "Kitty" fluxboxUltimate.config.xsession.windowManager.fluxbox.menu);
    assert lib.hasInfix "Kitty" fluxboxBbb.config.xsession.windowManager.fluxbox.menu;
    assert lib.hasInfix "exec ${browserBundle}/chromium-" chromium.text;
    assert !(builtins.elem "Iosevka Term" ultimate.config.fonts.fontconfig.defaultFonts.monospace);
    assert builtins.elem "Iosevka Term" bbb.config.fonts.fontconfig.defaultFonts.monospace;
    assert !(builtins.elem "Cascadia Code NF" ultimate.config.fonts.fontconfig.defaultFonts.monospace);
    assert builtins.elem "Cascadia Code NF" bbb.config.fonts.fontconfig.defaultFonts.monospace;
    assert !(builtins.hasAttr ".local/bin/devcell-wine-init" ultimate.config.home.file);
    assert builtins.hasAttr ".local/bin/devcell-wine-init" bbb.config.home.file;
    assert lib.sort builtins.lessThan (enabledModules ultimate) == lib.sort builtins.lessThan flake.devcellProfiles.ultimate;
    assert lib.sort builtins.lessThan (enabledModules bbb) == lib.sort builtins.lessThan flake.devcellProfiles.bbb;
    {
      ultimatePackages = builtins.length up;
      bbbPackages = builtins.length bp;
      ultimateMcps = builtins.attrNames um;
      bbbMcps = builtins.attrNames bm;
      # Force the full activation derivations, not just the package list.
      ultimateActivation = ultimate.activationPackage.drvPath;
      bbbActivation = bbb.activationPackage.drvPath;
    };
  checkLayers = stack: let
    h = configs."devcell-${stack}-aarch64";
    nixCfg = { system = "aarch64-linux"; config.allowUnfree = true; };
    image = import ../packages/image.nix {
      pkgs = import flake.inputs.nixpkgs nixCfg;
      pkgsUnstable = import flake.inputs.nixpkgs-unstable nixCfg;
      pkgsEdge = import flake.inputs.nixpkgs-edge nixCfg;
      homeConfig = h;
      stackName = stack;
      nix2container = { buildLayer = args: args; buildImage = args: args; };
    };
    selected = map toString h.config.home.packages;
    deps = lib.concatMap (layer: layer.deps) image.layers;
  in assert lib.all (p: builtins.elem (toString p) selected) deps;
    map (p: p.name) deps;
in {
  linux = checkLinux "";
  aarch64 = checkLinux "-aarch64";
  variants = assert lib.all (name: builtins.hasAttr name configs) [
    "devcell-bbb" "devcell-bbb-aarch64" "devcell-bbb-darwin"
    "vagrant-bbb" "vagrant-bbb-aarch64" "wsl-bbb" "wsl-bbb-aarch64"
  ]; true;
  catalog = assert lib.all (name:
    builtins.hasAttr name flake.devcellModules && builtins.hasAttr name flake.modules
  ) specialistModules; true;
  images = assert lib.all (system: builtins.hasAttr "devcell-bbb-pure-image" flake.packages.${system}) [
    "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"
  ]; true;
  ultimateLayers = checkLayers "ultimate";
  bbbLayers = checkLayers "bbb";
}
