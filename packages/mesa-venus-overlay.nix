# Mesa overlay: apply the Venus 16 KiB alignment patch for libkrun/krunkit
# GPU passthrough on Apple Silicon.
#
# Only affects aarch64-linux builds (the guest arch inside krunkit VMs).
# x86_64-linux and darwin builds get stock Mesa unchanged.
#
# Once upstream merges VIRTIO_GPU_F_BLOB_ALIGNMENT (kernel + Mesa), this
# overlay can be removed.
final: prev: {
  mesa = prev.mesa.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./mesa-venus-16k-align.patch
    ];
  });
}
