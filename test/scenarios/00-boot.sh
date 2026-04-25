#!/bin/bash
# Scenario A: page loads, wterm initializes, WebSocket handshake completes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

echo "[00-boot] open $URL"
ab open "$URL" >/dev/null
ab wait 2000 >/dev/null

state="$(ab_eval 'JSON.stringify({hasTerm: !!window.term, hasBridge: !!window.term?.bridge, cols: window.term?.cols, rows: window.term?.rows})')"
state_unwrapped="$(echo "$state" | jq -r '.')"
echo "[00-boot] state=$state_unwrapped"

fails=0
hasTerm=$(echo "$state_unwrapped"   | jq -r '.hasTerm')
hasBridge=$(echo "$state_unwrapped" | jq -r '.hasBridge')
cols=$(echo "$state_unwrapped"      | jq -r '.cols')

assert_true "wterm instance present" "$hasTerm"   || ((fails++))
assert_true "WASM bridge present"    "$hasBridge" || ((fails++))
assert_gt   "cols > 0" 0 "$cols"                  || ((fails++))

title="$(ab get title 2>/dev/null | head -1)"
echo "[00-boot] title=$title"
if [[ "$title" == *"e2e-test"* || "$title" == *"tmux"* || "$title" == *"ttyd"* ]]; then
  echo "  PASS  title looks tmux-ish"
else
  echo "  FAIL  unexpected title: $title"
  ((fails++))
fi

exit $fails
