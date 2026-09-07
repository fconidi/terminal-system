#!/bin/bash
# terminal-system/tests/test_launcher_smoke.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../build/usr/bin"
STUB_DIR="$HERE/stubs"
SOCK="/tmp/ts-test-launcher-$$.sock"
FAIL=0

cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; rm -f "$SOCK"; }
trap cleanup EXIT

export PATH="$STUB_DIR:$BIN_DIR:$PATH"
export TS_STUB_RESPONSE="echo launcher-smoke-ok"
# terminal-system runs as an exec'd child process (not sourced), so it only
# inherits exported environment.
export SOCK
# terminal-system's cmd_start() reads TS_TMUX_SOCK_ARGS to pick which tmux
# server to use (see build/usr/bin/terminal-system) -- production defaults
# to a dedicated per-invocation socket (-L) so its bind-key changes can't
# leak into the user's other tmux sessions; the test points it at our
# throwaway socket instead, the same way test_tmux_helpers.sh does.
export TS_TMUX_SOCK_ARGS="-S $SOCK"

check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == *"$want"* ]]; then echo "ok - $desc"; else echo "FAIL - $desc (got: '$got')"; FAIL=1; fi
}

# Bootstrap the isolated server ourselves, before terminal-system starts it,
# so we can force panes to spawn a plain (non-login) shell. On stock
# Debian/Ubuntu, /etc/profile unconditionally resets PATH for login shells
# (tmux's default for new panes), which would wipe our STUB_DIR/BIN_DIR
# prefix the instant the right pane's shell starts -- before it ever gets to
# `exec ts-brain` -- for reasons that have nothing to do with
# terminal-system itself. A persistent bootstrap session keeps the server
# alive while we set this (killing a tmux server's last session kills the
# server, which would discard the option too).
tmux -S "$SOCK" new-session -d -s bootstrap -n bootstrap
tmux -S "$SOCK" set-option -g default-command "exec bash --norc --noprofile"

# terminal-system does `exec tmux ... attach`, which needs a real terminal;
# background it so this test isn't blocked by that exec.
( terminal-system claude & )
sleep 0.7

sessions="$(tmux -S "$SOCK" list-sessions 2> /dev/null)"
check "launcher creates a tmux session" "$sessions" "terminal-system-"

session_name="$(tmux -S "$SOCK" list-sessions -F '#{session_name}' 2> /dev/null | grep '^terminal-system-' | head -1)"
panes="$(tmux -S "$SOCK" list-panes -t "$session_name" 2> /dev/null | wc -l)"
[ "$panes" -eq 2 ] && echo "ok - launcher creates exactly two panes" || { echo "FAIL - expected 2 panes, got $panes"; FAIL=1; }

right_out="$(tmux -S "$SOCK" capture-pane -p -t "$session_name:0.1" -S -10)"
check "right pane is running ts-brain" "$right_out" "terminal-system --"
right_pid="$(tmux -S "$SOCK" display-message -p -t "$session_name:0.1" '#{pane_pid}')"
right_args="$(ps -o args= -p "$right_pid" 2>/dev/null || true)"
check "launcher passes a stable pane id to ts-brain" "$right_args" "%"

# Mouse mode is on for both panes (see below), which routes mouse-drag
# selection through tmux copy-mode instead of the terminal's own selection.
# Without a copy-pipe target, that selection only ever lands in tmux's
# internal buffer -- never the system clipboard -- on either pane.
copy_keys="$(tmux -S "$SOCK" list-keys -T copy-mode 2>/dev/null)"
check "mouse-drag copy pipes selection to xclip (emacs table)" "$copy_keys" 'MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"'
copy_keys_vi="$(tmux -S "$SOCK" list-keys -T copy-mode-vi 2>/dev/null)"
check "mouse-drag copy pipes selection to xclip (vi table)" "$copy_keys_vi" 'MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"'

tmux -S "$SOCK" send-keys -t "$session_name:0.1" ":quit" C-m
sleep 0.3

exit $FAIL
