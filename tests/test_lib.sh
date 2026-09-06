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
    dangerous=("rm -rf /" "rm -rf /*" "rm -fr /" "mkfs.ext4 /dev/sdb1" "dd if=/dev/zero of=/dev/sda" ":(){ :|:& };:" "chmod -R 777 /" "shutdown -h now" "reboot" "killall -9 sshd" "userdel -r root" "iptables -F" "echo hi > /dev/sda")
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

exit $FAIL
