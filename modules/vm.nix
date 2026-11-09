# vm — QEMU virtualisation and disk-image tooling
{pkgs, pkgsEdge, config, lib, ...}: let
  cfg = config.devcell.modules.vm;

  vmapplePatches = [
    ./vm-patches/0001-hw-vmapple-run-VMApple-guests-under-TCG.patch
    ./vm-patches/0002-target-arm-add-an-apple-m1-CPU-model-for-VMApple-gue.patch
    ./vm-patches/0003-target-arm-serve-VMApple-s-PAC-hypercalls-under-TCG-.patch
    ./vm-patches/0004-target-arm-kvm-run-VMApple-guests-under-KVM.patch
  ];

  # Use pkgsEdge to check arch — avoids infinite recursion with nixpkgs.overlays
  isAarch64Linux = pkgsEdge.stdenv.hostPlatform.isLinux && pkgsEdge.stdenv.hostPlatform.isAarch64;
in {
  options.devcell.modules.vm = {
    enable = lib.mkEnableOption "QEMU virtualisation: full system emulation (x86, ARM), disk image utilities, UEFI firmware";
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "QEMU system emulation (x86_64, aarch64), qemu-img/qemu-nbd utilities, OVMF UEFI firmware, swtpm TPM emulator, genisoimage ISO creation, vmapple KVM support (aarch64)";
        mcpServers = [];
        sizeMb = 800;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # On aarch64-linux, overlay pkgs.qemu with the vmapple-patched build
    # from nixpkgs-edge (v11.1.x, which the patches target). This makes
    # any reference to pkgs.qemu get the patched version automatically.
    nixpkgs.overlays = lib.mkIf isAarch64Linux [
      (final: prev: {
        qemu = pkgsEdge.qemu.overrideAttrs (old: {
          patches = (old.patches or []) ++ vmapplePatches;
          hostCpuTargets = [ "aarch64-softmmu" "arm-softmmu" "x86_64-softmmu" "xtensa-softmmu" "xtensaeb-softmmu" ];
        });
      })
    ];

    home.packages = with pkgs; [
      qemu
      powershell # cross-platform shell — lint and run Windows provisioning scripts on the host (use: pwsh)
      cdrkit     # ISO 9660/UDF image creation — provides genisoimage/mkisofs for building bootable ISOs (use: genisoimage)
      msitools   # Windows Installer inspection — extracts MSI payloads and tables host-side (use: msiextract, msiinfo)
      swtpm      # software TPM 2.0 emulator — required for Windows 11 guests
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      virtiofsd  # vhost-user virtio-fs daemon — shares host directories into QEMU guests (use: virtiofsd); Linux-only, macOS guests use tart/VirtioFS
    ] ++ lib.optionals pkgs.stdenv.isx86_64 [
      OVMF       # UEFI firmware for x86_64 VMs — depends on syslinux (x86-only)
    ];
  };
}
