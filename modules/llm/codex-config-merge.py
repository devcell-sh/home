"""Merge staged DevCell configuration without losing Codex's user-owned tables.

Both s6 and the legacy entrypoint call this packaged helper. It only writes the
candidate output; callers back up the target and atomically replace it on success.
"""

import os
import re
import sys
import tomllib
from pathlib import Path

import tomli_w


ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:-|-)([^}]*))?\}")


def read_config(path):
    try:
        return tomllib.loads(Path(path).read_text())
    except FileNotFoundError:
        return {}


def server_config(name, server, enabled):
    server = dict(server)
    server["enabled"] = server.get("enabled", False) or name in enabled
    env = {}
    forwarded = list(server.get("env_vars", []))
    missing = set()

    def expand(match):
        variable, operator, default = match.groups()
        value = os.environ.get(variable)
        if operator == ":-" and not value:
            return default
        if operator == "-" and value is None:
            return default
        if value is None:
            missing.add(variable)
            return ""
        return value

    for key, value in server.get("env", {}).items():
        # Native forwarding reads credentials at server launch, keeps missing
        # servers visible, and avoids freezing tokens in config.toml.
        match = ENV_REF.fullmatch(value)
        if match and match.group(1) == key and match.group(2) is None:
            if key not in forwarded:
                forwarded.append(key)
            if not os.environ.get(key):
                missing.add(key)
        else:
            # Aliases (NOTION_TOKEN <- NOTION_API_KEY) and shell-style defaults
            # are resolved at activation. Never evaluate the value as shell code.
            env[key] = ENV_REF.sub(expand, value)
    if "env" in server:
        server["env"] = env
    if forwarded:
        server["env_vars"] = forwarded
    if missing:
        print(f"Codex MCP {name}: missing {', '.join(sorted(missing))}; "
              "definition retained", file=sys.stderr)
    return server


def merge(nix, providers, existing):
    merged = dict(existing)
    managed_names = set(nix.get("devcellManagedServers", []))
    enabled = set(filter(None, os.environ.get("DEVCELL_MCP_ENABLED", "").split(",")))
    cleaned = {
        name: server for name, server in existing.get("mcp_servers", {}).items()
        if name not in managed_names
        and not server.get("command", "").startswith(("/opt/devcell/", "/nix/store/"))
    }
    managed = {
        name: server_config(name, server, enabled)
        for name, server in nix.get("mcp_servers", {}).items()
    }
    merged["mcp_servers"] = {**cleaned, **managed}
    if providers.get("model_providers"):
        merged["model_providers"] = {
            **existing.get("model_providers", {}), **providers["model_providers"]
        }
    return merged


def main():
    nix_path, providers_path, target_path, output_path = sys.argv[1:]
    merged = merge(read_config(nix_path), read_config(providers_path), read_config(target_path))
    result = tomli_w.dumps(merged)
    # Catch serialization loss before the caller replaces the user's file.
    if tomllib.loads(result) != merged:
        raise ValueError("Codex config failed TOML round-trip validation")
    Path(output_path).write_text(result)


if __name__ == "__main__":
    main()
