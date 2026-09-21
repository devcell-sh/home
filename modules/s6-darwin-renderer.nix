# s6-darwin-renderer.nix — render s6 service dirs for macOS from modules/s6/
#
# Imported by hosts/macos/default.nix. Runs as a nix-darwin activation script
# that copies service definitions to /etc/s6/services/ where s6-svscan reads them.
{ pkgs, lib, ... }:

let
  s6Root = ./s6;

  # Services that only run on Linux (excluded from macOS rendering)
  linuxOnlyServices = [
    "env-setup"
    "gui-config"
    "xvfb"
    "dbus-session"
    "window-manager"
    "x11vnc"
    "pulseaudio"
    "xrdp"
    "xrdp-chansrv"
  ];

  # Build the rendered service tree as a derivation
  s6Services = pkgs.runCommand "devcell-s6-darwin-services" {
    src = s6Root;
  } ''
    mkdir -p $out

    for svc_dir in $src/*/; do
      svc_name=$(basename "$svc_dir")

      # Skip the user bundle (rendered separately below)
      [ "$svc_name" = "user" ] && continue

      # Skip Linux-only services
      case "$svc_name" in
        ${lib.concatMapStringsSep "|" (s: s) linuxOnlyServices}) continue ;;
      esac

      mkdir -p "$out/$svc_name"

      # Copy type file
      if [ -f "$svc_dir/type" ]; then
        cp "$svc_dir/type" "$out/$svc_name/type"
      fi

      # Copy notification-fd if present
      if [ -f "$svc_dir/notification-fd" ]; then
        cp "$svc_dir/notification-fd" "$out/$svc_name/notification-fd"
      fi

      # Dependencies: copy dependencies.d/, filtering out Linux-only deps
      if [ -d "$svc_dir/dependencies.d" ]; then
        mkdir -p "$out/$svc_name/dependencies.d"
        for dep in "$svc_dir/dependencies.d"/*; do
          dep_name=$(basename "$dep")
          case "$dep_name" in
            ${lib.concatMapStringsSep "|" (s: s) linuxOnlyServices}) continue ;;
          esac
          touch "$out/$svc_name/dependencies.d/$dep_name"
        done
      fi

      # Scripts: prefer darwin/ subdir, fall back to shared
      if [ -d "$svc_dir/darwin" ]; then
        # Use darwin-specific scripts
        for script in "$svc_dir/darwin"/*; do
          [ -f "$script" ] || continue
          cp "$script" "$out/$svc_name/$(basename "$script")"
          chmod +x "$out/$svc_name/$(basename "$script")"
        done
      else
        # Use shared scripts
        for script in up run finish down; do
          if [ -f "$svc_dir/$script" ]; then
            cp "$svc_dir/$script" "$out/$svc_name/$script"
            chmod +x "$out/$svc_name/$script"
          fi
        done
      fi
    done

    # Generate darwin-specific user bundle
    mkdir -p "$out/user"
    echo "bundle" > "$out/user/type"
    mkdir -p "$out/user/contents.d"
    for svc_dir in "$out"/*/; do
      svc_name=$(basename "$svc_dir")
      [ "$svc_name" = "user" ] && continue
      touch "$out/user/contents.d/$svc_name"
    done
  '';

in {
  # Activation script: install rendered s6 services and compile the database
  system.activationScripts.postActivation.text = ''
    echo "s6-darwin-renderer: installing service tree..."

    # Clean and populate /etc/s6/services from the nix-built tree
    rm -rf /etc/s6/services
    mkdir -p /etc/s6/services

    # Copy each service dir (can't symlink: s6-svscan needs writable dirs for supervise/)
    for svc_dir in ${s6Services}/*/; do
      svc_name=$(basename "$svc_dir")
      cp -r "$svc_dir" "/etc/s6/services/$svc_name"
      chmod -R u+w "/etc/s6/services/$svc_name"
    done

    # For longruns, s6-svscan needs a supervise/ dir it can write to
    for svc_dir in /etc/s6/services/*/; do
      if [ -f "$svc_dir/type" ] && [ "$(cat "$svc_dir/type")" = "longrun" ]; then
        mkdir -p "$svc_dir/supervise"
      fi
    done

    echo "s6-darwin-renderer: $(find /etc/s6/services/ -mindepth 1 -maxdepth 1 -type d | wc -l) services installed"
  '';
}
