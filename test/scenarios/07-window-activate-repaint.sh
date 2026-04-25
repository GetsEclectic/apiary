#!/bin/bash
# Scenario G: activating an EXISTING (idle) window via the FAB must fully
# repaint its visible screen.
#
# The guarded bug: wterm's \e[3J (used by main.js::clearScrollback to drop
# the cross-window scrollback ring) wipes any grid cells painted by cursor
# addressing. tmux's window-switch redraw is cursor-addressed, so firing
# \e[3J AFTER tmux's redraw leaves an idle window completely blank until
# the next output or a resize event (e.g. the Android keyboard opening on
# tap) triggers a fresh repaint. The fix is to call clearScrollback BEFORE
# /activate so \e[3J hits first and tmux's redraw paints unmolested.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

MARKER="repaint-marker-$$"

echo "[07-window-activate-repaint] painting marker in initial window"
ab_eval "window.term.onData('echo $MARKER\r'); 'sent'" >/dev/null
ab wait 1500 >/dev/null

present_before=$(ab_eval "document.querySelector('.term-grid')?.innerText.includes('$MARKER')")
echo "[07-window-activate-repaint] marker visible before switch: $present_before"

fails=0
assert_true "marker painted in initial window" "$present_before" || ((fails++))

echo "[07-window-activate-repaint] creating a second e2e-test window (activates it, leaves window 0 idle)"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-sess-add[data-session="e2e-test"]' >/dev/null
ab wait 1500 >/dev/null

present_on_new=$(ab_eval "document.querySelector('.term-grid')?.innerText.includes('$MARKER')")
echo "[07-window-activate-repaint] marker visible on new window (expected false): $present_on_new"

echo "[07-window-activate-repaint] switching back to window 0 (idle, existing content)"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-row[data-session="e2e-test"][data-index="0"]' >/dev/null
# 1200ms: long enough for /activate + tmux's redraw bytes to reach wterm;
# NOT long enough for any background output to sneak in and falsely
# "repaint" the idle cells. If this flakes, tighten rather than loosen —
# a longer wait defeats the test.
ab wait 1200 >/dev/null

present_after=$(ab_eval "document.querySelector('.term-grid')?.innerText.includes('$MARKER')")
echo "[07-window-activate-repaint] marker visible after switch back: $present_after"

assert_true "idle existing window fully repaints on FAB activate" "$present_after" || ((fails++))

# Clean up: kill the window we added so the scenario is idempotent.
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
target_idx=$(ab_eval "(() => { const rows = Array.from(document.querySelectorAll('.tm-row[data-session=\"e2e-test\"]')); const idxs = rows.map(r => parseInt(r.dataset.index, 10)); return Math.max(...idxs); })()")
ab click ".tm-row[data-session=\"e2e-test\"][data-index=\"$target_idx\"] .tm-kill" >/dev/null
ab wait 300 >/dev/null
ab click ".tm-row[data-session=\"e2e-test\"][data-index=\"$target_idx\"].confirm .tm-confirm-btn" >/dev/null
ab wait 1000 >/dev/null
ab click '#tm-close' >/dev/null

exit $fails
