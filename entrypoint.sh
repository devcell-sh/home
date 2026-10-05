#!/bin/bash
# Minimal container init — notify host, stay alive for docker exec.
#
# All bootstrap logic lives in s6 oneshot services (modules/s6/).
# The CLI runs s6 activation via docker exec, then attaches the agent.

notify() {
    [ -n "$DEVCELL_BOOT_DIR" ] && [ -d "$DEVCELL_BOOT_DIR" ] || return 0
    touch "$DEVCELL_BOOT_DIR/$1" 2>/dev/null || true
}

notify container.ready
exec sleep infinity
