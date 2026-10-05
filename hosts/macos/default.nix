# hosts/macos/default.nix — nix-darwin system config for the devcell macOS VM
# Applied via: nix run nix-darwin -- switch --flake /Volumes/nixhome#<stack>
{ pkgs, ... }: {
  imports = [
    ../../modules/s6-darwin-renderer.nix
  ];
  # Nix daemon settings
  nix.settings = {
    experimental-features = "nix-command flakes";
    allowed-users = [ "devcell" ];
    trusted-users = [ "root" "devcell" ];
  };

  # Target Apple Silicon (tart ARM VMs)
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  # Declare the devcell user so home-manager's common.nix can resolve
  # homeDirectory from users.users.devcell.home (otherwise it's null).
  users.users.devcell = {
    uid = 502;
    home = "/Users/devcell";
    shell = pkgs.bashInteractive;
  };
  users.knownUsers = [ "devcell" ];

  # nix-darwin creates the user via dscl but doesn't mkdir the home directory.
  # home-manager's activate script does `cd $HOME` early, so ensure it exists
  # before activation proceeds. preActivation runs before users/groups/etc.
  # Also grants devcell passwordless sudo (home-manager activation scripts need
  # it for installing LaunchDaemons and managed tools).
  system.activationScripts.preActivation.text = ''
    if [ ! -d /Users/devcell ]; then
      mkdir -p /Users/devcell
      chown 502:staff /Users/devcell
      echo "created /Users/devcell (uid 502)"
    fi
    if [ ! -f /etc/sudoers.d/devcell ]; then
      mkdir -p /etc/sudoers.d
      echo "devcell ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/devcell
      chmod 0440 /etc/sudoers.d/devcell
      echo "granted devcell passwordless sudo"
    fi
    # Set devcell password for ARD Screen Sharing authentication.
    dscl . -passwd /Users/devcell admin 2>/dev/null || true
    mkdir -p /etc/s6/services
  '';

  # Minimal system packages — user env managed via home-manager
  environment.systemPackages = with pkgs; [
    git
    s6
    s6-rc
    execline
  ];

  # s6-svscan: supervise the devcell service tree.
  # Depends on nix volume being mounted (com.devcell.mount-nix runs first via
  # provisioning). KeepAlive restarts s6-svscan if it dies.
  launchd.daemons.s6-svscan = {
    serviceConfig = {
      Label = "com.devcell.s6-svscan";
      ProgramArguments = [
        "${pkgs.s6}/bin/s6-svscan"
        "/etc/s6/services"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/var/log/devcell-s6-svscan.log";
      StandardErrorPath = "/var/log/devcell-s6-svscan.log";
    };
  };

  # Enable macOS Screen Sharing via ARD auth (username/password).
  # Uses the devcell user's macOS credentials (set in preActivation).
  # Works with macOS Screen Sharing and Royal TSX.
  system.activationScripts.postActivation.text = ''
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
      -activate -configure -access -on \
      -restart -agent -privs -all \
      -allowAccessFor -allUsers 2>/dev/null || true

    # Grant tart-guest-agent screen capture and microphone TCC permissions so
    # it can share the VM display without an interactive consent dialog.
    AGENT=$(command -v tart-guest-agent 2>/dev/null \
      || { [ -x /usr/local/bin/tart-guest-agent ] && echo /usr/local/bin/tart-guest-agent; } \
      || { find /usr/local /opt/homebrew -name tart-guest-agent -type f 2>/dev/null | head -1; })
    if [ -n "$AGENT" ]; then
      TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
      for SVC in kTCCServiceScreenCapture kTCCServiceMicrophone kTCCServiceListenEvent; do
        sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('$SVC', '$AGENT', 1, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, CAST(strftime('%s','now') AS INTEGER));" 2>/dev/null \
          && echo "TCC: granted $SVC to $AGENT" \
          || echo "TCC: failed to grant $SVC to $AGENT (SIP may block writes)"
      done
    else
      echo "TCC: tart-guest-agent not found, skipping permission grants"
    fi
  '';

  # Required for nix-darwin
  system.stateVersion = 5;
}
