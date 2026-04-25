#!/bin/bash
# Scenario D: scrollback diagnostic + finger-drag.
# This is THE bug-finder for the open issue: native vertical scroll on the
# tmux scrollback isn't engaging on Android. The diagnostic eval discriminates
# three failure modes documented in the plan.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

echo "[03-scroll] generating 200 lines of output"
ab_eval "window.term.onData('for i in \$(seq 1 200); do echo line-\$i; done\r'); 'sent'" >/dev/null
ab wait 3000 >/dev/null

echo "[03-scroll] === DIAGNOSTIC SNAPSHOT ==="
diag=$(ab_eval "JSON.stringify({
  scrollbackCount: window.term.bridge.getScrollbackCount(),
  hasScrollbackClass: document.querySelector('.wterm').classList.contains('has-scrollback'),
  overflowY: getComputedStyle(document.querySelector('.wterm')).overflowY,
  scrollHeight: document.querySelector('.wterm').scrollHeight,
  clientHeight: document.querySelector('.wterm').clientHeight,
  scrollTop: document.querySelector('.wterm').scrollTop,
  scrollbackRowCount: document.querySelectorAll('.term-scrollback-row').length,
  usingAltScreen: window.term.bridge.usingAltScreen()
})")
diag_unwrapped="$(echo "$diag" | jq -r '.')"
echo "$diag_unwrapped" | jq .
echo "[03-scroll] === END DIAGNOSTIC ==="

scrollback_count=$(echo "$diag_unwrapped" | jq -r '.scrollbackCount')
has_class=$(echo "$diag_unwrapped"        | jq -r '.hasScrollbackClass')
overflow=$(echo "$diag_unwrapped"         | jq -r '.overflowY')
sh=$(echo "$diag_unwrapped"               | jq -r '.scrollHeight')
ch=$(echo "$diag_unwrapped"               | jq -r '.clientHeight')

alt=$(echo "$diag_unwrapped" | jq -r '.usingAltScreen')

fails=0
assert_true  "tmux did not put wterm into alt-screen (smcup/rmcup stripped)" "$([[ $alt == false ]] && echo true || echo false)" || ((fails++))
assert_gt    "scrollback ring populated"                                      0  "$scrollback_count" || ((fails++))
assert_true  ".has-scrollback class on .wterm"                                "$has_class" || ((fails++))
assert_true  "computed overflow-y=auto on .wterm"                             "$([[ $overflow == auto ]] && echo true || echo false)" || ((fails++))
assert_true  "DOM actually overflows (scrollHeight > clientHeight)"           "$([[ $sh -gt $ch ]] && echo true || echo false)" || ((fails++))

# Best-effort drag (CDP drag on --device Pixel 5 doesn't reliably fire touch
# events, so this is informational — the five assertions above guard the real
# regression surface). Native finger-drag on-device uses the browser's built-in
# scroll handler which only needs overflow:auto + overflowing content.
echo "[03-scroll] attempting drag scroll (informational)..."
ab drag '.wterm' '.wterm' --from-position '50%,80%' --to-position '50%,20%' 2>/dev/null || true
ab wait 500 >/dev/null
new_st=$(ab_eval "document.querySelector('.wterm').scrollTop")
echo "[03-scroll] scrollTop after drag: $new_st"

exit $fails
