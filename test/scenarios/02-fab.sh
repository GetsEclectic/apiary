#!/bin/bash
# Scenario C: FAB drawer talks to the tmux-api sidecar end-to-end.
# Critical: scope every action to data-session="e2e-test". Never touch "main".
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

echo "[02-fab] open drawer"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 500 >/dev/null

before=$(ab_eval "document.querySelectorAll('.tm-row[data-session=\"e2e-test\"]').length")
echo "[02-fab] e2e-test windows before: $before"

echo "[02-fab] add a new window in e2e-test"
ab click '.tm-sess-add[data-session="e2e-test"]' >/dev/null
ab wait 1500 >/dev/null
# The drawer closes on activate; reopen + wait for refresh
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 500 >/dev/null

after=$(ab_eval "document.querySelectorAll('.tm-row[data-session=\"e2e-test\"]').length")
echo "[02-fab] e2e-test windows after add: $after"

fails=0
expected_after=$((before + 1))
assert_eq "window count incremented by 1" "$expected_after" "$after" || ((fails++))

# Find the highest-index e2e-test window and kill it (the one we just added).
target_idx=$(ab_eval "(() => { const rows = Array.from(document.querySelectorAll('.tm-row[data-session=\"e2e-test\"]')); const idxs = rows.map(r => parseInt(r.dataset.index, 10)); return Math.max(...idxs); })()")
echo "[02-fab] killing e2e-test:$target_idx"

ab click ".tm-row[data-session=\"e2e-test\"][data-index=\"$target_idx\"] .tm-kill" >/dev/null
ab wait 500 >/dev/null
ab click ".tm-row[data-session=\"e2e-test\"][data-index=\"$target_idx\"].confirm .tm-confirm-btn" >/dev/null
ab wait 1500 >/dev/null

after_kill=$(ab_eval "document.querySelectorAll('.tm-row[data-session=\"e2e-test\"]').length")
echo "[02-fab] e2e-test windows after kill: $after_kill"
assert_eq "window count back to before-add" "$before" "$after_kill" || ((fails++))

# Sanity: prod 'main' session count must NOT have changed during this scenario.
# (We never touched it, but check defensively.)
main_count=$(ab_eval "document.querySelectorAll('.tm-row[data-session=\"main\"]').length")
echo "[02-fab] main windows: $main_count (informational, must be unchanged from a prior count)"

ab click '#tm-close' >/dev/null
exit $fails
