#!/bin/bash
# Scenario F: horizontal swipe on the terminal switches tmux windows AND
# seeds wterm with the target window's history (same flow as FAB activate).
# Used to send raw `C-b n/p` and just drop the ring; new flow looks up the
# active window via /windows, computes the next/prev sibling in-session,
# fetches /scrollback for the target, and routes through /activate.
#
# CDP `drag` may emit pointer events instead of touch events. The swipe
# handler in main.js only listens for touchstart/touchend, so we dispatch
# synthetic TouchEvents via eval.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

# Ensure we have at least 2 windows in e2e-test (so prefix+n/p has somewhere to go)
echo "[05-swipe] ensuring 2+ windows in e2e-test"
ws_url="https://localhost:3544"
mapfile -t windows < <(curl -sS --cacert "$CA" --cert "$CRT" --key "$KEY" "$ws_url/windows" | jq -r '.windows[] | select(.session=="e2e-test") | .index')
echo "[05-swipe] e2e-test windows: ${windows[*]}"
if (( ${#windows[@]} < 2 )); then
  curl -sS --cacert "$CA" --cert "$CRT" --key "$KEY" -X POST -H "Content-Type: application/json" -d '{"session":"e2e-test"}' "$ws_url/new-window" >/dev/null
  sleep 1
fi

# Get currently active e2e-test window
get_active() {
  curl -sS --cacert "$CA" --cert "$CRT" --key "$KEY" "$ws_url/windows" | jq -r '.windows[] | select(.session=="e2e-test" and .active==true) | .index'
}
active_before=$(get_active)
echo "[05-swipe] active before swipe: $active_before"

# Paint a marker in the source window so we can prove the post-swipe scrollback
# came from the TARGET window (must NOT contain this marker), not the source.
SOURCE_MARKER="swipe-source-marker-$$"
echo "[05-swipe] painting source-window marker: $SOURCE_MARKER"
ab_eval "window.term.onData('echo $SOURCE_MARKER\r'); 'sent'" >/dev/null
ab wait 1500 >/dev/null
scrollback_before=$(ab_eval "window.term.bridge.getScrollbackCount()")
echo "[05-swipe] scrollback count before swipe: $scrollback_before"

# Synthesize a horizontal touch swipe on the #terminal element. The handler in
# main.js requires |dx| > 80 and |dx| > 1.5*|dy|.
echo "[05-swipe] dispatching synthetic touch swipe (left)"
ab_eval "(() => {
  const el = document.getElementById('terminal');
  const rect = el.getBoundingClientRect();
  const startX = rect.left + rect.width * 0.85;
  const endX   = rect.left + rect.width * 0.15;
  const y      = rect.top  + rect.height * 0.5;
  const t = (x, y, id) => new Touch({ identifier: id, target: el, clientX: x, clientY: y, pageX: x, pageY: y });
  const start = t(startX, y, 0);
  const end   = t(endX,   y, 0);
  el.dispatchEvent(new TouchEvent('touchstart', { touches:[start], targetTouches:[start], changedTouches:[start], bubbles:true, cancelable:true }));
  el.dispatchEvent(new TouchEvent('touchend',   { touches:[],      targetTouches:[],     changedTouches:[end],   bubbles:true, cancelable:true }));
  return 'dispatched';
})()" >/dev/null
ab wait 1500 >/dev/null

active_after=$(get_active)
echo "[05-swipe] active after  swipe: $active_after"

scrollback_after=$(ab_eval "window.term.bridge.getScrollbackCount()")
echo "[05-swipe] scrollback count after  swipe: $scrollback_after"
source_marker_after=$(ab_eval "document.querySelector('.wterm').innerText.includes('$SOURCE_MARKER')")
echo "[05-swipe] source-window marker visible after swipe: $source_marker_after (want false)"

fails=0
if [[ "$active_after" == "$active_before" ]]; then
  echo "  FAIL  swipe did not change active window"
  ((fails++))
else
  echo "  PASS  swipe changed active window ($active_before -> $active_after)"
fi

# After the swipe wterm should show the TARGET window's history, not the
# source window's. The source-window marker must be gone, but scrollback
# itself should be populated (capture-pane of the target pane).
assert_true "source-window marker not visible after swipe (proves target's history seeded)" "$([[ $source_marker_after == false ]] && echo true || echo false)" || ((fails++))
assert_gt   "scrollback populated from target window after swipe" 0 "$scrollback_after" || ((fails++))

exit $fails
