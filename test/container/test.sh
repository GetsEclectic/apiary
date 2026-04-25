#!/usr/bin/env bash
# Run Apiary test container, install Apiary inside, verify services + endpoints.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

CONTAINER="${APIARY_TEST_CONTAINER:-apiary-test-run}"
IMAGE="${APIARY_TEST_IMAGE:-apiary-test}"

# Build the image if it isn't already present. Build context is the repo root
# so the Dockerfile's `COPY . /home/apiary/src/apiary` picks up the whole repo.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "=== 0. Build image $IMAGE from $REPO_ROOT ==="
  docker build -f "$HERE/Dockerfile" -t "$IMAGE" "$REPO_ROOT"
fi

# Clean slate if previous run left the container.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "=== 1. Start container (systemd PID 1) ==="
docker run -d \
  --name "$CONTAINER" \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  -p 3643:3443 \
  "$IMAGE" >/dev/null
echo "started."

echo
echo "=== 2. Wait for systemd to come up ==="
for i in $(seq 1 30); do
  if docker exec "$CONTAINER" systemctl is-system-running --wait 2>/dev/null \
       | grep -qE '^(running|degraded)$'; then
    break
  fi
  sleep 1
done
docker exec "$CONTAINER" systemctl is-system-running || true

echo
echo "=== 3. Enable linger + start user@1000.service ==="
docker exec "$CONTAINER" loginctl enable-linger apiary
docker exec "$CONTAINER" systemctl start user@1000.service
# Wait for the user bus socket to exist.
for i in $(seq 1 20); do
  if docker exec "$CONTAINER" test -S /run/user/1000/bus; then
    echo "user bus ready"
    break
  fi
  sleep 1
done
docker exec -u apiary "$CONTAINER" bash -lc \
  'XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-system-running' || true

echo
echo "=== 4. Run install.sh inside the container as apiary user ==="
docker exec -u apiary -w /home/apiary/src/apiary "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/run/user/1000
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
  ./install.sh
' 2>&1 | tail -40

echo
echo "=== 5. Service status ==="
docker exec -u apiary "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/run/user/1000
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
  systemctl --user is-active apiary-tmux.service apiary-tmux-api.service apiary-ttyd.service
  echo
  systemctl --user status apiary-ttyd.service apiary-tmux-api.service --no-pager -l | tail -40
'

echo
echo "=== 6. mTLS curl: ttyd index.html ==="
docker exec -u apiary "$CONTAINER" bash -lc '
  cd ~/.config/apiary
  curl -sS --cacert ca.crt --cert client.crt --key client.key https://localhost:3443/ | head -20
  echo
  echo "HTTP status:"
  curl -sS -o /dev/null -w "%{http_code}\n" --cacert ca.crt --cert client.crt --key client.key https://localhost:3443/
'

echo
echo "=== 7. mTLS curl: tmux-api /windows via :3443 ==="
docker exec -u apiary "$CONTAINER" bash -lc '
  cd ~/.config/apiary
  curl -sS --cacert ca.crt --cert client.crt --key client.key https://localhost:3443/windows | tee /tmp/windows.json | jq .
  jq -e ".windows | length >= 1" /tmp/windows.json
'

echo
echo "=== 8. tmux session check ==="
docker exec -u apiary "$CONTAINER" bash -lc '
  export XDG_RUNTIME_DIR=/run/user/1000
  tmux list-sessions 2>&1 || echo "tmux list-sessions failed"
'

echo
echo "=== done ==="
