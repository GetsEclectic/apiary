# Security

Apiary gives anyone holding a valid client certificate a shell on the host. Treat it accordingly.

## Trust boundary

- **mTLS is the sole authentication boundary.** `tmux-api.py` terminates mTLS on `:3443` and is the only service bound to a non-loopback address. `ttyd` itself runs on `127.0.0.1:3441` and is reachable only through the mTLS proxy.
- **The CA is your self-signed CA.** `gen-certs.sh` creates a private CA, a server cert, and one client cert per invocation. Trust is bootstrapped by manually importing `ca.crt` on each device you use. There is no path revocation beyond regenerating the CA and re-distributing `ca.crt` to every device.
- **Intended deployment is a LAN you control end-to-end.** Apiary is not hardened for direct public-internet exposure. No rate limiting, no account model, no intrusion detection. If you tunnel it to the internet (Tailscale, WireGuard, Cloudflare Tunnel with mTLS), the tunnel is part of your trust boundary.

## What the `.p12` password is not

`gen-certs.sh` bundles the client key into `<user>-client.p12` with a default password of `apiary` (overridable via `P12_PASS=…`). The password exists because Android's key store refuses empty-password PKCS#12 files. **It is not a security boundary.** If an attacker can read the `.p12` file from disk, they can import it. Protect the file with filesystem permissions (the script sets `0600`) and your distribution channel (AirDrop, encrypted USB, signed email) — not the password.

## Private material that must not leave the host

The `gen-certs.sh` / tmux-api.py state directory (`$APIARY_STATE_DIR`, default `~/.config/apiary/`) holds:

- `ca.key` — signs all client certs. Compromise means anyone can mint a client that your server will trust.
- `server.key` — the TLS server key.
- `client.key` / `<user>-client.p12` — a client identity. Anyone holding one has shell access.
- `vapid.json` — the Web Push VAPID keypair. Less critical, but a leak lets someone forge push notifications to your subscribed devices.
- `subscriptions.json` — endpoints your host will push to.

All of these are owner-read-only (`0600`) and are in `.gitignore`. If you add new state, extend `.gitignore` accordingly.

## What is validated on the API surface

- Session and window names: `^[A-Za-z0-9_.-]+$`.
- Scrollback row counts: capped to 100 000.
- Working directories for `/new-window`: realpath-resolved and required to be inside `$APIARY_CWD_ROOT` (defaults to `$HOME`). Null bytes and newlines are rejected.
- All `tmux` invocations use `subprocess.run([...])` with list args. There is no `shell=True` anywhere in the codebase.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/GetsEclectic/apiary/security/advisories/new) on the repo. Please do not file public issues for anything that compromises the shell boundary.
