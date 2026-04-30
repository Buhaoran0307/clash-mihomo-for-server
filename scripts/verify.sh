#!/usr/bin/env bash
set -euo pipefail

echo "== systemd status =="
systemctl is-active clash-core

controller_addr="$(awk -F':' '/^[[:space:]]*external-controller[[:space:]]*:/ {print $2 ":" $3; exit}' /opt/clash/config.yaml | sed -E "s/[[:space:]'\"]//g;s/:$//")"
secret="$(awk -F':' '/^[[:space:]]*secret[[:space:]]*:/ {$1=""; sub(/^:/,""); print; exit}' /opt/clash/config.yaml | sed -E "s/^[[:space:]]+//;s/[[:space:]]+$//;s/^['\"]//;s/['\"]$//")"
if [[ -z "${controller_addr:-}" || "${controller_addr}" != *:* ]]; then
  echo "failed: unable to parse external-controller from /opt/clash/config.yaml"
  exit 1
fi

auth_header=()
if [[ -n "${secret:-}" ]]; then
  auth_header=(-H "Authorization: Bearer ${secret}")
fi

echo "== controller version =="
curl -fsSL "${auth_header[@]}" "http://${controller_addr}/version"
echo

echo "== controller proxies =="
curl -fsSL "${auth_header[@]}" "http://${controller_addr}/proxies" >/dev/null
echo "ok: /proxies reachable"
echo

echo "== subscription updater check =="
test -x /opt/clash/scripts/verge-sync
test -x /opt/clash/scripts/update-subscription.sh
test -f /opt/clash/scripts/merge-clash-overlay.py
/opt/clash/scripts/verge-sync --help >/dev/null
echo "ok: updater binary/script/merge helper ready"

