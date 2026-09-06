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

ts_parse_commands() {
    local raw="$1" cleaned line out=() wc
    if grep -q '^```' <<< "$raw"; then
        cleaned="$(sed -n '/^```/,/^```/{//!p}' <<< "$raw")"
    else
        cleaned="$raw"
    fi

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        wc=$(wc -w <<< "$line")
        if [ "$wc" -gt 12 ]; then
            printf '%s\n' "$raw"
            return 2
        fi
        out+=("$line")
    done <<< "$cleaned"

    if [ "${#out[@]}" -eq 0 ]; then
        printf '%s\n' "$raw"
        return 2
    fi

    printf '%s\n' "${out[@]}"
    return 0
}

TS_HISTORY=()
TS_HISTORY_MAX="${TS_HISTORY_MAX:-5}"

ts_history_append() {
    local instruction="$1" commands="$2" output="$3"
    TS_HISTORY+=("istruzione: ${instruction}
comandi:
${commands}
output:
${output}")
    if [ "${#TS_HISTORY[@]}" -gt "$TS_HISTORY_MAX" ]; then
        TS_HISTORY=("${TS_HISTORY[@]: -$TS_HISTORY_MAX}")
    fi
}

ts_history_context() {
    local entry
    for entry in "${TS_HISTORY[@]:-}"; do
        [ -z "$entry" ] && continue
        printf '%s\n---\n' "$entry"
    done
}

ts_build_prompt() {
    local instruction="$1" ctx
    ctx="$(ts_history_context)"
    if [ -n "$ctx" ]; then
        printf 'Contesto sessione precedente:\n%s\nIstruzione attuale: %s\n' "$ctx" "$instruction"
    else
        printf 'Istruzione attuale: %s\n' "$instruction"
    fi
}

ts_type_into_pane() {
    local target="$1" cmd="$2" delay="${3:-0.004}" i char
    for ((i = 0; i < ${#cmd}; i++)); do
        char="${cmd:$i:1}"
        [ "$char" = ';' ] && char='\;'
        tmux send-keys -t "$target" -l -- "$char"
        sleep "$delay"
    done
}

ts_send_enter() {
    tmux send-keys -t "$1" C-m
}

ts_clear_typed_line() {
    tmux send-keys -t "$1" C-u
}

ts_capture_pane_tail() {
    local target="$1" lines="${2:-20}"
    tmux capture-pane -p -t "$target" -S "-$lines"
}

ts_confirm_and_send() {
    local target="$1" cmd="$2" reply
    printf '[CONFERMA] %s\n' "$cmd"
    printf 'invio = esegui, n = annulla: '
    if ! IFS= read -r reply || [ "$reply" = "n" ] || [ "$reply" = "N" ]; then
        ts_clear_typed_line "$target"
        return 1
    fi
    ts_send_enter "$target"
    return 0
}

ts_auto_send() {
    local target="$1" delay="${2:-0.3}"
    sleep "$delay"
    ts_send_enter "$target"
}
