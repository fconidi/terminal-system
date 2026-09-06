#!/bin/bash
# terminal-system/tests/test_lib.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build/usr/lib/terminal-system/lib.sh"
FAIL=0

run() {
    local out
    out="$(bash -c "$1")"
    printf '%s\n' "$out"
    grep -q '^FAIL' <<< "$out" && FAIL=1
    return 0
}

run '
    tmpdir="$(mktemp -d)"
    printf "#!/bin/bash\necho fake\n" > "$tmpdir/claude"
    chmod +x "$tmpdir/claude"
    PATH="$tmpdir:$PATH"; . "'"$LIB"'"
    got="$(ts_resolve_bin claude)"
    [ "$got" = "$tmpdir/claude" ] && echo "ok - resolve_bin finds claude on PATH" || echo "FAIL - resolve_bin on PATH (got: $got)"
    rm -rf "$tmpdir"
'

run '
    tmphome="$(mktemp -d)"
    mkdir -p "$tmphome/.local/bin"
    printf "#!/bin/bash\necho fake\n" > "$tmphome/.local/bin/codex"
    chmod +x "$tmphome/.local/bin/codex"
    HOME="$tmphome"; PATH="/nonexistent"; . "'"$LIB"'"
    got="$(ts_resolve_bin codex)"
    [ "$got" = "$tmphome/.local/bin/codex" ] && echo "ok - resolve_bin falls back to ~/.local/bin" || echo "FAIL - resolve_bin fallback (got: $got)"
    PATH="/usr/bin:/bin"
    rm -rf "$tmphome"
'

run '
    PATH="/nonexistent"; HOME="/nonexistent"; . "'"$LIB"'"
    if ts_resolve_bin claude > /dev/null 2>&1; then echo "FAIL - resolve_bin should fail when nothing installed"; else echo "ok - resolve_bin fails cleanly"; fi
'

run '
    tmpdir="$(mktemp -d)"
    printf "#!/bin/bash\n" > "$tmpdir/claude"; chmod +x "$tmpdir/claude"
    printf "#!/bin/bash\n" > "$tmpdir/codex"; chmod +x "$tmpdir/codex"
    PATH="$tmpdir:$PATH"; . "'"$LIB"'"
    got="$(ts_pick_engine claude)"
    [ "$got" = "claude" ] && echo "ok - pick_engine returns requested when available" || echo "FAIL - pick_engine requested (got: $got)"
    rm -rf "$tmpdir"
'

run '
    tmpdir="$(mktemp -d)"
    printf "#!/bin/bash\n" > "$tmpdir/codex"; chmod +x "$tmpdir/codex"
    PATH="$tmpdir:/usr/bin:/bin"; HOME="/nonexistent"; . "'"$LIB"'"
    got="$(ts_pick_engine claude)"
    [ "$got" = "codex" ] && echo "ok - pick_engine falls back to codex" || echo "FAIL - pick_engine fallback (got: $got)"
    rm -rf "$tmpdir"
'

run '
    PATH="/nonexistent"; HOME="/nonexistent"; . "'"$LIB"'"
    if ts_pick_engine claude > /dev/null 2>&1; then echo "FAIL - pick_engine should fail when neither installed"; else echo "ok - pick_engine fails cleanly"; fi
'

run '
    . "'"$LIB"'"
    dangerous=("rm -rf /" "rm -rf /*" "rm -fr /" "rm -r -f /" "rm -f -r /" "rm -rf -- /" "mkfs.ext4 /dev/sdb1" "dd if=/dev/zero of=/dev/sda" ":(){ :|:& };:" "chmod -R 777 /" "chmod 777 -R /" "chmod -vR 777 /" "shutdown -h now" "reboot" "killall -9 sshd" "userdel -r root" "iptables -F" "echo hi > /dev/sda" "echo hi > /dev/vda" "echo hi > /dev/nvme0n1")
    for c in "${dangerous[@]}"; do
        if ts_is_dangerous_command "$c"; then echo "ok - flagged dangerous: $c"; else echo "FAIL - should be flagged dangerous: $c"; fi
    done
'

run '
    . "'"$LIB"'"
    safe=("sudo adduser Pippo" "sudo usermod -aG sudo Pippo" "apt update" "apt-get upgrade -y" "apt-get autoremove -y" "rm -rf /home/pippo/tmp" "rm -rf ./build" "systemctl restart networking" "ls -la /dev/sda1" "df -h" "userdel pippo")
    for c in "${safe[@]}"; do
        if ts_is_dangerous_command "$c"; then echo "FAIL - false positive: $c"; else echo "ok - correctly not flagged: $c"; fi
    done
'

run '
    STUBS="'"$HERE"'/stubs"
    PATH="$STUBS:$PATH"; . "'"$LIB"'"
    export TS_STUB_RESPONSE="sudo adduser Pippo"
    got="$(ts_call_engine claude "create user Pippo")"
    [ "$got" = "sudo adduser Pippo" ] && echo "ok - call_engine claude returns stub text" || echo "FAIL - call_engine claude (got: $got)"
'

run '
    STUBS="'"$HERE"'/stubs"
    log="$(mktemp)"
    PATH="$STUBS:$PATH"; . "'"$LIB"'"
    export TS_STUB_RESPONSE="sudo adduser Pippo"
    export TS_STUB_ARG_LOG="$log"
    ts_call_engine claude "create user Pippo" > /dev/null
    args="$(cat "$log")"
    rm -f "$log"
    grep -Fxq -- "--disallowedTools" <<< "$args" && grep -Fxq -- "*" <<< "$args" && echo "ok - call_engine claude disables tools" || echo "FAIL - call_engine claude missing --disallowedTools * (args: $args)"
'

run '
    STUBS="'"$HERE"'/stubs"
    PATH="$STUBS:$PATH"; . "'"$LIB"'"
    export TS_STUB_RESPONSE="sudo adduser Pippo"
    got="$(ts_call_engine codex "create user Pippo")"
    [ "$got" = "sudo adduser Pippo" ] && echo "ok - call_engine codex returns stub text" || echo "FAIL - call_engine codex (got: $got)"
'

run '
    STUBS="'"$HERE"'/stubs"
    log="$(mktemp)"
    PATH="$STUBS:$PATH"; . "'"$LIB"'"
    export TS_STUB_RESPONSE="sudo adduser Pippo"
    export TS_STUB_ARG_LOG="$log"
    ts_call_engine codex "create user Pippo" > /dev/null
    args="$(cat "$log")"
    rm -f "$log"
    grep -Fxq -- "-s" <<< "$args" && grep -Fxq -- "read-only" <<< "$args" && echo "ok - call_engine codex uses read-only sandbox" || echo "FAIL - call_engine codex missing -s read-only (args: $args)"
'

run '
    PATH="/nonexistent"; HOME="/nonexistent"; . "'"$LIB"'"
    if ts_call_engine claude "x" > /dev/null 2>&1; then echo "FAIL - call_engine should fail when binary missing"; else echo "ok - call_engine fails cleanly when binary missing"; fi
'

run '
    STUBS="'"$HERE"'/stubs"
    PATH="$STUBS:$PATH"; . "'"$LIB"'"
    export TS_STUB_RESPONSE=""
    if ts_call_engine claude "x" > /dev/null 2>&1; then echo "FAIL - call_engine should fail on empty response"; else echo "ok - call_engine fails cleanly on empty response"; fi
'

run '
    . "'"$LIB"'"
    got="$(ts_parse_commands "sudo adduser Pippo")"; rc=$?
    [ "$got" = "sudo adduser Pippo" ] && [ "$rc" -eq 0 ] && echo "ok - parse_commands single clean command" || echo "FAIL - parse_commands single (got: $got / rc=$rc)"
'

run '
    . "'"$LIB"'"
    raw="\`\`\`
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
\`\`\`"
    got="$(ts_parse_commands "$raw")"; rc=$?
    want="sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y"
    [ "$got" = "$want" ] && [ "$rc" -eq 0 ] && echo "ok - parse_commands fenced multi-command" || echo "FAIL - parse_commands fenced (got: $got / rc=$rc)"
'

run '
    . "'"$LIB"'"
    raw="To create a new user you can use the adduser command followed by the username you want to create."
    got="$(ts_parse_commands "$raw")"; rc=$?
    [ "$got" = "$raw" ] && [ "$rc" -eq 2 ] && echo "ok - parse_commands flags prose as unparseable" || echo "FAIL - parse_commands prose (rc=$rc)"
'

run '
    . "'"$LIB"'"
    got="$(ts_parse_commands "
sudo adduser Pippo

")"; rc=$?
    [ "$got" = "sudo adduser Pippo" ] && [ "$rc" -eq 0 ] && echo "ok - parse_commands trims blank lines" || echo "FAIL - parse_commands blank lines (got: $got / rc=$rc)"
'

run '
    . "'"$LIB"'"
    got="$(ts_parse_commands "")"; rc=$?
    [ "$rc" -eq 2 ] && echo "ok - parse_commands flags empty input as unparseable" || echo "FAIL - parse_commands empty (rc=$rc)"
'

run '
    . "'"$LIB"'"
    TS_HISTORY=()
    ctx="$(ts_history_context)"
    [ -z "$ctx" ] && echo "ok - history_context empty with no history" || echo "FAIL - history_context should be empty (got: $ctx)"
'

run '
    . "'"$LIB"'"
    TS_HISTORY=()
    ts_history_append "create user Pippo" "sudo adduser Pippo" "Adding user Pippo..."
    ctx="$(ts_history_context)"
    [[ "$ctx" == *"create user Pippo"* && "$ctx" == *"sudo adduser Pippo"* ]] && echo "ok - history_context includes appended entry" || echo "FAIL - history_context missing entry (got: $ctx)"
'

run '
    . "'"$LIB"'"
    TS_HISTORY=()
    TS_HISTORY_MAX=2
    ts_history_append "i1" "c1" "o1"
    ts_history_append "i2" "c2" "o2"
    ts_history_append "i3" "c3" "o3"
    [ "${#TS_HISTORY[@]}" -eq 2 ] && echo "ok - history trims to TS_HISTORY_MAX" || echo "FAIL - history not trimmed (count: ${#TS_HISTORY[@]})"
    ctx="$(ts_history_context)"
    [[ "$ctx" != *"i1"* && "$ctx" == *"i2"* && "$ctx" == *"i3"* ]] && echo "ok - history keeps most recent entries" || echo "FAIL - wrong entries kept (got: $ctx)"
'

run '
    . "'"$LIB"'"
    TS_HISTORY=()
    got="$(ts_build_prompt "create user Pippo")"
    [[ "$got" == *"create user Pippo"* ]] && echo "ok - build_prompt includes instruction with no history" || echo "FAIL - build_prompt (got: $got)"
'

run '
    . "'"$LIB"'"
    TS_HISTORY=()
    ts_history_append "create user Pippo" "sudo adduser Pippo" "done"
    got="$(ts_build_prompt "now add him to the sudo group")"
    [[ "$got" == *"create user Pippo"* && "$got" == *"now add him to the sudo group"* ]] && echo "ok - build_prompt folds in history" || echo "FAIL - build_prompt missing context (got: $got)"
'

exit $FAIL
