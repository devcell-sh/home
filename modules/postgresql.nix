# postgresql.nix — PostgreSQL server (standalone, not imported by any stack)
# Import this module into a stack when you need a local PostgreSQL instance.
# s6 services auto-start PostgreSQL, create the data dir and default database.
{pkgs, config, lib, ...}: let
  cfg = config.devcell.modules.postgresql;
in {
  options.devcell.modules.postgresql = {
    enable = lib.mkEnableOption "Standalone PostgreSQL 17 instance (s6 auto-starts + initdb)";
    meta = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        description = "Local PostgreSQL 17 — s6-managed, default db created";
        mcpServers = [ ];
        sizeMb = 60;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    devcell.s6.services = {
      postgres       = ./s6/postgres;
      postgres-init  = ./s6/postgres-init;
      postgres-setup = ./s6/postgres-setup;
    };

    home.packages = [
      pkgs.postgresql  # PostgreSQL 17 (use: psql, pg_ctl, initdb)
    ];
  };
}
