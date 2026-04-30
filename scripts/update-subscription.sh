#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${TARGET:-/opt/clash/config.yaml}"
USER_AGENT="${SUB_UA:-clash-verge/v2.4.7}"
SUB_URL_FILE="${SUB_URL_FILE:-/opt/clash/subscription.url}"

resolve_sub_url() {
  if [[ -n "${SUB_URL:-}" ]]; then
    printf '%s' "$SUB_URL"
    return 0
  fi
  if [[ -f "$SUB_URL_FILE" ]]; then
    local line
    line="$(head -n1 "$SUB_URL_FILE" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -n "$line" ]]; then
      printf '%s' "$line"
      return 0
    fi
  fi
  if [[ -f "$ROOT_DIR/source/order_url" ]]; then
    line="$(head -n1 "$ROOT_DIR/source/order_url" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -n "$line" ]]; then
      printf '%s' "$line"
      return 0
    fi
  fi
  return 1
}

if ! URL="$(resolve_sub_url)"; then
  echo "error: 未找到订阅链接。请任选其一："
  echo "  - 环境变量 SUB_URL=https://..."
  echo "  - 已部署机器：在 /opt/clash/subscription.url 写入一行订阅 URL（安装时会从 source/order_url 复制）"
  echo "  - 开发仓库：在 source/order_url 写入一行订阅 URL"
  exit 1
fi

if [[ -x "/opt/clash/scripts/verge-sync" ]]; then
  SYNC_BIN="/opt/clash/scripts/verge-sync"
elif [[ -x "$ROOT_DIR/tools/verge-sync/bin/verge-sync" ]]; then
  SYNC_BIN="$ROOT_DIR/tools/verge-sync/bin/verge-sync"
elif [[ -x "$ROOT_DIR/tools/verge-sync/target/release/verge-sync" ]]; then
  SYNC_BIN="$ROOT_DIR/tools/verge-sync/target/release/verge-sync"
else
  echo "error: 未找到 verge-sync。"
  echo "  期望路径: /opt/clash/scripts/verge-sync"
  echo "  或先在仓库执行: cd tools/verge-sync && cargo build --release"
  exit 1
fi

TARGET_PARENT="$(dirname "$TARGET")"
if [[ ! -d "$TARGET_PARENT" ]]; then
  if ! mkdir -p "$TARGET_PARENT" 2>/dev/null; then
    echo "error: 目录不存在且无法创建: $TARGET_PARENT（请用 root/sudo 运行，或先安装 clash 到 /opt/clash）"
    exit 1
  fi
fi

echo "Using verge-sync: $SYNC_BIN"
"$SYNC_BIN" --url "$URL" --target "$TARGET" --user-agent "$USER_AGENT"

apply_local_overlay() {
  local td py ran=0
  td="$(dirname "$TARGET")"
  py="$SCRIPT_DIR/merge-clash-overlay.py"
  [[ -f "$py" ]] || py="$ROOT_DIR/scripts/merge-clash-overlay.py"
  if [[ ! -f "$py" ]]; then
    echo "[WARN] 未找到 merge-clash-overlay.py，跳过仓库 UI 参数合并"
    return 0
  fi
  if [[ -f "$td/repo-config-overlay.yaml" ]]; then
    python3 "$py" "$td/repo-config-overlay.yaml" "$TARGET"
    ran=1
  elif [[ -f "$ROOT_DIR/config.yaml" ]]; then
    python3 "$py" "$ROOT_DIR/config.yaml" "$TARGET"
    ran=1
  fi
  if (( ran )); then
    echo "[INFO] 已用仓库根 config.yaml（或 $td/repo-config-overlay.yaml）覆盖同名顶层字段 -> $TARGET"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart clash-core 2>/dev/null || sudo systemctl restart clash-core 2>/dev/null || true
      sleep 1
    fi
  fi
}

refresh_country_mmdb_bundle() {
  local td
  td="$(dirname "$TARGET")"
  if [[ -f "$td/.country-mmdb.bak" ]]; then
    install -m644 "$td/.country-mmdb.bak" "$td/Country.mmdb" 2>/dev/null || sudo install -m644 "$td/.country-mmdb.bak" "$td/Country.mmdb" 2>/dev/null || true
    echo "[INFO] 已从 .country-mmdb.bak 刷新 Country.mmdb"
  fi
}

cleanup_old_config_backups() {
  local td cfg_name f
  td="$(dirname "$TARGET")"
  cfg_name="$(basename "$TARGET")"
  shopt -s nullglob
  for f in "$TARGET".bak.* "$td/$cfg_name".bak.*; do
    rm -f "$f" 2>/dev/null || sudo rm -f "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

auto_switch_healthy_groups() {
  local cfg="${TARGET}"
  local controller
  local secret
  controller="$(awk -F':' '/^[[:space:]]*external-controller[[:space:]]*:/ {print $2 ":" $3; exit}' "$cfg" | sed -E "s/[[:space:]'\"]//g;s/:$//")"
  secret="$(awk -F':' '/^[[:space:]]*secret[[:space:]]*:/ {$1=""; sub(/^:/,""); print; exit}' "$cfg" | sed -E "s/^[[:space:]]+//;s/[[:space:]]+$//;s/^['\"]//;s/['\"]$//")"
  if [[ -z "${controller:-}" || "${controller}" != *:* ]]; then
    echo "[WARN] skip auto-switch: external-controller not found in ${cfg}"
    return 0
  fi
  python3 - <<'PY' "$controller" "$secret"
import json, sys, urllib.parse, urllib.request
import time
controller = sys.argv[1]
secret = sys.argv[2]
base = f"http://{controller}"
noise = ("剩余流量", "套餐到期", "重置剩余", "距离下次重置")
headers = {"Content-Type": "application/json"}
if secret:
    headers["Authorization"] = f"Bearer {secret}"

def req(path, method="GET", payload=None, timeout=12):
    data = None if payload is None else json.dumps(payload).encode()
    r = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw or "{}")

def is_noise(name):
    return isinstance(name, str) and any(k in name for k in noise)

def is_leaf_proxy(meta):
    """只对真实出站测 delay；跳过 Selector / URLTest 等（否则测 Auto 会跟着坏节点跑）。"""
    if not isinstance(meta, dict):
        return False
    t = (meta.get("type") or "").lower()
    return t not in (
        "selector",
        "urltest",
        "fallback",
        "relay",
        "loadbalance",
        "compatibility",
    )

def delay_ok(node):
    urls = [
        "http://www.gstatic.com/generate_204",
        "https://www.gstatic.com/generate_204",
        "http://cp.cloudflare.com/generate_204",
    ]
    enc_node = urllib.parse.quote(node, safe="")
    for u in urls:
        try:
            out = req(
                f"/proxies/{enc_node}/delay?timeout=10000&url={urllib.parse.quote(u, safe='')}",
                timeout=14,
            )
            d = out.get("delay")
            if isinstance(d, (int, float)) and d >= 0 and d < 15000:
                return True
        except Exception:
            continue
    return False

try:
    proxies = None
    for _ in range(20):
        try:
            proxies = req("/proxies").get("proxies", {})
            break
        except Exception:
            time.sleep(0.5)
    if proxies is None:
        raise RuntimeError("controller not ready after restart")
except Exception as e:
    print(f"[WARN] skip auto-switch: cannot read /proxies ({e})")
    raise SystemExit(0)

proxies_group = proxies.get("Proxies", {})
raw_members = [x for x in (proxies_group.get("all") or []) if isinstance(x, str) and not is_noise(x)]
members = [n for n in raw_members if is_leaf_proxy(proxies.get(n, {}))]
preferred = sorted(
    members,
    key=lambda n: (
        0 if "实验" in n else 1,
        0 if "香港" in n and "中继" in n else 1,
        0 if "IEPL" in n else 1,
        n,
    ),
)
target = None
for n in preferred[:60]:
    if delay_ok(n):
        target = n
        break

if not target and preferred:
    target = preferred[0]
    print(f"[WARN] no healthy node found by delay test; fallback first preferred leaf -> {target}")
elif not target:
    print("[WARN] no healthy node found by delay test; keep current selection")
    raise SystemExit(0)

for group in ("Proxies", "Google", "Auto"):
    try:
        req(f"/proxies/{urllib.parse.quote(group, safe='')}", method="PUT", payload={"name": target}, timeout=8)
        print(f"[INFO] switched {group} -> {target}")
    except Exception as e:
        print(f"[WARN] failed switching {group}: {e}")
PY
}

sanitize_noise_nodes() {
  local cfg="${TARGET}"
  python3 - <<'PY' "$cfg"
import sys, yaml
path=sys.argv[1]
noise=("剩余流量","套餐到期","重置剩余","距离下次重置")
with open(path,"r",encoding="utf-8") as f:
    data=yaml.safe_load(f)
if not isinstance(data,dict):
    raise SystemExit(0)
removed=set()
proxies=data.get("proxies")
if isinstance(proxies,list):
    kept=[]
    for p in proxies:
        if isinstance(p,dict) and isinstance(p.get("name"),str) and any(k in p["name"] for k in noise):
            removed.add(p["name"])
            continue
        kept.append(p)
    data["proxies"]=kept
groups=data.get("proxy-groups")
if isinstance(groups,list):
    for g in groups:
        arr=g.get("proxies") if isinstance(g,dict) else None
        if isinstance(arr,list):
            g["proxies"]=[x for x in arr if not (isinstance(x,str) and (x in removed or any(k in x for k in noise)))]
with open(path,"w",encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
print(f"[INFO] noise proxies removed: {len(removed)}")
PY
  systemctl restart clash-core >/dev/null 2>&1 || true
}

sanitize_noise_nodes
apply_local_overlay
auto_switch_healthy_groups
refresh_country_mmdb_bundle
cleanup_old_config_backups
echo "Done: subscription updated, local overlay applied, and healthy node auto-switch applied."
