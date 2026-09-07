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
    '>[[:space:]]*/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|xvd[a-z][0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?|mmcblk[0-9]+(p[0-9]+)?)([[:space:]]|$)'
)

ts_rm_root_dangerous() {
    local cmd="$1" words=() i word flags="" target=""
    read -r -a words <<< "$cmd"
    for ((i = 0; i < ${#words[@]}; i++)); do
        [ "${words[$i]}" = "rm" ] || continue
        for ((i = i + 1; i < ${#words[@]}; i++)); do
            word="${words[$i]}"
            [ "$word" = "--" ] && continue
            if [[ "$word" == -* ]]; then
                flags+="$word"
                continue
            fi
            target="$word"
            break
        done
        [[ "$flags" == *r* && "$flags" == *f* ]] || return 1
        [[ "$target" = "/" || "$target" = "/*" ]] && return 0
        return 1
    done
    return 1
}

ts_chmod_root_dangerous() {
    local cmd="$1" words=() i word recursive=0 mode="" target=""
    read -r -a words <<< "$cmd"
    for ((i = 0; i < ${#words[@]}; i++)); do
        [ "${words[$i]}" = "chmod" ] || continue
        for ((i = i + 1; i < ${#words[@]}; i++)); do
            word="${words[$i]}"
            if [[ "$word" == -* ]]; then
                [[ "$word" == *R* ]] && recursive=1
                continue
            fi
            if [ -z "$mode" ]; then
                mode="$word"
                continue
            fi
            target="$word"
            break
        done
        [ "$recursive" -eq 1 ] && [ "$mode" = "777" ] && [ "$target" = "/" ] && return 0
        return 1
    done
    return 1
}

ts_is_dangerous_command() {
    local cmd="$1" p
    ts_rm_root_dangerous "$cmd" && return 0
    ts_chmod_root_dangerous "$cmd" && return 0
    for p in "${TS_DANGER_PATTERNS[@]}"; do
        [[ "$cmd" =~ $p ]] && return 0
    done
    return 1
}

TS_SYSTEM_PROMPT="You translate natural-language instructions into shell commands for Debian/Ubuntu Linux. Reply ONLY with the required shell commands, one per line, with no explanations, no markdown, and no backticks. If more than one command is needed, list them in order, one per line."

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
            "$bin" exec -s read-only --skip-git-repo-check --output-last-message "$tmpfile" -- "$TS_SYSTEM_PROMPT
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
    TS_HISTORY+=("instruction: ${instruction}
commands:
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
        printf 'Previous session context:\n%s\nCurrent instruction: %s\n' "$ctx" "$instruction"
    else
        printf 'Current instruction: %s\n' "$instruction"
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

ts_focus_pane() {
    tmux select-pane -t "$1" > /dev/null 2>&1 || true
}

ts_command_needs_input() {
    local cmd="$1"
    [[ "$cmd" =~ (^|[[:space:]\;\&\|])sudo([[:space:]]|$) ]] && return 0
    [[ "$cmd" =~ (^|[[:space:]\;\&\|])(su|passwd|ssh|scp|sftp|ftp|mysql|psql)([[:space:]]|$) ]] && return 0
    [[ "$cmd" =~ (^|[[:space:]\;\&\|])(nano|vim|vi|less|more|man|top|htop)([[:space:]]|$) ]] && return 0
    [[ "$cmd" =~ (^|[[:space:]\;\&\|])read([[:space:]]|$) ]] && return 0
    return 1
}

ts_refocus_after_signal() {
    local return_target="$1" signal="$2"
    (
        tmux wait-for "$signal" > /dev/null 2>&1 || exit 0
        ts_pane_alive "$return_target" || exit 0
        ts_focus_pane "$return_target"
    ) &
}

ts_append_refocus_signal() {
    local target="$1" signal="$2" quoted_signal suffix
    printf -v quoted_signal '%q' "$signal"
    suffix="; tmux wait-for -S $quoted_signal >/dev/null 2>&1"
    ts_type_into_pane "$target" "$suffix"
}

ts_send_enter() {
    local target="$1" cmd="${2:-}" return_target="${3:-}" signal
    if [ -z "$cmd" ]; then
        tmux send-keys -t "$target" C-m
        ts_focus_pane "$target"
    elif ts_command_needs_input "$cmd"; then
        if [ -n "$return_target" ] && ts_pane_alive "$return_target"; then
            signal="terminal-system-refocus-$$-$RANDOM"
            ts_refocus_after_signal "$return_target" "$signal"
            ts_append_refocus_signal "$target" "$signal"
        fi
        tmux send-keys -t "$target" C-m
        ts_focus_pane "$target"
    else
        tmux send-keys -t "$target" C-m
    fi
}

ts_clear_typed_line() {
    tmux send-keys -t "$1" C-u
}

ts_capture_pane_tail() {
    local target="$1" lines="${2:-20}"
    tmux capture-pane -p -t "$target" -S "-$lines"
}

ts_pane_alive() {
    local target="$1"
    case "$target" in
        %*) tmux list-panes -a -F '#{pane_id}' 2> /dev/null | grep -Fxq -- "$target" ;;
        *)  tmux display-message -p -t "$target" '#{pane_id}' > /dev/null 2>&1 ;;
    esac
}

ts_pane_shell_name() {
    tmux display-message -p -t "$1" '#{pane_current_command}' 2> /dev/null
}

ts_wait_pane_idle() {
    local target="$1" shell_name="$2" timeout="${3:-30}" i
    for ((i = 0; i < timeout * 10; i++)); do
        ts_pane_alive "$target" || return 1
        [ "$(ts_pane_shell_name "$target")" = "$shell_name" ] && return 0
        sleep 0.1
    done
    return 1
}

ts_confirm_and_send() {
    local target="$1" cmd="$2" return_target="${3:-}" reply edited
    while true; do
        TS_CONFIRMED_COMMAND="$cmd"
        printf '[CONFIRM] %s\n' "$cmd"
        printf 'enter = run, e = edit, n = cancel: '
        if ! IFS= read -r reply || [ "$reply" = "n" ] || [ "$reply" = "N" ]; then
            ts_clear_typed_line "$target"
            return 1
        fi
        case "$reply" in
            e|E|m|M)
                ts_clear_typed_line "$target"
                printf 'edit command: '
                if [ -t 0 ]; then
                    IFS= read -e -i "$cmd" -r edited || return 1
                else
                    IFS= read -r edited || return 1
                fi
                [ -n "$edited" ] || return 1
                cmd="$edited"
                TS_CONFIRMED_COMMAND="$cmd"
                ts_type_into_pane "$target" "$cmd"
                continue
                ;;
        esac
        ts_send_enter "$target" "$cmd" "$return_target"
        return 0
    done
}

ts_auto_send() {
    local target="$1" delay="${2:-0.3}" cmd="${3:-}" return_target="${4:-}"
    sleep "$delay"
    ts_send_enter "$target" "$cmd" "$return_target"
}
