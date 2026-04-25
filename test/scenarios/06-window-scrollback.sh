#!/bin/bash
# Scenario F: per-window scrollback must survive window switches.
#
# wterm has one client-side scrollback ring shared across all tmux windows.
# Old behavior on activate was just \e[3J (drop the ring) → next window had
# no scrollback at all until output happened to push grid rows into the ring,
# which on an idle window never happened (couldn't scroll back) and on a busy
# window meant scrollback contained tmux's repaint artifacts ("the wrong
# thing"). New behavior on activate fetches /scrollback for the target window
# (capture-pane, includes both history AND visible pane) and writes it into
# wterm — the ring gets the target's REAL tmux history, the grid gets the
# visible content, and tmux's own repaint then overwrites the grid cells
# idempotently. This scenario guards that the per-window history is actually
# what wterm shows after a switch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

A_MARKER="window-a-marker-$$"
B_MARKER="window-b-marker-$$"

echo "[06-window-scrollback] painting marker in window A (window 0)"
ab_eval "window.term.onData('echo $A_MARKER\r'); 'sent'" >/dev/null
ab wait 1500 >/dev/null

echo "[06-window-scrollback] creating new e2e-test window (window B, activates it)"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-sess-add[data-session="e2e-test"]' >/dev/null
ab wait 1500 >/dev/null

echo "[06-window-scrollback] painting marker in window B"
ab_eval "window.term.onData('echo $B_MARKER\r'); 'sent'" >/dev/null
ab wait 1500 >/dev/null

# At this point the wterm ring may contain B's recent output. We're about to
# switch back to A and the ring should END UP with A's tmux history, not B's.
echo "[06-window-scrollback] switching back to window A via FAB"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-row[data-session="e2e-test"][data-index="0"]' >/dev/null
ab wait 1500 >/dev/null

# innerText spans both .term-scrollback-row (the ring DOM rows) and the
# visible grid, so both sources are observable here.
present_a=$(ab_eval "document.querySelector('.wterm').innerText.includes('$A_MARKER')")
present_b=$(ab_eval "document.querySelector('.wterm').innerText.includes('$B_MARKER')")
scrollback_count=$(ab_eval "window.term.bridge.getScrollbackCount()")
has_class=$(ab_eval "document.querySelector('.wterm').classList.contains('has-scrollback')")
echo "[06-window-scrollback] A marker present: $present_a (want true — proves seed worked)"
echo "[06-window-scrollback] B marker present: $present_b (want false — proves we're not showing the previous window)"
echo "[06-window-scrollback] scrollback count: $scrollback_count (want > 0)"
echo "[06-window-scrollback] has-scrollback class: $has_class (want true — engages overflow-y:auto for finger-drag)"

fails=0
assert_true "window A's history visible after A → B → A" "$present_a" || ((fails++))
assert_true "window B's content NOT visible after switching back to A" "$([[ $present_b == false ]] && echo true || echo false)" || ((fails++))
assert_gt   "scrollback ring populated from target window's history" 0 "$scrollback_count" || ((fails++))
assert_true "has-scrollback class on .wterm (overflow-y becomes auto)" "$has_class" || ((fails++))

# Clean up: kill the B window so this scenario is idempotent.
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
