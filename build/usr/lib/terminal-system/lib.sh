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

TS_DANGER_PATTERNS=(
    '(^|[[:space:]])rm[[:space:]]+-[a-z]*r[a-z]*f[a-z]*[[:space:]]+/[[:space:]]*$'
    '(^|[[:space:]])rm[[:space:]]+-[a-z]*f[a-z]*r[a-z]*[[:space:]]+/[[:space:]]*$'
    '(^|[[:space:]])rm[[:space:]]+-[a-z]*r[a-z]*f[a-z]*[[:space:]]+/\*'
    '(^|[[:space:]])rm[[:space:]]+-[a-z]*f[a-z]*r[a-z]*[[:space:]]+/\*'
    '(^|[[:space:]])mkfs(\.[a-zA-Z0-9]+)?[[:space:]]'
    '(^|[[:space:]])dd[[:space:]].*of=/dev/'
    ':\(\)[[:space:]]*\{[[:space:]]*:\|:\&[[:space:]]*\}[[:space:]]*\;[[:space:]]*:'
    '(^|[[:space:]])chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/[[:space:]]*$'
    '(^|[[:space:]])(shutdown|reboot|halt|poweroff)([[:space:]]|$)'
    '(^|[[:space:]])killall[[:space:]]+-9([[:space:]]|$)'
    '(userdel|groupdel)[[:space:]].*[[:space:]](root|sudo|admin)([[:space:]]|$)'
    '(^|[[:space:]])iptables[[:space:]]+-F([[:space:]]|$)'
    '>[[:space:]]*/dev/sd[a-z][0-9]*([[:space:]]|$)'
)

ts_is_dangerous_command() {
    local cmd="$1" p
    for p in "${TS_DANGER_PATTERNS[@]}"; do
        [[ "$cmd" =~ $p ]] && return 0
    done
    return 1
}

TS_SYSTEM_PROMPT="Sei un traduttore da istruzioni in linguaggio naturale a comandi shell per Debian/Ubuntu Linux. Rispondi SOLO con i comandi shell necessari, uno per riga, senza spiegazioni, senza markdown, senza backtick. Se serve piu' di un comando per completare l'istruzione, elencali in ordine, uno per riga."

ts_call_engine() {
    local engine="$1" prompt="$2" bin out rc tmpfile
    bin="$(ts_resolve_bin "$engine")" || return 1

    case "$engine" in
        claude)
            out="$("$bin" -p --disallowedTools "*" --system-prompt "$TS_SYSTEM_PROMPT" -- "$prompt" 2> /dev/null)"
            rc=$?
            ;;
        codex)
            tmpfile="$(mktemp)"
            "$bin" exec -s read-only --output-last-message "$tmpfile" -- "$TS_SYSTEM_PROMPT
$prompt" > /dev/null 2>&1
            rc=$?
            out="$(cat "$tmpfile" 2> /dev/null)"
            rm -f "$tmpfile"
            ;;
        *)
            return 1
            ;;
    esac

    [ $rc -eq 0 ] && [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
}
