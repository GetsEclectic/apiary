#!/bin/bash
# Scenario H: large-burst scrollback integrity across a window round-trip.
#
# 03-scroll paints 200 lines and only asserts "ring is populated + DOM
# overflows"; 06-window-scrollback asserts that a single marker line
# survives A → B → A. Neither checks that a *large, ordered* burst makes
# it through the seedScrollback path with no drops, dupes, or reordering —
# the real-world failure mode is a long `claude`/`pytest` run finishing in
# one window while the user is flipped to another.
#
# Paints 600 zero-padded, TAG-prefixed lines in window A, flips to B,
# flips back, and asserts every line 0001..0600 appears exactly once in
# wterm's observable text (ring rows + visible grid) in strictly
# contiguous ascending order. 600 comfortably exceeds the 24-row visible
# grid and sits well inside tmux-api's default 2000-row capture and
# tmux's 100000 history-limit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

TAG="bulk-$$"
COUNT=600
LAST=$(printf '%04d' "$COUNT")

echo "[08-large-scrollback] painting $COUNT ordered lines in window A, tag=$TAG"
ab_eval "window.term.onData('for i in \$(seq -f %04g 1 $COUNT); do echo $TAG-\$i; done\r'); 'sent'" >/dev/null

# Poll for the last line to reach wterm. Painting 600 short lines through
# bash + tmux + ttyd + wterm takes ~1-3s on this box; 20x500ms = 10s cap.
echo "[08-large-scrollback] waiting for $TAG-$LAST to land in wterm"
for _ in $(seq 1 20); do
  landed=$(ab_eval "document.querySelector('.wterm').innerText.includes('$TAG-$LAST')")
  [[ "$landed" == "true" ]] && break
  ab wait 500 >/dev/null
done

echo "[08-large-scrollback] creating window B (activates it)"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-sess-add[data-session="e2e-test"]' >/dev/null
ab wait 1500 >/dev/null

echo "[08-large-scrollback] switching back to window A via FAB (triggers seedScrollback)"
ab click '#tm-fab' >/dev/null
ab wait '#tm-drawer.open' >/dev/null
ab wait 300 >/dev/null
ab click '.tm-row[data-session="e2e-test"][data-index="0"]' >/dev/null
# Seed is an HTTP round-trip + wterm.write of ~600 rows; give it a moment.
ab wait 2500 >/dev/null

echo "[08-large-scrollback] extracting observed $TAG-NNNN sequence from wterm"
# innerText walks scrollback rows + visible grid in DOM order, so the hit
# array is the rendered sequence top-to-bottom. We return a compact stats
# object so the shell side can assert without round-tripping 600 strings.
stats_json=$(ab_eval "(() => {
  const text = document.querySelector('.wterm').innerText;
  const hits = text.match(/$TAG-[0-9]{4}/g) || [];
  const nums = hits.map(h => parseInt(h.split('-').pop(), 10));
  const uniq = new Set(nums);
  let contiguous = nums.length > 0;
  let firstBreak = null;
  for (let i = 1; i < nums.length; i++) {
    if (nums[i] !== nums[i-1] + 1) {
      contiguous = false;
      if (firstBreak === null) firstBreak = { at: i, prev: nums[i-1], curr: nums[i], context: nums.slice(Math.max(0, i-3), Math.min(nums.length, i+3)) };
    }
  }
  const counts = {};
  for (const n of nums) counts[n] = (counts[n] || 0) + 1;
  const dupes = Object.entries(counts).filter(([, c]) => c > 1).map(([n, c]) => ({ n: +n, c }));
  const ringRows = Array.from(document.querySelectorAll('.term-scrollback-row')).map(r => r.innerText);
  const gridText = document.querySelector('.term-grid')?.innerText || '';
  const ringHits = (ringRows.join('\\n').match(/$TAG-[0-9]{4}/g) || []).length;
  const gridHits = (gridText.match(/$TAG-[0-9]{4}/g) || []).length;
  return JSON.stringify({
    count: nums.length,
    unique: uniq.size,
    first: nums[0] ?? null,
    last: nums[nums.length - 1] ?? null,
    contiguous,
    firstBreak,
    dupes,
    ringHits,
    gridHits
  });
})()")
stats=$(echo "$stats_json" | jq -r '.')
echo "[08-large-scrollback] stats=$stats"

hits=$(echo      "$stats" | jq -r '.count')
unique=$(echo    "$stats" | jq -r '.unique')
first=$(echo     "$stats" | jq -r '.first')
last=$(echo      "$stats" | jq -r '.last')
contiguous=$(echo "$stats" | jq -r '.contiguous')

fails=0
assert_eq   "all $COUNT ordered lines observed after A → B → A" "$COUNT" "$hits"   || ((fails++))
assert_eq   "no duplicate line numbers"                          "$COUNT" "$unique" || ((fails++))
assert_eq   "first observed is 1"                                "1"      "$first"  || ((fails++))
assert_eq   "last observed is $COUNT"                            "$COUNT" "$last"   || ((fails++))
assert_true "sequence strictly contiguous (no drops or reorder)" "$contiguous"      || ((fails++))

# Cleanup: kill window B so the scenario is idempotent.
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
