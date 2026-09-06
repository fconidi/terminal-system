#!/bin/bash
# terminal-system/tests/test_ts_brain_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../build/usr/bin"
STUB_DIR="$HERE/stubs"
SOCK="/tmp/ts-test-brain-$$.sock"
FAIL=0

cleanup() { tmux -S "$SOCK" kill-server > /dev/null 2>&1; }
trap cleanup EXIT

export PATH="$STUB_DIR:$BIN_DIR:$PATH"

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

start_session() {
    local name="$1"
    tmux -S "$SOCK" new-session -d -s "$name" -x 220 -y 50
    tmux -S "$SOCK" split-window -h -t "$name:0"
    tmux -S "$SOCK" send-keys -t "$name:0.1" "PATH='$STUB_DIR:$BIN_DIR:$PATH' exec ts-brain '$name' '$name:0.0' claude" C-m
    sleep 1.5
}

# --- Scenario 1: single instruction -> single command typed and auto-run ---
export TS_STUB_RESPONSE="echo hello-from-ai"
start_session s1
tmux -S "$SOCK" send-keys -t s1:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s1:0.1 "saluta il mondo" C-m
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
tmux -S "$SOCK" send-keys -t s2:0.1 "pulisci tutto" C-m
sleep 0.6
left_before="$(tmux -S "$SOCK" capture-pane -p -t s2:0.0 -S -10)"
not_contains "scenario 2: dangerous command is NOT auto-executed" "$left_before" "No such file or directory"
right_out="$(tmux -S "$SOCK" capture-pane -p -t s2:0.1 -S -10)"
check "scenario 2: brain asks for confirmation despite auto-mode" "$right_out" "CONFERMA"
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
tmux -S "$SOCK" send-keys -t s3:0.1 "aggiorna il sistema" C-m
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
tmux -S "$SOCK" new-session -d -s s4 -x 220 -y 50
tmux -S "$SOCK" split-window -h -t s4:0
tmux -S "$SOCK" send-keys -t s4:0.1 "PATH='$FALLBACK_DIR:$BIN_DIR:/usr/bin:/bin' HOME=/nonexistent exec ts-brain s4 s4:0.0 claude" C-m
sleep 1.5
right_out="$(tmux -S "$SOCK" capture-pane -p -t s4:0.1 -S -10)"
check "scenario 4: falls back to codex when claude is unavailable" "$right_out" "codex"
tmux -S "$SOCK" send-keys -t s4:0.1 ":quit" C-m
sleep 0.2
rm -rf "$FALLBACK_DIR"

# --- Scenario 5: unparseable (prosy) response requires explicit confirmation ---
export TS_STUB_RESPONSE="Per completare questa operazione dovresti prima verificare lo stato del sistema e poi procedere con cautela."
tmux -S "$SOCK" set-environment -g TS_STUB_RESPONSE "$TS_STUB_RESPONSE" 2>/dev/null
start_session s5
tmux -S "$SOCK" send-keys -t s5:0.1 ":auto on" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5:0.1 "fai qualcosa di vago" C-m
sleep 0.5
left_before="$(tmux -S "$SOCK" capture-pane -p -t s5:0.0 -S -10)"
not_contains "scenario 5: nothing typed into left pane before confirmation" "$left_before" "Per completare"
tmux -S "$SOCK" send-keys -t s5:0.1 "n" C-m
sleep 0.2
tmux -S "$SOCK" send-keys -t s5:0.1 ":quit" C-m
sleep 0.2

exit $FAIL
