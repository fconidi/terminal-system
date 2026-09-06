#!/bin/bash
# terminal-system/tests/test_launcher_smoke.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../build/usr/bin"
STUB_DIR="$HERE/stubs"
SOCK="/tmp/ts-test-launcher-$$.sock"
FAIL=0

STUB_TMUX_DIR="$(mktemp -d)"
cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; rm -rf "$STUB_TMUX_DIR"; }
trap cleanup EXIT

export PATH="$STUB_DIR:$BIN_DIR:$PATH"
export TS_STUB_RESPONSE="echo launcher-smoke-ok"
# terminal-system runs as an exec'd child process (not sourced), so it only
# inherits exported environment. The wrapped tmux() function below is
# exported too, but its body references $SOCK -- without exporting SOCK
# itself, terminal-system's own `set -u` turns that into a hard "SOCK:
# unbound variable" failure the moment it calls tmux.
export SOCK

check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == *"$want"* ]]; then echo "ok - $desc"; else echo "FAIL - $desc (got: '$got')"; FAIL=1; fi
}

# terminal-system normally does `exec tmux attach`, which needs a real
# terminal. Drive it through our isolated socket instead by wrapping tmux,
# the same technique used in test_tmux_helpers.sh, and by backgrounding it
# since `exec tmux attach` would otherwise block this test.
tmux() { command tmux -S "$SOCK" "$@"; }
export -f tmux

# `exec` does its own PATH lookup and never resolves shell functions (a
# function has no separate process image for exec to switch to), so
# terminal-system's own `exec tmux attach -t "$session"` would bypass the
# tmux() function above entirely and reach the real, default tmux server.
# A PATH-prepended stub *script* named tmux is what `exec tmux ...` actually
# finds; the shell function still wins for the test's own plain (non-exec)
# `tmux ...` calls, since function lookup takes precedence there. Both paths
# then converge on the same isolated socket.
cat > "$STUB_TMUX_DIR/tmux" << EOF
#!/bin/bash
exec /usr/bin/tmux -S "$SOCK" "\$@"
EOF
chmod +x "$STUB_TMUX_DIR/tmux"
export PATH="$STUB_TMUX_DIR:$PATH"

# Bootstrap the isolated server ourselves, before terminal-system starts it,
# so we can force panes to spawn a plain (non-login) shell. On stock
# Debian/Ubuntu, /etc/profile unconditionally resets PATH for login shells
# (tmux's default for new panes), which would wipe our STUB_DIR/BIN_DIR
# prefix the instant the right pane's shell starts -- before it ever gets to
# `exec ts-brain` -- for reasons that have nothing to do with
# terminal-system itself. A persistent bootstrap session keeps the server
# alive while we set this (killing a tmux server's last session kills the
# server, which would discard the option too).
tmux new-session -d -s bootstrap -n bootstrap
tmux set-option -g default-command "exec bash --norc --noprofile"

( terminal-system claude & )
sleep 0.7

sessions="$(tmux -S "$SOCK" list-sessions 2> /dev/null)"
check "launcher creates a tmux session" "$sessions" "terminal-system-"

session_name="$(tmux -S "$SOCK" list-sessions -F '#{session_name}' 2> /dev/null | grep '^terminal-system-' | head -1)"
panes="$(tmux -S "$SOCK" list-panes -t "$session_name" 2> /dev/null | wc -l)"
[ "$panes" -eq 2 ] && echo "ok - launcher creates exactly two panes" || { echo "FAIL - expected 2 panes, got $panes"; FAIL=1; }

right_out="$(tmux -S "$SOCK" capture-pane -p -t "$session_name:0.1" -S -10)"
check "right pane is running ts-brain" "$right_out" "terminal-system --"

tmux -S "$SOCK" send-keys -t "$session_name:0.1" ":quit" C-m
sleep 0.3

exit $FAIL
