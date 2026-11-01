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

# --- Scenario 8: a command that is not on the dangerous denylist but is
# also not on the new safe-readonly allowlist still asks for confirmation
# in auto-mode. Regression test for the 2026-09-07 review finding: the old
# denylist-only auto-mode would have run this without asking.
export TS_STUB_RESPONSE="systemctl restart networking"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s8
tmux -S "$SOCK" send-keys -t s8:0.1 ":auto readonly" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s8:0.1 "restart networking" C-m
sleep 0.6
right_out="$(tmux -S "$SOCK" capture-pane -p -t s8:0.1 -S -10)"
check "scenario 8: non-allowlisted, non-dangerous command still asks in auto-mode" "$right_out" "[CONFIRM] systemctl restart networking"
tmux -S "$SOCK" send-keys -t s8:0.1 "n" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s8:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 9: context is off by default (nothing sent to the AI engine
# from a prior instruction) and only carried forward after :context on.
context_log="$(mktemp)"
export TS_STUB_RESPONSE="echo first-instruction-output"
export TS_STUB_ARG_LOG="$context_log"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
tmux -S "$SOCK" set-environment -g TS_STUB_ARG_LOG "$context_log" 2>/dev/null
start_session s9
tmux -S "$SOCK" send-keys -t s9:0.1 "run the first instruction" C-m
sleep 0.6
tmux -S "$SOCK" send-keys -t s9:0.1 C-m
sleep 0.4
export TS_STUB_RESPONSE="echo second-instruction-output"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
tmux -S "$SOCK" send-keys -t s9:0.1 "run a second instruction" C-m
sleep 0.6
prompt_arg="$(cat "$context_log")"
not_contains "scenario 9: context off by default -- prior instruction not sent to the AI engine" "$prompt_arg" "run the first instruction"
tmux -S "$SOCK" send-keys -t s9:0.1 C-m
sleep 0.4
tmux -S "$SOCK" send-keys -t s9:0.1 ":context on" C-m
sleep 0.2
export TS_STUB_RESPONSE="echo third-instruction-output"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
tmux -S "$SOCK" send-keys -t s9:0.1 "run a third instruction" C-m
sleep 0.6
tmux -S "$SOCK" send-keys -t s9:0.1 C-m
sleep 0.4
export TS_STUB_RESPONSE="echo fourth-instruction-output"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
tmux -S "$SOCK" send-keys -t s9:0.1 "run a fourth instruction" C-m
sleep 0.6
prompt_arg="$(cat "$context_log")"
check "scenario 9: after :context on, a later prompt carries the prior instruction" "$prompt_arg" "run a third instruction"
tmux -S "$SOCK" send-keys -t s9:0.1 ":context show" C-m
sleep 0.2
right_out="$(tmux -S "$SOCK" capture-pane -p -t s9:0.1 -S -20)"
check "scenario 9: :context show prints stored context" "$right_out" "run a third instruction"
tmux -S "$SOCK" send-keys -t s9:0.1 ":quit" C-m
sleep 0.2
rm -f "$context_log"
unset TS_STUB_ARG_LOG
tmux -S "$SOCK" set-environment -gu TS_STUB_ARG_LOG 2>/dev/null

# --- Scenario 10: exit status reported; :fix diagnoses and always confirms ---
fix_log="$(mktemp)"
export TS_STUB_ARG_LOG="$fix_log"
tmux -S "$SOCK" set-environment -g TS_STUB_ARG_LOG "$TS_STUB_ARG_LOG" 2>/dev/null
fix_resp="$(mktemp)"
printf 'ls /nonexistent-ts-fix-dir\n' > "$fix_resp"
export TS_STUB_RESPONSE_FILE="$fix_resp"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE_FILE "$fix_resp" 2>/dev/null
start_session s10
tmux -S "$SOCK" send-keys -t s10:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s10:0.1 "list a missing dir" C-m
sleep 1.2
right_out="$(tmux -S "$SOCK" capture-pane -p -t s10:0.1 -S -20)"
check "scenario 10: failed command shows its exit status" "$right_out" "(exit 2)"
check "scenario 10: failed command hints at :fix" "$right_out" "type :fix"
prompt_arg="$(cat "$fix_log")"
check "scenario 10: instruction prompt carries the environment block" "$prompt_arg" "Environment:"
printf '# the directory does not exist\necho fixed-by-ai\n' > "$fix_resp"
tmux -S "$SOCK" send-keys -t s10:0.1 ":fix" C-m
sleep 1.2
right_out="$(tmux -S "$SOCK" capture-pane -p -t s10:0.1 -S -20)"
check "scenario 10: :fix prints the cause" "$right_out" "cause: the directory does not exist"
check "scenario 10: fix command asks confirmation even in auto-mode" "$right_out" "[CONFIRM] echo fixed-by-ai"
prompt_arg="$(cat "$fix_log")"
check "scenario 10: fix prompt carries exit status" "$prompt_arg" "Exit status: 2"
tmux -S "$SOCK" send-keys -t s10:0.1 C-m
sleep 0.6
out="$(tmux -S "$SOCK" capture-pane -p -t s10:0.0 -S -20)"
check "scenario 10: confirmed fix executes" "$out" "fixed-by-ai"
tmux -S "$SOCK" send-keys -t s10:0.1 ":fix" C-m
sleep 0.3
right_out="$(tmux -S "$SOCK" capture-pane -p -t s10:0.1 -S -6)"
check "scenario 10: :fix with nothing recorded says so" "$right_out" "nothing to fix"
tmux -S "$SOCK" send-keys -t s10:0.1 ":quit" C-m
sleep 0.2
rm -f "$fix_log" "$fix_resp"
unset TS_STUB_RESPONSE_FILE
tmux -S "$SOCK" set-environment -gu TS_STUB_RESPONSE_FILE 2>/dev/null
unset TS_STUB_ARG_LOG
tmux -S "$SOCK" set-environment -gu TS_STUB_ARG_LOG 2>/dev/null

# --- Scenario 11: :follow runs steps, feeds output back, stops on DONE ---
seq_dir="$(mktemp -d)"
printf 'echo step-a\n' > "$seq_dir/1"
printf 'echo step-b\n' > "$seq_dir/2"
printf 'DONE\n# goal reached\n' > "$seq_dir/3"
follow_log="$(mktemp)"
export TS_STUB_SEQ_DIR="$seq_dir" TS_STUB_ARG_LOG="$follow_log"
tmux -S "$SOCK" set-environment -g TS_STUB_SEQ_DIR "$seq_dir" 2>/dev/null
tmux -S "$SOCK" set-environment -g TS_STUB_ARG_LOG "$follow_log" 2>/dev/null
start_session s11
tmux -S "$SOCK" send-keys -t s11:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s11:0.1 ":follow check things" C-m
sleep 5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s11:0.1 -S -30)"
check "scenario 11: first step announced" "$right_out" "step 1/5"
check "scenario 11: second step announced" "$right_out" "step 2/5"
check "scenario 11: stops on DONE with summary" "$right_out" "goal reached"
out="$(tmux -S "$SOCK" capture-pane -p -t s11:0.0 -S -30)"
check "scenario 11: step one ran in the left panel" "$out" "step-a"
check "scenario 11: step two ran in the left panel" "$out" "step-b"
prompt_arg="$(cat "$follow_log")"
check "scenario 11: last request carries the earlier output" "$prompt_arg" "step 1: echo step-a"
tmux -S "$SOCK" send-keys -t s11:0.1 ":quit" C-m
sleep 0.2
rm -rf "$seq_dir" "$follow_log"
unset TS_STUB_SEQ_DIR TS_STUB_ARG_LOG
tmux -S "$SOCK" set-environment -gu TS_STUB_SEQ_DIR 2>/dev/null
tmux -S "$SOCK" set-environment -gu TS_STUB_ARG_LOG 2>/dev/null

# --- Scenario 11b: :follow stops when the same step comes back twice ---
export TS_STUB_RESPONSE="echo same-step"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s11b
tmux -S "$SOCK" send-keys -t s11b:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s11b:0.1 ":follow loop forever" C-m
sleep 4
right_out="$(tmux -S "$SOCK" capture-pane -p -t s11b:0.1 -S -30)"
check "scenario 11b: repeated step stops the loop" "$right_out" "same step came back twice"
tmux -S "$SOCK" send-keys -t s11b:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 12: :watch opens an observer panel that advises on errors ---
watch_resp="$(mktemp)"
printf 'The directory is missing.\n$ mkdir /nonexistent-watch-dir\n' > "$watch_resp"
export TS_STUB_RESPONSE_FILE="$watch_resp"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE_FILE "$watch_resp" 2>/dev/null
consent_dir="$(mktemp -d)"
mkdir -p "$consent_dir/terminal-system"; date +%F > "$consent_dir/terminal-system/watch-consent"
export XDG_STATE_HOME="$consent_dir"
tmux -S "$SOCK" set-environment -g XDG_STATE_HOME "$consent_dir" 2>/dev/null
start_session s12
tmux -S "$SOCK" send-keys -t s12:0.1 ":watch on" C-m
sleep 1.5
panes="$(tmux -S "$SOCK" list-panes -t s12 | wc -l)"
check "scenario 12: :watch on opens a third panel" "$panes" "3"
tmux -S "$SOCK" send-keys -t s12:0.0 "ls /nonexistent-watch-dir" C-m
sleep 8
watch_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.2 -S -20)"
check "scenario 12: observer prints advice for an error" "$watch_out" "The directory is missing."
left_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.0 -S -20)"
not_contains "scenario 12: observer never types into the left panel" "$left_out" "mkdir /nonexistent-watch-dir"
# pause: output produced while paused must never reach the AI
printf 'SHOULD-NOT-APPEAR-WHILE-PAUSED\n' > "$watch_resp"
tmux -S "$SOCK" send-keys -t s12:0.1 ":watch pause" C-m
sleep 2.5
watch_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.2 -S -30)"
check "scenario 12: pause is announced in the observer" "$watch_out" "paused"
tmux -S "$SOCK" send-keys -t s12:0.0 "ls /nonexistent-paused-dir" C-m
sleep 9
watch_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.2 -S -30)"
not_contains "scenario 12: nothing is analysed while paused" "$watch_out" "SHOULD-NOT-APPEAR-WHILE-PAUSED"
tmux -S "$SOCK" send-keys -t s12:0.1 ":watch resume" C-m
sleep 3
watch_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.2 -S -30)"
check "scenario 12: resume is announced" "$watch_out" "resumed"
sleep 8
watch_out="$(tmux -S "$SOCK" capture-pane -p -t s12:0.2 -S -30)"
not_contains "scenario 12: output from the paused period is not sent after resume" "$watch_out" "SHOULD-NOT-APPEAR-WHILE-PAUSED"
tmux -S "$SOCK" send-keys -t s12:0.1 ":watch off" C-m
sleep 0.6
panes="$(tmux -S "$SOCK" list-panes -t s12 | wc -l)"
check "scenario 12: :watch off closes the panel" "$panes" "2"
tmux -S "$SOCK" send-keys -t s12:0.1 ":quit" C-m
sleep 0.2
rm -f "$watch_resp"
unset TS_STUB_RESPONSE_FILE
tmux -S "$SOCK" set-environment -gu TS_STUB_RESPONSE_FILE 2>/dev/null

# --- Scenario 13: structured JSON reply; why/risk shown; high risk beats auto; ? explains ---
json_resp="$(mktemp)"
cat > "$json_resp" << 'JSON'
{"commands":[{"cmd":"echo json-low","why":"prints a word","risk":"low"},{"cmd":"echo json-high","why":"pretends to be dangerous","risk":"high"}]}
JSON
export TS_STUB_RESPONSE_FILE="$json_resp"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE_FILE "$json_resp" 2>/dev/null
start_session s13
tmux -S "$SOCK" send-keys -t s13:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s13:0.1 "say words" C-m
sleep 2
out="$(tmux -S "$SOCK" capture-pane -p -t s13:0.0 -S -20)"
check "scenario 13: low-risk read-only command auto-runs" "$out" "json-low"
right_out="$(tmux -S "$SOCK" capture-pane -p -t s13:0.1 -S -20)"
check "scenario 13: high-risk command asks despite auto-mode" "$right_out" "[CONFIRM] echo json-high"
check "scenario 13: confirm shows why and risk" "$right_out" "pretends to be dangerous  [risk: high]"
printf 'This only prints a word.\n' > "$json_resp"
tmux -S "$SOCK" send-keys -t s13:0.1 "?" C-m
sleep 1.5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s13:0.1 -S -20)"
check "scenario 13: ? asks the AI to explain" "$right_out" "This only prints a word."
tmux -S "$SOCK" send-keys -t s13:0.1 "n" C-m
sleep 0.3
tmux -S "$SOCK" send-keys -t s13:0.1 ":quit" C-m
sleep 0.2
rm -f "$json_resp"
unset TS_STUB_RESPONSE_FILE
tmux -S "$SOCK" set-environment -gu TS_STUB_RESPONSE_FILE 2>/dev/null

# --- Scenario 12b: first :watch needs consent; refusal enables nothing ---
nc_dir="$(mktemp -d)"
export XDG_STATE_HOME="$nc_dir"
tmux -S "$SOCK" set-environment -g XDG_STATE_HOME "$nc_dir" 2>/dev/null
start_session s12b
tmux -S "$SOCK" send-keys -t s12b:0.1 ":watch on" C-m
sleep 0.5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s12b:0.1 -S -20)"
check "scenario 12b: consent notice is shown" "$right_out" "sends its recent output"
tmux -S "$SOCK" send-keys -t s12b:0.1 "n" C-m
sleep 0.5
panes="$(tmux -S "$SOCK" list-panes -t s12b | wc -l)"
check "scenario 12b: refusing opens no observer" "$panes" "2"
[ ! -e "$nc_dir/terminal-system/watch-consent" ] && echo "ok - scenario 12b: refusal is not remembered" || { echo "FAIL - scenario 12b: refusal was remembered"; FAIL=1; }
tmux -S "$SOCK" send-keys -t s12b:0.1 ":watch on" C-m
sleep 0.5
tmux -S "$SOCK" send-keys -t s12b:0.1 "y" C-m
sleep 1
panes="$(tmux -S "$SOCK" list-panes -t s12b | wc -l)"
check "scenario 12b: accepting opens the observer" "$panes" "3"
[ -f "$nc_dir/terminal-system/watch-consent" ] && echo "ok - scenario 12b: consent is remembered" || { echo "FAIL - scenario 12b: consent not stored"; FAIL=1; }
tmux -S "$SOCK" send-keys -t s12b:0.1 ":quit" C-m
sleep 0.2
rm -rf "$nc_dir" "$consent_dir"
unset XDG_STATE_HOME
tmux -S "$SOCK" set-environment -gu XDG_STATE_HOME 2>/dev/null

# --- Scenario 14: a yes/no prompt in the left panel pulls focus there, then returns ---
export TS_STUB_RESPONSE="python3 -c \"a=input('Proceed? [y/N] ');print('got-'+a)\""
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s14
right_id="$(tmux -S "$SOCK" display-message -p -t s14:0.1 '#{pane_id}')"
left_id="$(tmux -S "$SOCK" display-message -p -t s14:0.0 '#{pane_id}')"
tmux -S "$SOCK" send-keys -t s14:0.1 "ask me something" C-m
sleep 1
tmux -S "$SOCK" send-keys -t s14:0.1 C-m
sleep 2
active="$(tmux -S "$SOCK" list-panes -t s14 -F '#{pane_active} #{pane_id}' | awk '$1==1{print $2}')"
check "scenario 14: focus moved to the left panel at the prompt" "$active" "$left_id"
right_out="$(tmux -S "$SOCK" capture-pane -p -t s14:0.1 -S -20)"
check "scenario 14: the right panel says why" "$right_out" "waiting for your input"
tmux -S "$SOCK" send-keys -t s14:0.0 "y" C-m
sleep 1.5
active="$(tmux -S "$SOCK" list-panes -t s14 -F '#{pane_active} #{pane_id}' | awk '$1==1{print $2}')"
check "scenario 14: focus returned to the right panel" "$active" "$right_id"
out="$(tmux -S "$SOCK" capture-pane -p -t s14:0.0 -S -20)"
check "scenario 14: the answer reached the program" "$out" "got-y"
tmux -S "$SOCK" send-keys -t s14:0.1 ":quit" C-m
sleep 0.2

# --- Scenario 15: long command -> status lines, no 120 s abort, Ctrl-C stops waiting ---
export TS_STATUS_AFTER=1 TS_STATUS_EVERY=1 TS_NOTIFY_AFTER=2
for v in TS_STATUS_AFTER TS_STATUS_EVERY TS_NOTIFY_AFTER; do tmux -S "$SOCK" set-environment -g "$v" "${!v}" 2>/dev/null; done
export TS_STUB_RESPONSE="sleep 4"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s15
tmux -S "$SOCK" send-keys -t s15:0.1 "wait a bit" C-m
sleep 1
tmux -S "$SOCK" send-keys -t s15:0.1 C-m
sleep 7
right_out="$(tmux -S "$SOCK" capture-pane -p -t s15:0.1 -S -30)"
check "scenario 15: long command prints a still-running line" "$right_out" "still running"
check "scenario 15: long command reports its duration" "$right_out" "finished after"
check "scenario 15: result is still reported" "$right_out" "-> ran: sleep 4"
export TS_STUB_RESPONSE="sleep 30"
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
tmux -S "$SOCK" kill-session -t s15
start_session s15b
tmux -S "$SOCK" send-keys -t s15b:0.1 "wait long" C-m
sleep 1
tmux -S "$SOCK" send-keys -t s15b:0.1 C-m
sleep 3
tmux -S "$SOCK" send-keys -t s15b:0.1 C-c
sleep 1.5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s15b:0.1 -S -30)"
check "scenario 15: Ctrl-C stops waiting" "$right_out" "stopped waiting"
tmux -S "$SOCK" send-keys -t s15b:0.0 C-c
for v in TS_STATUS_AFTER TS_STATUS_EVERY TS_NOTIFY_AFTER; do tmux -S "$SOCK" set-environment -gu "$v" 2>/dev/null; unset "$v"; done
tmux -S "$SOCK" send-keys -t s15b:0.1 ":quit" C-m
sleep 0.2

exit $FAIL
