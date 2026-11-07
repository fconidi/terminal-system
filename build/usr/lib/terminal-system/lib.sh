#!/bin/bash
# terminal-system/build/usr/lib/terminal-system/lib.sh
# Shared functions for terminal-system and ts-brain. Sourced, not executed.

ts_resolve_bin() {
    local name="$1" p
    p="$(command -v "$name" 2> /dev/null)" && { echo "$p"; return 0; }
    [ -x "$HOME/.local/bin/$name" ] && { echo "$HOME/.local/bin/$name"; return 0; }
    # Newest installed node version first (version sort, descending).
    while IFS= read -r p; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done < <(printf '%s\n' "$HOME"/.nvm/versions/node/*/bin/"$name" | sort -rV)
    return 1
}

TS_ENGINES=(claude codex agy)

ts_pick_engine() {
    local requested="$1" e
    case " ${TS_ENGINES[*]} " in
        *" $requested "*) ;;
        *) return 1 ;;
    esac
    if ts_resolve_bin "$requested" > /dev/null 2>&1; then
        echo "$requested"; return 0
    fi
    for e in "${TS_ENGINES[@]}"; do
        [ "$e" = "$requested" ] && continue
        if ts_resolve_bin "$e" > /dev/null 2>&1; then
            echo "$e"; return 0
        fi
    done
    return 1
}

# Text of a command with quoting removed, so that `rm -rf '/'`, `rm -rf "/"`
# and `rm -rf \/` are judged like `rm -rf /`.
ts_unquote() {
    local s="$1"
    s="${s//\'/}"
    s="${s//\"/}"
    s="${s//\\/}"
    s="${s//\$\{HOME\}/\$HOME}"
    printf '%s' "$s"
}

TS_DANGER_PATTERNS=(
    '(^|[[:space:];&|])mkfs(\.[a-zA-Z0-9]+)?([[:space:]]|$)'
    '(^|[[:space:];&|])mke2fs([[:space:]]|$)'
    '(^|[[:space:];&|])dd[[:space:]].*of=(/dev/|\$)'
    ':\(\)[[:space:]]*\{[[:space:]]*:\|:\&[[:space:]]*\}[[:space:]]*\;[[:space:]]*:'
    '(^|[[:space:];&|])(shutdown|reboot|halt|poweroff)([[:space:]]|$)'
    '(^|[[:space:];&|])killall[[:space:]]+-9([[:space:]]|$)'
    '(userdel|groupdel)[[:space:]].*[[:space:]](root|sudo|admin)([[:space:]]|$)'
    '(^|[[:space:];&|])iptables[[:space:]]+-F([[:space:]]|$)'
    '>[[:space:]]*/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?|mmcblk[0-9]+(p[0-9]+)?)([[:space:]]|$)'
    '(^|[[:space:];&|])(wipefs|shred|blkdiscard|zerofree|mkswap|hdparm)[[:space:]].*/dev/'
    '(^|[[:space:];&|])cryptsetup[[:space:]]+(luksFormat|erase|luksErase|luksKillSlot|reencrypt)'
    '(^|[[:space:];&|])(cp|mv|install|rsync|tee|cat)[[:space:]].*[[:space:]>]/dev/(sd[a-z]|vd[a-z]|xvd[a-z]|hd[a-z]|nvme[0-9]|mmcblk[0-9])'
    '\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(sh|bash|zsh|dash|ksh|python3?|perl|ruby)([[:space:]]|$)'
    '(^|[[:space:];&|])mv[[:space:]].*[[:space:]]/dev/null([[:space:]]|$)'
    '>>?[[:space:]]*/etc/(passwd|shadow|group|sudoers|fstab)([[:space:]]|$)'
)

# Targets that must never be removed recursively without the confirmation code.
ts_protected_target() {
    local t="$1"
    t="${t%/\*}"
    while [[ "$t" == */ ]]; do t="${t%/}"; done
    case "$t" in
        ""|"~"|'$HOME'|/home|/etc|/usr|/var|/boot|/bin|/sbin|/lib|/lib32|/lib64|/opt|/root|/srv|/mnt|/media|/dev|/proc|/sys|/run|/snap) return 0 ;;
    esac
    return 1
}

ts_rm_root_dangerous() {
    local cmd words=() i word flags targets=() active=0
    cmd="$(ts_unquote "$1")"
    read -r -a words <<< "$cmd"
    for ((i = 0; i <= ${#words[@]}; i++)); do
        word="${words[$i]:-}"
        if [ "$active" -eq 1 ]; then
            case "$word" in
                ""|";"|"&&"|"||"|"|"|"&")
                    if [[ "$flags" == *r* || "$flags" == *R* || "$flags" == *recursive* ]]; then
                        for word in "${targets[@]}"; do
                            ts_protected_target "$word" && return 0
                        done
                    fi
                    active=0
                    continue
                    ;;
                --) continue ;;
                -*) flags+="$word"; continue ;;
                *) targets+=("$word"); continue ;;
            esac
        fi
        if [ "${word##*/}" = "rm" ]; then
            active=1; flags=""; targets=()
        fi
    done
    return 1
}

ts_chmod_root_dangerous() {
    local cmd words=() i word recursive=0 targets=() active=0 seen_mode=0 name
    cmd="$(ts_unquote "$1")"
    read -r -a words <<< "$cmd"
    for ((i = 0; i <= ${#words[@]}; i++)); do
        word="${words[$i]:-}"
        if [ "$active" -eq 1 ]; then
            case "$word" in
                "" | ";" | "&&" | "||" | "|" | "&")
                    if [ "$recursive" -eq 1 ]; then
                        for word in "${targets[@]}"; do
                            ts_protected_target "$word" && return 0
                        done
                    fi
                    active=0
                    continue
                    ;;
                --recursive) recursive=1; continue ;;
                -*)
                    [[ "$word" == -*R* ]] && recursive=1
                    continue
                    ;;
                *)
                    # The first plain word is the mode (chmod) or owner (chown/chgrp).
                    if [ "$seen_mode" -eq 0 ]; then seen_mode=1; else targets+=("$word"); fi
                    continue
                    ;;
            esac
        fi
        name="${word##*/}"
        case "$name" in
            chmod | chown | chgrp) active=1; recursive=0; targets=(); seen_mode=0 ;;
        esac
    done
    return 1
}

# Disk partitioners are only dangerous when they write; listing is fine.
ts_disk_tool_dangerous() {
    local cmd="$1"
    [[ "$cmd" =~ (^|[[:space:];\&|])(fdisk|sfdisk|cfdisk|parted|gdisk|sgdisk|partprobe)[[:space:]] ]] || return 1
    [[ "$cmd" =~ /dev/ ]] || return 1
    [[ "$cmd" =~ [[:space:]](-l|--list|-p|--print|print|-s[[:space:]]+[^[:space:]]*print)([[:space:]]|$) ]] && return 1
    return 0
}

ts_is_dangerous_command() {
    local cmd p
    cmd="$(ts_unquote "$1")"
    ts_rm_root_dangerous "$1" && return 0
    ts_chmod_root_dangerous "$1" && return 0
    ts_disk_tool_dangerous "$cmd" && return 0
    for p in "${TS_DANGER_PATTERNS[@]}"; do
        [[ "$cmd" =~ $p ]] && return 0
    done
    return 1
}

# ---- text safety ------------------------------------------------------------

# True when the text holds anything a terminal or readline would act on:
# control characters (Ctrl-U, Ctrl-O, ESC...), line breaks, C1 controls,
# zero-width and bidirectional override characters.
ts_has_control_chars() {
    local s="$1"
    case "$s" in *$'\n'* | *$'\r'*) return 0 ;; esac
    printf '%s' "$s" | LC_ALL=C grep -q -P '[\x01-\x1f\x7f]|\xc2[\x80-\x9f]|\xe2\x80[\x8b-\x8f\xa8-\xae]|\xe2\x81[\xa6-\xa9]|\xef\xbb\xbf'
}

# Filter for text that came from an AI or a terminal and is about to be
# printed: removes escape sequences and other characters a terminal would
# interpret, so it cannot redraw or fake the interface.
ts_clean_text() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' \
        | LC_ALL=C sed -E -e 's/\xc2[\x80-\x9f]//g' -e 's/\xe2\x80[\x8b-\x8f\xa8-\xae]//g' \
              -e 's/\xe2\x81[\xa6-\xa9]//g' -e 's/\xef\xbb\xbf//g'
}

# ---- auto-mode allowlist ----------------------------------------------------
#
# Auto-mode skips confirmation only for a command that (1) starts with a
# known read-only program, (2) uses only options from that program's own
# allowlist, (3) carries none of the shell metacharacters that could chain or
# redirect, and (4) does not name a file that usually holds secrets. Anything
# else stops for confirmation.

TS_SENSITIVE_PATH='(\.ssh|\.gnupg|\.aws|\.kube|\.docker/config|\.netrc|\.npmrc|\.pgpass|\.git-credentials|/etc/shadow|/etc/gshadow|/etc/sudoers|id_(rsa|dsa|ecdsa|ed25519)|\.pem|\.key|\.p12|\.pfx|\.kdbx|(^|/)\.env|credential|passw|secret|token|private)'

# $1 regex of allowed option words; remaining arguments are the command words.
ts_opts_allowed() {
    local pattern="$1" w
    shift
    for w in "$@"; do
        [[ "$w" == -* && "$w" != "-" && "$w" != "--" ]] || continue
        [[ "$w" =~ $pattern ]] || return 1
    done
    return 0
}

# Number of words that are not options.
ts_plain_words() {
    local w n=0
    for w in "$@"; do
        [[ "$w" == -* ]] || n=$((n + 1))
    done
    printf '%s' "$n"
}

ts_is_safe_readonly_command() {
    local cmd="$1" words=() base sub w lw plain
    ts_has_control_chars "$cmd" && return 1
    [[ "$cmd" =~ [\<\>\|\`\;\&\(\)\\] ]] && return 1
    [[ "$cmd" == *'$('* ]] && return 1
    # ${name:=word} / ${name=word} assign name as a side effect of expansion.
    [[ "$cmd" =~ \$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?:?=[^=] ]] && return 1
    read -r -a words <<< "$cmd"
    [ "${#words[@]}" -eq 0 ] && return 1
    base="${words[0]##*/}"
    # A bare command name resolved from PATH only: an explicit path could be a
    # planted binary posing as a trusted name.
    [ "${words[0]}" != "$base" ] && return 1
    for w in "${words[@]:1}"; do
        lw="${w,,}"
        lw="${lw//\/etc\/passwd/}"
        [[ "$lw" =~ $TS_SENSITIVE_PATH ]] && return 1
    done
    case "$base" in
        find)
            for w in "${words[@]}"; do
                case "$w" in -delete | -exec | -execdir | -fprintf | -fprint | -fprint0 | -fls | -ok | -okdir) return 1 ;; esac
            done
            return 0
            ;;
        git)
            # log/diff/show are excluded: they can run a configured pager,
            # external diff or textconv filter.
            sub="${words[1]:-}"
            case "$sub" in
                status) ts_opts_allowed '^(-s|--short|-b|--branch|--porcelain(=v[12])?|--long|-u|--untracked-files(=.*)?|--ignored|-v|--verbose|--show-stash)$' "${words[@]:2}" ;;
                branch)
                    ts_opts_allowed '^(-a|--all|-r|--remotes|-v|-vv|--verbose|--list|-l|--show-current|--merged|--no-merged|--contains|--no-color|--color)$' "${words[@]:2}" || return 1
                    plain="$(ts_plain_words "${words[@]:2}")"
                    # A plain word would create a branch, unless it is a --list pattern.
                    [ "$plain" -eq 0 ] && return 0
                    for w in "${words[@]:2}"; do [ "$w" = "--list" ] || [ "$w" = "-l" ] && return 0; done
                    return 1
                    ;;
                remote)
                    case "${words[2]:-}" in
                        "" | -v | --verbose) [ "${#words[@]}" -le 3 ] ;;
                        get-url) [ "${#words[@]}" -le 5 ] ;;
                        *) return 1 ;;
                    esac
                    ;;
                describe) ts_opts_allowed '^(--tags|--always|--long|--abbrev=[0-9]+|--dirty|--all|--first-parent|--exact-match)$' "${words[@]:2}" ;;
                blame | shortlog) ts_opts_allowed '^-[A-Za-z0-9]+$' "${words[@]:2}" ;;
                *) return 1 ;;
            esac
            ;;
        systemctl)
            sub="${words[1]:-}"
            case "$sub" in
                status | is-active | is-enabled | is-failed | list-units | list-unit-files | show | cat)
                    ts_opts_allowed '^(--no-pager|-l|--full|--user|--system|--failed|-a|--all|--type=[a-z,]+|-t|--state=[a-z,]+|-n[0-9]*|--lines=[0-9]+|-q|--quiet|--no-legend|-p|--property=.*)$' "${words[@]:2}"
                    ;;
                *) return 1 ;;
            esac
            ;;
        journalctl)
            ts_opts_allowed '^(-n[0-9]*|--lines(=[0-9]+)?|-u|--unit(=.*)?|-b|--boot(=.*)?|-k|--dmesg|-r|--reverse|-e|--pager-end|-x|--catalog|--no-pager|-p|--priority(=.*)?|-o|--output(=.*)?|-S|--since(=.*)?|-U|--until(=.*)?|-q|--quiet|--no-hostname|-a|--all|-xe|-eu|-ex)$' "${words[@]:1}"
            ;;
        dpkg)
            sub="${words[1]:-}"
            case "$sub" in -l | --list | -s | --status | -L | --listfiles | -S | --search) ts_opts_allowed '^$' "${words[@]:2}" ;; *) return 1 ;; esac
            ;;
        apt | apt-get)
            sub="${words[1]:-}"
            case "$sub" in
                list | search | show | policy) ts_opts_allowed '^(--installed|--upgradable|-a|--all-versions|--no-pager|-q|--quiet)$' "${words[@]:2}" ;;
                *) return 1 ;;
            esac
            ;;
        date)
            ts_opts_allowed '^(-u|-R|-I(date|hours|minutes|seconds|ns)?|--utc|--universal|--rfc-email|--iso-8601(=[a-z]+)?)$' "${words[@]:1}" || return 1
            # A bare argument would set the clock; only +FORMAT is a display.
            for w in "${words[@]:1}"; do
                [[ "$w" == -* || "$w" == +* ]] || return 1
            done
            return 0
            ;;
        hostname)
            ts_opts_allowed '^(-f|-s|-i|-I|-d|-A|--fqdn|--short|--ip-address|--all-ip-addresses|--domain|--all-fqdns)$' "${words[@]:1}" || return 1
            [ "$(ts_plain_words "${words[@]:1}")" -eq 0 ]
            ;;
        tail | head)
            ts_opts_allowed '^(-[ncqv0-9+]+|--(lines|bytes|quiet|silent|verbose)(=[+0-9]+)?)$' "${words[@]:1}"
            ;;
        cat)
            ts_opts_allowed '^(-[nbsETAv]+|--(number|number-nonblank|squeeze-blank|show-all|show-ends|show-tabs|show-nonprinting))$' "${words[@]:1}"
            ;;
        wc)
            ts_opts_allowed '^(-[lwcmL]+|--(lines|words|bytes|chars|max-line-length))$' "${words[@]:1}"
            ;;
        tree)
            ts_opts_allowed '^(-[adfhLCNpusgtriFDxIP]+|--(noreport|dirsfirst|charset=[A-Za-z0-9-]+))$' "${words[@]:1}"
            ;;
        file)
            ts_opts_allowed '^(-[biLsz]+|--(brief|mime|mime-type|mime-encoding|dereference|uncompress))$' "${words[@]:1}"
            ;;
        du)
            for w in "${words[@]:1}"; do
                case "$w" in --files0-from*) return 1 ;; esac
            done
            return 0
            ;;
        last)
            for w in "${words[@]:1}"; do
                case "$w" in -f* | --file*) return 1 ;; esac
            done
            return 0
            ;;
        printf)
            # -v stores the result in a variable instead of printing it.
            for w in "${words[@]:1}"; do
                case "$w" in -v*) return 1 ;; esac
            done
            return 0
            ;;
        history)
            # Bare/numeric listing only: -w/-r read or overwrite files.
            for w in "${words[@]:1}"; do
                case "$w" in -*) return 1 ;; esac
            done
            return 0
            ;;
        ls | grep | egrep | fgrep | ps | df | free | uptime | whoami | id | pwd | uname | which | type | stat | lsblk | lscpu | lsusb | lspci | echo | w | who)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Best effort only: removes common secrets from text before it is stored or
# sent to an AI engine. It does not replace reviewing what you share.
ts_redact_secrets() {
    local script
    script="$(cat << 'SED'
/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[REDACTED-PRIVATE-KEY]
s/\b((AKIA|ASIA)[0-9A-Z]{16})\b/[REDACTED-AWS-KEY]/g
s/\b(gh[pousr]_[A-Za-z0-9]{20,})\b/[REDACTED-TOKEN]/g
s/\b(github_pat_[A-Za-z0-9_]{20,})\b/[REDACTED-TOKEN]/g
s/\b(xox[baprs]-[A-Za-z0-9-]{10,})\b/[REDACTED-TOKEN]/g
s/\b(sk-[A-Za-z0-9_-]{16,})\b/[REDACTED-KEY]/g
s/\bAIza[0-9A-Za-z_-]{30,}\b/[REDACTED-KEY]/g
s/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/[REDACTED-JWT]/g
s#://[^/@[:space:]]+:[^/@[:space:]]+@#://[REDACTED]@#g
s/(authorization|proxy-authorization|cookie|set-cookie)([[:space:]]*:[[:space:]]*).*/\1\2[REDACTED]/I
s/(bearer)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 [REDACTED]/Ig
s/(mysql[a-z]*[^|;&]*[[:space:]])-p[^[:space:]]+/\1-p[REDACTED]/I
s/([A-Za-z0-9_.-]*(pass(word|wd|phrase)?|secret|token|api[_-]?key|private[_-]?key|credential)[A-Za-z0-9_.-]*["']?[[:space:]]*[:=][[:space:]]*)("[^"]*"|'[^']*'|[^[:space:],;]+)/\1[REDACTED]/Ig
SED
)"
    sed -E "$script"
}

# The prompt bans cosmetic printf/echo section headers: asking for headers made
# the model glue a header and a command into one broken shell line.
TS_SYSTEM_PROMPT="You translate natural-language instructions into shell commands for Linux (the Environment block in the request describes the actual system; assume Debian/Ubuntu if it is missing). Reply ONLY with a JSON object, no markdown, no backticks: {\"commands\":[{\"cmd\":\"<one standalone shell command>\",\"why\":\"<one short sentence saying what it does>\",\"risk\":\"low|medium|high\"}]}. risk is low for read-only or harmless commands, medium for reversible changes to files, packages or services, high for anything destructive, irreversible, or affecting disks, boot, users, firewall or network access. Each cmd must be exactly one standalone command. Never use printf/echo purely to print a cosmetic section header or label -- if the instruction asks for several kinds of information, just list the actual commands to gather each one, in order, with no header lines and no chaining ';'/'&&' between them. If more than one command is needed, list them in order."

# No forced default model; set TS_CLAUDE_MODEL, TS_CODEX_MODEL or TS_AGY_MODEL to choose one.
TS_CLAUDE_MODEL="${TS_CLAUDE_MODEL:-}"
TS_CODEX_MODEL="${TS_CODEX_MODEL:-}"
TS_AGY_MODEL="${TS_AGY_MODEL:-}"
TS_AGY_SETTINGS='{"toolPermission":"strict","permissions":{"deny":["read_file(*)","write_file(*)","read_url(*)","execute_url(*)","command(*)","unsandboxed(*)","mcp(*)"]}}'

ts_call_engine() {
    local engine="$1" prompt="$2" system_prompt="${3:-$TS_SYSTEM_PROMPT}" bin out rc tmpfile model_args=()
    local limit="${TS_ENGINE_TIMEOUT:-120}"
    bin="$(ts_resolve_bin "$engine")" || return 1

    # Engines run from / so settings, hooks or MCP servers of whatever
    # project the terminal happens to be in are never picked up, and with a
    # time limit so a dead network cannot block the REPL forever.
    case "$engine" in
        claude)
            [ -n "$TS_CLAUDE_MODEL" ] && model_args=(--model "$TS_CLAUDE_MODEL")
            # The prompt goes through stdin, not argv, so other users cannot read it with ps.
            out="$(cd / && printf '%s' "$prompt" | timeout --foreground -k 5 "$limit" "$bin" -p --no-session-persistence --disallowedTools "*" "${model_args[@]}" --system-prompt "$system_prompt" 2> /dev/null)"
            rc=$?
            ;;
        codex)
            [ -n "$TS_CODEX_MODEL" ] && model_args=(--model "$TS_CODEX_MODEL")
            tmpfile="$(mktemp)" || return 1
            (cd / && timeout --foreground -k 5 "$limit" "$bin" exec -s read-only --skip-git-repo-check "${model_args[@]}" --output-last-message "$tmpfile" -- "$system_prompt
$prompt" > /dev/null 2>&1 < /dev/null)
            rc=$?
            out="$(cat "$tmpfile" 2> /dev/null)"
            rm -f "$tmpfile"
            ;;
        agy)
            # Deny every tool explicitly, including reads that plan mode allows.
            # Attach the prompt to -p with '=' for agy's flag parser.
            [ -n "$TS_AGY_MODEL" ] && model_args=(--model "$TS_AGY_MODEL")
            out="$(cd / && timeout --foreground -k 5 "$limit" "$bin" --settings "$TS_AGY_SETTINGS" --disable-slash-commands "${model_args[@]}" -p="Do not call any tool or run any command yourself; only write the reply text.
$system_prompt
$prompt" 2> /dev/null < /dev/null)"
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

# Set by a SIGINT trap in the REPL; lets ts_ask tell "the user pressed Ctrl-C"
# from "the engine failed".
TS_INTERRUPTED=0
TS_REPLY=""
TS_ASK_VERBOSE=0

# Asks the active engine and, if it fails, every other installed engine.
# Sets TS_REPLY, and TS_ENGINE when it switched. Not for use in a subshell.
# Returns 0 on an answer, 1 when no engine answered, 2 when interrupted.
ts_ask() {
    local prompt="$1" system_prompt="${2:-$TS_SYSTEM_PROMPT}" active="$TS_ENGINE" e out
    TS_REPLY=""
    TS_INTERRUPTED=0
    [ "$TS_ASK_VERBOSE" -eq 1 ] && echo "   asking $active... (Ctrl-C cancels)"
    if out="$(ts_call_engine "$active" "$prompt" "$system_prompt")"; then
        TS_REPLY="$out"
        return 0
    fi
    if [ "$TS_INTERRUPTED" -eq 1 ]; then
        TS_INTERRUPTED=0
        echo "cancelled."
        return 2
    fi
    for e in "${TS_ENGINES[@]}"; do
        [ "$e" = "$active" ] && continue
        ts_resolve_bin "$e" > /dev/null 2>&1 || continue
        echo "error: $active did not respond; trying $e."
        if out="$(ts_call_engine "$e" "$prompt" "$system_prompt")"; then
            TS_ENGINE="$e"
            echo "engine: $e"
            TS_REPLY="$out"
            return 0
        fi
        if [ "$TS_INTERRUPTED" -eq 1 ]; then
            TS_INTERRUPTED=0
            echo "cancelled."
            return 2
        fi
        active="$e"
    done
    return 1
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
import json, sys, unicodedata
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
def bad(ch):
    return unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")
def text(v):
    # display text: one line, nothing a terminal would interpret
    s = " ".join(str(v).split()) if v is not None else ""
    return "".join(ch for ch in s if not bad(ch))
n = ignored = 0
for it in items:
    if isinstance(it, str):
        it = {"cmd": it}
    if not isinstance(it, dict):
        continue
    raw_cmd = it.get("cmd")
    cmd = str(raw_cmd).replace("\t", " ").strip() if raw_cmd is not None else ""
    if not cmd:
        continue
    # A command is typed into a live shell: control characters (Ctrl-U, Ctrl-O,
    # ESC...), line breaks and invisible characters are never legitimate.
    if any(bad(ch) for ch in cmd):
        ignored += 1
        continue
    risk = text(it.get("risk")).lower()
    if risk not in ("low", "medium", "high"):
        risk = ""
    print("\t".join([cmd, risk, text(it.get("why"))]))
    n += 1
if ignored:
    sys.stderr.write("terminal-system: ignored %d command(s) containing control characters\n" % ignored)
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
    local raw="$1" cleaned line out=() wc first
    if grep -q '^```' <<< "$raw"; then
        cleaned="$(sed -n '/^```/,/^```/{//!p}' <<< "$raw")"
    else
        cleaned="$raw"
    fi
    # Half a JSON reply is not a command.
    if [[ "${cleaned#"${cleaned%%[![:space:]]*}"}" == \{* ]]; then
        printf '%s\n' "$raw"
        return 2
    fi

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        if ts_has_control_chars "$line"; then
            printf '%s\n' "$raw"
            return 2
        fi
        wc=$(wc -w <<< "$line")
        if [ "$wc" -gt 12 ]; then
            # Long lines are real commands too (apt-get install with many
            # packages), but prose is not: accept one only when it starts
            # with a program or builtin that exists, and cap its length.
            first="${line%%[[:space:]]*}"
            [ "$first" = "sudo" ] && { first="${line#sudo}"; first="${first#"${first%%[![:space:]]*}"}"; first="${first%%[[:space:]]*}"; }
            if [ "$wc" -gt 200 ] || ! type -t -- "$first" > /dev/null 2>&1; then
                printf '%s\n' "$raw"
                return 2
            fi
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
    instruction="$(ts_redact_secrets <<< "$instruction")"
    commands="$(ts_redact_secrets <<< "$commands")"
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
    cmd="$(ts_redact_secrets <<< "$cmd")"
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
    # Typed text reaches readline: a control character in it (Ctrl-U, Ctrl-O,
    # ESC, a line break...) would edit or submit the line before the user has
    # confirmed anything, and could hide what really runs. Refuse it.
    #
    # Everything goes out in ONE `send-keys -l` call: splitting into chunks
    # made tmux and the pane desynchronize on long commands. A trailing ";" is
    # the one thing tmux's own parser swallows, so it needs the \; escape.
    local target="$1" cmd="$2"
    if ts_has_control_chars "$cmd"; then
        echo "refused: the command contains control characters and was not typed." >&2
        return 1
    fi
    [[ "$cmd" == *\; ]] && cmd="${cmd%;}\;"
    tmux send-keys -t "$target" -l -- "$cmd"
}

# Prepares a command for typing: drops a trailing comment and trailing ';'
# (the completion marker is appended after the command, and a comment or ';;'
# would swallow or break it), refuses control characters, a background '&'
# and unfinished lines. Prints the command; returns 1 when it cannot be used.
ts_prepare_command() {
    local cmd="$1" out="" i ch prev=" " quote="" escaped=0
    ts_has_control_chars "$cmd" && return 1
    for ((i = 0; i < ${#cmd}; i++)); do
        ch="${cmd:i:1}"
        if [ "$escaped" -eq 1 ]; then
            escaped=0
        elif [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
            escaped=1
        elif [ -n "$quote" ]; then
            [ "$ch" = "$quote" ] && quote=""
        elif [ "$ch" = "'" ] || [ "$ch" = '"' ]; then
            quote="$ch"
        elif [ "$ch" = "#" ] && { [ "$prev" = " " ] || [ "$i" -eq 0 ]; }; then
            break
        fi
        out+="$ch"
        prev="$ch"
    done
    out="${out%"${out##*[![:space:]]}"}"
    while [[ "$out" == *\; ]]; do
        out="${out%;}"
        out="${out%"${out##*[![:space:]]}"}"
    done
    [ -n "$quote" ] && return 1
    [ -n "$out" ] || return 1
    case "$out" in
        *"&&" | *"||" | *"|" | *"\\") return 1 ;;
        *"&") return 1 ;;
    esac
    printf '%s' "$out"
}

# The completion marker is typed after the command, so it only works when
# the left panel is a plain local shell. Inside ssh, su, a database client or
# an editor the marker would be typed into that program instead.
ts_left_panel_tracked() {
    local fg
    fg="$(tmux display-message -p -t "$1" '#{pane_current_command}' 2> /dev/null)"
    case "$fg" in
        "" | bash | zsh | sh | dash | fish | ksh) return 0 ;;
    esac
    return 1
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
        # Unbounded wait on purpose: it ends with the tmux session at the latest.
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

# Blocks until the in-band marker fires, or `seconds` elapses. The marker can
# only fire once the shell has run the marked command to completion.
ts_wait_for_signal() {
    local signal="$1" seconds="${2:-120}"
    timeout "$seconds" tmux wait-for "$signal" > /dev/null 2>&1
}

# Builds "cmd; tmux wait-for -S signal" as ONE string for ts_type_into_pane:
# typing the marker in a second send-keys call can desynchronize the pane.
ts_marked_command() {
    local cmd="$1" signal="$2"
    printf '%s%s' "$cmd" "$(ts_signal_suffix "$signal")"
}

TS_EXPLAIN_SYSTEM_PROMPT="You explain a Linux shell command to the person about to run it. In at most four short plain sentences say what it does, what each important option or part means, and anything risky or irreversible about it. No markdown, no backticks."

TS_EXPLAIN_RESULT_PROMPT="You explain the result of a Linux shell command to the person who ran it. You get the command and the terminal output that followed. In at most five short plain sentences say what the command did, what the output means, and, if it shows an error, the likely cause and the next thing to try. No markdown, no backticks."

# Asks the engine to explain a command (used by "?" in the confirm step).
ts_explain_command() {
    local cmd out
    cmd="$(ts_redact_secrets <<< "$1")"
    if [ -z "${TS_ENGINE:-}" ]; then
        echo "(no AI engine available for an explanation)"
        return 0
    fi
    if ts_ask "$(ts_env_context "${TS_TARGET:-}")
Command: $cmd" "$TS_EXPLAIN_SYSTEM_PROMPT"; then
        ts_clean_text <<< "$TS_REPLY"
    else
        echo "(the AI engine did not respond)"
    fi
}

ts_confirm_and_send() {
    local target="$1" cmd="$2" return_target="${3:-}" signal="${4:-}" reply edited code="" ai_high=0 shown
    # High-risk commands (rated high by the AI, or matching the local
    # dangerous-pattern list) cannot be run by a stray Enter: the short
    # code shown must be typed. The AI can only raise the risk, never lower it.
    [ "${TS_RISK[$cmd]:-}" = "high" ] && ai_high=1
    if [ "$ai_high" -eq 1 ] || ts_is_dangerous_command "$cmd"; then
        code="$(printf '%04x' $((RANDOM % 65536)))"
    fi
    while true; do
        TS_CONFIRMED_COMMAND="$cmd"
        shown="$(ts_clean_text <<< "$cmd")"
        printf '[CONFIRM] %s\n' "$shown"
        if [ -n "${TS_WHY[$cmd]:-}" ] || [ -n "${TS_RISK[$cmd]:-}" ]; then
            printf '   %s%s\n' "$(ts_clean_text <<< "${TS_WHY[$cmd]:-}")" "${TS_RISK[$cmd]:+  [AI risk estimate: ${TS_RISK[$cmd]}]}"
        fi
        if [ -n "$code" ]; then
            printf 'HIGH RISK -- type %s to run, e = edit, ? = explain, n = cancel: ' "$code"
        else
            printf 'enter = run, e = edit, ? = explain, n = cancel: '
        fi
        # EOF or an interrupted read (Ctrl-C) cancels.
        if ! IFS= read -r reply; then
            ts_clear_typed_line "$target"
            return 1
        fi
        case "$reply" in
            n | N | no | NO | No | q | Q | cancel)
                ts_clear_typed_line "$target"
                return 1
                ;;
            \?)
                ts_explain_command "$cmd"
                continue
                ;;
            e | E | m | M)
                ts_clear_typed_line "$target"
                printf 'edit command: '
                if [ -t 0 ]; then
                    IFS= read -e -i "$cmd" -r edited || return 1
                else
                    IFS= read -r edited || return 1
                fi
                [ -n "$edited" ] || return 1
                if ! edited="$(ts_prepare_command "$edited")"; then
                    echo "that command cannot be used here (control characters, background '&', or an unfinished line)."
                    ts_type_into_pane "$target" "$cmd"
                    continue
                fi
                cmd="$edited"
                TS_CONFIRMED_COMMAND="$cmd"
                ts_type_into_pane "$target" "$cmd" || return 1
                code=""
                if [ "$ai_high" -eq 1 ] || ts_is_dangerous_command "$cmd"; then
                    code="$(printf '%04x' $((RANDOM % 65536)))"
                fi
                continue
                ;;
        esac
        if [ -n "$code" ]; then
            if [ "$reply" != "$code" ]; then
                echo "not confirmed: type $code exactly to run this command."
                continue
            fi
        else
            case "$reply" in
                "" | y | Y | yes | YES) ;;
                *)
                    echo "not understood: press Enter or y to run, e = edit, ? = explain, n = cancel."
                    continue
                    ;;
            esac
        fi
        # Appending the marker onto whatever is already on the line is safe
        # here because a real pause (the operator's own reply) separates it
        # from the typed command.
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
    first="${first%[.!;:,]}"
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
    local start=$SECONDS elapsed next_status line last_prompt="" focused=0 got=0 interrupted=0 previous_trap
    TS_WAIT_REASON=""
    next_status=$((start + TS_STATUS_AFTER))
    previous_trap="$(trap -p INT)"
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
    if [ -n "$previous_trap" ]; then
        eval "$previous_trap"
    else
        trap - INT
    fi
    [ "$got" -eq 1 ] || tmux set-environment -gu "$(ts_rc_var "$signal")" > /dev/null 2>&1
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
