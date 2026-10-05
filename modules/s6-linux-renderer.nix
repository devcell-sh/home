# s6-linux-renderer.nix — render s6 service dirs for Linux from modules/s6/
#
# Imported by base.nix. Stages service definitions to ~/.config/devcell/s6-services/
# via home.file, then an activation script copies them to /etc/s6/services/ where
# the entrypoint's s6 activation loop reads them.
#
# Mirrors s6-darwin-renderer.nix but includes all services (Linux runs the full
# set including GUI/desktop services that macOS excludes).
#
# Gated on pkgs.stdenv.isLinux so macOS builds (which import base.nix too)
# skip this module entirely — macOS uses s6-darwin-renderer.nix instead.
{ pkgs, lib, ... }:

let
  s6Root = ./s6;

  # Services that only run on macOS (excluded from Linux rendering).
  # Currently none — all darwin services also have Linux support.
  darwinOnlyServices = [];

  s6Services = pkgs.runCommand "devcell-s6-linux-services" {
    src = s6Root;
  } ''
    mkdir -p $out

    for svc_dir in $src/*/; do
      svc_name=$(basename "$svc_dir")

      # Skip the user bundle (macOS s6-rc concept, not used on Linux)
      [ "$svc_name" = "user" ] && continue

      ${lib.optionalString (darwinOnlyServices != []) ''
        case "$svc_name" in
          ${lib.concatMapStringsSep "|" (s: s) darwinOnlyServices}) continue ;;
        esac
      ''}

      mkdir -p "$out/$svc_name"

      # Copy type file
      if [ -f "$svc_dir/type" ]; then
        cp "$svc_dir/type" "$out/$svc_name/type"
      fi

      # Copy notification-fd if present
      if [ -f "$svc_dir/notification-fd" ]; then
        cp "$svc_dir/notification-fd" "$out/$svc_name/notification-fd"
      fi

      # Dependencies
      if [ -d "$svc_dir/dependencies.d" ]; then
        mkdir -p "$out/$svc_name/dependencies.d"
        for dep in "$svc_dir/dependencies.d"/*; do
          dep_name=$(basename "$dep")
          touch "$out/$svc_name/dependencies.d/$dep_name"
        done
      fi

      # Scripts: prefer linux/ subdir, fall back to shared
      if [ -d "$svc_dir/linux" ] && [ "$(ls -A "$svc_dir/linux" 2>/dev/null)" ]; then
        for script in "$svc_dir/linux"/*; do
          [ -f "$script" ] || continue
          cp "$script" "$out/$svc_name/$(basename "$script")"
          chmod +x "$out/$svc_name/$(basename "$script")"
        done
      else
        for script in up run finish down; do
          if [ -f "$svc_dir/$script" ]; then
            cp "$svc_dir/$script" "$out/$svc_name/$script"
            chmod +x "$out/$svc_name/$script"
          fi
        done
      fi
    done
  '';

in lib.mkIf pkgs.stdenv.isLinux {
  # Stage the rendered service tree into the home directory so the
  # stageS6Services activation script can copy it to /etc/s6/services/.
  home.file.".config/devcell/s6-services".source = s6Services;

  # Activation: copy staged s6 services to /etc/s6/services/
  home.activation.stageS6Services = lib.hm.dag.entryAfter ["writeBoundary"] ''
    export PATH="/usr/bin:/bin:$PATH"
    if [ -d "$HOME/.config/devcell/s6-services" ]; then
      $DRY_RUN_CMD sudo mkdir -p /etc/s6/services
      $DRY_RUN_CMD sudo ${pkgs.rsync}/bin/rsync -a --chmod=+x --delete \
        "$HOME/.config/devcell/s6-services/" /etc/s6/services/
      # Longruns need a writable supervise/ dir for s6-svscan
      for svc_dir in /etc/s6/services/*/; do
        if [ -f "$svc_dir/type" ] && [ "$(cat "$svc_dir/type")" = "longrun" ]; then
          $DRY_RUN_CMD sudo mkdir -p "$svc_dir/supervise"
        fi
      done
      echo "s6-linux-renderer: $(find /etc/s6/services/ -mindepth 1 -maxdepth 1 -type d | wc -l) services installed"
    fi
  '';
}
