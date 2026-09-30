# community-home

The shared Nix home environment for [devcell](https://github.com/DimmKirr/devcell) cells. This flake defines what a cell's `$HOME` contains: shells, editors, language toolchains, CLI tools, and the entrypoint glue that adapts it all to the container user at startup.

The layout maps to how devcell composes environments. `modules/` holds toggleable capabilities (go, node, infra, graphics, vm, and so on), `stacks/` combines them into the image variants a cell can be built from, and `hosts/` carries the host-specific bits. `packages/` is for things nixpkgs doesn't have or has wrong.

devcell consumes this repo as a flake input: `github:devcell-sh/community-home` is the default when a cell has no local nixhome configured (override with `DEVCELL_NIXHOME_PATH` or the `[nix].nixhome` TOML key). You can also point home-manager at it directly; nothing in here is devcell-specific except the entrypoint.

```nix
inputs.community-home.url = "github:devcell-sh/community-home";
```

Choose `stack = "ultimate"` for general development, cloud tools, browser
automation and desktop support. Choose `stack = "bbb"` to add
the specialist tools formerly bundled with ultimate: electronics/KiCad,
Wine/Winetricks, QEMU, Swift, publishing, security/reverse engineering,
Inkscape/GIMP and their MCPs, FFmpeg/yt-dlp, Kitty, wxWidgets, the FreeRDP client, the GTK4/WebKitGTK
development stack for Wails 3/native UI builds, VPN tooling, and personal-service
MCPs (social, travel, news, Plex and chat-completion providers).

`bbb` includes ultimate. Migrating an existing project that needs the previous
tool selection only requires changing `[cell] stack = "bbb"` and rebuilding.
Individual capability modules can also be added with `[cell] modules = [...]`.
For a custom Nix composition, `devcell.modules.graphics.inkscape.enable = true`
adds Inkscape back to ultimate. GIMP uses `devcell.modules.graphics.gimp.enable`;
native UI headers use `devcell.modules.desktop.nativeUi.enable`, and FreeRDP
uses `devcell.modules.desktop.rdpClient.enable`. These remain enabled by default
in the standalone graphics/desktop modules. Kitty and wxWidgets use
`devcell.modules.desktop.kitty.enable` and `devcell.modules.desktop.wxWidgets.enable`.
FFmpeg, yt-dlp, the optional Iosevka/Cascadia Code fonts and `terraform-plugin-docs` are selected
by `bbb`. MailSlurp and its MCP registration come from `qa-tools`, also in `bbb`.
Draw.io desktop and its Electron runtime also live in `bbb`, controlled by
`devcell.modules.graphics.drawio.enable`. Lightweight XML-to-PNG export belongs
to the `drawio-diagram` skill and reuses Chromium; no exporter npm dependency is
added to the stack.
General `terraform-docs`, AWS tools, XTerm and VNC/RDP servers remain in ultimate.
Other applications retain needed runtime libraries.

Interactive Chromium and Patchright automation share the browser from
`playwright-driver.browsers`. The `chromium` command keeps its interactive profile,
extension and CDP flags; it no longer adds a separate `pkgs.chromium` distribution.
The current pinned bundle reports Chromium 141; the previous interactive build
reported 149. Browser version updates now need to update the shared bundle.

The stack split changes future builds; it does not clean the shared Nix store
or alter running containers. `task test:stacks` checks package/MCP boundaries,
all stack variants, and that OCI layer hints cannot add unselected packages.
