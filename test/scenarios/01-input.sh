#!/bin/bash
# Scenario B: input round-trip via ttyd protocol.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

MARKER="wterm-e2e-marker-$$"
echo "[01-input] sending: echo $MARKER"

# Type by dispatching keystrokes via the wterm input handler. Use term.onData
# directly — it's the path InputHandler hits and lets us avoid focus quirks.
ab_eval "window.term.onData('echo $MARKER\r'); 'sent'" >/dev/null
ab wait 1500 >/dev/null

echo "[01-input] checking DOM for marker"
present="$(ab_eval "document.querySelector('.term-grid')?.innerText.includes('$MARKER')")"
echo "[01-input] present=$present"

fails=0
assert_true "marker echoed back into terminal DOM" "$present" || ((fails++))
exit $fails
