# Changelog

All notable changes to Apiary will be documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and version numbers follow [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- Notification taps now open the installed PWA instead of a browser tab. The hook was injecting an absolute URL built from `hostname -s`, which is cross-origin from the hostname/IP the PWA was actually installed under (`.local` via mDNS or LAN IP); the service worker's cross-origin `clients.openWindow()` then fell back to the browser. The hook now defaults to the relative path `/`, and the service worker strips any incoming origin and resolves against its own scope, so the tap target is always same-origin as the PWA.

## [0.1.0] — 2026-04-24

Initial public release.

- Phone-first web terminal served by `ttyd` over mTLS, fronted by `tmux-api.py` on `:3443` (loopback ttyd on `:3441`).
- Persistent `tmux` session that survives browser disconnects, with a floating window-switcher drawer optimized for one-thumb use.
- Web Push notifications with payloads fetched back over the same mTLS origin (no third-party push service ever sees notification text).
- Image-paste flow: paste in the browser, file lands on the host via `/upload`, `@<abs path>` is typed into the active tty for Claude Code / aider / etc. to pick up as an attachment.
- Linux (systemd user units) and macOS (launchd LaunchDaemons) install paths from a single `install.sh`.
- CI: container smoke test on Ubuntu 24.04, full install + mTLS smoke on macOS 14.

[Unreleased]: https://github.com/GetsEclectic/apiary/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/GetsEclectic/apiary/releases/tag/v0.1.0
