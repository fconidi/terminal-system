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
        [ "$recursive" -eq 1 ] && [ -n "$mode" ] && [ "$target" = "/" ] && return 0
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

# Auto-mode's real gate: a denylist can only ever catch the destructive
# patterns someone thought to list (see TS_DANGER_PATTERNS above, and the
# 2026-09-07 review that walked past all of them with `/bin/rm -rf /`,
# `bash -c 'rm -rf /'`, `find / -delete`, `curl URL | sh`, etc). This is an
# allowlist instead: auto-mode only skips confirmation for a command whose
# first word is a known read-only program AND that carries none of the
# shell metacharacters (redirects, pipes, substitution, chaining,
# backgrounding) that would let a "safe" command smuggle an arbitrary one.
# Everything not explicitly recognized here still stops for confirmation.
ts_is_safe_readonly_command() {
    local cmd="$1" words=() base sub w
    [[ "$cmd" =~ [\<\>\|\`\;\&] ]] && return 1
    [[ "$cmd" == *'$('* ]] && return 1
    read -r -a words <<< "$cmd"
    [ "${#words[@]}" -eq 0 ] && return 1
    base="${words[0]##*/}"
    case "$base" in
        find)
            for w in "${words[@]}"; do
                case "$w" in -delete | -exec | -execdir | -fprintf | -fls | -ok | -okdir) return 1 ;; esac
            done
            return 0
            ;;
        git)
            sub="${words[1]:-}"
            case "$sub" in status | log | diff | show | branch | remote | describe | blame | shortlog) return 0 ;; *) return 1 ;; esac
            ;;
        systemctl)
            sub="${words[1]:-}"
            case "$sub" in status | is-active | is-enabled | is-failed | list-units | list-unit-files | show | cat) return 0 ;; *) return 1 ;; esac
            ;;
        journalctl)
            for w in "${words[@]}"; do
                case "$w" in --vacuum* | --flush | --sync | --rotate) return 1 ;; esac
            done
            return 0
            ;;
        dpkg)
            sub="${words[1]:-}"
            case "$sub" in -l | --list | -s | --status | -L | --listfiles | -S | --search) return 0 ;; *) return 1 ;; esac
            ;;
        apt | apt-get)
            sub="${words[1]:-}"
            case "$sub" in list | search | show | policy) return 0 ;; *) return 1 ;; esac
            ;;
        date)
            for w in "${words[@]:1}"; do
                case "$w" in -s | --set | --set=*) return 1 ;; esac
            done
            return 0
            ;;
        hostname)
            for w in "${words[@]:1}"; do
                [[ "$w" == -* ]] && continue
                return 1
            done
            return 0
            ;;
        tail)
            for w in "${words[@]:1}"; do
                case "$w" in -f | -F | --follow | --follow=*) return 1 ;; esac
            done
            return 0
            ;;
        ls | cat | grep | egrep | fgrep | head | wc | ps | df | du | free | uptime | whoami | id | pwd | uname | which | type | stat | file | tree | lsblk | lscpu | lsusb | lspci | printenv | history | echo | printf | w | who | last)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Best-effort only: catches common accidental leaks (plaintext secrets in
# command output, API keys with a recognizable prefix) before pane output
# is stored as AI context. Not a DLP system -- it will not catch everything,
# and reviewing :context show before relying on it is the user's job.
ts_redact_secrets() {
    sed -E \
        -e 's/\b(AKIA[0-9A-Z]{16})\b/[REDACTED-AWS-KEY]/g' \
        -e 's/\b(gh[pousr]_[A-Za-z0-9]{20,})\b/[REDACTED-TOKEN]/g' \
        -e 's/\b(xox[baprs]-[A-Za-z0-9-]{10,})\b/[REDACTED-TOKEN]/g' \
        -e 's/\b(sk-[A-Za-z0-9_-]{16,})\b/[REDACTED-KEY]/g' \
        -e 's/([Bb]earer)[[:space:]]+[A-Za-z0-9._-]+/\1 [REDACTED]/g' \
        -e 's/([Pp]assword|[Pp]asswd|[Ss]ecret|[Tt]oken|[Aa]pi[_-]?[Kk]ey)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/g'
}

# The "never use printf/echo ... cosmetic section header" clause exists
# because, for a multi-part instruction (e.g. "show me kernel, uptime,
# memory, disk, network, and upgradable packages"), the model likes to
# organize the reply as one "printf 'header'; actual-command" line per
# section. On roughly 1 in 3-4 such replies it drops the separator between
# the printf call and the command that follows it on the same line (e.g.
# "uname -aprintf '\n=== Uptime ===\n'", reproduced repeatedly 2026-09-08,
# including against a real live terminal-system session, not just direct
# API calls) -- silently producing one broken, glued-together shell line
# that then runs whatever garbage that glue happened to form. An earlier
# attempt just asked for headers on their own line instead of banning them;
# that measurably helped but did not eliminate the glueing, because the
# header-then-command adjacency itself is what triggers it, on the same line
# or the next. Banning cosmetic headers removes the adjacency entirely
# (10/10 clean runs against the same instruction after this change, vs.
# frequent glueing before) at the cost of losing the nicely labeled
# multi-section output -- a deliberate trade for not risking a garbled
# command reaching a real shell.
TS_SYSTEM_PROMPT="You translate natural-language instructions into shell commands for Debian/Ubuntu Linux. Reply ONLY with the required shell commands, one per line, with no explanations, no markdown, and no backticks. Each line must be exactly one standalone command. Never use printf/echo purely to print a cosmetic section header or label -- if the instruction asks for several kinds of information, just list the actual commands to gather each one, in order, with no header lines and no chaining ';'/'&&' between them. If more than one command is needed, list them in order, one per line."

# No forced default model: measured (2026-09-07, 5+5 interleaved runs) haiku
# averaging 15.18s vs 10.86s for the CLI's own default on this setup -- the
# assumption that a lighter model would be faster did not hold here. Left
# overridable via env var for anyone who wants to test their own setup.
TS_CLAUDE_MODEL="${TS_CLAUDE_MODEL:-}"
TS_CODEX_MODEL="${TS_CODEX_MODEL:-}"

ts_call_engine() {
    local engine="$1" prompt="$2" bin out rc tmpfile model_args=()
    bin="$(ts_resolve_bin "$engine")" || return 1

    case "$engine" in
        claude)
            [ -n "$TS_CLAUDE_MODEL" ] && model_args=(--model "$TS_CLAUDE_MODEL")
            out="$("$bin" -p --disallowedTools "*" "${model_args[@]}" --system-prompt "$TS_SYSTEM_PROMPT" -- "$prompt" 2> /dev/null)"
            rc=$?
            ;;
        codex)
            [ -n "$TS_CODEX_MODEL" ] && model_args=(--model "$TS_CODEX_MODEL")
            tmpfile="$(mktemp)"
            "$bin" exec -s read-only --skip-git-repo-check "${model_args[@]}" --output-last-message "$tmpfile" -- "$TS_SYSTEM_PROMPT
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
# Opt-in: left-panel output can contain secrets, file contents, or anything
# else a command printed. Off by default -- nothing is kept as AI context,
# or sent in a future prompt, unless the user turns it on with :context on.
TS_CONTEXT_ENABLED="${TS_CONTEXT_ENABLED:-0}"

ts_history_append() {
    [ "$TS_CONTEXT_ENABLED" -eq 1 ] || return 0
    local instruction="$1" commands="$2" output="$3"
    output="$(ts_redact_secrets <<< "$output")"
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
    # tmux's own CLI parser treats a trailing, unescaped ";" at the end of a
    # send-keys -l argument as a command separator and swallows it (verified:
    # embedded ";" mid-argument is always safe; only a ";" that is the last
    # character of the argument needs the \; escape).
    #
    # This used to split $cmd into small chunks and send each with its own
    # `tmux send-keys` call plus a short sleep, for a typewriter effect. That
    # fired 20+ separate tmux-client processes per long AI-generated command
    # (e.g. "printf ...; uname -a; printf ...; uptime; ..." from a "show me
    # everything" instruction), and reproduced empirically (2026-09-08): past
    # some point in that rapid-fire sequence, tmux's pane state and the typed
    # text desync -- a chunk boundary landing mid-command drops the text
    # already typed and silently reproduces the whole thing on a fresh
    # prompt, with no separator between the two commands that happened to
    # meet at that boundary. Sending the whole string in one `send-keys -l`
    # call (verified 5/5 against real tmux on a 272-char multi-command
    # string) does not hit this -- there is no longer a mid-string boundary
    # for it to happen at. Only the escape for a trailing ";" on the full
    # string remains necessary (verified separately).
    local target="$1" cmd="$2"
    [[ "$cmd" == *\; ]] && cmd="${cmd%;}\\;"
    tmux send-keys -t "$target" -l -- "$cmd"
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

# Polls tmux's own idea of the pane's foreground process rather than an
# in-band completion marker: a marker means appending `; echo $? > file;
# tmux wait-for -S sig` to every single command before it's typed, which
# would permanently clutter every line the user sees in the left panel just
# to close a theoretical race. Empirically (2026-09-07, 5/5 trials against a
# real tmux 3.5a server, `sleep 2`) a single sample never read "idle" early.
# Two consecutive idle samples, 100ms apart, are required before declaring
# done, so a lone transient misread can't cause a false-idle -- cheap
# insurance against the case the empirical test didn't happen to hit,
# without paying for it on every command.
ts_wait_pane_idle() {
    local target="$1" shell_name="$2" timeout="${3:-30}" i confirmations=0
    for ((i = 0; i < timeout * 10; i++)); do
        ts_pane_alive "$target" || return 1
        if [ "$(ts_pane_shell_name "$target")" = "$shell_name" ]; then
            confirmations=$((confirmations + 1))
            [ "$confirmations" -ge 2 ] && return 0
        else
            confirmations=0
        fi
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
