#!/bin/bash
# terminal-system/tests/test_tmux_helpers.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build/usr/lib/terminal-system/lib.sh"
SOCK="/tmp/ts-test-tmux-$$.sock"
FAIL=0
TEST_TMP="$(mktemp -d)"
export SOCK

cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; rm -f "$SOCK"; rm -rf "$TEST_TMP"; }
trap cleanup EXIT

# Wrap every tmux call the library makes so it targets our isolated socket.
tmux() { command tmux -S "$SOCK" "$@"; }
export -f tmux
. "$LIB"

tmux new-session -d -s t -x 200 -y 50
tmux split-window -h -t t
LEFT_PANE="$(tmux display-message -p -t t:0.0 '#{pane_id}')"
RIGHT_PANE="$(tmux display-message -p -t t:0.1 '#{pane_id}')"

check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == *"$want"* ]]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (got: '$got', want to contain: '$want')"
        FAIL=1
    fi
}

check_active_pane() {
    local desc="$1" target="$2" active wanted window
    wanted="$(tmux display-message -p -t "$target" '#{pane_id}')"
    window="$(tmux display-message -p -t "$target" '#{session_name}:#{window_index}')"
    active="$(tmux list-panes -t "$window" -F '#{pane_active} #{pane_id}' | awk '$1 == 1 { print $2 }')"
    if [ "$active" = "$wanted" ]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (active: '$active', wanted: '$wanted')"
        FAIL=1
    fi
}

wait_for_active_pane() {
    local desc="$1" target="$2" i active wanted window
    wanted="$(tmux display-message -p -t "$target" '#{pane_id}')"
    window="$(tmux display-message -p -t "$target" '#{session_name}:#{window_index}')"
    for ((i = 0; i < 40; i++)); do
        active="$(tmux list-panes -t "$window" -F '#{pane_active} #{pane_id}' | awk '$1 == 1 { print $2 }')"
        if [ "$active" = "$wanted" ]; then
            echo "ok - $desc"
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL - $desc (active: '$active', wanted: '$wanted')"
    FAIL=1
    return 1
}

wait_for_shell() {
    local target="$1" marker="$TEST_TMP/ready-marker" i
    tmux send-keys -t "$target" "printf ready > '$marker'" C-m
    for ((i = 0; i < 60; i++)); do
        [ "$(cat "$marker" 2> /dev/null)" = "ready" ] && return 0
        sleep 0.05
    done
    echo "FAIL - shell did not become ready"
    FAIL=1
    return 1
}

wait_for_shell "$LEFT_PANE"

marker="$TEST_TMP/typed-marker"
tmux select-pane -t "$RIGHT_PANE"
ts_type_into_pane "$LEFT_PANE" "printf typed-marker-ran > '$marker'"
sleep 0.2
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
check "type_into_pane types without executing" "$out" "printf typed-marker-ran"
[ -e "$marker" ] && { echo "FAIL - command ran before Enter was sent"; FAIL=1; } || echo "ok - command did not run before Enter"
check_active_pane "typing leaves focus on the operator pane before execution" "$RIGHT_PANE"

ts_send_enter "$LEFT_PANE" "printf typed-marker-ran > '$marker'"
sleep 0.3
[ "$(cat "$marker" 2> /dev/null)" = "typed-marker-ran" ] && echo "ok - send_enter runs the typed command" || { echo "FAIL - send_enter did not run the typed command"; FAIL=1; }
check_active_pane "send_enter keeps focus on the operator pane for non-interactive commands" "$RIGHT_PANE"

interactive_marker="$TEST_TMP/interactive-marker"
ts_type_into_pane "$LEFT_PANE" "sleep 0.6; printf interactive-marker-ran > '$interactive_marker'"
ts_send_enter "$LEFT_PANE" "sudo apt update" "$RIGHT_PANE"
sleep 0.3
check_active_pane "send_enter moves focus to the execution pane for interactive commands" "$LEFT_PANE"
for ((i = 0; i < 30; i++)); do
    [ "$(cat "$interactive_marker" 2> /dev/null)" = "interactive-marker-ran" ] && break
    sleep 0.1
done
[ "$(cat "$interactive_marker" 2> /dev/null)" = "interactive-marker-ran" ] && echo "ok - send_enter still runs an interactive-class command" || { echo "FAIL - send_enter did not run the interactive-class command"; FAIL=1; }
sleep 0.5
wait_for_active_pane "focus returns to the operator pane after the interactive command finishes" "$RIGHT_PANE"
tmux select-pane -t "$RIGHT_PANE"

ts_type_into_pane "$LEFT_PANE" "echo should-be-cleared"
ts_clear_typed_line "$LEFT_PANE"
ts_send_enter "$LEFT_PANE" "echo should-be-cleared"
sleep 0.3
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
if [[ "$out" == *"should-be-cleared"* ]]; then
    echo "FAIL - clear_typed_line did not prevent execution"; FAIL=1
else
    echo "ok - clear_typed_line prevents the command from running"
fi

ts_type_into_pane "$LEFT_PANE" "echo auto-sent"
ts_auto_send "$LEFT_PANE" 0.1 "echo auto-sent"
sleep 0.3
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
check "auto_send runs the typed command after a delay" "$out" "auto-sent"

ts_type_into_pane "$LEFT_PANE" "echo confirmed"
echo | ts_confirm_and_send "$LEFT_PANE" "echo confirmed" > /dev/null
sleep 0.3
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
check "confirm_and_send with empty reply runs the command" "$out" "confirmed"

edit_marker="$TEST_TMP/edit-marker"
ts_type_into_pane "$LEFT_PANE" "printf wrong > '$edit_marker'"
ts_confirm_and_send "$LEFT_PANE" "printf wrong > '$edit_marker'" > /dev/null <<< $'e\nprintf edited-marker-ran > '"$edit_marker"$'\n'
sleep 0.4
[ "$(cat "$edit_marker" 2> /dev/null)" = "edited-marker-ran" ] && echo "ok - confirm_and_send can edit before execution" || { echo "FAIL - edited command did not run"; FAIL=1; }
[ "${TS_CONFIRMED_COMMAND:-}" = "printf edited-marker-ran > $edit_marker" ] && echo "ok - confirm_and_send records edited command" || { echo "FAIL - confirmed command was not updated after edit (got: '${TS_CONFIRMED_COMMAND:-}')"; FAIL=1; }

ts_type_into_pane "$LEFT_PANE" "echo not-confirmed"
echo n | ts_confirm_and_send "$LEFT_PANE" "echo not-confirmed" > /dev/null
sleep 0.3
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
if [[ "$out" == *"not-confirmed"* ]]; then
    echo "FAIL - confirm_and_send with 'n' should not run the command"; FAIL=1
else
    echo "ok - confirm_and_send with 'n' cancels the command"
fi

ts_type_into_pane "$LEFT_PANE" "echo eof-not-confirmed"
ts_confirm_and_send "$LEFT_PANE" "echo eof-not-confirmed" < /dev/null > /dev/null
rc=$?
if [ "$rc" -eq 1 ]; then
    echo "ok - confirm_and_send returns 1 on closed stdin (EOF)"
else
    echo "FAIL - confirm_and_send returned $rc on closed stdin (EOF), expected 1"; FAIL=1
fi
sleep 0.3
out="$(ts_capture_pane_tail "$LEFT_PANE" 5)"
if [[ "$out" == *"eof-not-confirmed"* ]]; then
    echo "FAIL - confirm_and_send on closed stdin should not run the command"; FAIL=1
else
    echo "ok - confirm_and_send on closed stdin cancels the command"
fi

ts_type_into_pane "$LEFT_PANE" "echo one; echo two"
sleep 0.2
# Use -J (join wrapped lines) directly: the pane is narrow relative to the
# shell's prompt, so this line can visually wrap mid-command; -J reconstructs
# the original logical line so the check isn't sensitive to terminal width.
out="$(tmux capture-pane -p -J -t "$LEFT_PANE" -S -5)"
check "type_into_pane preserves a literal semicolon" "$out" "echo one; echo two"
ts_clear_typed_line "$LEFT_PANE"

exit $FAIL
