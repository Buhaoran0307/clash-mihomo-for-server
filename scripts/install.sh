#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-clash-assets.sh
source "$ROOT_DIR/scripts/lib-clash-assets.sh"

TARGET_DIR="/opt/clash"
SCRIPT_DIR="/opt/clash/scripts"
UI_DIR="/opt/clash/ui"
SYSTEMD_DIR="/etc/systemd/system"
SYNC_SRC_BIN="$ROOT_DIR/tools/verge-sync/bin/verge-sync"
if [[ ! -x "$SYNC_SRC_BIN" ]]; then
  SYNC_SRC_BIN="$ROOT_DIR/tools/verge-sync/target/release/verge-sync"
fi

if [[ ! -x "$SYNC_SRC_BIN" ]]; then
  echo "error: missing verge-sync binary"
  echo "  尝试过: $ROOT_DIR/tools/verge-sync/bin/verge-sync"
  echo "  尝试过: $ROOT_DIR/tools/verge-sync/target/release/verge-sync"
  echo "请先编译: cd tools/verge-sync && cargo build --release && mkdir -p bin && cp target/release/verge-sync bin/"
  echo "或在全新机器上直接运行: sudo bash scripts/bootstrap.sh"
  exit 1
fi

if gz=$(clash_find_mihomo_gzip "$ROOT_DIR"); then
  echo "[install] 从 source 更新内核: $gz"
  clash_install_mihomo_from_gzip "$gz" "$TARGET_DIR/clash"
fi

if [[ ! -x "$TARGET_DIR/clash" ]]; then
  echo "error: 未找到 $TARGET_DIR/clash（Mihomo 可执行文件）。"
  echo "全新安装请运行: sudo bash scripts/bootstrap.sh"
  echo "或将 mihomo 的 .gz 放入 source/ 后重试本脚本"
  exit 1
fi

echo "[1/8] preparing directories"
sudo mkdir -p "$TARGET_DIR" "$SCRIPT_DIR" "$UI_DIR"

echo "[2/8] backup existing deployment files"
if [[ -d "$TARGET_DIR" ]]; then
  ts="$(date +%Y%m%d_%H%M%S)"
  [[ -f "$TARGET_DIR/clash" ]] && sudo cp -a "$TARGET_DIR/clash" "$TARGET_DIR/clash.bak.${ts}" || true
  [[ -f "$TARGET_DIR/config.yaml" ]] && sudo cp -a "$TARGET_DIR/config.yaml" "$TARGET_DIR/config.yaml.bak.${ts}" || true
  [[ -d "$TARGET_DIR/nogui" ]] && sudo cp -a "$TARGET_DIR/nogui" "$TARGET_DIR/nogui.bak.${ts}" || true
fi

echo "[3/8] remove legacy nogui python api components"
sudo systemctl stop clash-nogui-api 2>/dev/null || true
sudo systemctl disable clash-nogui-api 2>/dev/null || true
sudo rm -f "$SYSTEMD_DIR/clash-nogui-api.service"
sudo rm -rf "$TARGET_DIR/nogui"
sudo rm -f "$TARGET_DIR/run_api.py"

echo "[4/8] deploy MetaCubeXD UI, merge helper, subscription scripts"
sudo install -m 644 "$ROOT_DIR/scripts/merge-clash-overlay.py" "$SCRIPT_DIR/merge-clash-overlay.py"
if clash_deploy_metacubex_ui "$ROOT_DIR" "$UI_DIR"; then
  echo "      MetaCubeXD: gh-pages -> $UI_DIR (external-ui: /opt/clash/ui)"
else
  echo "      warn: MetaCubeXD 未部署（需 git clone gh-pages 或 source/metacubexd 含 index.html），见 README"
  sudo mkdir -p "$UI_DIR"
fi
sudo install -m 755 "$ROOT_DIR/scripts/update-subscription.sh" "$SCRIPT_DIR/update-subscription.sh"
sudo install -m 755 "$SYNC_SRC_BIN" "$SCRIPT_DIR/verge-sync"
if [[ -f "$ROOT_DIR/source/order_url" ]]; then
  sudo install -m 644 "$ROOT_DIR/source/order_url" "$TARGET_DIR/subscription.url"
fi
if clash_deploy_country_mmdb "$ROOT_DIR" "$TARGET_DIR"; then
  echo "      deployed source/Country.mmdb + .country-mmdb.bak"
else
  echo "      warn: missing source/Country.mmdb"
fi
if [[ -f "$ROOT_DIR/config.yaml" ]]; then
  sudo install -m 644 "$ROOT_DIR/config.yaml" "$TARGET_DIR/repo-config-overlay.yaml"
  echo "      deployed repo root config.yaml -> $TARGET_DIR/repo-config-overlay.yaml"
fi
if [[ -f "$TARGET_DIR/config.yaml" && -f "$TARGET_DIR/repo-config-overlay.yaml" ]]; then
  sudo python3 "$ROOT_DIR/scripts/merge-clash-overlay.py" "$TARGET_DIR/repo-config-overlay.yaml" "$TARGET_DIR/config.yaml"
  echo "      merged repo-config-overlay into config.yaml"
fi

echo "[5/8] install systemd units"
sudo install -m 644 "$ROOT_DIR/systemd/clash-core.service" "$SYSTEMD_DIR/clash-core.service"

echo "      remove legacy clash.service (if exists)"
sudo systemctl stop clash 2>/dev/null || true
sudo systemctl disable clash 2>/dev/null || true
sudo rm -f "$SYSTEMD_DIR/clash.service"
sudo rm -rf "$SYSTEMD_DIR/clash.service.d"

echo "[6/8] reload and enable services"
sudo systemctl daemon-reload
sudo systemctl enable clash-core
sudo systemctl restart clash-core

echo "[7/8] health checks"
sudo systemctl --no-pager --full status clash-core | sed -n '1,20p'

echo "[8/8] usage hints"
controller_addr="$(awk -F':' '/^[[:space:]]*external-controller[[:space:]]*:/ {print $2 ":" $3; exit}' /opt/clash/config.yaml | sed -E "s/[[:space:]'\"]//g;s/:$//")"
if [[ -n "${controller_addr:-}" && "${controller_addr}" == *:* ]]; then
  echo "open web ui: http://${controller_addr}/ui/"
else
  echo "open web ui: (unable to detect external-controller host:port from /opt/clash/config.yaml)"
fi
echo "subscription update: sudo /opt/clash/scripts/update-subscription.sh"
echo "（订阅 URL 来自 /opt/clash/subscription.url，或由环境变量 SUB_URL 指定）"
