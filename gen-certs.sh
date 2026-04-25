#!/usr/bin/env bash
# Generate local CA + server cert + client cert + p12 bundle for Apiary.
# Writes everything under $STATE_DIR (default ~/.config/apiary).
set -euo pipefail

: "${STATE_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/apiary}"
: "${CERT_HOST:=$(hostname)}"
: "${LAN_IP:=$(hostname -I 2>/dev/null | awk '{print $1}')}"
: "${CLIENT_CN:=${USER:-$(id -un)}}"

# X.509 CN max is 64 bytes. GHA macOS runners (and some corporate Macs) have
# hostnames longer than that. Keep the full hostname in SAN DNS entries and
# truncate only the CN.
CERT_CN="${CERT_HOST:0:63}"
: "${P12_NAME:=${CLIENT_CN}-client.p12}"
: "${P12_PASS:=apiary}"  # Android credential installer rejects empty p12 passwords.

mkdir -p "$STATE_DIR"
cd "$STATE_DIR"

force() { [[ "${FORCE:-0}" == "1" ]]; }

if [[ -z "${LAN_IP}" ]]; then
  # macOS / BSDs don't have `hostname -I`; fall back to ipconfig if available.
  if command -v ipconfig >/dev/null; then
    # Prefer the interface carrying the default route (en0 is wrong for
    # Ethernet-primary Macs, USB-C dock setups, or Wi-Fi-down laptops).
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    LAN_IP="$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null || true)"
    [[ -z "$LAN_IP" ]] && LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
fi

if [[ -z "${LAN_IP}" ]]; then
  echo "Could not auto-detect LAN IP; set LAN_IP=... and retry" >&2
  exit 1
fi

if [[ ! -f ca.key || ! -f ca.crt ]] || force; then
  echo ">> generating CA"
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -key ca.key -sha256 -days 3650 \
    -subj "/CN=apiary local CA" -out ca.crt
fi

cat > server.ext <<EOF
[req]
distinguished_name=req
[v3_req]
subjectAltName=@alt
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt]
DNS.1=${CERT_HOST}
DNS.2=${CERT_HOST}.local
DNS.3=localhost
IP.1=${LAN_IP}
IP.2=127.0.0.1
EOF

if [[ ! -f server.key || ! -f server.crt ]] || force; then
  echo ">> generating server cert (CN=${CERT_CN}, IP=${LAN_IP})"
  openssl genrsa -out server.key 2048
  openssl req -new -key server.key -subj "/CN=${CERT_CN}" -out server.csr
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -sha256 -extfile server.ext -extensions v3_req \
    -out server.crt
fi

cat > client.ext <<EOF
extendedKeyUsage=clientAuth
EOF

if [[ ! -f client.key || ! -f client.crt ]] || force; then
  echo ">> generating client cert (CN=${CLIENT_CN})"
  openssl genrsa -out client.key 2048
  openssl req -new -key client.key -subj "/CN=${CLIENT_CN}" -out client.csr
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -sha256 -extfile client.ext \
    -out client.crt
fi

if [[ ! -f "${P12_NAME}" ]] || force; then
  echo ">> bundling ${P12_NAME}"
  openssl pkcs12 -export \
    -inkey client.key -in client.crt -certfile ca.crt \
    -name "${CLIENT_CN}@apiary" \
    -out "${P12_NAME}" -passout "pass:${P12_PASS}"
fi

chmod 600 ca.key server.key client.key "${P12_NAME}"

echo
echo "Done. Files in $STATE_DIR:"
echo "  ca.crt               — trust this as a root CA on each device"
echo "  ${P12_NAME}  — import as a client certificate"
