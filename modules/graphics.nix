# graphics.nix — Graphics tools: Draw.io, Inkscape, GIMP, Blender + MCP servers
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.devcell.modules.graphics;
  bin = config.devcell.managedMcp.nixBinPrefix;

  # inkscape-mcp: Python MCP server exposing Inkscape CLI and DOM operations.
  # Source: https://github.com/grumpydevorg/inkscape-mcps
  inkscape-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "inkscape-mcp";
    version = "0.1.0";
    src = pkgs.fetchFromGitHub {
      owner = "grumpydevorg";
      repo = "inkscape-mcps";
      rev = "e621da1a8287896fa3a7bf8e3cf4fd6a9c2f87ea";
      hash = "sha256-P+84x+jHg+o0ddsZzwaIHaRZXKzh63gJK9r14x3gFQU=";
    };
    pyproject = true;
    build-system = [pkgs.python3Packages.hatchling];
    nativeBuildInputs = [pkgs.python3Packages.pythonRelaxDepsHook];
    pythonRelaxDeps = ["scour"]; # nixpkgs has 0.38.2; upstream requires <0.38
    dependencies = with pkgs.python3Packages; [
      fastmcp  # MCP framework
      pydantic # data validation
      anyio    # async runtime
      filelock # file locking
      inkex    # Inkscape Python extension library
      scour    # SVG optimizer
    ];
    doCheck = false;
  };

  # gimp-mcp: Python MCP server bridging GIMP 3.0 with AI assistants.
  # Two components: a GIMP plug-in (opens port 9877 inside GIMP) and an
  # MCP bridge (stdio server that Claude talks to, forwarding to port 9877).
  # Source: https://github.com/maorcc/gimp-mcp
  gimp-mcp-src = pkgs.fetchFromGitHub {
    owner = "maorcc";
    repo = "gimp-mcp";
    rev = "09bfb2d3e5ca8efdc50c8d0b8c9cdf590ce422c6";
    hash = "sha256-fmsaDarIQJ9buQjsEYjEet1yCPlQp1w7ZYSYoN//LK0=";
  };

  gimp-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "gimp-mcp";
    version = "0.1.0";
    src = gimp-mcp-src;
    pyproject = true;
    build-system = [pkgs.python3Packages.setuptools];
    dependencies = with pkgs.python3Packages; [
      mcp      # Model Context Protocol SDK
      fastmcp  # declared by upstream pyproject.toml
    ];
    postPatch = ''
      substituteInPlace gimp_mcp_server.py \
        --replace-fail 'FastMCP("GimpMCP", description=' 'FastMCP("GimpMCP", instructions='
    '';
    doCheck = false;
  };

  # GIMP 3.0 plug-in: opens the MCP socket server on port 9877 inside GIMP.
  # Installed to ~/.config/GIMP/3.0/plug-ins/ so GIMP loads it at startup.
  gimp-mcp-plugin = pkgs.stdenvNoCC.mkDerivation {
    pname = "gimp-mcp-plugin";
    version = "0.1.0";
    src = gimp-mcp-src;
    installPhase = ''
      mkdir -p $out/gimp-mcp-plugin
      cp gimp-mcp-plugin.py $out/gimp-mcp-plugin/gimp-mcp-plugin.py
      chmod +x $out/gimp-mcp-plugin/gimp-mcp-plugin.py
    '';
  };

  # Wrapper: ensures GIMP is running with the MCP plugin before starting
  # the MCP bridge. Installs the plugin on first run, then launches GIMP
  # headlessly and calls plug-in-mcp-server to open port 9877.
  gimp-mcp-wrapper = pkgs.writeShellScript "gimp-mcp-wrapper" ''
    export DISPLAY=''${DISPLAY:-:99}
    PLUGIN_DIR="$HOME/.config/GIMP/3.0/plug-ins/gimp-mcp-plugin"
    mkdir -p "$PLUGIN_DIR"
    ln -sf "${gimp-mcp-plugin}/gimp-mcp-plugin/gimp-mcp-plugin.py" "$PLUGIN_DIR/gimp-mcp-plugin.py"
    if ! ${pkgs.netcat-gnu}/bin/netcat -z localhost 9877 2>/dev/null; then
      ${pkgs.gimp}/bin/gimp --no-interface \
        --batch-interpreter=python-fu-eval \
        -b "proc = Gimp.get_pdb().lookup_procedure('plug-in-mcp-server'); config = proc.create_config(); config.set_property('run-mode', Gimp.RunMode.NONINTERACTIVE); proc.run(config)" &
      for i in $(seq 1 60); do
        ${pkgs.netcat-gnu}/bin/netcat -z localhost 9877 2>/dev/null && break
        sleep 0.5
      done
      if ! ${pkgs.netcat-gnu}/bin/netcat -z localhost 9877 2>/dev/null; then
        echo "gimp-mcp: GIMP failed to start MCP server on port 9877" >&2
        exit 1
      fi
    fi
    exec ${bin}/gimp-mcp-server "$@"
  '';

  # blender-mcp: Python MCP server bridging Blender with AI assistants.
  # Two components: a Blender add-on (opens port 9876 inside Blender) and an
  # MCP bridge (stdio server that Claude talks to, forwarding to port 9876).
  # Source: https://github.com/ahujasid/mcp-for-blender
  blender-mcp-src = pkgs.fetchFromGitHub {
    owner = "ahujasid";
    repo = "mcp-for-blender";
    rev = "2e4b0bc294694b1570d76ed01be657c22e6d02a0";
    hash = "sha256-Gf0J0NEkeiHptdcbJFZxj0uw1yV+cQded33EGkuecKk=";
  };

  blender-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "mcp-for-blender";
    version = "2.2.7";
    src = blender-mcp-src;
    pyproject = true;
    build-system = [pkgs.python3Packages.setuptools pkgs.python3Packages.wheel];
    dependencies = with pkgs.python3Packages; [
      mcp    # Model Context Protocol SDK
      httpx  # HTTP client
    ];
    doCheck = false;
  };

  # Blender add-on: opens the MCP socket server on port 9876 inside Blender.
  # Installed to ~/.config/blender/<version>/scripts/addons/ so Blender loads it.
  blender-mcp-addon = pkgs.stdenvNoCC.mkDerivation {
    pname = "blender-mcp-addon";
    version = "2.2.7";
    src = blender-mcp-src;
    installPhase = ''
      mkdir -p $out
      cp src/blender_mcp/bundled/addon.py $out/blender_mcp.py
    '';
  };

  # Python script: configure Blender GPU preferences on first run.
  # Probes for hardware accelerators (OptiX > HIP > oneAPI > Metal),
  # falls back to CPU. Enables the blender_mcp add-on and saves prefs.
  blender-gpu-setup = pkgs.writeText "blender-gpu-setup.py" ''
    import bpy, sys

    prefs = bpy.context.preferences
    bpy.ops.preferences.addon_enable(module="blender_mcp")

    try:
        cycles = prefs.addons["cycles"].preferences
    except KeyError:
        print("blender-gpu-setup: Cycles add-on not available, skipping GPU config", file=sys.stderr)
        bpy.ops.wm.save_userpref()
        sys.exit(0)

    chosen = None
    for dev_type in ("OPTIX", "HIP", "ONEAPI", "METAL"):
        try:
            cycles.compute_device_type = dev_type
            cycles.get_devices()
            hw = [d for d in cycles.devices if d.type != "CPU"]
            if hw:
                for d in cycles.devices:
                    d.use = True
                chosen = dev_type
                print(f"blender-gpu-setup: {dev_type} with {len(hw)} device(s)", file=sys.stderr)
                break
        except Exception:
            continue

    if not chosen:
        cycles.compute_device_type = "NONE"
        cycles.get_devices()
        for d in cycles.devices:
            d.use = True
        print("blender-gpu-setup: no hardware GPU, using CPU rendering", file=sys.stderr)

    bpy.ops.wm.save_userpref()
  '';

  # Wrapper: ensures Blender is running with the MCP add-on before starting
  # the MCP bridge. On first run: installs the add-on, configures Cycles GPU
  # preferences, then launches Blender headlessly to open port 9876.
  blender-mcp-wrapper = pkgs.writeShellScript "blender-mcp-wrapper" ''
    export DISPLAY=''${DISPLAY:-:99}
    export BLENDER_MCP_DISABLE_TELEMETRY=1

    BLENDER_VER=$(${pkgs.blender}/bin/blender --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+')
    ADDON_DIR="$HOME/.config/blender/$BLENDER_VER/scripts/addons"
    mkdir -p "$ADDON_DIR"
    ln -sf "${blender-mcp-addon}/blender_mcp.py" "$ADDON_DIR/blender_mcp.py"

    STAMP="$HOME/.config/blender/$BLENDER_VER/.gpu-configured"
    if [ ! -f "$STAMP" ]; then
      echo "blender-mcp: first run — configuring GPU and add-on preferences" >&2
      ${pkgs.blender}/bin/blender --background --python "${blender-gpu-setup}" 2>&1 | \
        grep -E "^blender-gpu-setup:" >&2 || true
      touch "$STAMP"
    fi

    if ! ${pkgs.netcat-gnu}/bin/netcat -z localhost 9876 2>/dev/null; then
      ${pkgs.blender}/bin/blender --background \
        --python-expr "
import bpy
bpy.ops.preferences.addon_enable(module='blender_mcp')
import blender_mcp
" &
      for i in $(seq 1 60); do
        ${pkgs.netcat-gnu}/bin/netcat -z localhost 9876 2>/dev/null && break
        sleep 0.5
      done
      if ! ${pkgs.netcat-gnu}/bin/netcat -z localhost 9876 2>/dev/null; then
        echo "blender-mcp: Blender failed to start MCP server on port 9876" >&2
        exit 1
      fi
    fi
    exec ${bin}/mcp-for-blender "$@"
  '';
in {
  options.devcell.modules.graphics = {
    enable = lib.mkEnableOption "Draw.io + Inkscape + GIMP + Blender + their MCP servers";
    drawio.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include the Electron-based Draw.io desktop exporter";
    };
    inkscape.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include Inkscape and its MCP server with the graphics tools";
    };
    gimp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include GIMP and its MCP server with the graphics tools";
    };
    blender.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include Blender and its MCP server with the graphics tools";
    };
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "Vector graphics (Inkscape), raster (GIMP), 3D (Blender), Draw.io headless; MCP for Inkscape + GIMP + Blender";
        mcpServers = [ "inkscape-mcp" "gimp-mcp" "blender-mcp" ];
        sizeMb = 1400;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; lib.optionals cfg.inkscape.enable [
      inkscape         # vector graphics editor (use: inkscape)
      inkscape-mcp     # Inkscape MCP server for Claude
    ] ++ [
      potrace          # bitmap → SVG tracer; ships mkbitmap preprocessor (use: potrace, mkbitmap)
    ]
    ++ lib.optionals (pkgs.stdenv.isLinux && cfg.gimp.enable) [
      gimp             # GNU Image Manipulation Program 3.2 — GTK/X11, Linux only (use: gimp)
      gimp-mcp         # GIMP MCP server — requires gimp, Linux only
    ]
    ++ lib.optionals (pkgs.stdenv.isLinux && cfg.blender.enable) [
      blender          # 3D creation/animation suite — Linux only (use: blender)
      blender-mcp      # Blender MCP server — requires blender, Linux only
    ]
    ++ lib.optionals (pkgs.stdenv.isLinux && cfg.drawio.enable) [
      drawio-headless  # Draw.io headless CLI — Electron, Linux only (use: drawio)
    ];

    devcell.managedMcp.servers = lib.mkMerge [
      (lib.mkIf cfg.inkscape.enable {
        "inkscape-mcp" = {
          command = "${bin}/inkscape-mcp";
          args = [];
          env = {
            INKS_INKSCAPE_BIN = "${pkgs.inkscape}/bin/inkscape";
            INKS_WORKSPACE = "./";
          };
        };
      })
      # gimp is Linux-only; the wrapper interpolates ${pkgs.gimp}, which
      # throws on darwin even when home.packages guards the package itself.
      (lib.mkIf (pkgs.stdenv.isLinux && cfg.gimp.enable) {
        "gimp-mcp" = {
          command = "${gimp-mcp-wrapper}";
          args = [];
          env = {};
        };
      })
      (lib.mkIf (pkgs.stdenv.isLinux && cfg.blender.enable) {
        "blender-mcp" = {
          command = "${blender-mcp-wrapper}";
          args = [];
          env = {
            BLENDER_MCP_DISABLE_TELEMETRY = "1";
          };
        };
      })
    ];
  };
}
