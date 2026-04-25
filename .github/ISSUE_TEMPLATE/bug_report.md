---
name: Bug report
about: Something installed and ran, but didn't behave the way you expected.
labels: bug
---

**For security issues, do not open a public issue.** Use the [private security advisory flow](https://github.com/GetsEclectic/apiary/security/advisories/new) instead.

## What happened

A clear description of the bug, ideally with a phone-side and host-side observation.

## Expected

What you thought would happen.

## Repro

1. ...
2. ...

## Environment

- Host OS: (e.g. Ubuntu 24.04 / macOS 14.5)
- `ttyd --version`:
- `tmux -V`:
- Browser on the phone: (Chrome / Safari / version)
- Apiary commit (`git -C ~/src/apiary rev-parse HEAD`):

## Logs

Relevant lines from:

- `journalctl --user -u apiary-tmux-api.service` (Linux) / `~/.config/apiary/log/tmux-api.{out,err}` (macOS)
- Browser DevTools console
