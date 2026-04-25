#!/bin/bash
# Scenario I: image paste uploads to tmux-api /upload and injects
# "@<absolute-path> " into the tty.
#
# End-to-end exercise of:
#   1. attachPasteHandler extracting a File from ClipboardEvent.clipboardData
#   2. POST /upload on the tmux-api sidecar writing the bytes to PASTE_DIR
#   3. sendInput typing "@<path> " over the ttyd WebSocket
#   4. the shell in tmux echoing that text back into wterm's DOM
#
# If this passes we know the paste-to-attach flow works through the same
# mTLS origin a phone uses, and Claude Code picks up the absolute @-path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib.sh"

: "${APIARY_STATE_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/apiary}"
PASTE_DIR="$APIARY_STATE_DIR/paste"

echo "[09-paste-image] dispatching synthetic image paste"
# The server validates Content-Type header but not PNG structure, so any bytes
# with type: 'image/png' exercise the happy path. We tag the bytes with a
# scenario-unique marker so we can locate the file we just wrote (the PASTE_DIR
# is shared with prod and may contain other files from earlier test runs).
MARKER="e2e-paste-$$-$(date +%s)"
path=$(ab_eval "(async () => {
  const marker = '$MARKER';
  const bytes = new TextEncoder().encode(marker);
  const file = new File([bytes], 'paste.png', { type: 'image/png' });
  const dt = new DataTransfer();
  dt.items.add(file);
  const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
  document.dispatchEvent(ev);
  // The handler is async (fetch + sendInput) and preventDefault has already
  // fired synchronously. Poll the terminal DOM for the injected '@<path> '
  // token — an absolute path will contain APIARY_STATE_DIR.
  for (let i = 0; i < 40; i++) {
    await new Promise(r => setTimeout(r, 150));
    const txt = document.querySelector('.wterm')?.innerText || '';
    const m = txt.match(/@(\\/\\S*paste-\\S+\\.png)/);
    if (m) return m[1];
  }
  return null;
})()" | jq -r '.')

echo "[09-paste-image] observed path=$path"

fails=0
if [[ -z "$path" || "$path" == "null" ]]; then
  echo "  FAIL  @<path> never reached terminal DOM"
  ((fails++))
fi

if [[ -n "$path" && "$path" != "null" ]]; then
  if [[ -f "$path" ]]; then
    echo "  PASS  upload wrote file $path"
  else
    echo "  FAIL  path advertised but file missing: $path"
    ((fails++))
  fi
  # The payload we "pasted" is the marker string; the stored file must match.
  if [[ -f "$path" ]] && grep -q "$MARKER" "$path"; then
    echo "  PASS  stored bytes match pasted payload"
  else
    echo "  FAIL  stored bytes don't contain marker $MARKER"
    ((fails++))
  fi
  # Perms must be 0600 — image pastes can contain sensitive content (screenshots
  # of private chats, internal dashboards). Same guarantee as subscriptions.json.
  perms=$(stat -c '%a' "$path" 2>/dev/null || echo "?")
  if [[ "$perms" == "600" ]]; then
    echo "  PASS  file mode is 0600"
  else
    echo "  FAIL  file mode is $perms (expected 600)"
    ((fails++))
  fi
  rm -f "$path"
fi

# Clear the injected command line so subsequent scenarios see a clean prompt.
ab_eval "window.term.onData('\\u0003'); 'ctrl-c sent'" >/dev/null
ab wait 300 >/dev/null

exit $fails
