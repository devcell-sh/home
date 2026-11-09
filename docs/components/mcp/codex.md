# Codex MCP configuration

## Connections

Domain modules register servers in `devcell.managedMcp.servers`.
`modules/llm/codex.nix` converts the same inventory used by Claude into
`/etc/codex/nix-mcp-servers.toml`. Both stdio and HTTP entries are retained.

The `codex-config` s6 service calls `devcell-codex-config-merge`, packaged by
`codex.nix` from `codex-config-merge.py`. The legacy `30-codex.sh` entrypoint calls
the same helper. It writes a candidate file; the caller replaces
`~/.codex/config.toml` only after a successful merge and TOML validation.

`mcp-toggle` applies the Nix enablement defaults and `DEVCELL_MCP_ENABLED` from
`.devcell.toml`'s `[mcp] enabled` list. Definitions remain visible when disabled.
OAuth login and credentials are separate from inventory and enablement.

## Environment handling

- `TOKEN = "${TOKEN}"` becomes native `env_vars = ["TOKEN"]`. Codex reads the
  value at launch; missing credentials never remove the server definition.
- `${VAR:-default}` uses the default when VAR is absent or empty.
- `${VAR-default}` uses the default only when VAR is absent.
- Renamed variables, such as `NOTION_TOKEN = "${NOTION_API_KEY}"`, and embedded
  substitutions resolve during activation. Re-activate after changing these
  values. A missing value produces an empty substitution and a warning naming
  the variable, never its contents. Values are never executed as shell code.
- Unrelated user tables, including nested project, plugin and provider settings,
  survive the merge. TOML formatting/comments may change.
- TUI preferences, including `tui.alternate_screen`, belong to the user in
  `~/.codex/config.toml`. They are neither generated nor overridden. Leaving a
  preference unset preserves Codex's default behavior.

## Upgrade checks

Run `task test:codex` after editing the Codex version or either platform hash.
The suite also runs under `task test:unit`, included in CI's `task test`.

| Level | Check | Typical cost |
|---|---|---|
| Static | Nix and shell syntax | Seconds |
| Merge | Both startup callers, missing env/defaults, nested settings, repeat activation, failed writes | Seconds |
| Package | Build pinned CLI/helper, compare generated Claude/Codex inventories, load both transports with `codex mcp list --json` | Seconds cached; minutes on first download |

The fixture evaluates the production Nix modules and uses the pinned binary,
not an unrelated CLI from PATH. Changing the version therefore changes the test
artifact. Tests use an isolated Codex home and do not start MCP processes,
authenticate, exercise OAuth, or validate remote-service availability.

## Drift points

- The executable pin and both npm archive hashes must agree.
- The generated inventory must contain every registered server.
- Both startup paths must call the packaged helper; do not add inline mergers.
- `env_vars`, HTTP fields and enablement must survive the pinned CLI's parsing.
- Local source changes require a rebuilt image to update staged `/etc` files and
  startup services. Repairing a user's config alone does not update image startup.
