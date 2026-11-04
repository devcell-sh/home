# s6-linux-renderer.nix — render s6 service dirs for Linux
#
# Imported by base.nix. Collects service directories registered via
# config.devcell.s6.services (each module adds its own services there),
# compiles them at build time via s6-rc-compile, and installs both the
# source tree (for up.sh scripts) and the compiled database to
# /etc/s6-rc/ where the entrypoint's s6-rc activation reads them.
#
# Gated on pkgs.stdenv.isLinux so macOS builds (which import base.nix too)
# skip this module entirely.
{ pkgs, lib, config, ... }:

let
  services = config.devcell.s6.services;

  s6Services = pkgs.runCommand "devcell-s6-linux-services" {
    nativeBuildInputs = [ pkgs.s6-rc ];
  } (''
    SOURCE="$out/source"
    mkdir -p "$SOURCE"
  '' + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: src: ''
    svc_dir="${src}"
    svc_name="${name}"

    mkdir -p "$SOURCE/$svc_name"

    # Copy type file
    if [ -f "$svc_dir/type" ]; then
      cp "$svc_dir/type" "$SOURCE/$svc_name/type"
    fi

    # Copy notification-fd if present (readiness protocol for longruns)
    if [ -f "$svc_dir/notification-fd" ]; then
      cp "$svc_dir/notification-fd" "$SOURCE/$svc_name/notification-fd"
    fi

    # Dependencies: copy only deps that are in the registered set
    if [ -d "$svc_dir/dependencies.d" ]; then
      mkdir -p "$SOURCE/$svc_name/dependencies.d"
      for dep in "$svc_dir/dependencies.d"/*; do
        dep_name=$(basename "$dep")
        touch "$SOURCE/$svc_name/dependencies.d/$dep_name"
      done
    fi

    # Bundle contents
    if [ -d "$svc_dir/contents.d" ]; then
      mkdir -p "$SOURCE/$svc_name/contents.d"
      for item in "$svc_dir/contents.d"/*; do
        item_name=$(basename "$item")
        touch "$SOURCE/$svc_name/contents.d/$item_name"
      done
    fi

    # Data dir (contains check scripts for s6-notifyoncheck readiness)
    if [ -d "$svc_dir/data" ]; then
      cp -r "$svc_dir/data" "$SOURCE/$svc_name/data"
      chmod -R +x "$SOURCE/$svc_name/data"
    fi

    # Log dir (s6-rc-compile creates a <name>-log pipeline automatically)
    if [ -d "$svc_dir/log" ]; then
      cp -r "$svc_dir/log" "$SOURCE/$svc_name/log"
      chmod +x "$SOURCE/$svc_name/log/run"
    fi

    svc_type=""
    [ -f "$SOURCE/$svc_name/type" ] && svc_type=$(cat "$SOURCE/$svc_name/type")

    # Scripts: prefer linux/ subdir, fall back to shared
    if [ -d "$svc_dir/linux" ] && [ "$(ls -A "$svc_dir/linux" 2>/dev/null)" ]; then
      for script in "$svc_dir/linux"/*; do
        [ -f "$script" ] || continue
        cp "$script" "$SOURCE/$svc_name/$(basename "$script")"
        chmod +x "$SOURCE/$svc_name/$(basename "$script")"
      done
    else
      for script in up run finish down; do
        if [ -f "$svc_dir/$script" ]; then
          cp "$svc_dir/$script" "$SOURCE/$svc_name/$script"
          chmod +x "$SOURCE/$svc_name/$script"
        fi
      done
    fi

    # s6-rc-compile requires oneshot "up" to be an argv (execline-parsed),
    # not a multi-line shell script. Rename shell up -> up.sh, write an
    # execline-compatible up that calls the shell script.
    if [ "$svc_type" = "oneshot" ] && [ -f "$SOURCE/$svc_name/up" ]; then
      mv "$SOURCE/$svc_name/up" "$SOURCE/$svc_name/up.sh"
      chmod +x "$SOURCE/$svc_name/up.sh"
      echo "export RC_NAME $svc_name /etc/s6-rc/source/$svc_name/up.sh" > "$SOURCE/$svc_name/up"
    fi

    # Same for oneshot "down" if present
    if [ "$svc_type" = "oneshot" ] && [ -f "$SOURCE/$svc_name/down" ]; then
      mv "$SOURCE/$svc_name/down" "$SOURCE/$svc_name/down.sh"
      chmod +x "$SOURCE/$svc_name/down.sh"
      echo "/etc/s6-rc/source/$svc_name/down.sh" > "$SOURCE/$svc_name/down"
    fi
  '') services) + ''

    # Generate user bundle containing all registered services
    mkdir -p "$SOURCE/user"
    echo "bundle" > "$SOURCE/user/type"
    mkdir -p "$SOURCE/user/contents.d"
  '' + lib.concatStringsSep "\n" (map (name: ''
    touch "$SOURCE/user/contents.d/${name}"
  '') (builtins.attrNames services)) + ''

    # Compile the service database
    s6-rc-compile "$out/compiled" "$SOURCE"
  '');

in lib.mkIf pkgs.stdenv.isLinux {
  # Stage the rendered service tree into the home directory so the
  # activation script can copy it to /etc/s6-rc/.
  home.file.".config/devcell/s6-services".source = s6Services;

  # Activation: install s6-rc source and compiled database
  home.activation.stageS6Services = lib.hm.dag.entryAfter ["writeBoundary"] ''
    export PATH="/usr/bin:/bin:$PATH"
    if [ -d "$HOME/.config/devcell/s6-services" ]; then
      # Install source tree (contains up.sh scripts that the compiled DB references)
      $DRY_RUN_CMD sudo mkdir -p /etc/s6-rc
      $DRY_RUN_CMD sudo ${pkgs.rsync}/bin/rsync -a --chmod=+x --delete \
        "$HOME/.config/devcell/s6-services/source/" /etc/s6-rc/source/
      $DRY_RUN_CMD sudo ${pkgs.rsync}/bin/rsync -a --delete \
        "$HOME/.config/devcell/s6-services/compiled/" /etc/s6-rc/compiled/
      echo "s6-linux-renderer: $(find /etc/s6-rc/source/ -mindepth 1 -maxdepth 1 -type d | wc -l) services installed, database compiled"
    fi
  '';
}
