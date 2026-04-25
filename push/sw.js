// Service worker for apiary push notifications.
//
// Strategy: pushes from the server carry no payload. On receipt, the worker
// fetches /push/latest over the same mTLS origin that registered it; the
// notification body therefore never transits a third-party push service.

// Absolute paths: SW scope is "/" (it fronts the terminal too), so relative
// URLs would resolve against the site root rather than the push subtree.
const LATEST_URL = new URL("/push/latest", self.registration.scope).toString();
// PNG, not SVG: Chrome for Android stopped rasterizing SVG notification
// icons, producing a blank white square in both the content icon and the
// status-bar badge. PNGs render reliably; SVGs retained as build sources.
const ICON_URL   = new URL("/icon.png",    self.registration.scope).toString();
// Android masks the badge (status-bar icon) alpha-to-white; a background-
// filled image ends up as a solid white square. badge.png is a silhouette only.
const BADGE_URL  = new URL("/badge.png",   self.registration.scope).toString();
const VAPID_KEY_URL = new URL("/push/vapid-public-key", self.registration.scope).toString();
const SUBSCRIBE_URL = new URL("/push/subscribe",        self.registration.scope).toString();
const FALLBACK   = { title: "agent finished", body: "" };

function b64urlToBytes(s) {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

self.addEventListener("install",  (e) => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

// Chrome on Android rotates push endpoints (FCM token rotation, long idle,
// Doze, network resets) and fires `pushsubscriptionchange` on the SW. If we
// don't re-subscribe here the user's notifications go silently dead until
// they manually toggle the bell. Re-subscribe with the same VAPID key, POST
// the new endpoint, then purge the old one server-side.
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil((async () => {
    let newSub = event.newSubscription;
    if (!newSub) {
      try {
        const r = await fetch(VAPID_KEY_URL, { credentials: "include", cache: "no-store" });
        if (!r.ok) return;
        const { key } = await r.json();
        newSub = await self.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: b64urlToBytes(key),
        });
      } catch (_) {
        return;
      }
    }
    // Register the new sub before deleting the old one so we never end up
    // with zero registered endpoints if the second request fails.
    try {
      await fetch(SUBSCRIBE_URL, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(newSub.toJSON()),
      });
    } catch (_) {}
    if (event.oldSubscription) {
      try {
        await fetch(SUBSCRIBE_URL, {
          method: "DELETE",
          credentials: "include",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ endpoint: event.oldSubscription.endpoint }),
        });
      } catch (_) {}
    }
  })());
});

self.addEventListener("push", (event) => {
  event.waitUntil((async () => {
    let n = { ...FALLBACK };
    try {
      if (event.data) {
        // Payload-encrypted push (rare in this app; supported for completeness).
        Object.assign(n, event.data.json());
      } else {
        const r = await fetch(LATEST_URL, { credentials: "include", cache: "no-store" });
        if (r.ok) Object.assign(n, await r.json());
      }
    } catch (_) {
      // Fall through to FALLBACK; Chrome penalises push events that never
      // call showNotification, so we show *something* regardless.
    }
    await self.registration.showNotification(n.title || FALLBACK.title, {
      body: (n.body || "").slice(0, 280),
      icon: ICON_URL,
      badge: BADGE_URL,
      tag: n.tag || "ttyd-agent",
      data: { url: n.url || "" },
      renotify: true,
    });
  })());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data && event.notification.data.url;
  if (!url) return;
  event.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if (c.url === url && "focus" in c) return c.focus();
    }
    return self.clients.openWindow(url);
  })());
});
