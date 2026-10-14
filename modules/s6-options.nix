# s6-options.nix — declare devcell.s6.services option
#
# Each module registers its s6 services by adding entries to this attrset.
# The s6-linux-renderer.nix and s6-darwin-renderer.nix collect all registered
# services and compile them into the s6-rc database, replacing the old
# glob-everything-under-modules/s6/ approach.
#
# This ensures services are only included when their owning module is enabled.
{ lib, ... }: {
  options.devcell.s6.services = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = {};
    description = ''
      s6-rc service directories to include in the compiled database.
      Keys are service names, values are paths to the service directory.
      The "user" bundle is generated automatically from all registered services.
    '';
  };
}
