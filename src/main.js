import { WTerm } from "@wterm/dom";

const OP_OUTPUT = 0x30;
const OP_TITLE = 0x31;
const OP_PREFS = 0x32;
const OP_INPUT = 0x30;
const OP_RESIZE = 0x31;

// In prod the terminal page and the tmux-api share an origin (tmux-api
// terminates mTLS and reverse-proxies everything it doesn't serve itself
// through to ttyd), so the base is empty and all fetches stay same-origin.
// In the e2e harness the two run on different ports, so the build step
// substitutes the API port here.
const TMUX_API_PORT = "__TMUX_API_PORT__";
const TMUX_API = TMUX_API_PORT
  ? "https://" + location.hostname + ":" + TMUX_API_PORT
  : "";

function api(path, method, payload) {
  const opts = { method: method || "GET" };
  if (payload) { opts.headers = { "Content-Type": "application/json" }; opts.body = JSON.stringify(payload); }
  return fetch(TMUX_API + path, opts).then((r) =>
    r.json().then((j) => {
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      return j;
    }, () => { throw new Error("HTTP " + r.status); })
  );
}

// wterm's scrollback ring is shared across all tmux windows in this client,
// so on every window switch we (a) drop the previous window's ring with
// \e[3J and (b) re-seed it with the *target* window's actual tmux history
// from /scrollback. The seed includes both the history above the visible
// pane AND the current visible pane content, so it lands on the wterm grid
// in the right shape — when tmux's own select-window repaint arrives a
// moment later it overwrites the same cells idempotently and there is no
// flicker. Without the seed, has-scrollback stays false (overflow-y hidden,
// finger-drag does nothing) until output or a resize incidentally pushes
// rows into the ring, and what does end up in the ring is whatever tmux
// happened to paint on the grid — not real history.
async function seedScrollback(session, index) {
  if (!window.term) return;
  window.term.write("\x1b[3J");
  try {
    const r = await api(`/scrollback?session=${encodeURIComponent(session)}&index=${index}`);
    if (r.data) window.term.write(r.data);
  } catch (err) {
    // Non-fatal: tmux's select-window repaint will still bring the visible
    // screen back. Just no scrollback history this time.
    console.warn("seedScrollback failed:", err);
  }
}

async function fetchToken() {
  try {
    const base = location.pathname.replace(/\/+$/, "");
    const res = await fetch(base + "/token");
    if (!res.ok) return "";
    const j = await res.json();
    return j.token || "";
  } catch {
    return "";
  }
}

function wsUrl() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const base = location.pathname.replace(/\/+$/, "");
  return `${scheme}//${location.host}${base}/ws${location.search}`;
}

function concatInputFrame(opByte, body) {
  const out = new Uint8Array(body.length + 1);
  out[0] = opByte;
  out.set(body, 1);
  return out;
}

async function start() {
  const el = document.getElementById("terminal");
  const term = new WTerm(el, { cursorBlink: true });
  window.term = term;
  await term.init();

  // wterm parks a hidden <textarea> at position:absolute; top:0; left:-9999px
  // inside .wterm. On Android, Chrome scrolls the nearest scrollable ancestor to
  // keep the focused caret in view on every keystroke — which snaps .wterm to
  // scrollTop=0 (top of scrollback). position:fixed anchors the textarea to the
  // viewport so scroll-into-view has nothing to scroll.
  const hiddenInput = el.querySelector("textarea");
  if (hiddenInput) hiddenInput.style.position = "fixed";

  // First-tap-opens-keyboard pins view to top of scrollback otherwise. Android's
  // keyboard animation shrinks the layout viewport over ~300ms, during which
  // wterm's ResizeObserver samples _isScrolledToBottom AFTER clientHeight has
  // dropped — returning false and skipping the scroll-to-bottom that would
  // normally re-pin. Pin scrollTop to scrollHeight on every animation frame for
  // 700ms after focus so Android's scroll-into-view and wterm's resize path
  // both get overridden.
  if (hiddenInput) {
    hiddenInput.addEventListener("focus", () => {
      const pinUntil = performance.now() + 700;
      const tick = () => {
        el.scrollTop = el.scrollHeight;
        if (performance.now() < pinUntil) requestAnimationFrame(tick);
      };
      tick();
    });
  }

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  const token = await fetchToken();

  let ws = null;
  let reconnectDelayMs = 500;
  const MAX_RECONNECT_MS = 8000;
  const DISCONNECT_MSG_DELAY_MS = 2000;
  let reconnectTimer = null;
  let disconnectMsgTimer = null;
  let disconnectShown = false;

  const send = (bytes) => {
    if (ws && ws.readyState === 1) ws.send(bytes);
  };
  const sendInput = (str) => send(concatInputFrame(OP_INPUT, encoder.encode(str)));
  const sendResize = (cols, rows) =>
    send(concatInputFrame(OP_RESIZE, encoder.encode(JSON.stringify({ columns: cols, rows }))));

  term.onData = sendInput;
  term.onTitle = (t) => { document.title = t; };
  term.onResize = (cols, rows) => sendResize(cols, rows);

  function connect() {
    ws = new WebSocket(wsUrl(), ["tty"]);
    ws.binaryType = "arraybuffer";

    ws.addEventListener("open", () => {
      reconnectDelayMs = 500;
      clearTimeout(disconnectMsgTimer);
      disconnectMsgTimer = null;
      if (disconnectShown) {
        term.write("\r\n\x1b[32m[ttyd: reconnected]\x1b[0m\r\n");
        disconnectShown = false;
      }
      ws.send(encoder.encode(JSON.stringify({ AuthToken: token, columns: term.cols, rows: term.rows })));
    });

    ws.addEventListener("message", (ev) => {
      const data = ev.data;
      if (typeof data === "string") return;
      const buf = new Uint8Array(data);
      if (buf.length === 0) return;
      const op = buf[0];
      const payload = buf.subarray(1);
      if (op === OP_OUTPUT) {
        term.write(payload);
      } else if (op === OP_TITLE) {
        document.title = decoder.decode(payload);
      } else if (op === OP_PREFS) {
        /* ignore */
      }
    });

    ws.addEventListener("close", () => {
      clearTimeout(disconnectMsgTimer);
      disconnectMsgTimer = setTimeout(() => {
        term.write(`\r\n\x1b[31m[ttyd: connection lost, reconnecting...]\x1b[0m\r\n`);
        disconnectShown = true;
      }, DISCONNECT_MSG_DELAY_MS);
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(() => {
        reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_MS);
        connect();
      }, reconnectDelayMs);
    });
  }

  connect();

  // Android Chrome aggressively kills backgrounded WebSockets, so by the time
  // the tab comes back the reconnect timer has usually backed off to several
  // seconds. Force an immediate reconnect on return-to-visible so reopening
  // the tab snaps back to the live session without waiting out the backoff.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    reconnectDelayMs = 500;
    connect();
  });

  attachSwipeHandler(el);
  attachPasteHandler(sendInput);
  attachLongPressPaste(sendInput);
  mountFabDrawer();
  consumeLaunchParams();
  registerServiceWorker();
}

function pasteError(msg) {
  if (window.term) window.term.write(`\r\n\x1b[31m[paste: ${msg}]\x1b[0m\r\n`);
}

// POST a Blob/File to /upload and type "@<abs-path> " into the tty. Shared
// by the desktop paste-event path (ctrl+V) and the mobile paste-button path
// (navigator.clipboard.read). Returns true on success.
async function uploadImageAndInject(blob, type, sendInput) {
  try {
    const res = await fetch(TMUX_API + "/upload", {
      method: "POST",
      headers: { "Content-Type": type },
      body: blob,
    });
    if (!res.ok) {
      let msg = "HTTP " + res.status;
      try { msg = (await res.json()).error || msg; } catch {}
      pasteError(msg);
      return false;
    }
    const { path } = await res.json();
    sendInput("@" + path + " ");
    return true;
  } catch (err) {
    pasteError(err.message);
    return false;
  }
}

// Desktop ctrl+V. The `paste` event only fires when the browser itself
// dispatches a paste (an editable element has focus, or keyboard ctrl+V is
// routed to the page). On Android Chrome, long-press on wterm never triggers
// this because the hidden textarea is positioned at left:-9999px — the
// long-press target is .term-grid, which isn't editable. For that case see
// attachLongPressPaste() below.
function attachPasteHandler(sendInput) {
  document.addEventListener("paste", async (e) => {
    if (!e.clipboardData) return;
    const images = [];
    for (const item of e.clipboardData.items) {
      if (item.kind === "file" && item.type && item.type.startsWith("image/")) {
        const f = item.getAsFile();
        if (f) images.push(f);
      }
    }
    if (images.length === 0) return;  // let wterm handle plain-text pastes
    e.preventDefault();
    for (const file of images) {
      await uploadImageAndInject(file, file.type, sendInput);
    }
  });
}

// Long-press inside the terminal → paste. The native Android long-press →
// Paste menu isn't feasible: wterm's textarea has
// pointer-events:none and sits at left:-9999px, and making it a long-press
// target would break scroll + .term-row text selection. Instead, we hook
// the `contextmenu` event — Chrome Android fires it on every long-press
// (before showing any native menu) and desktop browsers fire it on
// right-click — and call navigator.clipboard.read() to paste. Same flow as
// the old ctrl+V path: images → /upload → @path, text → direct sendInput.
//
// If a non-collapsed selection exists we skip, so long-press on selected
// text still opens the native Copy/Share menu instead of swallowing the
// user's selection gesture. Empty-area long-press is unambiguously paste.
function attachLongPressPaste(sendInput) {
  const el = document.getElementById("terminal");
  if (!el) return;
  el.addEventListener("contextmenu", async (e) => {
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    e.preventDefault();
    if (!navigator.clipboard || !navigator.clipboard.read) {
      pasteError("clipboard.read unsupported in this browser");
      return;
    }
    try {
      const items = await navigator.clipboard.read();
      for (const item of items) {
        const imgType = item.types.find((t) => t.startsWith("image/"));
        if (imgType) {
          const blob = await item.getType(imgType);
          await uploadImageAndInject(blob, imgType, sendInput);
          continue;
        }
        if (item.types.includes("text/plain")) {
          const blob = await item.getType("text/plain");
          const text = await blob.text();
          if (text) sendInput(text);
        }
      }
    } catch (err) {
      pasteError(err.name === "NotAllowedError" ? "clipboard permission denied" : err.message);
    }
  });
}

// Register the PWA service worker for web-push. Same-origin only; the SW is
// served by tmux-api at /sw.js with Service-Worker-Allowed: /. In the e2e
// harness the page and API live on different ports, so push is disabled —
// browsers won't allow cross-origin SW registration anyway.
async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  if (TMUX_API_PORT) return; // cross-origin e2e — skip
  try {
    await navigator.serviceWorker.register("/sw.js", { scope: "/" });
  } catch (err) {
    console.warn("SW register failed:", err);
  }
}

function b64urlToBytes(s) {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function pushSubscription() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) return null;
  const reg = await navigator.serviceWorker.ready;
  return reg.pushManager.getSubscription();
}

async function enablePush() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    throw new Error("Push not supported in this browser");
  }
  const perm = await Notification.requestPermission();
  if (perm !== "granted") throw new Error("Notification permission " + perm);
  const reg = await navigator.serviceWorker.ready;
  const { key } = await api("/push/vapid-public-key");
  const sub = await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: b64urlToBytes(key),
  });
  await api("/push/subscribe", "POST", sub.toJSON());
  return sub;
}

async function disablePush() {
  const sub = await pushSubscription();
  if (!sub) return;
  try {
    await api("/push/subscribe", "DELETE", { endpoint: sub.endpoint });
  } catch (err) {
    console.warn("server unsubscribe failed:", err);
  }
  await sub.unsubscribe();
}

// Handle ?prompt=...&cwd=... on load: spawn a new tmux window running claude
// in the target dir, then prefill its input box (no submit). Clear the query
// afterwards so a refresh doesn't re-launch.
async function consumeLaunchParams() {
  const sp = new URLSearchParams(location.search);
  const prompt = sp.get("prompt");
  const cwd = sp.get("cwd");
  if (!prompt && !cwd) return;
  history.replaceState(null, "", location.pathname);
  try {
    const payload = { session: sp.get("session") || "apiary" };
    if (cwd) payload.cwd = cwd;
    if (prompt) payload.prompt = prompt;
    // New window has no history, so no /scrollback fetch — just drop the
    // previous window's ring before tmux's repaint of the new pane arrives.
    if (window.term) window.term.write("\x1b[3J");
    const w = await api("/new-window", "POST", payload);
    await api("/activate", "POST", { session: w.session, index: w.index });
  } catch (err) {
    if (window.term) {
      window.term.write(`\r\n\x1b[31m[launch failed: ${err.message}]\x1b[0m\r\n`);
    }
  }
}

function attachSwipeHandler(el) {
  const SWIPE_TH = 80;
  let startX = null, startY = null;
  el.addEventListener("touchstart", (e) => {
    if (e.touches.length !== 1) { startX = null; return; }
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
  }, { passive: true });
  el.addEventListener("touchend", (e) => {
    if (startX === null || e.changedTouches.length !== 1) return;
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) { startX = null; return; }
    const dx = e.changedTouches[0].clientX - startX;
    const dy = e.changedTouches[0].clientY - startY;
    startX = null;
    if (Math.abs(dx) > SWIPE_TH && Math.abs(dx) > Math.abs(dy) * 1.5) {
      swipeToWindow(dx > 0 ? -1 : 1);
    }
  }, { passive: true });
}

// Used to be a raw `C-b n/p` keystroke, but we need to know the target
// session+index before the switch so we can fetch its scrollback and seed
// wterm. Look up the active window in /windows, compute the next/prev sibling
// in the same session, then run the standard seed→activate flow.
async function swipeToWindow(offset) {
  try {
    const d = await api("/windows");
    const windows = d.windows || [];
    const active = windows.find((w) => w.active);
    if (!active) return;
    const siblings = windows
      .filter((w) => w.session === active.session)
      .sort((a, b) => a.index - b.index);
    if (siblings.length < 2) return;
    const i = siblings.findIndex((w) => w.index === active.index);
    const target = siblings[(i + offset + siblings.length) % siblings.length];
    await seedScrollback(target.session, target.index);
    await api("/activate", "POST", { session: target.session, index: target.index });
  } catch (err) {
    console.warn("swipe failed:", err);
  }
}

function mountFabDrawer() {
  const fab = document.getElementById("tm-fab");
  const drawer = document.getElementById("tm-drawer");
  const backdrop = document.getElementById("tm-backdrop");
  const body = document.getElementById("tm-body");
  const closeBtn = document.getElementById("tm-close");
  const pushBtn = document.getElementById("tm-push");

  let tickerHandle = null;

  // Hide the push toggle when push isn't available (no SW, cross-origin
  // e2e harness, or the browser lacks PushManager).
  if (pushBtn) {
    if (TMUX_API_PORT || !("serviceWorker" in navigator) || !("PushManager" in window)) {
      pushBtn.style.display = "none";
    } else {
      refreshPushBtn();
      pushBtn.addEventListener("click", togglePush);
    }
  }

  async function refreshPushBtn() {
    const sub = await pushSubscription();
    pushBtn.classList.toggle("on", !!sub);
    pushBtn.title = sub ? "notifications on" : "notifications off";
  }

  async function togglePush() {
    pushBtn.disabled = true;
    try {
      const sub = await pushSubscription();
      if (sub) await disablePush();
      else     await enablePush();
      await refreshPushBtn();
    } catch (err) {
      showError("Push: " + err.message);
    } finally {
      pushBtn.disabled = false;
    }
  }

  function openDrawer() {
    drawer.classList.add("open");
    backdrop.classList.add("open");
    body.dataset.fresh = "1";
    load();
  }
  function closeDrawer() {
    drawer.classList.remove("open");
    backdrop.classList.remove("open");
    if (tickerHandle) { clearInterval(tickerHandle); tickerHandle = null; }
  }

  function formatDuration(secs) {
    if (secs < 60) return secs + "s";
    if (secs < 3600) {
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return s ? m + "m " + s + "s" : m + "m";
    }
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    return m ? h + "h " + m + "m" : h + "h";
  }

  function tickDurations() {
    const now = Date.now();
    body.querySelectorAll(".tm-duration[data-anchor]").forEach((el) => {
      const anchor = parseInt(el.dataset.anchor, 10);
      if (!anchor) return;
      const secs = Math.max(0, Math.floor((now - anchor) / 1000));
      el.textContent = formatDuration(secs);
    });
  }

  function showError(msg) {
    body.innerHTML = "";
    const e = document.createElement("div");
    e.className = "tm-err";
    e.textContent = msg;
    body.appendChild(e);
  }

  function load() {
    body.innerHTML = '<div class="tm-empty">Loading...</div>';
    api("/windows").then((d) => render(d.windows || []))
      .catch((err) => showError("Failed: " + err.message));
  }

  function render(windows) {
    const bySession = {};
    const order = [];
    windows.forEach((w) => {
      if (!(w.session in bySession)) { bySession[w.session] = []; order.push(w.session); }
      bySession[w.session].push(w);
    });
    order.sort((a, b) => (a === "apiary" ? -1 : b === "apiary" ? 1 : a.localeCompare(b)));

    body.innerHTML = "";
    if (!order.length) {
      const empty = document.createElement("div");
      empty.className = "tm-empty";
      empty.textContent = "No windows.";
      body.appendChild(empty);
      return;
    }

    order.forEach((sess) => {
      const hd = document.createElement("div");
      hd.className = "tm-sess";
      const nm = document.createElement("div");
      nm.className = "tm-sess-name";
      nm.textContent = sess;
      const add = document.createElement("button");
      add.className = "tm-sess-add";
      add.dataset.session = sess;
      add.innerHTML = "&#43;";
      add.setAttribute("aria-label", "new window in " + sess);
      add.addEventListener("click", (ev) => { ev.stopPropagation(); newWindow(sess); });
      hd.appendChild(nm);
      hd.appendChild(add);
      body.appendChild(hd);

      bySession[sess].sort((a, b) => a.index - b.index).forEach((w) => body.appendChild(makeRow(w)));
    });

    if (body.dataset.fresh === "1") {
      const rows = body.querySelectorAll(".tm-row");
      rows.forEach((row, i) => { row.style.animationDelay = (i * 28) + "ms"; });
      // Clear after the longest stagger + animation completes so re-renders skip it.
      const total = rows.length * 28 + 400;
      setTimeout(() => { delete body.dataset.fresh; }, total);
    }

    if (tickerHandle) clearInterval(tickerHandle);
    tickerHandle = setInterval(tickDurations, 1000);
    tickDurations();
  }

  // tmux's #{window_activity} updates on any pane output. Claude's TUI renders
  // a spinner every ~100ms while working, so "output in the last 2s" is a
  // reliable proxy for "busy". Longer gaps mean the window is idle — either
  // waiting for input (Claude prompt, shell prompt) or just sitting there.
  const BUSY_THRESHOLD_SECS = 2;

  function makeRow(w) {
    const row = document.createElement("div");
    row.className = "tm-row" + (w.active ? " active" : "");
    row.dataset.session = w.session;
    row.dataset.index = w.index;
    const idx = document.createElement("span"); idx.className = "tm-idx"; idx.textContent = w.index;
    const status = document.createElement("span");
    const busy = typeof w.idle_secs === "number" && w.idle_secs < BUSY_THRESHOLD_SECS;
    status.className = "tm-status " + (busy ? "busy" : "idle");
    status.setAttribute("aria-label", busy ? "busy" : "idle");
    const nm = document.createElement("span"); nm.className = "tm-name"; nm.textContent = w.name;
    const dur = document.createElement("span"); dur.className = "tm-duration";
    if (typeof w.busy_secs === "number") {
      // Anchor to a client-local start time so setInterval can tick forward
      // without refetching. The server's busy_secs is authoritative on refresh.
      dur.dataset.anchor = String(Date.now() - w.busy_secs * 1000);
      dur.textContent = formatDuration(w.busy_secs);
    }
    const kill = document.createElement("button"); kill.className = "tm-kill"; kill.innerHTML = "&#10005;";
    kill.setAttribute("aria-label", "kill " + w.name);
    row.appendChild(idx); row.appendChild(status); row.appendChild(nm); row.appendChild(dur); row.appendChild(kill);
    row.addEventListener("click", () => activate(w));
    kill.addEventListener("click", (ev) => { ev.stopPropagation(); enterConfirm(row, w); });
    return row;
  }

  function enterConfirm(row, w) {
    row.classList.add("confirm");
    row.innerHTML = "";
    const nm = document.createElement("span"); nm.className = "tm-name";
    nm.textContent = "Kill " + w.index + ": " + w.name + "?";
    const yes = document.createElement("button"); yes.className = "tm-confirm-btn"; yes.textContent = "Kill";
    const no = document.createElement("button"); no.className = "tm-cancel-btn"; no.textContent = "Cancel";
    row.appendChild(nm); row.appendChild(no); row.appendChild(yes);
    yes.addEventListener("click", (ev) => { ev.stopPropagation(); killWindow(w); });
    no.addEventListener("click", (ev) => { ev.stopPropagation(); load(); });
  }

  async function activate(w) {
    try {
      await seedScrollback(w.session, w.index);
      await api("/activate", "POST", { session: w.session, index: w.index });
      closeDrawer();
    } catch (err) {
      showError("Activate failed: " + err.message);
    }
  }
  function killWindow(w) {
    api("/kill", "POST", { session: w.session, index: w.index })
      .then(load)
      .catch((err) => showError("Kill failed: " + err.message));
  }
  function newWindow(sess) {
    // New window has no history — skip /scrollback, just drop the previous
    // ring before tmux's repaint.
    if (window.term) window.term.write("\x1b[3J");
    api("/new-window", "POST", { session: sess })
      .then((w) => api("/activate", "POST", { session: w.session, index: w.index }))
      .then(() => { closeDrawer(); })
      .catch((err) => showError("New window failed: " + err.message));
  }

  fab.addEventListener("click", openDrawer);
  backdrop.addEventListener("click", closeDrawer);
  closeBtn.addEventListener("click", closeDrawer);
}

start();
