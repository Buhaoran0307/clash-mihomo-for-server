#!/usr/bin/env bash
# 全新机器一键安装：系统依赖、Mihomo 内核（优先 source 内 *mihomo*.gz）、编译 verge-sync、
# 部署仓库根 config.yaml、source/order_url、Country.mmdb、MetaCubeXD（gh-pages -> /opt/clash/ui，与官方一致）、
# 并写入 repo-config-overlay 供订阅更新时合并。
# 用法（在仓库根目录）: sudo bash scripts/bootstrap.sh
# 环境变量:
#   MIHOMO_VERSION=v1.19.24   无本地 .gz 时从 GitHub 下载
#   MIHOMO_DOWNLOAD_URL=...   完全自定义下载地址
#   BOOTSTRAP_SKIP_APT=1      跳过 apt
#   METACUBEXD_GIT_URL=...    MetaCubeXD 仓库 URL（默认官方）；无本地 gh-pages 时 clone 到 /opt/clash/ui
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo bash "$SCRIPT_PATH" "$@"
fi

ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
# shellcheck source=scripts/lib-clash-assets.sh
source "$ROOT_DIR/scripts/lib-clash-assets.sh"

TARGET_DIR="/opt/clash"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.24}"

install_debian_packages() {
  if [[ "${BOOTSTRAP_SKIP_APT:-0}" == "1" ]]; then
    echo "[bootstrap] BOOTSTRAP_SKIP_APT=1，跳过 apt。"
    return 0
  fi
  if [[ ! -f /etc/debian_version ]]; then
    echo "提示: 非 Debian/Ubuntu，跳过 apt；请自行具备 curl、gzip、cargo、python3+PyYAML、systemd。"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update -qq; then
    echo "[WARN] apt-get update 失败（常见于 EOL 发行版如 Trusty 的签名失效、源指向 archive）。"
    echo "       可选: 修复 /etc/apt/sources.list（例如改用 old-releases.ubuntu.com）后重试；"
    echo "       或在本机已手动安装依赖时: sudo BOOTSTRAP_SKIP_APT=1 bash scripts/bootstrap.sh"
    return 1
  fi
  if ! apt-get install -y -qq \
    curl ca-certificates git systemd python3 python3-yaml gzip \
    cargo build-essential pkg-config; then
    echo "[WARN] apt-get install 失败。"
    return 1
  fi
  return 0
}

ensure_runtime_commands() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  if ! command -v gunzip >/dev/null 2>&1 && ! command -v gzip >/dev/null 2>&1; then
    missing+=("gzip")
  fi
  command -v cargo >/dev/null 2>&1 || missing+=("cargo")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    missing+=("PyYAML（python3-yaml 或 pip3 install pyyaml）")
  fi
  if ((${#missing[@]} > 0)); then
    echo "error: 缺少: ${missing[*]}"
    echo "请先修复 apt 软件源，或手动安装上述工具后执行:"
    echo "  sudo BOOTSTRAP_SKIP_APT=1 bash $ROOT_DIR/scripts/bootstrap.sh"
    exit 1
  fi
}

mihomo_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *)
      echo "error: 不支持的 CPU 架构: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

download_mihomo() {
  local arch url tmp
  arch="$(mihomo_arch)"
  if [[ -n "${MIHOMO_DOWNLOAD_URL:-}" ]]; then
    url="$MIHOMO_DOWNLOAD_URL"
  else
    url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${arch}-${MIHOMO_VERSION}.gz"
  fi
  tmp="$(mktemp)"
  echo "[bootstrap] 下载 Mihomo: $url"
  curl -fsSL "$url" -o "${tmp}.gz"
  gunzip -c "${tmp}.gz" >"$tmp"
  chmod 755 "$tmp"
  install -m 755 "$tmp" "$TARGET_DIR/clash"
  rm -f "$tmp" "${tmp}.gz"
}

install_or_download_mihomo() {
  local gz
  if gz=$(clash_find_mihomo_gzip "$ROOT_DIR"); then
    echo "[bootstrap] 使用 source 内内核包（按修改时间取最新）: $gz"
    clash_install_mihomo_from_gzip "$gz" "$TARGET_DIR/clash"
    return 0
  fi
  echo "[bootstrap] source 内未找到 *mihomo*.gz，从网络下载..."
  download_mihomo
}

build_verge_sync() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: 未找到 cargo。Debian/Ubuntu 请先安装依赖段中的 cargo；其它发行版请安装 Rust 后再运行本脚本。"
    exit 1
  fi
  echo "[bootstrap] 编译 verge-sync (cargo)..."
  (cd "$ROOT_DIR/tools/verge-sync" && cargo build --release)
  mkdir -p "$ROOT_DIR/tools/verge-sync/bin"
  install -m755 "$ROOT_DIR/tools/verge-sync/target/release/verge-sync" "$ROOT_DIR/tools/verge-sync/bin/verge-sync"
}

assert_bootstrap_inputs() {
  [[ -f "$ROOT_DIR/config.yaml" ]] || {
    echo "error: 缺少仓库根 $ROOT_DIR/config.yaml（对外发布请放不含敏感信息的模板，含 external-controller / secret / external-ui 等）"
    exit 1
  }
  [[ -f "$ROOT_DIR/source/order_url" ]] || {
    echo "error: 缺少 $ROOT_DIR/source/order_url（一行订阅链接，勿提交到公开仓库时请用本地占位或 .gitignore）"
    exit 1
  }
  [[ -f "$ROOT_DIR/source/Country.mmdb" ]] || {
    echo "error: 缺少 $ROOT_DIR/source/Country.mmdb（离线 GeoIP；公开仓库可 .gitignore，由部署机自备）"
    exit 1
  }
}

merge_repo_overlay_into() {
  local target="$1"
  [[ -f "$ROOT_DIR/scripts/merge-clash-overlay.py" ]] || return 0
  if [[ -f "$ROOT_DIR/config.yaml" ]]; then
    install -m644 "$ROOT_DIR/config.yaml" "$TARGET_DIR/repo-config-overlay.yaml"
  fi
  if [[ -f "$TARGET_DIR/repo-config-overlay.yaml" ]]; then
    python3 "$ROOT_DIR/scripts/merge-clash-overlay.py" "$TARGET_DIR/repo-config-overlay.yaml" "$target"
    echo "[bootstrap] 已合并仓库根 config.yaml（经 repo-config-overlay.yaml）-> $target"
  fi
}

echo "[bootstrap] 安装系统依赖（apt）..."
if ! install_debian_packages; then
  echo "[bootstrap] apt 未成功，检查本机是否已有必备命令..."
fi
ensure_runtime_commands

echo "[bootstrap] 准备目录..."
mkdir -p "$TARGET_DIR" "$TARGET_DIR/scripts" "$TARGET_DIR/ui"

assert_bootstrap_inputs

echo "[bootstrap] 安装内核与本地配置..."
install_or_download_mihomo
install -m644 "$ROOT_DIR/config.yaml" "$TARGET_DIR/config.yaml"
install -m644 "$ROOT_DIR/source/order_url" "$TARGET_DIR/subscription.url"
merge_repo_overlay_into "$TARGET_DIR/config.yaml"

clash_deploy_country_mmdb "$ROOT_DIR" "$TARGET_DIR" || true
echo "[bootstrap] 已部署 Country.mmdb 与备份 .country-mmdb.bak"

if clash_deploy_metacubex_ui "$ROOT_DIR" "$TARGET_DIR/ui"; then
  echo "[bootstrap] MetaCubeXD 已在 $TARGET_DIR/ui（external-ui 请设为 /opt/clash/ui；访问 http://<controller>/ui/）"
else
  echo "[WARN] MetaCubeXD 未能部署到 $TARGET_DIR/ui。请安装 git、保证可访问 GitHub，或手动执行："
  echo "      sudo rm -rf /opt/clash/ui && sudo git clone --depth 1 -b gh-pages https://github.com/MetaCubeX/metacubexd.git /opt/clash/ui"
  echo "      离线可将 gh-pages 克隆到 \"$ROOT_DIR/source/metacubexd\"（根目录须有 index.html）后重新运行本脚本。"
  mkdir -p "$TARGET_DIR/ui"
fi

build_verge_sync

echo "[bootstrap] 调用 scripts/install.sh 完成脚本与 systemd 部署..."
bash "$ROOT_DIR/scripts/install.sh"

echo "[bootstrap] 完成。更新订阅: sudo /opt/clash/scripts/update-subscription.sh"
