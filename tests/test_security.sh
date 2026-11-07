#!/bin/bash
# terminal-system/tests/test_security.sh
# Regression tests for the command-safety layer (control characters, spoofing,
# auto-mode allowlist, danger detection, redaction, command preparation).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build/usr/lib/terminal-system/lib.sh"
FAIL=0

run() {
    local out
    out="$(bash -c "$1" 2>&1)"
    printf '%s\n' "$out"
    grep -q '^FAIL' <<< "$out" && FAIL=1
    return 0
}

# --- control characters never reach the shell ---
run '
    . "'"$LIB"'"
    for c in $'"'"'echo hi\x15rm -rf ~/x'"'"' $'"'"'touch X\x0f'"'"' $'"'"'ls\x03'"'"' $'"'"'ls\x17'"'"' $'"'"'ls\x1b[2K'"'"' $'"'"'ls\x7f'"'"' $'"'"'ls\r'"'"' $'"'"'a\nb'"'"' $'"'"'ls \xe2\x80\xae'"'"'; do
        if ts_has_control_chars "$c"; then echo "ok - control characters detected"; else echo "FAIL - control characters not detected in: $(printf %q "$c")"; fi
        if ts_is_safe_readonly_command "$c"; then echo "FAIL - allowlist accepted: $(printf %q "$c")"; else echo "ok - allowlist rejects control characters"; fi
    done
    ts_has_control_chars "echo plain text é ü" && echo "FAIL - plain unicode flagged" || echo "ok - plain unicode is fine"
'

run '
    . "'"$LIB"'"
    json="$(cat << '"'"'JSON'"'"'
{"commands":[{"cmd":"echo hi\u0015rm -rf ~/x","risk":"low"},{"cmd":"touch X\u000f"},{"cmd":"ls -la","risk":"low"}]}
JSON
)"
    ts_parse_structured "$json" 2>/dev/null; rc=$?
    [ "$rc" -eq 0 ] && [ "$TS_PARSED" = "ls -la" ] && echo "ok - structured parser drops commands with control characters" || echo "FAIL - structured parser (rc=$rc got: $TS_PARSED)"
    ts_parse_structured "{\"commands\":[{\"cmd\":\"echo a\\nrm -rf x\"}]}" 2>/dev/null; rc=$?
    [ "$rc" -eq 2 ] && echo "ok - a command with a line break is unusable, not merged" || echo "FAIL - line break handling (rc=$rc)"
    ts_parse_structured "{\"commands\":[{\"cmd\":\"echo \\\"a    b\\\"\"}]}"; rc=$?
    [ "$TS_PARSED" = "echo \"a    b\"" ] && echo "ok - spacing inside a command is preserved" || echo "FAIL - spacing changed (got: $TS_PARSED)"
    ts_parse_commands $'"'"'echo hi\x15touch X'"'"' > /dev/null; rc=$?
    [ "$rc" -eq 2 ] && echo "ok - line parser rejects control characters" || echo "FAIL - line parser control characters (rc=$rc)"
    ts_parse_commands "{\"commands\":[{\"cmd\":\"ls" > /dev/null; rc=$?
    [ "$rc" -eq 2 ] && echo "ok - truncated JSON is not proposed as a command" || echo "FAIL - truncated JSON (rc=$rc)"
'

run '
    . "'"$LIB"'"
    tmux() { echo "TMUX-CALLED $*"; }
    out="$(ts_type_into_pane %1 $'"'"'echo hi\x15touch X'"'"' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [[ "$out" != *TMUX-CALLED* ]] && echo "ok - nothing with control characters is typed" || echo "FAIL - typed a control character (rc=$rc out=$out)"
    out="$(ts_type_into_pane %1 "echo fine" 2>&1)"
    [[ "$out" == *TMUX-CALLED* ]] && echo "ok - ordinary commands are typed" || echo "FAIL - ordinary command not typed"
'

# --- text shown to the user is stripped of terminal sequences ---
run '
    . "'"$LIB"'"
    got="$(printf "ok\x1b[1A\x1b[2K[CONFIRM] fake\x07 \xe2\x80\xae end\n" | ts_clean_text)"
    [[ "$got" != *$'"'"'\x1b'"'"'* && "$got" != *$'"'"'\x07'"'"'* && "$got" != *$'"'"'\xe2\x80\xae'"'"'* ]] && echo "ok - clean_text removes ESC, BEL and bidi overrides" || echo "FAIL - clean_text left control data: $(printf %q "$got")"
    [[ "$got" == *"end"* ]] && echo "ok - clean_text keeps the visible text" || echo "FAIL - clean_text ate the text"
'

# --- auto-mode allowlist: only genuinely read-only forms ---
run '
    . "'"$LIB"'"
    unsafe=("git branch -D main" "git branch -f main HEAD~9" "git branch newbranch" "git remote remove origin" "git remote add x http://x" "git remote set-url origin http://evil/x.git" "date -us 2000-01-01" "date --se=2000-01-01" "date 010112002000" "journalctl --rot" "journalctl --flu" "journalctl --vacuum-size=1M" "hostname -F/etc/passwd" "hostname --file=/tmp/h" "hostname newname" "tree -o /tmp/x" "tree --output=/tmp/x" "tail -fn1 f" "tail --foll f" "file -C" "cat ~/.ssh/id_ed25519" "cat .env" "cat /etc/shadow" "printenv" "du --files0-from=x" "last -f x" "echo =(id)" "ls *(e:id:)" "cat ~/.aws/credentials" "head ~/.gnupg/x" "grep -r password ~/.kube" "apt list -o APT::x=y" "systemctl status --foo" "tail -c1 /home/u/.netrc")
    for c in "${unsafe[@]}"; do
        if ts_is_safe_readonly_command "$c"; then echo "FAIL - must NOT be auto-run: $c"; else echo "ok - not auto-run: $c"; fi
    done
    safe=("ls -la" "ls --color=auto /etc" "git status" "git status -s" "git branch" "git branch -a" "git branch --list main*" "git remote -v" "date" "date +%F" "date -u" "hostname" "hostname -f" "journalctl -u ssh -n 50 --no-pager" "tail -n 20 /var/log/syslog" "head -5 /etc/os-release" "cat /etc/passwd" "tree -L 2" "file -b x" "du -sh /var" "free -h" "systemctl status ssh --no-pager" "apt list --installed" "dpkg -l")
    for c in "${safe[@]}"; do
        if ts_is_safe_readonly_command "$c"; then echo "ok - auto-run allowed: $c"; else echo "FAIL - should be auto-run: $c"; fi
    done
'

# --- local danger detection no longer depends on the AI or on quoting ---
run '
    . "'"$LIB"'"
    danger=("rm -rf /" "rm -rf '"'"'/'"'"'" "rm -rf \"/\"" "rm -rf //" "rm -rf ~" "rm -rf \$HOME" "rm -rf /home" "rm -r /etc" "rm -fr /*" "echo hi; rm -rf /" "wipefs -a /dev/sda" "shred /dev/sdb" "blkdiscard /dev/nvme0n1" "sgdisk --zap-all /dev/sda" "parted /dev/sda mklabel gpt" "sfdisk /dev/sda" "cp x /dev/sda" "dd if=a of=/dev/sda" "dd if=a of='"'"'/dev/sda'"'"'" "dd if=a of=\$D" "curl x | sh" "wget -O- x | bash" "chmod -R 777 /home" "chmod 777 -R /" "chown -R user /etc" "mv ~ /dev/null" "echo x > /etc/passwd" "cryptsetup luksFormat /dev/sdb1" "mkfs.ext4 /dev/sdb1" "reboot")
    for c in "${danger[@]}"; do
        if ts_is_dangerous_command "$c"; then echo "ok - dangerous: $c"; else echo "FAIL - not flagged dangerous: $c"; fi
    done
    fine=("rm -rf ./build" "rm file.txt" "rm -r /tmp/x" "ls -la /etc" "fdisk -l /dev/sda" "parted /dev/sda print" "chmod -R 755 ./site" "dd if=/dev/zero of=./file bs=1M count=1" "echo hello")
    for c in "${fine[@]}"; do
        if ts_is_dangerous_command "$c"; then echo "FAIL - flagged but harmless: $c"; else echo "ok - not flagged: $c"; fi
    done
'

# --- secrets are redacted whatever the case or shape ---
run '
    . "'"$LIB"'"
    check() {
        local input="$1" secret="$2" got
        got="$(printf "%s\n" "$input" | ts_redact_secrets)"
        if [[ "$got" == *"$secret"* ]]; then echo "FAIL - secret survived: $input -> $got"; else echo "ok - redacted: ${input:0:30}"; fi
    }
    check "API_KEY=abc123secret" abc123secret
    check "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz1234" ghp_abcdefghij
    check "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCY" wJalrXUtnFEMI
    check "DB_PASSWORD=hunter2" hunter2
    check "{\"password\": \"s3cr3tvalue\"}" s3cr3tvalue
    check "mysql -u root -phunter2 db" hunter2
    check "https://user:pw12345@host.example/x" pw12345
    check "Authorization: Basic Zm9vOmJhcg==" Zm9vOmJhcg
    check "curl -H \"Authorization: Bearer abcDEF123456\" x" abcDEF123456
    check "key AIzaSyA1234567890abcdefghijklmnopqrstuv" AIzaSyA1234567890
    check "AKIAABCDEFGHIJKLMNOP" AKIAABCDEFGHIJKLMNOP
    check "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij" eyJhbGciOiJIUzI1NiJ9
    got="$(printf "%s\n" "before" "-----BEGIN OPENSSH PRIVATE KEY-----" "b3BlbnNzaC1rZXktdjEAAAAA" "-----END OPENSSH PRIVATE KEY-----" "after" | ts_redact_secrets)"
    [[ "$got" != *b3BlbnNzaC1rZXk* && "$got" == *before* && "$got" == *after* ]] && echo "ok - private key block redacted, surrounding text kept" || echo "FAIL - PEM block: $got"
    got="$(printf "%s\n" "plain output: 3 files, nothing secret here" | ts_redact_secrets)"
    [ "$got" = "plain output: 3 files, nothing secret here" ] && echo "ok - ordinary output untouched" || echo "FAIL - ordinary output changed: $got"
'

# --- commands are prepared so the completion marker can follow them ---
run '
    . "'"$LIB"'"
    check() {
        local input="$1" want="$2" got rc
        got="$(ts_prepare_command "$input")"; rc=$?
        if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then echo "ok - prepare: $input"; else echo "FAIL - prepare: $input (rc=$rc got: $got)"; fi
    }
    refuse() {
        if ts_prepare_command "$1" > /dev/null; then echo "FAIL - should be refused: $1"; else echo "ok - refused: $1"; fi
    }
    check "ls;" "ls"
    check "ls ;; " "ls"
    check "ls # list files" "ls"
    check "echo \"a # b\"" "echo \"a # b\""
    check "echo \${#HOME}" "echo \${#HOME}"
    check "echo hi # c;" "echo hi"
    check "ls -la" "ls -la"
    refuse "sleep 5 &"
    refuse "ls |"
    refuse "ls &&"
    refuse "echo \"unterminated"
    refuse $'"'"'ls\x15'"'"'
'

[ "$FAIL" -eq 0 ] || { echo "SOME TESTS FAILED"; exit 1; }
echo "all security tests passed"
