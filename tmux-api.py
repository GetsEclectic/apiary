#!/usr/bin/env python3
"""mTLS front-end for ttyd, tmux window management, and a web-push PWA.

Topology: this process terminates mTLS on :3443 (configurable via
TMUX_API_PORT). It directly serves:

  - static PWA assets (/sw.js, /manifest.webmanifest, /icon.svg)
  - tmux window API (/windows, /scrollback, /activate, /kill, /new-window)
  - web push API   (/push/vapid-public-key, /push/subscribe, /push/notify,
                    /push/latest)

Anything else — including the terminal UI at `/`, `/token`, `/ws`, and
anything ttyd adds in future — is reverse-proxied to ttyd listening on
loopback at TTYD_UPSTREAM_HOST:TTYD_UPSTREAM_PORT. WebSocket upgrades
(the terminal itself) are handled by hijacking the socket after the HTTP
handshake and piping raw bytes bidirectionally.
"""
import base64
import gzip
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

try:
    import jwt  # PyJWT (python3-jwt on Debian/Ubuntu)
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    _PUSH_SUPPORTED = True
    _PUSH_IMPORT_ERR = None
except ImportError as e:
    _PUSH_SUPPORTED = False
    _PUSH_IMPORT_ERR = str(e)

CERT_DIR = os.environ.get(
    "APIARY_STATE_DIR",
    os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "apiary"),
)
PORT = int(os.environ.get("TMUX_API_PORT", "3443"))
# The port of the *public* origin we accept CORS from. In the default single-
# port layout, cross-origin doesn't apply — main.js is served from the same
# origin as the API. Kept for the e2e harness which still runs a split
# terminal/API pair on two ports.
TTYD_ORIGIN_PORT = os.environ.get("TTYD_ORIGIN_PORT", str(PORT))
TTYD_UPSTREAM_HOST = os.environ.get("TTYD_UPSTREAM_HOST", "127.0.0.1")
# When unset, this process serves 404 for unknown paths instead of proxying.
# The e2e harness leaves it unset (it has ttyd on a separate port the browser
# talks to directly).
TTYD_UPSTREAM_PORT = os.environ.get("TTYD_UPSTREAM_PORT")
CWD_ROOT = (
    os.environ.get("APIARY_CWD_ROOT")
    or os.environ.get("TMUX_API_CWD_ROOT")
    or os.path.expanduser("~")
)
TMUX = shutil.which("tmux") or "/usr/bin/tmux"

# How many lines of pane history to seed wterm with on window switch. Includes
# both scrollback above the visible pane and the current visible content (we
# capture -S -<N> to -E -, so the visible screen lands on the wterm grid and
# anything above it overflows into wterm's ring). 5000 is a balance between
# reaching deep enough into a Claude-TUI conversation and avoiding the
# perf hit a 20000-line seed had on window switch. tmux's own history-limit
# is a separate cap; lines beyond the seed live only in tmux.
SCROLLBACK_DEFAULT_ROWS = int(os.environ.get("TMUX_API_SCROLLBACK_ROWS", "5000"))
SCROLLBACK_MAX_ROWS = 100000

SESSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
ORIGIN_RE = re.compile(rf"^https://[^/]+:{TTYD_ORIGIN_PORT}$")
MAX_PROMPT_LEN = 5000
# Delay before typing into the claude input — enough for the shell + claude TUI
# to boot and be ready to accept keystrokes. Too short and the keys land in the
# shell prompt; too long and the phone user is left waiting.
PREFILL_DELAY_S = 2.5

LIST_FORMAT = "#{window_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}\t#{window_activity}"

# Matches the client-side threshold. A window with pane output in the last N
# seconds is "busy"; anything longer is idle. Claude's TUI renders the spinner
# every ~100ms while working, so 2s comfortably spans any inter-frame gap.
BUSY_THRESHOLD_SECS = 2
# Background refresh cadence. Without this, busy_since is only updated when a
# client calls /windows — so first-time drawer opens during an ongoing claude
# run would anchor busy_since near "now" and under-report elapsed time.
POLL_INTERVAL_SECS = 2

# window_id (tmux's globally-unique `@N` identifier) -> unix ts when the window
# first looked busy. Survives session/name/index changes for the same pane set.
# Persisted to tmpfs so service restarts don't re-anchor in-progress runs to
# "now" — without this, restarting tmux-api during a long claude turn would
# make the FAB show ~0s elapsed while claude's TUI shows the true elapsed.
_busy_since = {}
# wid -> unix ts when the window went idle after being busy. Cleared when the
# user activates that window. Not persisted — loses flags across restarts, but
# that's acceptable for a personal tool.
_needs_attention = {}
# wid -> unix ts of the most recent moment we observed the window active in an
# attached session (or the moment of an explicit /activate). Switching away
# from a window causes a one-shot pane redraw that tmux records as activity;
# without this, the next busy→idle transition would re-flag a window the user
# just looked at. Any flag transition within the grace window is treated as
# user-induced and suppressed.
_last_active_at = {}
ACTIVATION_GRACE_SECS = 5
_busy_lock = threading.Lock()

# Cache for /windows responses. list_windows() spawns 2 tmux subprocesses;
# with the background poll running every 2s and swipe + drawer both calling
# /windows, caching for 1s avoids redundant work without staling the busy
# timers (which only matter to within ~1s anyway).
_windows_cache = None       # (timestamp, result_list)
_windows_cache_lock = threading.Lock()
_WINDOWS_CACHE_TTL = 1.0   # seconds


def list_windows_cached():
    global _windows_cache
    now = time.monotonic()
    with _windows_cache_lock:
        if _windows_cache and (now - _windows_cache[0]) < _WINDOWS_CACHE_TTL:
            return _windows_cache[1]
    result = list_windows()
    with _windows_cache_lock:
        _windows_cache = (now, result)
    return result


def _invalidate_windows_cache():
    # The frontend's load() after /kill or /new-window races the 1s cache TTL
    # plus the background poll's refresh — without this, a killed window can
    # linger in the drawer for up to a full poll cycle.
    global _windows_cache
    with _windows_cache_lock:
        _windows_cache = None


_STATE_PATH = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/tmp",
    f"tmux-api-busy.{PORT}.json",
)

# -- Web push ---------------------------------------------------------------
# Strategy: server sends VAPID-signed empty pushes. The service worker handles
# the `push` event by fetching /push/latest over this same mTLS origin; the
# notification body therefore never transits Google/Mozilla/Apple push servers.
# We only need JWT signing (ES256), not payload encryption (RFC 8291), so the
# stdlib + python3-jwt + python3-cryptography is enough.

# Image pastes from the browser land here. A file appears in this directory
# each time the user pastes an image in wterm; main.js then types "@<abs path>"
# into the tty so Claude Code picks it up as an attachment. Kept inside the
# apiary state dir so it inherits the same 0700 parent perms as certs.
PASTE_DIR = Path(CERT_DIR) / "paste"
# Biggest image we'll accept in a single paste. Screenshots from the Pixel 5
# are ~2-3 MB; 20 MB leaves headroom for higher-res panels without letting a
# runaway paste balloon disk use.
UPLOAD_MAX_BYTES = 20 * 1024 * 1024
# MIME whitelist → file extension. Anything else is rejected; we don't want
# this endpoint to double as a generic file drop.
UPLOAD_EXTS = {
    "image/png":  "png",
    "image/jpeg": "jpg",
    "image/gif":  "gif",
    "image/webp": "webp",
    "image/bmp":  "bmp",
}

PUSH_DIR_CODE = Path(__file__).resolve().parent / "push"
VAPID_PATH    = Path(CERT_DIR) / "vapid.json"
SUBS_PATH     = Path(CERT_DIR) / "subscriptions.json"
LATEST_PATH   = Path(CERT_DIR) / "push-latest.json"
# VAPID's `sub` claim must be mailto: or https:. Endpoints ignore it in
# practice but the RFC requires it and some push services reject missing/bad
# values. A placeholder mailto is fine for private/personal deployments.
VAPID_SUBJECT = os.environ.get("VAPID_SUBJECT", "mailto:admin@localhost")
PUSH_TTL      = int(os.environ.get("PUSH_TTL", "300"))
PUSH_MAX_BODY  = 240
PUSH_MAX_TITLE = 80

_subs_lock = threading.Lock()

# Root-level PWA assets. They must be same-origin with the terminal page so
# the service worker can register and the manifest can be linked from /.
_STATIC_FILES = {
    "/sw.js":                ("sw.js",                "application/javascript"),
    "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    "/icon.png":             ("icon.png",             "image/png"),
    "/badge.png":            ("badge.png",            "image/png"),
    "/icon.svg":             ("icon.svg",             "image/svg+xml"),
    "/badge.svg":            ("badge.svg",            "image/svg+xml"),
}


def _load_busy_state():
    try:
        with open(_STATE_PATH) as f:
            raw = json.load(f)
        return {str(k): int(v) for k, v in raw.items()}
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"[tmux-api] busy state load failed: {e}", flush=True)
        return {}


def _save_busy_state_locked():
    # 0o600 at creation: _STATE_PATH normally lands in XDG_RUNTIME_DIR (0700 per
    # user), but falls back to /tmp when that's unset — e.g. inside containers
    # or non-systemd shells — where the default umask would otherwise make this
    # world-readable. Matches the pattern used by _write_private_text below.
    try:
        tmp = _STATE_PATH + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(_busy_since, f)
        os.replace(tmp, _STATE_PATH)
    except Exception as e:
        print(f"[tmux-api] busy state save failed: {e}", flush=True)


_busy_since = _load_busy_state()


def run_tmux(args, capture=True):
    return subprocess.run(
        [TMUX, *args],
        capture_output=capture,
        text=True,
        timeout=5,
        env={**os.environ, "TMUX": ""},
    )


def _attached_sessions():
    # tmux marks #{window_active}=1 for the active window of *every* session,
    # not just the one a client is currently displaying. Filtering by attached
    # session collapses that to the single window the user is actually looking
    # at — the property the drawer's "active" highlight is meant to reflect.
    r = run_tmux(["list-clients", "-F", "#{client_session}"])
    if r.returncode != 0:
        return set()
    return {s for s in r.stdout.splitlines() if s}


def list_windows():
    r = run_tmux(["list-windows", "-a", "-F", LIST_FORMAT])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "tmux list-windows failed")
    attached = _attached_sessions()
    now = int(time.time())
    rows = []
    seen_ids = set()
    dirty = False
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 7:
            continue
        wid, session, index, name, active, panes, activity = parts
        seen_ids.add(wid)
        try:
            idle = max(0, now - int(activity))
        except ValueError:
            idle = None
        busy_secs = None
        is_active_attached = active == "1" and session in attached
        with _busy_lock:
            if is_active_attached:
                _last_active_at[wid] = now
            if idle is not None and idle < BUSY_THRESHOLD_SECS:
                # First observation of this busy spell: best guess for the
                # start is the last activity timestamp (now - idle).
                if wid not in _busy_since:
                    _busy_since[wid] = now - idle
                    dirty = True
                busy_secs = max(0, now - _busy_since[wid])
                _needs_attention.pop(wid, None)  # busy now, not waiting
            else:
                if _busy_since.pop(wid, None) is not None:
                    dirty = True
                    # Only flag if the spell didn't end in a grace window
                    # after the user last viewed this pane — otherwise the
                    # deselect-redraw from switching away re-flags it.
                    if (now - _last_active_at.get(wid, 0)) >= ACTIVATION_GRACE_SECS:
                        _needs_attention[wid] = now  # just finished
            if is_active_attached:
                _needs_attention.pop(wid, None)  # user is looking at it
            needs_att = wid in _needs_attention
        rows.append({
            "session": session,
            "index": int(index),
            "name": name,
            "active": active == "1" and session in attached,
            "panes": int(panes),
            "idle_secs": idle,
            "busy_secs": busy_secs,
            "needs_attention": needs_att,
        })
    with _busy_lock:
        for wid in list(_busy_since.keys()):
            if wid not in seen_ids:
                _busy_since.pop(wid, None)
                dirty = True
        for wid in list(_needs_attention.keys()):
            if wid not in seen_ids:
                _needs_attention.pop(wid, None)
        for wid in list(_last_active_at.keys()):
            if wid not in seen_ids:
                _last_active_at.pop(wid, None)
        if dirty:
            _save_busy_state_locked()
    return rows


def _busy_poll_loop():
    global _windows_cache
    while True:
        try:
            result = list_windows()
            with _windows_cache_lock:
                _windows_cache = (time.monotonic(), result)
        except Exception as e:
            print(f"[tmux-api] busy poll failed: {e}", flush=True)
        time.sleep(POLL_INTERVAL_SECS)


def _get_window_id(session, index):
    r = run_tmux(["list-windows", "-t", f"{session}:{index}", "-F", "#{window_id}"])
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.strip().splitlines()[0]


def validate_target(body):
    session = body.get("session")
    index = body.get("index")
    if not isinstance(session, str) or not SESSION_RE.match(session):
        raise ValueError("bad session")
    if not isinstance(index, int):
        raise ValueError("bad index")
    return session, index


def resolve_cwd(raw):
    if not isinstance(raw, str) or not raw or "\x00" in raw or "\n" in raw:
        raise ValueError("bad cwd")
    rp = os.path.realpath(raw)
    if not (rp == CWD_ROOT or rp.startswith(CWD_ROOT + "/")):
        raise ValueError("cwd outside allowed root")
    if not os.path.isdir(rp):
        raise ValueError("cwd is not a directory")
    return rp


def sanitize_prompt(raw):
    if not isinstance(raw, str):
        raise ValueError("bad prompt")
    # Newlines in the prompt would submit claude's input prematurely when typed
    # via `send-keys -l`. Collapse them to spaces.
    s = raw.replace("\r", " ").replace("\n", " ").strip()
    if not s:
        raise ValueError("empty prompt")
    if len(s) > MAX_PROMPT_LEN:
        raise ValueError("prompt too long")
    return s


def schedule_prefill(target, prompt):
    def go():
        try:
            run_tmux(["send-keys", "-t", target, "-l", "--", prompt])
        except Exception as e:
            print(f"[tmux-api] prefill failed for {target}: {e}", flush=True)
    t = threading.Timer(PREFILL_DELAY_S, go)
    t.daemon = True
    t.start()


def _write_private_text(path, content):
    """Atomic write of a private file with 0600 mode set at creation — avoids
    the race window of `write_text` + post-hoc chmod, where another local user
    could open the file between the write and the chmod."""
    tmp = f"{os.fspath(path)}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)


def _ensure_vapid():
    """Generate a VAPID keypair on first run. Private key stays local; public
    key is base64url-encoded uncompressed P-256 point (65 bytes, 0x04 prefix)
    per the Web Push spec and is handed to the browser at subscribe time."""
    if not _PUSH_SUPPORTED:
        return
    if VAPID_PATH.exists():
        return
    priv = ec.generate_private_key(ec.SECP256R1())
    pem = priv.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    nums = priv.public_key().public_numbers()
    raw = b"\x04" + nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")
    pub_b64url = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
    _write_private_text(VAPID_PATH, json.dumps({"private_pem": pem, "public_b64url": pub_b64url}))
    print(f"[tmux-api] generated VAPID keypair at {VAPID_PATH}", flush=True)


def _load_vapid():
    try:
        with open(VAPID_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def _load_subs():
    try:
        with open(SUBS_PATH) as f:
            subs = json.load(f)
        return subs if isinstance(subs, list) else []
    except FileNotFoundError:
        return []
    except Exception as e:
        print(f"[tmux-api] subs load failed: {e}", flush=True)
        return []


def _save_subs(subs):
    _write_private_text(SUBS_PATH, json.dumps(subs))


def _valid_sub(sub):
    if not isinstance(sub, dict):
        return False
    endpoint = sub.get("endpoint")
    if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
        return False
    if len(endpoint) > 2048:
        return False
    keys = sub.get("keys")
    # keys is optional for the no-payload pattern, but Chrome always supplies
    # them on subscribe — store whatever the client sent so future code paths
    # (encrypted payloads) can use them without re-subscribing.
    if keys is not None and not isinstance(keys, dict):
        return False
    return True


def _vapid_auth_header(endpoint, vapid):
    """Build the `Authorization: vapid t=<JWT>, k=<pubkey>` header for `endpoint`.
    JWT claims: aud is the origin of the push endpoint, exp within 24h."""
    parsed = urlparse(endpoint)
    aud = f"{parsed.scheme}://{parsed.netloc}"
    payload = {"aud": aud, "exp": int(time.time()) + 12 * 3600, "sub": VAPID_SUBJECT}
    tok = jwt.encode(payload, vapid["private_pem"], algorithm="ES256")
    if isinstance(tok, bytes):
        tok = tok.decode()
    return f'vapid t={tok}, k={vapid["public_b64url"]}'


def _push_empty(sub, vapid):
    """Send an empty (zero-body) push to `sub`. Returns the HTTP status code
    from the push service, or 0 on network error. 404/410 mean the client
    unsubscribed and the subscription should be purged."""
    try:
        auth = _vapid_auth_header(sub["endpoint"], vapid)
    except Exception as e:
        print(f"[tmux-api] vapid sign failed: {e}", flush=True)
        return 0
    req = urllib.request.Request(
        sub["endpoint"],
        method="POST",
        data=b"",
        headers={
            "Authorization": auth,
            "TTL": str(PUSH_TTL),
            "Content-Length": "0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        print(f"[tmux-api] push send failed ({sub['endpoint'][:60]}...): {e}", flush=True)
        return 0


def _write_latest(payload):
    tmp = str(LATEST_PATH) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f)
    os.replace(tmp, LATEST_PATH)


def _push_notify(title, body, url=None, tag=None):
    if not _PUSH_SUPPORTED:
        return {"error": f"push unavailable: {_PUSH_IMPORT_ERR}", "delivered": 0, "gone": 0}
    vapid = _load_vapid()
    if not vapid:
        return {"error": "vapid keypair missing", "delivered": 0, "gone": 0}

    latest = {
        "title": (title or "notification")[:PUSH_MAX_TITLE],
        "body":  (body  or "")[:PUSH_MAX_BODY],
        "url":   url or "",
        "tag":   tag or "ttyd-agent",
        "ts":    int(time.time()),
    }
    _write_latest(latest)

    with _subs_lock:
        subs = _load_subs()
    delivered, gone, keep = 0, 0, []
    for sub in subs:
        status = _push_empty(sub, vapid)
        if status in (404, 410):
            gone += 1
            continue
        keep.append(sub)
        if 200 <= status < 300:
            delivered += 1
    if gone:
        with _subs_lock:
            _save_subs(keep)
    return {"delivered": delivered, "gone": gone, "subscribers": len(keep)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[tmux-api] {self.address_string()} {fmt % args}", flush=True)

    def _cors(self):
        origin = self.headers.get("Origin", "")
        if ORIGIN_RE.match(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Max-Age", "600")

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        # /scrollback can return ~500 KB of capture-pane output that compresses
        # ~10x. Threshold skips compressing /windows, /status, and the bare
        # {"ok": true} responses where compression overhead isn't worth it.
        encoding = None
        if len(body) > 1024 and "gzip" in self.headers.get("Accept-Encoding", ""):
            body = gzip.compress(body)
            encoding = "gzip"
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode() or "{}")

    def _handle_upload(self):
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        ext = UPLOAD_EXTS.get(ctype)
        if not ext:
            self._json(415, {"error": f"unsupported content-type: {ctype or 'missing'}"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._json(400, {"error": "bad content-length"})
            return
        if length <= 0:
            self._json(400, {"error": "empty body"})
            return
        if length > UPLOAD_MAX_BYTES:
            self._json(413, {"error": f"too large (> {UPLOAD_MAX_BYTES} bytes)"})
            return

        try:
            PASTE_DIR.mkdir(mode=0o700, exist_ok=True)
        except Exception as e:
            self._json(500, {"error": f"mkdir failed: {e}"})
            return

        # Read fully up front — we've already bounded length, and the file must
        # land atomically so Claude Code never observes a half-written image.
        raw = self.rfile.read(length)
        if len(raw) != length:
            self._json(400, {"error": "short read"})
            return

        stamp = time.strftime("%Y%m%d-%H%M%S")
        name = f"paste-{stamp}-{secrets.token_urlsafe(4)}.{ext}"
        final = PASTE_DIR / name
        tmp = PASTE_DIR / f".{name}.tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(raw)
            except Exception:
                try: os.unlink(tmp)
                except OSError: pass
                raise
            os.replace(tmp, final)
        except Exception as e:
            self._json(500, {"error": f"write failed: {e}"})
            return

        self._json(200, {"path": str(final), "bytes": length})

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _serve_static(self, path):
        spec = _STATIC_FILES.get(path)
        if not spec:
            return False
        filename, ctype = spec
        fp = PUSH_DIR_CODE / filename
        try:
            body = fp.read_bytes()
        except FileNotFoundError:
            self._json(404, {"error": f"asset missing: {filename}"})
            return True
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if filename == "sw.js":
            # Belt-and-braces: /sw.js's default scope is already "/" so this
            # is redundant for the canonical registration but costs nothing.
            self.send_header("Service-Worker-Allowed", "/")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)
        return True

    def _proxy_upstream(self):
        """Fallback for any path we don't serve locally: reverse-proxy to ttyd.
        Handles both regular HTTP and WebSocket upgrades (the terminal itself
        flows through /ws)."""
        if not TTYD_UPSTREAM_PORT:
            self._json(404, {"error": "not found"})
            return

        try:
            upstream = socket.create_connection(
                (TTYD_UPSTREAM_HOST, int(TTYD_UPSTREAM_PORT)),
                timeout=5,
            )
        except Exception as e:
            self._json(502, {"error": f"upstream unreachable: {e}"})
            return
        upstream.settimeout(None)

        connection_hdr = self.headers.get("Connection", "").lower()
        upgrade_hdr    = self.headers.get("Upgrade", "").lower()
        is_ws = "upgrade" in connection_hdr and upgrade_hdr == "websocket"

        # Reconstruct request line + headers. For non-WS, force Connection:
        # close so upstream releases the socket after the response and our
        # read-side pipe sees EOF promptly.
        out = [f"{self.command} {self.path} HTTP/1.1\r\n".encode("latin-1")]
        for k, v in self.headers.items():
            if (not is_ws) and k.lower() == "connection":
                continue
            out.append(f"{k}: {v}\r\n".encode("latin-1"))
        if not is_ws:
            out.append(b"Connection: close\r\n")
        out.append(b"\r\n")

        try:
            upstream.sendall(b"".join(out))
            cl = int(self.headers.get("Content-Length") or 0)
            if cl:
                upstream.sendall(self.rfile.read(cl))
        except Exception as e:
            try: upstream.close()
            except Exception: pass
            self._json(502, {"error": f"upstream write failed: {e}"})
            return

        downstream = self.connection
        done = threading.Event()

        def pipe(src, dst):
            try:
                while not done.is_set():
                    try:
                        data = src.recv(65536)
                    except (OSError, ssl.SSLError):
                        break
                    if not data:
                        break
                    try:
                        dst.sendall(data)
                    except Exception:
                        break
            finally:
                done.set()
                # Shutdown read-side of src and write-side of dst to unblock
                # the sibling pipe promptly; it's harmless if already down.
                for sock, how in ((src, socket.SHUT_RD), (dst, socket.SHUT_WR)):
                    try: sock.shutdown(how)
                    except Exception: pass

        t1 = threading.Thread(target=pipe, args=(upstream, downstream), daemon=True)
        t2 = threading.Thread(target=pipe, args=(downstream, upstream), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
        try: upstream.close()
        except Exception: pass
        # Signal the base handler to close the downstream connection rather
        # than loop for another request — the socket is in an undefined state.
        self.close_connection = True

    def do_GET(self):
        url = urlparse(self.path)
        if self._serve_static(url.path):
            return
        if url.path == "/push/vapid-public-key":
            vapid = _load_vapid()
            if not vapid:
                self._json(503, {"error": "vapid not ready"})
                return
            self._json(200, {"key": vapid["public_b64url"]})
            return
        if url.path == "/push/latest":
            try:
                with open(LATEST_PATH) as f:
                    self._json(200, json.load(f))
            except FileNotFoundError:
                self._json(404, {"error": "no notifications yet"})
            return
        if url.path == "/windows":
            try:
                self._json(200, {"windows": list_windows_cached()})
            except Exception as e:
                self._json(500, {"error": str(e)})
            return
        if url.path == "/status":
            try:
                windows = list_windows_cached()
            except Exception as e:
                self._json(500, {"error": str(e)})
                return
            n_attn = sum(1 for w in windows if w.get("needs_attention"))
            n_busy = sum(1 for w in windows if w.get("busy_secs") is not None)
            self._json(200, {"needs_attention": n_attn, "busy": n_busy})
            return
        if url.path == "/scrollback":
            q = parse_qs(url.query)
            session = (q.get("session") or [""])[0]
            if not SESSION_RE.match(session):
                self._json(400, {"error": "bad session"})
                return
            try:
                index = int((q.get("index") or [""])[0])
            except ValueError:
                self._json(400, {"error": "bad index"})
                return
            rows = SCROLLBACK_DEFAULT_ROWS
            if q.get("rows"):
                try:
                    rows = max(0, min(SCROLLBACK_MAX_ROWS, int(q["rows"][0])))
                except ValueError:
                    pass
            target = f"{session}:{index}"
            # -S -<rows>: start <rows> lines above visible pane top (history)
            # -E -:       end at bottom of visible pane (so capture includes the
            #             current screen — wterm writes it onto the grid and the
            #             history above overflows into the ring)
            # -e:         preserve SGR escapes (color/attrs)
            # -p:         print to stdout
            r = run_tmux([
                "capture-pane", "-p", "-e",
                "-S", f"-{rows}", "-E", "-",
                "-t", target,
            ])
            if r.returncode != 0:
                self._json(500, {"error": r.stderr.strip() or "capture-pane failed"})
                return
            # capture-pane separates lines with \n; wterm needs CR+LF to advance
            # to column 0 on the next line (otherwise lines stagger diagonally).
            # Strip tmux's trailing \n so the seed does not fire one extra
            # scroll past its last row — the extra scroll would push the top
            # visible row into wterm's ring, and the subsequent select-window
            # repaint would then re-paint that same row on the grid, leaving
            # it duplicated at the ring/grid seam.
            data = r.stdout.rstrip("\n").replace("\n", "\r\n")
            self._json(200, {"data": data})
            return
        # Unknown path: fall through to ttyd (terminal HTML, /ws, /token).
        self._proxy_upstream()

    def do_POST(self):
        # Check path before reading the body — proxied requests need their
        # body forwarded verbatim to ttyd by _proxy_upstream.
        if self.path not in ("/push/subscribe", "/push/notify",
                             "/activate", "/kill", "/new-window", "/upload"):
            self._proxy_upstream()
            return

        # /upload has a raw binary body, not JSON — handle before _read_body.
        if self.path == "/upload":
            self._handle_upload()
            return

        try:
            body = self._read_body()
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return

        if self.path == "/push/subscribe":
            if not _valid_sub(body):
                self._json(400, {"error": "invalid subscription"})
                return
            with _subs_lock:
                subs = _load_subs()
                subs = [s for s in subs if s.get("endpoint") != body["endpoint"]]
                subs.append(body)
                _save_subs(subs)
            self._json(200, {"ok": True, "subscribers": len(subs)})
            return

        if self.path == "/push/notify":
            title = body.get("title")
            msg   = body.get("body")
            link  = body.get("url")
            tag   = body.get("tag")
            if not isinstance(title, str) and not isinstance(msg, str):
                self._json(400, {"error": "title or body required"})
                return
            result = _push_notify(title, msg, url=link, tag=tag)
            self._json(200, result)
            return

        if self.path == "/activate":
            try:
                session, index = validate_target(body)
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            r = run_tmux(["select-window", "-t", f"{session}:{index}"])
            if r.returncode != 0:
                self._json(500, {"error": r.stderr.strip()})
                return
            # select-window changes the session's active window, but ttyd's
            # client stays attached to whatever session it was on — so a tap
            # on a window in a non-attached session moved nothing visible and
            # appeared to "switch back" once the drawer reopened. switch-client
            # makes the visible terminal follow. Failure is non-fatal: with no
            # connected client (e.g. headless tests) there's nothing to follow.
            run_tmux(["switch-client", "-t", session])
            wid = _get_window_id(session, index)
            if wid:
                with _busy_lock:
                    _needs_attention.pop(wid, None)
                    # Anchor the grace window now, ahead of the next poll, so
                    # the deselect-redraw of whatever was previously active
                    # doesn't race the bg loop into re-flagging it.
                    _last_active_at[wid] = time.time()
            self._json(200, {"ok": True})
            return

        if self.path == "/kill":
            try:
                session, index = validate_target(body)
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            r = run_tmux(["kill-window", "-t", f"{session}:{index}"])
            if r.returncode != 0:
                self._json(500, {"error": r.stderr.strip()})
                return
            _invalidate_windows_cache()
            self._json(200, {"ok": True})
            return

        if self.path == "/new-window":
            session = body.get("session")
            if not isinstance(session, str) or not SESSION_RE.match(session):
                self._json(400, {"error": "bad session"})
                return

            default_src = os.path.join(CWD_ROOT, "src")
            cwd = default_src if os.path.isdir(default_src) else CWD_ROOT
            if body.get("cwd") is not None:
                try:
                    cwd = resolve_cwd(body.get("cwd"))
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                    return

            prompt = None
            if body.get("prompt") is not None:
                try:
                    prompt = sanitize_prompt(body.get("prompt"))
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                    return

            spawn_cmd = "zsh -lic 'claude; exec zsh -li'"
            fmt = "#{session_name}\t#{window_index}\t#{window_name}"
            r = run_tmux([
                "new-window", "-t", f"{session}:",
                "-c", cwd,
                "-P", "-F", fmt,
                spawn_cmd,
            ])
            # Tmux destroys a session when its last window is killed, and the
            # bootstrap unit only fires at boot — so a /new-window call racing
            # against the close of the last window finds no session (or no
            # server, if exit-empty took the whole tmux down). Recreate via
            # new-session, which also revives the server.
            if r.returncode != 0:
                r = run_tmux([
                    "new-session", "-d", "-s", session,
                    "-c", cwd,
                    "-P", "-F", fmt,
                    spawn_cmd,
                ])
            if r.returncode != 0:
                self._json(500, {"error": r.stderr.strip()})
                return
            parts = r.stdout.strip().split("\t")
            if len(parts) != 3:
                self._json(500, {"error": "unexpected tmux output"})
                return

            if prompt:
                schedule_prefill(f"{parts[0]}:{int(parts[1])}", prompt)

            _invalidate_windows_cache()
            self._json(200, {
                "session": parts[0],
                "index": int(parts[1]),
                "name": parts[2],
            })
            return

        # Unreachable — path allow-list at top of method gates this.
        self._json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path != "/push/subscribe":
            self._proxy_upstream()
            return
        try:
            body = self._read_body()
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return
        # Only /push/subscribe reaches here (path guarded at method top).
        endpoint = body.get("endpoint")
        if not isinstance(endpoint, str):
            self._json(400, {"error": "endpoint required"})
            return
        with _subs_lock:
            subs = _load_subs()
            new  = [s for s in subs if s.get("endpoint") != endpoint]
            if len(new) != len(subs):
                _save_subs(new)
        self._json(200, {"ok": True, "subscribers": len(new)})


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{CERT_DIR}/server.crt", f"{CERT_DIR}/server.key")
    ctx.load_verify_locations(f"{CERT_DIR}/ca.crt")
    ctx.verify_mode = ssl.CERT_REQUIRED

    _ensure_vapid()
    if not _PUSH_SUPPORTED:
        print(f"[tmux-api] push disabled: {_PUSH_IMPORT_ERR}", flush=True)

    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    threading.Thread(target=_busy_poll_loop, daemon=True).start()
    print(f"[tmux-api] listening on 0.0.0.0:{PORT} (mTLS)", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
