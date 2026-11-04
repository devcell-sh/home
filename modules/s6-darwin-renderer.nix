# s6-darwin-renderer.nix — render s6 service dirs for macOS
#
# Imported by base.nix (gated on isDarwin). Collects service directories
# registered via config.devcell.s6.services, compiles them at build time
# via s6-rc-compile, and installs both the source tree (for up.sh scripts)
# and the compiled database to /etc/s6-rc/ where s6-rc activation reads them.
#
# Only services registered by enabled modules are included: desktop services
# (gui-config, xvfb, etc.) are never registered on darwin because
# desktop/default.nix gates on isLinux.
{ pkgs, lib, config, ... }:

let
  services = config.devcell.s6.services;

  s6Services = pkgs.runCommand "devcell-s6-darwin-services" {
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

    # Dependencies: copy dependencies.d/, filtering out services not in the set
    if [ -d "$svc_dir/dependencies.d" ]; then
      mkdir -p "$SOURCE/$svc_name/dependencies.d"
      for dep in "$svc_dir/dependencies.d"/*; do
        dep_name=$(basename "$dep")
        # Only include deps that are registered services
        case "$dep_name" in
          ${lib.concatMapStringsSep "|" (s: s) (builtins.attrNames services)}) touch "$SOURCE/$svc_name/dependencies.d/$dep_name" ;;
        esac
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

    # Scripts: prefer darwin/ subdir, fall back to shared
    if [ -d "$svc_dir/darwin" ] && [ "$(ls -A "$svc_dir/darwin" 2>/dev/null)" ]; then
      for script in "$svc_dir/darwin"/*; do
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

in lib.mkIf pkgs.stdenv.isDarwin {
  # Stage the rendered service tree into the home directory.
  home.file.".config/devcell/s6-services".source = s6Services;

  # Activation: install s6-rc source and compiled database.
  # Can't symlink: s6-svscan needs writable dirs for supervise/.
  home.activation.stageS6Services = lib.hm.dag.entryAfter ["writeBoundary"] ''
    export PATH="/usr/bin:/bin:$PATH"
    if [ -d "$HOME/.config/devcell/s6-services" ]; then
      $DRY_RUN_CMD sudo rm -rf /etc/s6-rc/source /etc/s6-rc/compiled
      $DRY_RUN_CMD sudo mkdir -p /etc/s6-rc/source

      for svc_dir in "$HOME/.config/devcell/s6-services/source"/*/; do
        svc_name=$(basename "$svc_dir")
        $DRY_RUN_CMD sudo cp -r "$svc_dir" "/etc/s6-rc/source/$svc_name"
        $DRY_RUN_CMD sudo chmod -R u+w "/etc/s6-rc/source/$svc_name"
      done

      $DRY_RUN_CMD sudo cp -r "$HOME/.config/devcell/s6-services/compiled" /etc/s6-rc/compiled
      $DRY_RUN_CMD sudo chmod -R u+w /etc/s6-rc/compiled
      echo "s6-darwin-renderer: $(find /etc/s6-rc/source/ -mindepth 1 -maxdepth 1 -type d | wc -l) services installed, database compiled"
    fi
  '';
}
