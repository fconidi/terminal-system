#!/bin/bash
# terminal-system/tests/test_ts_brain_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../build/usr/bin"
STUB_DIR="$HERE/stubs"
SOCK="/tmp/ts-test-brain-$$.sock"
FAIL=0

cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; rm -f "$SOCK"; }
trap cleanup EXIT

export PATH="$STUB_DIR:$BIN_DIR:$PATH"
tmux -S "$SOCK" new-session -d -s bootstrap -x 80 -y 10

check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == *"$want"* ]]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (got: '$got', want to contain: '$want')"
        FAIL=1
    fi
}
not_contains() {
    local desc="$1" got="$2" absent="$3"
    if [[ "$got" == *"$absent"* ]]; then
        echo "FAIL - $desc (should not contain '$absent', got: '$got')"
        FAIL=1
    else
        echo "ok - $desc"
    fi
}
check_count() {
    # Asserts that $needle occurs exactly $want times in $got. Used where a
    # plain contains/not_contains would be ambiguous: e.g. a still-pending,
    # unexecuted "echo SECOND-CMD" typed into the pane already contains the
    # substring "SECOND-CMD", so absence-of-substring can't distinguish
    # "typed but not yet run" from "already executed" (which adds a second,
    # standalone "SECOND-CMD" output line).
    local desc="$1" got="$2" needle="$3" want="$4" n
    n="$(grep -o -F -- "$needle" <<< "$got" | wc -l)"
    if [ "$n" -eq "$want" ]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (expected '$needle' to occur $want time(s), occurred $n; got: '$got')"
        FAIL=1
    fi
}

start_session() {
    local name="$1"
    START_LEFT_PANE="$(tmux -S "$SOCK" new-session -d -s "$name" -x 220 -y 50 -P -F '#{pane_id}')"
    START_RIGHT_PANE="$(tmux -S "$SOCK" split-window -h -t "$START_LEFT_PANE" -P -F '#{pane_id}')"
    tmux -S "$SOCK" send-keys -t "$START_RIGHT_PANE" "PATH='$STUB_DIR:$BIN_DIR:$PATH' exec ts-brain '$name' '$START_LEFT_PANE' claude" C-m
    sleep 1.5
}

# --- Scenario 1: single instruction -> single command typed and auto-run ---
export TS_STUB_RESPONSE="echo hello-from-ai"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s1
tmux -S "$SOCK" send-keys -t s1:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s1:0.1 "greet the world" C-m
sleep 0.6
out="$(tmux -S "$SOCK" capture-pane -p -t s1:0.0 -S -10)"
check "scenario 1: instruction produces expected command output" "$out" "hello-from-ai"
tmux -S "$SOCK" send-keys -t s1:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 2: blocklisted command forces manual confirm even in auto-mode ---
export TS_STUB_RESPONSE="rm -rf /"
# tmux caches the server's global environment at server-start time and does
# NOT refresh it for sessions created later on an already-running server;
# without this, s2's session would silently inherit scenario 1's stub value.
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s2
tmux -S "$SOCK" send-keys -t s2:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s2:0.1 "clean everything" C-m
sleep 0.6
left_before="$(tmux -S "$SOCK" capture-pane -p -t s2:0.0 -S -10)"
not_contains "scenario 2: dangerous command is NOT auto-executed" "$left_before" "No such file or directory"
right_out="$(tmux -S "$SOCK" capture-pane -p -t s2:0.1 -S -10)"
check "scenario 2: brain asks for confirmation despite auto-mode" "$right_out" "CONFIRM"
tmux -S "$SOCK" send-keys -t s2:0.1 "n" C-m
sleep 0.3
tmux -S "$SOCK" send-keys -t s2:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 3: multi-step response queues each command independently ---
export TS_STUB_RESPONSE=$'echo step-one\necho step-two\necho step-three'
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s3
tmux -S "$SOCK" send-keys -t s3:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s3:0.1 "update the system" C-m
sleep 2.0
out="$(tmux -S "$SOCK" capture-pane -p -t s3:0.0 -S -20)"
check "scenario 3: first queued command ran" "$out" "step-one"
check "scenario 3: second queued command ran" "$out" "step-two"
check "scenario 3: third queued command ran" "$out" "step-three"
tmux -S "$SOCK" send-keys -t s3:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 4: engine fallback when the requested engine is unavailable ---
FALLBACK_DIR="$(mktemp -d)"
cp "$STUB_DIR/codex" "$FALLBACK_DIR/codex"
export TS_STUB_RESPONSE="echo via-codex"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
s4_left="$(tmux -S "$SOCK" new-session -d -s s4 -x 220 -y 50 -P -F '#{pane_id}')"
s4_right="$(tmux -S "$SOCK" split-window -h -t "$s4_left" -P -F '#{pane_id}')"
tmux -S "$SOCK" send-keys -t "$s4_right" "PATH='$FALLBACK_DIR:$BIN_DIR:/usr/bin:/bin' HOME=/nonexistent exec ts-brain s4 '$s4_left' claude" C-m
sleep 1.5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s4:0.1 -S -10)"
check "scenario 4: falls back to codex when claude is unavailable" "$right_out" "codex"
tmux -S "$SOCK" send-keys -t s4:0.1 ":quit" C-m
sleep 0.2
rm -rf "$FALLBACK_DIR"

# --- Scenario 4b: runtime fallback when Claude exists but fails (e.g. quota exhausted) ---
export TS_STUB_EXIT_CLAUDE=1
export TS_STUB_RESPONSE_CODEX="echo runtime-codex"
tmux -S "$SOCK" set-environment -g TS_STUB_EXIT_CLAUDE "$TS_STUB_EXIT_CLAUDE" 2>/dev/null
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE_CODEX "$TS_STUB_RESPONSE_CODEX" 2>/dev/null
start_session s4b
tmux -S "$SOCK" send-keys -t s4b:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s4b:0.1 "use the runtime fallback" C-m
sleep 1.0
right_out="$(tmux -S "$SOCK" capture-pane -p -t s4b:0.1 -S -20)"
check "scenario 4b: reports runtime fallback to codex" "$right_out" "engine: codex"
out="$(tmux -S "$SOCK" capture-pane -p -t s4b:0.0 -S -10)"
check "scenario 4b: codex fallback command ran" "$out" "runtime-codex"
tmux -S "$SOCK" send-keys -t s4b:0.1 ":quit" C-m
sleep 0.2
unset TS_STUB_EXIT_CLAUDE TS_STUB_RESPONSE_CODEX
tmux -S "$SOCK" set-environment -gu TS_STUB_EXIT_CLAUDE 2>/dev/null
tmux -S "$SOCK" set-environment -gu TS_STUB_RESPONSE_CODEX 2>/dev/null

# --- Scenario 5: unparseable (prosy) response requires explicit confirmation ---
export TS_STUB_RESPONSE="To complete this operation you should first check the system state and then proceed carefully."
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s5
tmux -S "$SOCK" send-keys -t s5:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5:0.1 "do something vague" C-m
sleep 0.5
left_before="$(tmux -S "$SOCK" capture-pane -p -t s5:0.0 -S -10)"
not_contains "scenario 5: nothing typed into left pane before confirmation" "$left_before" "To complete"
tmux -S "$SOCK" send-keys -t s5:0.1 "n" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 5b: confirmed raw/prosy response still forces per-line manual confirmation in auto-mode ---
export TS_STUB_RESPONSE=$'# a b c d e f g h i j k l m\necho UNPARSEABLE-AUTO'
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s5b
tmux -S "$SOCK" send-keys -t s5b:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5b:0.1 "do something with ambiguous text" C-m
sleep 0.8
tmux -S "$SOCK" send-keys -t s5b:0.1 Enter
sleep 1.2
right_out="$(tmux -S "$SOCK" capture-pane -p -t s5b:0.1 -S -20)"
check "scenario 5b: confirmed raw response asks per-line confirmation" "$right_out" "[CONFIRM]"
left_after_confirm="$(tmux -S "$SOCK" capture-pane -p -J -t s5b:0.0 -S -10)"
not_contains "scenario 5b: auto-mode does not execute later raw lines after one confirmation" "$left_after_confirm" "UNPARSEABLE-AUTO"
tmux -S "$SOCK" send-keys -t s5b:0.1 "n" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5b:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 6: multi-command response with a dangerous first command ---
# Regression test for a fixed bug: `while IFS= read -r cmd; do ... done <<<
# "$parsed"` used to redirect stdin for the WHOLE loop body, so
# ts_confirm_and_send's own `IFS= read -r reply` silently consumed the NEXT
# queued command line as if it were the human's y/n answer, defeating the
# danger guardrail for any multi-command response. Not in auto-mode: this is
# the plain confirm-by-default path, which the bug affected identically.
export TS_STUB_RESPONSE=$'mkfs.ext4 /dev/nonexistent-ts-test-device\necho SECOND-CMD'
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s6
tmux -S "$SOCK" send-keys -t s6:0.1 "prepare the new disk" C-m
sleep 1.2
right_out="$(tmux -S "$SOCK" capture-pane -p -t s6:0.1 -S -20)"
check "scenario 6: dangerous first command gets its own confirmation prompt" "$right_out" "[CONFIRM] mkfs.ext4"
# -J joins soft-wrapped lines: the pane is narrow relative to the shell
# prompt, so this long command can wrap mid-word without it.
left_before="$(tmux -S "$SOCK" capture-pane -p -J -t s6:0.0 -S -10)"
check "scenario 6: dangerous first command is typed (pending) into left pane" "$left_before" "mkfs.ext4 /dev/nonexistent-ts-test-device"
not_contains "scenario 6: dangerous first command was NOT executed before confirmation" "$left_before" "No such file or directory"

tmux -S "$SOCK" send-keys -t s6:0.1 "n" C-m
sleep 0.6
right_out2="$(tmux -S "$SOCK" capture-pane -p -t s6:0.1 -S -20)"
check "scenario 6: declining the first command reaches the second command's own confirmation (not swallowed)" "$right_out2" "[CONFIRM] echo SECOND-CMD"
left_after_n="$(tmux -S "$SOCK" capture-pane -p -J -t s6:0.0 -S -10)"
not_contains "scenario 6: declined dangerous command still did not execute" "$left_after_n" "No such file or directory"
check_count "scenario 6: second command is only pending (typed once), not yet executed" "$left_after_n" "SECOND-CMD" 1

tmux -S "$SOCK" send-keys -t s6:0.1 C-m
sleep 0.6
left_final="$(tmux -S "$SOCK" capture-pane -p -J -t s6:0.0 -S -10)"
check_count "scenario 6: second command executes once independently confirmed (typed line + output line)" "$left_final" "SECOND-CMD" 2
tmux -S "$SOCK" send-keys -t s6:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 6b: manual confirmation can edit a generated command before execution ---
export TS_STUB_RESPONSE="echo WRONG-E2E"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s6b
tmux -S "$SOCK" send-keys -t s6b:0.1 "fix before running" C-m
sleep 0.8
tmux -S "$SOCK" send-keys -t s6b:0.1 "e" C-m
sleep 0.3
tmux -S "$SOCK" send-keys -t s6b:0.1 C-u "echo EDITED-E2E" C-m
sleep 0.8
right_out="$(tmux -S "$SOCK" capture-pane -p -t s6b:0.1 -S -20)"
check "scenario 6b: edited command gets a new confirmation prompt" "$right_out" "[CONFIRM] echo EDITED-E2E"
tmux -S "$SOCK" send-keys -t s6b:0.1 C-m
sleep 0.6
left_edited="$(tmux -S "$SOCK" capture-pane -p -J -t s6b:0.0 -S -12)"
check "scenario 6b: edited command executes" "$left_edited" "EDITED-E2E"
tmux -S "$SOCK" send-keys -t s6b:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 6c: fully manual command entry bypasses the AI engine ---
export TS_STUB_EXIT_CLAUDE=1
export TS_STUB_EXIT_CODEX=1
export TS_STUB_RESPONSE="echo AI-SHOULD-NOT-RUN"
tmux -S "$SOCK" set-environment -g TS_STUB_EXIT_CLAUDE "$TS_STUB_EXIT_CLAUDE" 2>/dev/null
tmux -S "$SOCK" set-environment -g TS_STUB_EXIT_CODEX "$TS_STUB_EXIT_CODEX" 2>/dev/null
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s6c
tmux -S "$SOCK" send-keys -t s6c:0.1 ":cmd echo MANUAL-CMD-E2E" C-m
sleep 0.8
right_out="$(tmux -S "$SOCK" capture-pane -p -t s6c:0.1 -S -20)"
check "scenario 6c: :cmd asks for confirmation without AI" "$right_out" "[CONFIRM] echo MANUAL-CMD-E2E"
tmux -S "$SOCK" send-keys -t s6c:0.1 C-m
sleep 0.6
left_manual="$(tmux -S "$SOCK" capture-pane -p -J -t s6c:0.0 -S -12)"
check "scenario 6c: :cmd executes the manual command" "$left_manual" "MANUAL-CMD-E2E"
not_contains "scenario 6c: :cmd does not run AI output" "$left_manual" "AI-SHOULD-NOT-RUN"
tmux -S "$SOCK" send-keys -t s6c:0.1 ":manual" C-m
sleep 0.3
tmux -S "$SOCK" send-keys -t s6c:0.1 "echo MANUAL-PROMPT-E2E" C-m
sleep 0.8
right_out="$(tmux -S "$SOCK" capture-pane -p -t s6c:0.1 -S -20)"
check "scenario 6c: :manual asks for confirmation" "$right_out" "[CONFIRM] echo MANUAL-PROMPT-E2E"
tmux -S "$SOCK" send-keys -t s6c:0.1 C-m
sleep 0.6
left_manual_prompt="$(tmux -S "$SOCK" capture-pane -p -J -t s6c:0.0 -S -16)"
check "scenario 6c: :manual executes the prompted command" "$left_manual_prompt" "MANUAL-PROMPT-E2E"
tmux -S "$SOCK" send-keys -t s6c:0.1 ":quit" C-m
sleep 0.2
unset TS_STUB_EXIT_CLAUDE TS_STUB_EXIT_CODEX TS_STUB_RESPONSE
tmux -S "$SOCK" set-environment -gu TS_STUB_EXIT_CLAUDE 2>/dev/null
tmux -S "$SOCK" set-environment -gu TS_STUB_EXIT_CODEX 2>/dev/null
tmux -S "$SOCK" set-environment -gu TS_STUB_RESPONSE 2>/dev/null

# --- Scenario 7: missing left pane exits instead of targeting the renumbered right pane ---
export TS_STUB_RESPONSE="echo SHOULD-NOT-SELF-FEED"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s7
tmux -S "$SOCK" send-keys -t s7:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" kill-pane -t "$START_LEFT_PANE"
sleep 0.2
tmux -S "$SOCK" send-keys -t "$START_RIGHT_PANE" "continue anyway" C-m
sleep 1.2
if tmux -S "$SOCK" has-session -t s7 2>/dev/null; then
    echo "FAIL - scenario 7: session should close when target pane is gone"
    FAIL=1
    tmux -S "$SOCK" kill-session -t s7 2>/dev/null
else
    echo "ok - scenario 7: session closes when target pane is gone"
fi

exit $FAIL
