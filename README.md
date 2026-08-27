# community-home

The shared Nix home environment for [devcell](https://github.com/DimmKirr/devcell) cells. This flake defines what a cell's `$HOME` contains: shells, editors, language toolchains, CLI tools, and the entrypoint glue that adapts it all to the container user at startup.

The layout maps to how devcell composes environments. `modules/` holds toggleable capabilities (go, node, infra, graphics, vm, and so on), `stacks/` combines them into the image variants a cell can be built from, and `hosts/` carries the host-specific bits. `packages/` is for things nixpkgs doesn't have or has wrong.

devcell consumes this repo as a flake input: `github:devcell-sh/community-home` is the default when a cell has no local nixhome configured (override with `DEVCELL_NIXHOME_PATH` or the `[nix].nixhome` TOML key). You can also point home-manager at it directly; nothing in here is devcell-specific except the entrypoint.

```nix
inputs.community-home.url = "github:devcell-sh/community-home";
```
