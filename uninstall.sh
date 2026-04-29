#!/usr/bin/env bash
# Uninstall Apiary services. Leaves the state dir (~/.config/apiary/ by default)
# alone unless --purge is passed — cert reuse across reinstalls is a feature.
set -euo pipefail

OS="$(uname -s)"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: $0 [--purge]"; echo "  --purge: also delete $APIARY_STATE_DIR (or ~/.config/apiary)"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

STATE_DIR="${APIARY_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/apiary}"

if [[ "$OS" == Darwin ]]; then
  AGENT_DIR="${HOME}/Library/LaunchAgents"
  GUI_DOMAIN="gui/$(id -u)"
  echo ">> stopping and removing LaunchAgents from $AGENT_DIR"
  for svc in com.apiary.ttyd com.apiary.tmux-api com.apiary.tmux; do
    launchctl bootout "$GUI_DOMAIN/$svc" 2>/dev/null || true
    rm -f "$AGENT_DIR/${svc}.plist"
  done

  # Earlier versions installed as LaunchDaemons; clean those up too if present.
  legacy=()
  for svc in com.apiary.ttyd com.apiary.tmux-api com.apiary.tmux; do
    [[ -f "/Library/LaunchDaemons/${svc}.plist" ]] && legacy+=("$svc")
  done
  if (( ${#legacy[@]} )); then
    echo ">> also removing ${#legacy[@]} legacy LaunchDaemons (requires sudo)"
    for svc in "${legacy[@]}"; do
      sudo launchctl bootout "system/$svc" 2>/dev/null || true
      sudo rm -f "/Library/LaunchDaemons/${svc}.plist"
    done
  fi
else
  UNIT_DIR="${HOME}/.config/systemd/user"
  if command -v systemctl >/dev/null && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    echo ">> stopping and disabling systemd user units"
    systemctl --user disable --now apiary-ttyd.service apiary-tmux-api.service apiary-tmux.service 2>/dev/null || true
  fi
  rm -f "$UNIT_DIR"/apiary-ttyd.service \
        "$UNIT_DIR"/apiary-tmux-api.service \
        "$UNIT_DIR"/apiary-tmux.service
  if command -v systemctl >/dev/null && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    systemctl --user daemon-reload
  fi
fi

if (( PURGE )); then
  echo ">> removing state dir $STATE_DIR"
  rm -rf "$STATE_DIR"
else
  echo ">> state dir $STATE_DIR left in place (pass --purge to delete)"
fi

echo
echo "done."
