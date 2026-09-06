#!/bin/bash
# terminal-system/tests/test_tmux_helpers.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build/usr/lib/terminal-system/lib.sh"
SOCK="/tmp/ts-test-tmux-$$.sock"
FAIL=0

cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; }
trap cleanup EXIT

# Wrap every tmux call the library makes so it targets our isolated socket.
tmux() { command tmux -S "$SOCK" "$@"; }
export -f tmux
. "$LIB"

tmux new-session -d -s t -x 200 -y 50
tmux split-window -h -t t

check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == *"$want"* ]]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (got: '$got', want to contain: '$want')"
        FAIL=1
    fi
}

ts_type_into_pane "t:0.0" "echo typed-not-yet-run"
sleep 0.2
out="$(ts_capture_pane_tail "t:0.0" 5)"
check "type_into_pane types without executing" "$out" "echo typed-not-yet-run"
[[ "$out" == *"typed-not-yet-run"*"typed-not-yet-run"* ]] && { echo "FAIL - command ran before Enter was sent"; FAIL=1; } || echo "ok - command did not run before Enter"

ts_send_enter "t:0.0"
sleep 0.3
out="$(ts_capture_pane_tail "t:0.0" 5)"
check "send_enter runs the typed command" "$out" "typed-not-yet-run"

ts_type_into_pane "t:0.0" "echo should-be-cleared"
ts_clear_typed_line "t:0.0"
ts_send_enter "t:0.0"
sleep 0.3
out="$(ts_capture_pane_tail "t:0.0" 5)"
if [[ "$out" == *"should-be-cleared"* ]]; then
    echo "FAIL - clear_typed_line did not prevent execution"; FAIL=1
else
    echo "ok - clear_typed_line prevents the command from running"
fi

ts_type_into_pane "t:0.0" "echo auto-sent"
ts_auto_send "t:0.0" 0.1
sleep 0.3
out="$(ts_capture_pane_tail "t:0.0" 5)"
check "auto_send runs the typed command after a delay" "$out" "auto-sent"

ts_type_into_pane "t:0.0" "echo confirmed"
echo | ts_confirm_and_send "t:0.0" "echo confirmed" > /dev/null
sleep 0.3
out="$(ts_capture_pane_tail "t:0.0" 5)"
check "confirm_and_send with empty reply runs the command" "$out" "confirmed"

ts_type_into_pane "t:0.0" "echo not-confirmed"
echo n | ts_confirm_and_send "t:0.0" "echo not-confirmed" > /dev/null
sleep 0.3
out="$(ts_capture_pane_tail "t:0.0" 5)"
if [[ "$out" == *"not-confirmed"* ]]; then
    echo "FAIL - confirm_and_send with 'n' should not run the command"; FAIL=1
else
    echo "ok - confirm_and_send with 'n' cancels the command"
fi

exit $FAIL
