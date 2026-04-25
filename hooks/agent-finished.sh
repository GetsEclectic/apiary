#!/usr/bin/env bash
# Claude Code Stop-hook: posts a short summary of the last assistant turn to
# the Apiary push endpoint. Exit code is always 0 — a noisy hook must not
# break the user's session — but every step is logged to
# $APIARY_STATE_DIR/hook.log so silent failures are recoverable. Tail the
# log to find out why a notification didn't land.
#
# Wire up in ~/.claude/settings.json:
#
#   "hooks": {
#     "Stop": [
#       { "hooks": [ { "type": "command",
#         "command": "$HOME/src/apiary/hooks/agent-finished.sh" } ] }
#     ]
#   }
#
# Optional env:
#   APIARY_NOTIFY_ENDPOINT  default: https://127.0.0.1:3443/push/notify
#   APIARY_STATE_DIR        default: $HOME/.config/apiary
#   APIARY_NOTIFY_URL       tap target on the device. default:
#                           https://<hostname>:3443/  — set to your reachable
#                           PWA URL or empty if you don't want the tap to
#                           navigate anywhere.

set -u

STATE_DIR="${APIARY_STATE_DIR:-$HOME/.config/apiary}"
LOG="$STATE_DIR/hook.log"
mkdir -p "$STATE_DIR"
[[ -f "$LOG" ]] || { : > "$LOG"; chmod 600 "$LOG"; }

log() { printf '%s pid=%s %s\n' "$(date -Iseconds)" "$$" "$*" >> "$LOG"; }

input=$(cat)
log "fired input_bytes=${#input}"

# Build the push payload + capture the Python block's diagnostic stderr into
# the log. stdout is the JSON payload; an empty stdout means "skip, see log".
tmp_err=$(mktemp -t apiary-hook-py.XXXXXX)
payload=$(CLAUDE_HOOK_JSON="$input" \
          TTYD_NOTIFY_URL="${APIARY_NOTIFY_URL:-https://$(hostname -s):3443/}" \
          python3 - 2>"$tmp_err" <<'PY'
import json, os, re, sys

def skip(reason):
    print(f"skip: {reason}", file=sys.stderr)
    sys.exit(0)

try:
    hook = json.loads(os.environ.get("CLAUDE_HOOK_JSON", "{}"))
except Exception as e:
    skip(f"hook json parse: {e}")

if hook.get("stop_hook_active"):
    skip("stop_hook_active (re-entry)")

transcript_path = hook.get("transcript_path") or ""
cwd = hook.get("cwd") or ""
session_id = hook.get("session_id") or ""
print(f"transcript={transcript_path!r} cwd={cwd!r} session={session_id[:8]}", file=sys.stderr)

if not transcript_path:
    skip("no transcript_path in hook input")
if not os.path.isfile(transcript_path):
    skip(f"transcript_path not a file: {transcript_path}")

last_text = ""
text_block_count = 0
assistant_msg_count = 0
try:
    with open(transcript_path) as f:
        for line in f:
            try:
                j = json.loads(line)
            except Exception:
                continue
            if j.get("type") != "assistant":
                continue
            assistant_msg_count += 1
            for block in (j.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text":
                    t = block.get("text") or ""
                    if t.strip():
                        last_text = t
                        text_block_count += 1
except Exception as e:
    skip(f"transcript read: {e}")

print(f"assistant_msgs={assistant_msg_count} text_blocks={text_block_count} last_text_chars={len(last_text)}", file=sys.stderr)

if not last_text:
    skip("no assistant text blocks in transcript")

body = re.sub(r"\s+", " ", last_text.strip())[:320]
title = (os.path.basename(cwd) or "claude") if cwd else "claude"
tag = f"claude-{session_id[:8]}" if session_id else "claude"
print(json.dumps({
    "title": title,
    "body":  body,
    "url":   os.environ.get("TTYD_NOTIFY_URL", ""),
    "tag":   tag,
}))
PY
)
py_status=$?
while IFS= read -r line; do log "py: $line"; done < "$tmp_err"
rm -f "$tmp_err"
log "py_exit=$py_status payload_bytes=${#payload}"

if [[ -z "$payload" ]]; then
    exit 0
fi

# Truncate the body for the log so a 320-char turn summary doesn't dominate
# the file; keep the title/tag intact.
log "payload_preview: $(printf '%s' "$payload" | head -c 200)"

endpoint="${APIARY_NOTIFY_ENDPOINT:-https://127.0.0.1:3443/push/notify}"

resp_body=$(mktemp -t apiary-hook-resp.XXXXXX)
http_code=$(curl -sS --max-time 5 \
    --cert "$STATE_DIR/client.crt" \
    --key  "$STATE_DIR/client.key" \
    --cacert "$STATE_DIR/ca.crt" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o "$resp_body" \
    -w '%{http_code}' \
    "$endpoint" 2>>"$LOG")
curl_status=$?
log "curl exit=$curl_status http=$http_code resp=$(head -c 200 "$resp_body" 2>/dev/null)"
rm -f "$resp_body"

exit 0
