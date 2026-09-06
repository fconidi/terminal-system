#!/bin/bash
# terminal-system/build/usr/lib/terminal-system/lib.sh
# Shared functions for terminal-system and ts-brain. Sourced, not executed.

ts_resolve_bin() {
    local name="$1" p
    p="$(command -v "$name" 2> /dev/null)" && { echo "$p"; return 0; }
    for p in "$HOME/.local/bin/$name" "$HOME"/.nvm/versions/node/*/bin/"$name"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

ts_pick_engine() {
    local requested="$1" other
    case "$requested" in
        claude) other=codex ;;
        codex)  other=claude ;;
        *) return 1 ;;
    esac
    if ts_resolve_bin "$requested" > /dev/null 2>&1; then
        echo "$requested"; return 0
    fi
    if ts_resolve_bin "$other" > /dev/null 2>&1; then
        echo "$other"; return 0
    fi
    return 1
}
