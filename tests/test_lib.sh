#!/bin/bash
# terminal-system/tests/test_lib.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../build/usr/lib/terminal-system/lib.sh"
FAIL=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc (got: '$got', want: '$want')"
        FAIL=1
    fi
}

test_resolve_bin_via_path() {
    local tmpdir; tmpdir="$(mktemp -d)"
    printf '#!/bin/bash\necho fake\n' > "$tmpdir/claude"
    chmod +x "$tmpdir/claude"
    ( PATH="$tmpdir:$PATH"; . "$LIB"
      got="$(ts_resolve_bin claude)"
      check "resolve_bin finds claude on PATH" "$got" "$tmpdir/claude" )
    rm -rf "$tmpdir"
}

test_resolve_bin_via_local_bin_fallback() {
    local tmphome; tmphome="$(mktemp -d)"
    mkdir -p "$tmphome/.local/bin"
    printf '#!/bin/bash\necho fake\n' > "$tmphome/.local/bin/codex"
    chmod +x "$tmphome/.local/bin/codex"
    ( HOME="$tmphome"; PATH="/nonexistent"; . "$LIB"
      got="$(ts_resolve_bin codex)"
      check "resolve_bin falls back to ~/.local/bin" "$got" "$tmphome/.local/bin/codex" )
    rm -rf "$tmphome"
}

test_resolve_bin_not_found() {
    ( PATH="/nonexistent"; HOME="/nonexistent"; . "$LIB"
      if ts_resolve_bin claude > /dev/null 2>&1; then
          echo "FAIL - resolve_bin should fail when nothing is installed"; FAIL=1
      else
          echo "ok - resolve_bin fails cleanly when nothing is installed"
      fi )
}

test_pick_engine_requested_available() {
    local tmpdir; tmpdir="$(mktemp -d)"
    printf '#!/bin/bash\n' > "$tmpdir/claude"; chmod +x "$tmpdir/claude"
    printf '#!/bin/bash\n' > "$tmpdir/codex"; chmod +x "$tmpdir/codex"
    ( PATH="$tmpdir:$PATH"; . "$LIB"
      got="$(ts_pick_engine claude)"
      check "pick_engine returns requested engine when available" "$got" "claude" )
    rm -rf "$tmpdir"
}

test_pick_engine_falls_back() {
    local tmpdir; tmpdir="$(mktemp -d)"
    printf '#!/bin/bash\n' > "$tmpdir/codex"; chmod +x "$tmpdir/codex"
    ( PATH="$tmpdir:$PATH"; . "$LIB"
      got="$(ts_pick_engine claude)"
      check "pick_engine falls back to codex when claude missing" "$got" "codex" )
    rm -rf "$tmpdir"
}

test_pick_engine_none_available() {
    ( PATH="/nonexistent"; HOME="/nonexistent"; . "$LIB"
      if ts_pick_engine claude > /dev/null 2>&1; then
          echo "FAIL - pick_engine should fail when neither engine is installed"; FAIL=1
      else
          echo "ok - pick_engine fails cleanly when neither engine is installed"
      fi )
}

test_resolve_bin_via_path
test_resolve_bin_via_local_bin_fallback
test_resolve_bin_not_found
test_pick_engine_requested_available
test_pick_engine_falls_back
test_pick_engine_none_available

exit $FAIL
