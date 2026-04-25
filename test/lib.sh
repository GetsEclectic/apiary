#!/bin/bash
# Shared helpers for the wterm-on-ttyd e2e harness.
#
# Conventions:
#   * SESSION is a single shared agent-browser session across scenarios.
#   * /usr/bin/google-chrome is required: agent-browser's Chrome-for-Testing
#     does not honor /etc/opt/chrome/policies/managed/ so the cert auto-select
#     policy is silently ignored and the mTLS handshake hangs.
#   * Every helper that returns data uses --json and parses with jq.

SESSION="${SESSION:-wterm-e2e}"
URL="${URL:-https://localhost:3543/}"
CHROME="${CHROME:-/usr/bin/google-chrome}"

ab() {
  agent-browser --session "$SESSION" --executable-path "$CHROME" "$@"
}

# Run a JS eval; print the result value as compact JSON. Exits nonzero if the
# eval threw or the page is unreachable.
ab_eval() {
  local out
  out="$(ab eval --json "$1" 2>&1)"
  if ! echo "$out" | jq -e '.success' >/dev/null 2>&1; then
    echo "[ab_eval ERROR] $out" >&2
    return 1
  fi
  echo "$out" | jq -c '.data.result'
}

assert_true() {
  local name="$1" actual="$2"
  if [[ "$actual" == "true" ]]; then
    echo "  PASS  $name"
  else
    echo "  FAIL  $name (got: $actual)"
    return 1
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $name"
  else
    echo "  FAIL  $name"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    return 1
  fi
}

assert_gt() {
  local name="$1" min="$2" actual="$3"
  if [[ -n "$actual" && "$actual" =~ ^[0-9]+$ && "$actual" -gt "$min" ]]; then
    echo "  PASS  $name ($actual > $min)"
  else
    echo "  FAIL  $name (got: '$actual', wanted > $min)"
    return 1
  fi
}
