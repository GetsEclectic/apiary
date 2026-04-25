#!/bin/bash
# Scenario E: text in the terminal DOM is selectable. Native long-press
# OS-handle behavior cannot be synthesized from CDP — that remains a manual
# phone check. This guards against future CSS that disables selection.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

selectable=$(ab_eval "(() => {
  const row = document.querySelector('.term-row');
  if (!row) return { ok: false, reason: 'no .term-row in DOM' };
  const range = document.createRange();
  range.selectNodeContents(row);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  const text = sel.toString();
  sel.removeAllRanges();
  return { ok: text.length > 0, len: text.length, sample: text.substring(0, 40) };
})()")
selectable_unwrapped="$(echo "$selectable" | jq -r '.')"
echo "[04-select] $selectable_unwrapped"

ok=$(echo "$selectable_unwrapped" | jq -r '.ok')

# Also assert user-select isn't disabled at the row level
us=$(ab_eval "(() => {
  const row = document.querySelector('.term-row');
  if (!row) return 'no-row';
  const cs = getComputedStyle(row);
  return JSON.stringify({ userSelect: cs.userSelect, webkitUserSelect: cs.webkitUserSelect });
})()")
us_unwrapped="$(echo "$us" | jq -r '.')"
echo "[04-select] computed style: $us_unwrapped"

fails=0
assert_true ".term-row contents are selectable via Range API" "$ok" || ((fails++))

us_ok="true"
[[ "$us_unwrapped" == *"\"none\""* ]] && us_ok="false"
assert_true "user-select is not 'none' on .term-row" "$us_ok" || ((fails++))

echo "[04-select] NOTE: native long-press OS-handle UI cannot be tested via CDP — verify on phone."
exit $fails
