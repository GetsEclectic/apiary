#!/usr/bin/env bash
# Install Apiary. Linux: systemd user units. macOS: launchd LaunchDaemons.
set -euo pipefail

OS="$(uname -s)"  # Linux | Darwin

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${APIARY_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/apiary}"

mkdir -p "$STATE_DIR" "$STATE_DIR/log"

# --- dep preflight ---
missing=()
for bin in ttyd npm tmux openssl python3; do
  command -v "$bin" >/dev/null || missing+=("$bin")
done

# envsubst is `gettext-base` on Debian/Ubuntu and `gettext` elsewhere; Homebrew
# keeps it unlinked, so resolve the binary path explicitly below.
ENVSUBST_BIN="$(command -v envsubst || true)"
if [[ -z "$ENVSUBST_BIN" && "$OS" == Darwin ]] && command -v brew >/dev/null; then
  _brew_gettext="$(brew --prefix gettext 2>/dev/null || true)"
  [[ -n "$_brew_gettext" && -x "$_brew_gettext/bin/envsubst" ]] && ENVSUBST_BIN="$_brew_gettext/bin/envsubst"
fi
[[ -z "$ENVSUBST_BIN" ]] && missing+=("envsubst")

if (( ${#missing[@]} )); then
  echo "Missing binaries: ${missing[*]}" >&2
  if command -v apt-get >/dev/null; then
    echo "Install on Debian/Ubuntu:"
    echo "  sudo apt-get install -y ttyd npm tmux openssl python3 gettext-base"
  elif command -v dnf >/dev/null; then
    echo "Install on Fedora:"
    echo "  sudo dnf install -y ttyd npm tmux openssl python3 gettext"
  elif command -v pacman >/dev/null; then
    echo "Install on Arch:"
    echo "  sudo pacman -S --needed ttyd npm tmux openssl python gettext"
  elif [[ "$OS" == Darwin ]]; then
    echo "Install with Homebrew:"
    echo "  brew install ttyd node tmux python@3.12 gettext jq bash"
  fi
  exit 1
fi

# tmux-api's /push/ endpoints need PyJWT + cryptography for VAPID signing.
# Other endpoints (windows/scrollback/activate) still work without them.
if ! python3 -c 'import jwt, cryptography' 2>/dev/null; then
  echo ">> WARN: python3 is missing 'jwt' and/or 'cryptography'; push notifications will be disabled."
  echo "   On Debian/Ubuntu: sudo apt install python3-jwt python3-cryptography"
fi

TTYD_BIN="$(command -v ttyd)"
TMUX_BIN="$(command -v tmux)"
PYTHON_BIN="$(command -v python3)"

# --- build UI ---
echo ">> building UI"
( cd "$REPO_DIR/src" && npm ci && npm run build )

# --- generate certs into STATE_DIR ---
if [[ ! -f "$STATE_DIR/server.key" || ! -f "$STATE_DIR/ca.key" ]]; then
  echo ">> generating certs in $STATE_DIR"
  STATE_DIR="$STATE_DIR" "$REPO_DIR/gen-certs.sh"
elif ! openssl x509 -in "$STATE_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null \
     | grep -qE "DNS:$(hostname)(,|\$|[[:space:]])"; then
  echo ">> server cert does not cover $(hostname), regenerating"
  rm -f "$STATE_DIR/server.crt" "$STATE_DIR/server.key" "$STATE_DIR/server.csr"
  STATE_DIR="$STATE_DIR" "$REPO_DIR/gen-certs.sh"
fi

# --- VAPID keypair guard ---
# tmux-api.py generates vapid.json lazily on first server boot. That's fine
# on a fresh install, but on a migration/reinstall every existing browser
# push subscription is cryptographically bound to the old VAPID public key
# and will be silently orphaned — the push server returns subscribers: 0
# forever until every device re-subscribes.
if [[ ! -f "$STATE_DIR/vapid.json" ]]; then
  echo
  echo "!! No VAPID keypair in $STATE_DIR."
  echo "   A fresh keypair will be generated on first server boot."
  echo "   If any device has previously subscribed to push (via a prior install"
  echo "   or a different STATE_DIR), its subscription will be silently"
  echo "   invalidated and push notifications will fail until it re-subscribes."
  if [[ -t 0 ]]; then
    read -r -p "   Proceed? Safe for a true fresh install. [y/N] " ans
    if [[ "${ans,,}" != y* ]]; then
      echo "   Aborting. Copy vapid.json from the prior STATE_DIR into $STATE_DIR and re-run."
      exit 1
    fi
  else
    echo "   (non-interactive: proceeding)"
  fi
fi

# --- render + install service units ---
APIARY_USER="$(id -un)"
APIARY_GROUP="$(id -gn)"
export REPO_DIR STATE_DIR TTYD_BIN TMUX_BIN PYTHON_BIN APIARY_USER APIARY_GROUP HOME

if [[ "$OS" == Darwin ]]; then
  STAGING="$STATE_DIR/launchd-staging"
  mkdir -p "$STAGING"
  echo ">> rendering plists into $STAGING"
  for svc in com.apiary.tmux com.apiary.tmux-api com.apiary.ttyd; do
    "$ENVSUBST_BIN" \
      '${REPO_DIR} ${STATE_DIR} ${TTYD_BIN} ${TMUX_BIN} ${PYTHON_BIN} ${APIARY_USER} ${APIARY_GROUP} ${HOME}' \
      < "$REPO_DIR/launchd/${svc}.plist.template" \
      > "$STAGING/${svc}.plist"
  done

  echo ">> installing plists into /Library/LaunchDaemons (requires sudo)"
  for svc in com.apiary.tmux com.apiary.tmux-api com.apiary.ttyd; do
    sudo install -m 0644 -o root -g wheel \
      "$STAGING/${svc}.plist" "/Library/LaunchDaemons/${svc}.plist"
  done

  echo ">> (re)loading launchd services"
  for svc in com.apiary.ttyd com.apiary.tmux-api com.apiary.tmux; do
    sudo launchctl bootout "system/$svc" 2>/dev/null || true
  done
  for svc in com.apiary.tmux com.apiary.tmux-api com.apiary.ttyd; do
    sudo launchctl bootstrap system "/Library/LaunchDaemons/${svc}.plist"
  done
  for svc in com.apiary.tmux com.apiary.tmux-api com.apiary.ttyd; do
    sudo launchctl kickstart -k "system/$svc"
  done

  echo
  echo "Services:"
  for svc in com.apiary.tmux com.apiary.tmux-api com.apiary.ttyd; do
    state="$(sudo launchctl print "system/$svc" 2>/dev/null | awk '/state =/{print $3; exit}')"
    printf "  %-22s %s\n" "$svc" "${state:-unknown}"
  done
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  echo ">> rendering units into $UNIT_DIR"
  for unit in apiary-tmux apiary-tmux-api apiary-ttyd; do
    "$ENVSUBST_BIN" '${REPO_DIR} ${STATE_DIR} ${TTYD_BIN} ${TMUX_BIN} ${PYTHON_BIN}' \
      < "$REPO_DIR/units/${unit}.service.template" \
      > "$UNIT_DIR/${unit}.service"
  done

  if ! command -v systemctl >/dev/null || [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo
    echo ">> systemctl --user unavailable (no user systemd session); skipping service activation."
    echo "   Run on the real target:"
    echo "     systemctl --user daemon-reload && systemctl --user enable --now apiary-tmux apiary-tmux-api apiary-ttyd"
  else
    systemctl --user daemon-reload
    systemctl --user enable --now apiary-tmux.service apiary-tmux-api.service apiary-ttyd.service
    echo
    echo "Services:"
    systemctl --user is-active apiary-tmux.service apiary-tmux-api.service apiary-ttyd.service
  fi
fi

echo
echo "Web UI: https://$(hostname):3443/"
echo "Trust $STATE_DIR/ca.crt as a root CA on each device."
echo "Import $STATE_DIR/${CLIENT_CN:-${USER:-$(id -un)}}-client.p12 as a client certificate."
