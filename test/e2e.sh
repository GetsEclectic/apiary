#!/bin/bash
# E2E driver for the wterm-on-ttyd setup. Spins up the parallel test stack on
# :3543/:3544, runs each scenario in /test/scenarios/ in order, tears down.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."

SESSION="wterm-e2e"
URL="https://localhost:3543/"
: "${APIARY_STATE_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/apiary}"
CA="$APIARY_STATE_DIR/ca.crt"
CRT="$APIARY_STATE_DIR/client.crt"
KEY="$APIARY_STATE_DIR/client.key"
export APIARY_STATE_DIR CA CRT KEY

cleanup() {
  echo
  echo "[driver] tearing down test stack"
  agent-browser close --all >/dev/null 2>&1 || true
  systemctl --user stop ttyd-e2e tmux-api-e2e tmux-e2e 2>/dev/null || true
}
trap cleanup EXIT

echo "[driver] starting e2e stack (ttyd:3543, tmux-api:3544, tmux session 'e2e-test')"
systemctl --user reset-failed ttyd-e2e tmux-api-e2e tmux-e2e 2>/dev/null || true
systemctl --user start tmux-e2e tmux-api-e2e ttyd-e2e

# Wait for both services
echo "[driver] waiting for ttyd-e2e on :3543"
for i in {1..20}; do
  if curl -sS --max-time 1 --cacert "$CA" --cert "$CRT" --key "$KEY" "https://localhost:3543/" -o /dev/null; then break; fi
  sleep 0.5
done
echo "[driver] waiting for tmux-api-e2e on :3544"
for i in {1..20}; do
  if curl -sS --max-time 1 --cacert "$CA" --cert "$CRT" --key "$KEY" "https://localhost:3544/windows" -o /dev/null; then break; fi
  sleep 0.5
done

# Reset e2e-test tmux to a clean single-window state to keep tests deterministic
echo "[driver] resetting e2e-test tmux session to clean state"
systemctl --user restart tmux-e2e
sleep 0.5

agent-browser close --all >/dev/null 2>&1 || true

scenarios=("$HERE/scenarios"/*.sh)
declare -A results
total=0
failed=0

for s in "${scenarios[@]}"; do
  name="$(basename "$s" .sh)"
  total=$((total + 1))
  echo
  echo "============================================================"
  echo "[driver] running $name"
  echo "============================================================"
  if bash "$s"; then
    results[$name]="PASS"
  else
    results[$name]="FAIL ($?)"
    failed=$((failed + 1))
  fi
done

echo
echo "============================================================"
echo "[driver] summary"
echo "============================================================"
for s in "${scenarios[@]}"; do
  name="$(basename "$s" .sh)"
  printf "  %-12s  %s\n" "$name" "${results[$name]}"
done
echo "[driver] $((total - failed))/$total passed"

exit $failed
