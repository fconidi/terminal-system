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
    local requested="$1" e candidates=()
    case "$requested" in
        claude) candidates=(codex agy) ;;
        codex)  candidates=(claude agy) ;;
        agy)    candidates=(claude codex) ;;
        *) return 1 ;;
    esac
    if ts_resolve_bin "$requested" > /dev/null 2>&1; then
        echo "$requested"; return 0
    fi
    for e in "${candidates[@]}"; do
        if ts_resolve_bin "$e" > /dev/null 2>&1; then
            echo "$e"; return 0
        fi
    done
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
    local cmd="$1" words=() i word flags="" targets=()
    read -r -a words <<< "$cmd"
    for ((i = 0; i < ${#words[@]}; i++)); do
        [ "${words[$i]##*/}" = "rm" ] || continue
        for ((i = i + 1; i < ${#words[@]}; i++)); do
            word="${words[$i]}"
            [ "$word" = "--" ] && continue
            if [[ "$word" == -* ]]; then
                flags+="$word"
            else
                targets+=("$word")
            fi
        done
        [[ "$flags" == *r* && "$flags" == *f* ]] || return 1
        for word in "${targets[@]}"; do
            [[ "$word" = "/" || "$word" = "/*" ]] && return 0
        done
        return 1
    done
    return 1
}

ts_chmod_root_dangerous() {
    local cmd="$1" words=() i word recursive=0 mode="" targets=()
    read -r -a words <<< "$cmd"
    for ((i = 0; i < ${#words[@]}; i++)); do
        [ "${words[$i]##*/}" = "chmod" ] || continue
        for ((i = i + 1; i < ${#words[@]}; i++)); do
            word="${words[$i]}"
            if [[ "$word" == -* ]]; then
                [[ "$word" == *R* ]] && recursive=1
                continue
            fi
            if [ -z "$mode" ]; then
                mode="$word"
            else
                targets+=("$word")
            fi
        done
        [ "$recursive" -eq 1 ] && [ -n "$mode" ] || return 1
        for word in "${targets[@]}"; do
            [ "$word" = "/" ] && return 0
        done
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
    # ${name:=word} / ${name=word} assign name as a side effect of expansion --
    # e.g. `echo ${PROMPT_COMMAND:=rm -rf /tmp/x}` reads as pure output but sets
    # PROMPT_COMMAND, which bash then runs unattended at the next prompt. This
    # is the only parameter-expansion form that mutates state; :-/:+/:? do not.
    [[ "$cmd" =~ \$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?:?=[^=] ]] && return 1
    read -r -a words <<< "$cmd"
    [ "${#words[@]}" -eq 0 ] && return 1
    base="${words[0]##*/}"
    # Require a bare command name resolved from PATH -- an explicit path
    # (/tmp/evil/ls, ./cat) would let an attacker-planted binary masquerade
    # as a trusted name and run unconfirmed.
    [ "${words[0]}" != "$base" ] && return 1
    case "$base" in
        find)
            for w in "${words[@]}"; do
                case "$w" in -delete | -exec | -execdir | -fprintf | -fprint | -fprint0 | -fls | -ok | -okdir) return 1 ;; esac
            done
            return 0
            ;;
        git)
            # log/diff/show excluded: they render diffs/blobs and can invoke a
            # repo- or user-configured core.pager, diff.external, or textconv
            # filter -- arbitrary local exec if that config is compromised.
            sub="${words[1]:-}"
            case "$sub" in status | branch | remote | describe | blame | shortlog) return 0 ;; *) return 1 ;; esac
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
        printf)
            # -v writes the result into an arbitrary named variable instead of
            # printing it (e.g. `printf -v PROMPT_COMMAND '...'` -- same
            # unattended-exec-at-next-prompt trick as the ${var:=} case above).
            for w in "${words[@]:1}"; do
                case "$w" in -v*) return 1 ;; esac
            done
            return 0
            ;;
        history)
            # Bare/numeric listing only -- `-w [file]`, `-r [file]` etc. read
            # or overwrite arbitrary files.
            for w in "${words[@]:1}"; do
                case "$w" in -*) return 1 ;; esac
            done
            return 0
            ;;
        ls | cat | grep | egrep | fgrep | head | wc | ps | df | du | free | uptime | whoami | id | pwd | uname | which | type | stat | file | tree | lsblk | lscpu | lsusb | lspci | printenv | echo | w | who | last)
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
TS_SYSTEM_PROMPT="You translate natural-language instructions into shell commands for Linux (the Environment block in the request describes the actual system; assume Debian/Ubuntu if it is missing). Reply ONLY with a JSON object, no markdown, no backticks: {\"commands\":[{\"cmd\":\"<one standalone shell command>\",\"why\":\"<one short sentence saying what it does>\",\"risk\":\"low|medium|high\"}]}. risk is low for read-only or harmless commands, medium for reversible changes to files, packages or services, high for anything destructive, irreversible, or affecting disks, boot, users, firewall or network access. Each cmd must be exactly one standalone command. Never use printf/echo purely to print a cosmetic section header or label -- if the instruction asks for several kinds of information, just list the actual commands to gather each one, in order, with no header lines and no chaining ';'/'&&' between them. If more than one command is needed, list them in order."

# No forced default model: measured (2026-09-07, 5+5 interleaved runs) haiku
# averaging 15.18s vs 10.86s for the CLI's own default on this setup -- the
# assumption that a lighter model would be faster did not hold here. Left
# overridable via env var for anyone who wants to test their own setup.
TS_CLAUDE_MODEL="${TS_CLAUDE_MODEL:-}"
TS_CODEX_MODEL="${TS_CODEX_MODEL:-}"
TS_AGY_MODEL="${TS_AGY_MODEL:-}"

ts_call_engine() {
    local engine="$1" prompt="$2" system_prompt="${3:-$TS_SYSTEM_PROMPT}" bin out rc tmpfile model_args=()
    bin="$(ts_resolve_bin "$engine")" || return 1

    case "$engine" in
        claude)
            [ -n "$TS_CLAUDE_MODEL" ] && model_args=(--model "$TS_CLAUDE_MODEL")
            out="$("$bin" -p --disallowedTools "*" "${model_args[@]}" --system-prompt "$system_prompt" -- "$prompt" 2> /dev/null)"
            rc=$?
            ;;
        codex)
            [ -n "$TS_CODEX_MODEL" ] && model_args=(--model "$TS_CODEX_MODEL")
            tmpfile="$(mktemp)" || return 1
            "$bin" exec -s read-only --skip-git-repo-check "${model_args[@]}" --output-last-message "$tmpfile" -- "$system_prompt
$prompt" > /dev/null 2>&1
            rc=$?
            out="$(cat "$tmpfile" 2> /dev/null)"
            rm -f "$tmpfile"
            ;;
        agy)
            [ -n "$TS_AGY_MODEL" ] && model_args=(--model "$TS_AGY_MODEL")
            out="$("$bin" -p "$system_prompt

$prompt" --disable-slash-commands "${model_args[@]}" 2> /dev/null)"
            rc=$?
            ;;
        *)
            return 1
            ;;
    esac

    [ $rc -eq 0 ] && [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
}

# Structured replies: {"commands":[{"cmd":..,"why":..,"risk":..}]}.
# Fills TS_PARSED (one command per line) plus TS_WHY / TS_RISK, keyed by the
# command text. Not for use in a subshell. Returns:
#   0 = valid JSON with commands, 1 = not JSON at all (caller falls back to
#   the line parser), 2 = JSON but unusable (empty / no commands).
# Needs python3; without it the reply is treated as "not JSON" (rc 1).
declare -A TS_WHY=() TS_RISK=()
TS_PARSED=""
ts_parse_structured() {
    local raw="$1" out cmd risk why
    TS_PARSED=""; TS_WHY=(); TS_RISK=()
    command -v python3 > /dev/null 2>&1 || return 1
    out="$(python3 -I -c '
import json, sys
raw = sys.stdin.read()
a, b = raw.find("{"), raw.rfind("}")
if a < 0 or b <= a:
    sys.exit(3)
try:
    data = json.loads(raw[a:b + 1])
except Exception:
    sys.exit(3)
items = data.get("commands") if isinstance(data, dict) else None
if not isinstance(items, list):
    sys.exit(2)
def clean(v):
    return " ".join(str(v).split()) if v is not None else ""
n = 0
for it in items:
    if isinstance(it, str):
        it = {"cmd": it}
    if not isinstance(it, dict):
        continue
    cmd = clean(it.get("cmd"))
    if not cmd:
        continue
    risk = clean(it.get("risk")).lower()
    if risk not in ("low", "medium", "high"):
        risk = ""
    print("\t".join([cmd, risk, clean(it.get("why"))]))
    n += 1
sys.exit(0 if n else 2)
' <<< "$raw")"
    case $? in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
    while IFS=$'\t' read -r cmd risk why; do
        [ -z "$cmd" ] && continue
        TS_PARSED+="$cmd"$'\n'
        [ -n "$risk" ] && TS_RISK["$cmd"]="$risk"
        [ -n "$why" ] && TS_WHY["$cmd"]="$why"
    done <<< "$out"
    TS_PARSED="${TS_PARSED%$'\n'}"
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
# Not env-overridable on purpose: ts-brain resets this at the start of every
# session, so an ambient env var could never enable it silently either way.
TS_CONTEXT_ENABLED=0

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

# Facts about the left panel's environment, sent with every request so the
# model stops guessing the package manager, the working directory or
# whether the panel is really a local shell. Deliberately limited to
# non-secret facts (distro, user, cwd, git branch, foreground program);
# no pane output is included here -- that stays behind :context on.
ts_env_context() {
    local target="${1:-}" distro="" user cwd="" fg="" branch="" shell_name=""
    if [ -r /etc/os-release ]; then
        distro="$(. /etc/os-release 2> /dev/null && printf '%s' "${PRETTY_NAME:-}")"
    fi
    user="$(id -un 2> /dev/null)"
    [ "$(id -u 2> /dev/null)" = "0" ] && user="$user (root)"
    if [ -n "$target" ]; then
        cwd="$(tmux display-message -p -t "$target" '#{pane_current_path}' 2> /dev/null)"
        fg="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2> /dev/null)"
    fi
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
        branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2> /dev/null)"
    fi
    shell_name="${SHELL##*/}"
    printf 'Environment:\n'
    [ -n "$distro" ] && printf -- '- system: %s\n' "$distro"
    [ -n "$user" ] && printf -- '- user: %s\n' "$user"
    [ -n "$cwd" ] && printf -- '- working directory: %s\n' "$cwd"
    [ -n "$branch" ] && printf -- '- git branch: %s\n' "$branch"
    [ -n "$shell_name" ] && printf -- '- shell: %s\n' "$shell_name"
    case "$fg" in
        ""|bash|zsh|sh|dash|fish|ksh) ;;
        *) printf -- '- the left panel is currently running "%s" (it may be a remote or interactive session, not a plain local shell)\n' "$fg" ;;
    esac
}

# Exit status that means "this command failed" for diagnosis purposes.
# 130 is the user's own Ctrl-C; 1 from grep/diff/cmp/test just means
# "no match" / "differs" / "false", which is an answer, not an error.
ts_rc_is_failure() {
    local cmd="$1" rc="$2" first
    [[ "$rc" =~ ^[0-9]+$ ]] || return 1
    [ "$rc" -eq 0 ] && return 1
    [ "$rc" -eq 130 ] && return 1
    first="${cmd%%[[:space:]]*}"
    first="${first##*/}"
    if [ "$rc" -eq 1 ]; then
        case "$first" in
            grep|egrep|fgrep|rgrep|zgrep|diff|cmp|test|"[") return 1 ;;
        esac
    fi
    return 0
}

TS_FIX_SYSTEM_PROMPT="A shell command typed into a Linux terminal failed. Using the Environment block, the command, its exit status and the last lines of terminal output, reply with: (1) one or two lines starting with '# ' that state the most likely cause in plain words, then (2) only if a fix exists, the shell command(s) that fix it, one standalone command per line, no markdown, no backticks, no chaining with ';' or '&&'. If you cannot tell the cause, say so in the '# ' line and give no command. Never repeat the failed command unchanged."

ts_build_fix_prompt() {
    local cmd="$1" rc="$2" output="$3" env
    env="$(ts_env_context "${TS_TARGET:-}")"
    [ -n "$env" ] && printf '%s\n' "$env"
    printf 'Failed command: %s\nExit status: %s\nLast terminal output:\n%s\n' "$cmd" "$rc" "$output"
}

# Splits a diagnosis reply into explanation ('# ' lines) and fix commands
# (everything else, validated by ts_parse_commands). Results go in globals
# (TS_FIX_EXPLANATION, TS_FIX_COMMANDS) so callers must not run this in a
# subshell. Returns 0, or 2 if the non-'#' text is not a usable command list.
TS_FIX_EXPLANATION=""
TS_FIX_COMMANDS=""
ts_parse_fix() {
    local raw="$1" line explain="" body="" prc
    TS_FIX_COMMANDS=""; TS_WHY=(); TS_RISK=()
    while IFS= read -r line; do
        case "$line" in
            "# "*|"#") explain+="${line#\#}"$'\n' ;;
            *) body+="$line"$'\n' ;;
        esac
    done <<< "$raw"
    TS_FIX_EXPLANATION="$(sed -E 's/^[[:space:]]+//' <<< "$explain")"
    if [ -z "${body//[[:space:]]/}" ]; then
        return 0
    fi
    TS_FIX_COMMANDS="$(ts_parse_commands "$body")"; prc=$?
    [ "$prc" -eq 0 ] || TS_FIX_COMMANDS=""
    return "$prc"
}

ts_build_prompt() {
    local instruction="$1" ctx env
    ctx="$(ts_history_context)"
    env="$(ts_env_context "${TS_TARGET:-}")"
    [ -n "$env" ] && printf '%s\n' "$env"
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
    # A literal CR or LF inside $cmd would submit the line early once typed
    # (canonical tty line discipline ends a line on \n, and translates \r to
    # \n on input by default) -- executing a truncated command in the target
    # pane before the caller's own confirm-then-Enter step ever runs. Neither
    # character can be a legitimate part of a single shell command line here.
    cmd="${cmd//$'\r'/}"
    cmd="${cmd//$'\n'/}"
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
        # Unbounded wait, deliberately: this only blocks past the target
        # pane's natural lifetime if that pane was killed before the appended
        # "tmux wait-for -S" suffix ever ran, and it is bounded by the tmux
        # *session's* lifetime regardless -- the server hangs up on this
        # client (making `wait-for` return) once the session it belongs to
        # ends. A tried fix that killed the waiter after a timeout was
        # reverted: killing this backgrounded job's PID does not reliably
        # reach the actual `tmux` client process across all invocation paths
        # (verified against this project's own test harness, which runs
        # `tmux` as a shell function -- killing the wrapper job it creates
        # orphans the real client instead of stopping it), so the added
        # complexity bought correctness only in the common case while
        # behaving unpredictably outside it.
        tmux wait-for "$signal" > /dev/null 2>&1 || exit 0
        ts_pane_alive "$return_target" || exit 0
        ts_focus_pane "$return_target"
    ) &
}

# Name of the tmux global variable that carries a command's exit status
# from the left panel back to ts-brain (signal names contain "-", which is
# not a valid variable name).
ts_rc_var() {
    printf 'TS_RC_%s' "${1//[^A-Za-z0-9]/_}"
}

# Prints the exit status recorded for $signal and removes the variable.
# Prints nothing (rc 1) if none was recorded.
ts_read_rc() {
    local var out
    var="$(ts_rc_var "$1")"
    out="$(tmux show-environment -g "$var" 2> /dev/null)" || return 1
    tmux set-environment -gu "$var" > /dev/null 2>&1
    [[ "$out" == "$var="* ]] || return 1
    printf '%s\n' "${out#"$var="}"
}

# Shell snippet that stores "$?" (the exit status of the command typed just
# before it) and then fires the completion signal. "$?" must be read first:
# any command in between would overwrite it.
ts_signal_suffix() {
    local signal="$1" record_rc="${2:-1}" quoted_signal var
    printf -v quoted_signal '%q' "$signal"
    if [ "$record_rc" = "1" ]; then
        var="$(ts_rc_var "$signal")"
        printf '; tmux set-environment -g %s "$?" >/dev/null 2>&1; tmux wait-for -S %s >/dev/null 2>&1' "$var" "$quoted_signal"
    else
        printf '; tmux wait-for -S %s >/dev/null 2>&1' "$quoted_signal"
    fi
}

ts_append_refocus_signal() {
    local target="$1" signal="$2" record_rc="${3:-1}"
    ts_type_into_pane "$target" "$(ts_signal_suffix "$signal" "$record_rc")"
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
            ts_append_refocus_signal "$target" "$signal" 0
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

# Superseded 2026-09-16: this used to poll tmux's idea of the pane's
# foreground process (`#{pane_current_command}` == shell_name, two
# consecutive samples 100ms apart) to decide a command had finished. That
# reading is ambiguous -- it's identical whether the command already
# finished OR hasn't been picked up by the shell yet, and the first sample
# was taken with zero delay after Enter was sent. Under real scheduling
# load (verified: 12-core CPU saturation, 210 trials) that ambiguity let
# the NEXT command in the queue get typed while the previous one's Enter
# hadn't been consumed yet, landing on the same still-open input line with
# no separator -- e.g. "lscpu" + "free -h" + "lspci -nnk | grep ..." glued
# into "lscpufree -hlspci -nnk | grep ...", which bash then ran as one
# broken command. Measured glue rate ~1% per command pair (2/210) under
# load, reproducing 5/5 with the same shape as the field report. Replaced
# by ts_wait_for_signal below (0/210 in the same stress test): an in-band
# completion marker removes the ambiguity by construction instead of
# shrinking the race window.

# Blocks until the in-band marker fires, or `seconds` elapses. Unlike
# polling pane_current_command, there is no "hasn't started yet" vs
# "already finished" ambiguity: the signal can only fire once the shell has
# actually run the marked command to completion.
ts_wait_for_signal() {
    local signal="$1" seconds="${2:-120}"
    timeout "$seconds" tmux wait-for "$signal" > /dev/null 2>&1
}

# Builds "cmd; tmux wait-for -S signal" as ONE string for ts_type_into_pane.
# Measured (2026-09-16, paired same-load runs, production 0.3s pre-Enter
# delay): appending the marker as a SECOND, separate send-keys call after
# cmd was already typed measured a *higher* glue rate (up to ~2-5% under an
# aggressive synthetic delay) than the pre-existing poll-based bug -- it
# reintroduces the same rapid-consecutive-send-keys desync already fixed
# once in ts_type_into_pane's own history (see its comment above). Typing
# cmd and the marker together in a single send-keys call measured 0/350
# glued at production timing, matching that same one-call fix.
ts_marked_command() {
    local cmd="$1" signal="$2"
    printf '%s%s' "$cmd" "$(ts_signal_suffix "$signal")"
}

TS_EXPLAIN_SYSTEM_PROMPT="You explain a Linux shell command to the person about to run it. In at most four short plain sentences say what it does, what each important option or part means, and anything risky or irreversible about it. No markdown, no backticks."

TS_EXPLAIN_RESULT_PROMPT="You explain the result of a Linux shell command to the person who ran it. You get the command and the terminal output that followed. In at most five short plain sentences say what the command did, what the output means, and, if it shows an error, the likely cause and the next thing to try. No markdown, no backticks."

# Asks the engine to explain a command (used by "?" in the confirm step).
ts_explain_command() {
    local cmd="$1" out
    if [ -z "${TS_ENGINE:-}" ]; then
        echo "(no AI engine available for an explanation)"
        return 0
    fi
    if out="$(ts_call_engine "$TS_ENGINE" "$(ts_env_context "${TS_TARGET:-}")
Command: $cmd" "$TS_EXPLAIN_SYSTEM_PROMPT")"; then
        printf '%s\n' "$out"
    else
        echo "(the AI engine did not respond)"
    fi
}

ts_confirm_and_send() {
    local target="$1" cmd="$2" return_target="${3:-}" signal="${4:-}" reply edited code=""
    # High-risk commands (rated high by the AI, or matching the local
    # dangerous-pattern list) cannot be run by a stray Enter: the short
    # code shown must be typed.
    if [ "${TS_RISK[$cmd]:-}" = "high" ] || ts_is_dangerous_command "$cmd"; then
        code="$(printf '%04x' $((RANDOM % 65536)))"
    fi
    while true; do
        TS_CONFIRMED_COMMAND="$cmd"
        printf '[CONFIRM] %s\n' "$cmd"
        if [ -n "${TS_WHY[$cmd]:-}" ] || [ -n "${TS_RISK[$cmd]:-}" ]; then
            printf '   %s%s\n' "${TS_WHY[$cmd]:-}" "${TS_RISK[$cmd]:+  [risk: ${TS_RISK[$cmd]}]}"
        fi
        if [ -n "$code" ]; then
            printf 'HIGH RISK -- type %s to run, e = edit, ? = explain, n = cancel: ' "$code"
        else
            printf 'enter = run, e = edit, ? = explain, n = cancel: '
        fi
        if ! IFS= read -r reply || [ "$reply" = "n" ] || [ "$reply" = "N" ]; then
            ts_clear_typed_line "$target"
            return 1
        fi
        case "$reply" in
            \?)
                ts_explain_command "$cmd"
                continue
                ;;
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
                code=""
                if [ "${TS_RISK[$cmd]:-}" = "high" ] || ts_is_dangerous_command "$cmd"; then
                    code="$(printf '%04x' $((RANDOM % 65536)))"
                fi
                continue
                ;;
        esac
        if [ -n "$code" ] && [ "$reply" != "$code" ]; then
            echo "not confirmed: type $code exactly to run this command."
            continue
        fi
        # Appending the marker onto whatever's already on the line (rather
        # than clearing and retyping cmd+marker together) is safe here
        # specifically because there's always a real pause since that text
        # was typed -- the operator's own [CONFIRM]/edit reply, which never
        # arrives in under the scheduling-latency window that makes a
        # zero-gap double send-keys risky (see ts_auto_send/ts_marked_command
        # above, where cmd and marker ARE combined into one call: there, the
        # only gap is a fixed 0.3s delay with no guarantee anything else
        # settled first).
        [ -n "$signal" ] && ts_append_refocus_signal "$target" "$signal"
        ts_send_enter "$target" "$cmd" "$return_target"
        return 0
    done
}

ts_auto_send() {
    local target="$1" delay="${2:-0.3}" cmd="${3:-}" return_target="${4:-}" signal="${5:-}"
    if [ -n "$signal" ]; then
        # Unlike the plain (no-signal) path below, this types cmd itself --
        # callers must not pre-type cmd when passing a signal.
        ts_type_into_pane "$target" "$(ts_marked_command "$cmd" "$signal")"
        sleep "$delay"
        ts_send_enter "$target" "$cmd" "$return_target"
        return
    fi
    sleep "$delay"
    ts_send_enter "$target" "$cmd" "$return_target"
}

# ---- :follow (closed loop) -------------------------------------------------

TS_FOLLOW_MAX="${TS_FOLLOW_MAX:-5}"

TS_FOLLOW_SYSTEM_PROMPT="You work toward a goal in a Linux terminal, one step at a time. You are given the Environment, the goal, and the steps already done with the terminal output they produced. Reply with EITHER the next shell command(s), one standalone command per line, no markdown, no backticks, no chaining with ';' or '&&', OR, when the goal is reached or cannot be reached, the single word DONE on the first line followed by one or two lines starting with '# ' that summarize the result or the blocker. Prefer one command per step so its output can be checked. Never repeat a command that already ran with the same result."

# $1 goal, $2 steps log (may be empty)
ts_build_follow_prompt() {
    local goal="$1" steps="$2" env
    env="$(ts_env_context "${TS_TARGET:-}")"
    [ -n "$env" ] && printf '%s\n' "$env"
    printf 'Goal: %s\n' "$goal"
    if [ -n "$steps" ]; then
        printf 'Steps done so far:\n%s\n' "$steps"
    else
        printf 'No steps done yet.\n'
    fi
}

# Parses a :follow reply. Sets TS_FOLLOW_DONE (0/1), TS_FOLLOW_SUMMARY and
# TS_FOLLOW_COMMANDS. Returns 2 when the reply is neither DONE nor a usable
# command list. Not for use in a subshell.
TS_FOLLOW_DONE=0
TS_FOLLOW_SUMMARY=""
TS_FOLLOW_COMMANDS=""
ts_parse_follow() {
    local raw="$1" first prc
    TS_FOLLOW_DONE=0; TS_FOLLOW_SUMMARY=""; TS_FOLLOW_COMMANDS=""; TS_WHY=(); TS_RISK=()
    first="$(grep -m1 -v '^[[:space:]]*$' <<< "$raw")"
    first="${first//[[:space:]]/}"
    if [ "$first" = "DONE" ]; then
        TS_FOLLOW_DONE=1
        TS_FOLLOW_SUMMARY="$(grep -E '^[[:space:]]*#' <<< "$raw" | sed -E 's/^[[:space:]]*#[[:space:]]?//')"
        return 0
    fi
    TS_FOLLOW_COMMANDS="$(ts_parse_commands "$raw")"; prc=$?
    [ "$prc" -eq 0 ] || TS_FOLLOW_COMMANDS=""
    return "$prc"
}

# ---- :watch (passive observer) ---------------------------------------------

TS_WATCH_QUIET="${TS_WATCH_QUIET:-2}"
TS_WATCH_MAX_WAIT="${TS_WATCH_MAX_WAIT:-5}"
TS_WATCH_MIN_INTERVAL="${TS_WATCH_MIN_INTERVAL:-10}"

TS_WATCH_SYSTEM_PROMPT="You watch the output of a Linux terminal and help the person using it in real time. You never run anything. You are given the Environment and the latest terminal output. If something went wrong (an error, a failed command, a warning that matters), say in one or two short lines what happened and, if there is a fix, give the exact command on its own line starting with '\$ '. If the output is routine and nothing needs attention, reply with exactly the single word OK. Reply in the language named in the Environment block. No markdown, no backticks."

# Reads stdin; succeeds if the text looks like a problem worth an AI call.
ts_looks_like_problem() {
    grep -Eiq \
        -e 'command not found' -e 'permission denied' -e 'no such file or directory' \
        -e 'not permitted' -e 'cannot (open|access|find|stat|create|remove|execute)' \
        -e 'unable to' -e 'could not' -e "couldn't" -e 'failed' -e 'failure' \
        -e '(^|[^a-z])error([^a-z]|$)' -e 'fatal' -e 'traceback' -e 'segmentation fault' \
        -e 'no space left' -e 'connection (refused|timed out|reset)' -e 'timed out' \
        -e 'unknown (command|option)' -e 'invalid (option|argument|syntax)' -e 'syntax error' \
        -e 'denied' -e 'unreachable' -e 'not found' -e 'broken' -e 'unmet dependencies' \
        -e '^E: ' -e 'exit(ed)? (status|code) [1-9]'
}

# $1 old snapshot file, $2 new snapshot file: prints the lines of $2 that
# are not in $1 (order kept).
ts_new_lines() {
    diff --old-line-format='' --unchanged-line-format='' --new-line-format='%L' "$1" "$2" 2> /dev/null
    return 0
}

# $1 target pane, $2 lines: redacted tail of the pane, 32 KiB at most.
ts_watch_snapshot() {
    tmux capture-pane -p -t "$1" -S "-${2:-120}" 2> /dev/null | ts_redact_secrets | tail -c 32768
}

ts_pane_in_alt_screen() {
    [ "$(tmux display-message -p -t "$1" '#{alternate_on}' 2> /dev/null)" = "1" ]
}

# ---- waiting for a command: prompts, long runs, notifications --------------

TS_MAX_WAIT="${TS_MAX_WAIT:-1800}"          # give up waiting after this many seconds
TS_STATUS_AFTER="${TS_STATUS_AFTER:-10}"    # first "still running" line after this many seconds
TS_STATUS_EVERY="${TS_STATUS_EVERY:-30}"    # then one every this many seconds
TS_NOTIFY_AFTER="${TS_NOTIFY_AFTER:-15}"    # bell + tmux message when a command ran at least this long

# Succeeds, printing the line, if the last non-empty lines of the pane look
# like a program waiting for the user: a yes/no question, a password or
# passphrase prompt, "Continue?", a pager.
ts_pane_awaiting_input() {
    local line
    line="$(tmux capture-pane -p -t "$1" 2> /dev/null | grep -v '^[[:space:]]*$' | tail -n 1)"
    [ -n "$line" ] || return 1
    if grep -Eiq \
        -e '\[[yn]/[yn]\]' -e '\((y/n|yes/no)' -e '\[(yes|no)/(yes|no)\]' \
        -e 'pass(word|phrase)[^:]*:[[:space:]]*$' -e '(continue|proceed|overwrite|replace)[^?]*\?[[:space:]]*(\[.*\])?[[:space:]]*$' \
        -e 'are you sure' -e '^\(END\)' -e '^--More--' -e '^:$' \
        -e 'enter (a |the |your )?[a-z ]+:[[:space:]]*$' \
        <<< "$line"; then
        printf '%s\n' "$line"
        return 0
    fi
    return 1
}

# Waits for the in-band completion signal of a command typed in the left
# panel. Unlike a single blocking wait:
#  - if the command stops at a prompt (yes/no, password, pager) focus moves
#    to the left panel so it can be answered there, and comes back after;
#  - long commands print a "still running" line now and then, and ring the
#    bell / show a tmux message when they finish;
#  - Ctrl-C in this panel stops the waiting (the command keeps running).
# Sets TS_WAIT_REASON to "timeout" or "interrupted" when returning 1.
TS_WAIT_REASON=""
ts_wait_command() {
    local signal="$1" cmd="$2" target="${3:-${TS_TARGET:-}}" back="${4:-${TS_OPERATOR:-}}"
    local start=$SECONDS elapsed next_status line last_prompt="" focused=0 got=0 interrupted=0
    TS_WAIT_REASON=""
    next_status=$((start + TS_STATUS_AFTER))
    trap 'interrupted=1' INT
    while true; do
        if timeout 0.5 tmux wait-for "$signal" > /dev/null 2>&1; then
            got=1
            break
        fi
        if [ "$interrupted" -eq 1 ]; then
            TS_WAIT_REASON="interrupted"
            break
        fi
        elapsed=$((SECONDS - start))
        if [ "$elapsed" -ge "$TS_MAX_WAIT" ]; then
            TS_WAIT_REASON="timeout"
            break
        fi
        if line="$(ts_pane_awaiting_input "$target")"; then
            if [ "$line" != "$last_prompt" ]; then
                last_prompt="$line"
                focused=1
                ts_focus_pane "$target"
                echo "   waiting for your input in the left panel: $line"
            fi
        else
            last_prompt=""
        fi
        if [ "$SECONDS" -ge "$next_status" ]; then
            line="$(tmux capture-pane -p -t "$target" 2> /dev/null | grep -v '^[[:space:]]*$' | tail -n 1)"
            echo "   still running (${elapsed}s): ${line:0:100}   [Ctrl-C here stops waiting]"
            next_status=$((SECONDS + TS_STATUS_EVERY))
        fi
    done
    trap - INT
    if [ "$focused" -eq 1 ] && [ -n "$back" ] && ts_pane_alive "$back"; then
        ts_focus_pane "$back"
    fi
    if [ "$got" -eq 1 ]; then
        elapsed=$((SECONDS - start))
        if [ "$elapsed" -ge "$TS_NOTIFY_AFTER" ]; then
            echo "   finished after ${elapsed}s"
            printf '\a'
            tmux display-message -d 5000 -t "${TS_SESSION:-$target}" "terminal-system: finished after ${elapsed}s: ${cmd:0:60}" > /dev/null 2>&1
        fi
        return 0
    fi
    return 1
}

ts_wait_stopped_message() {
    case "$TS_WAIT_REASON" in
        interrupted) echo "-> stopped waiting; the command may still be running in the left panel. Check it, then re-issue the rest." ;;
        *) echo "-> still running after ${TS_MAX_WAIT}s; stopping here so later commands aren't typed over it. Check the left panel, then re-issue the rest." ;;
    esac
}
