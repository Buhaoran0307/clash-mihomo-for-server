#!/usr/bin/env bash
# 由 bootstrap.sh / install.sh source；需预先设置 ROOT_DIR（仓库根目录）。
# shellcheck shell=bash

_clash_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

clash_find_mihomo_gzip() {
  local root="${1:?ROOT_DIR}" best="" f mt best_mt=-1 uname_m
  [[ -d "$root/source" ]] || return 1
  uname_m="$(uname -m)"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.tar.gz | *.tgz) continue ;;
    esac
    case "$uname_m" in
      x86_64)
        if echo "$f" | grep -qiE 'arm64|aarch64'; then continue; fi
        ;;
      aarch64 | arm64)
        if echo "$f" | grep -qiE '(^|[^a-z])amd64([^a-z]|$)|linux-amd64'; then continue; fi
        ;;
    esac
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if (( mt > best_mt )); then best_mt=$mt best=$f; fi
  done < <(find "$root/source" -maxdepth 1 -type f \( -iname '*mihomo*.gz' \) 2>/dev/null)
  [[ -n "$best" ]] && printf '%s' "$best" && return 0
  return 1
}

clash_install_mihomo_from_gzip() {
  local gz="$1" dest="$2" tmp
  tmp="$(mktemp)"
  gunzip -c "$gz" >"$tmp"
  chmod 755 "$tmp"
  _clash_as_root install -m 755 "$tmp" "$dest"
  rm -f "$tmp"
}

# 官方预构建前端为 gh-pages 分支，见 https://github.com/MetaCubeX/metacubexd
# 部署到 Mihomo external-ui 目录（本仓库为 /opt/clash/ui）。
# 优先使用本地已存在的 gh-pages 镜像（目录根须有 index.html）；否则 git clone --depth 1 -b gh-pages。
# 环境变量 METACUBEXD_GIT_URL 可覆盖仓库地址（默认 https://github.com/MetaCubeX/metacubexd.git）。
clash_find_metacubex_source_dir() {
  local root="${1:?ROOT_DIR}" d
  if [[ -d "$root/source/metacubexd" ]]; then
    printf '%s' "$root/source/metacubexd"
    return 0
  fi
  d="$(find "$root/source" -maxdepth 2 -mindepth 1 -type d -iname '*metacubex*' 2>/dev/null | head -n1)"
  if [[ -n "$d" && -d "$d" ]]; then
    printf '%s' "$d"
    return 0
  fi
  return 1
}

clash_deploy_country_mmdb() {
  local root="${1:?ROOT_DIR}" target_dir="$2"
  [[ -f "$root/source/Country.mmdb" ]] || return 1
  _clash_as_root install -m644 "$root/source/Country.mmdb" "$target_dir/Country.mmdb"
  _clash_as_root install -m644 "$root/source/Country.mmdb" "$target_dir/.country-mmdb.bak"
  return 0
}

clash_deploy_metacubex_ui() {
  local root="${1:?ROOT_DIR}" ui_dir="${2:?UI_DIR}" src url
  url="${METACUBEXD_GIT_URL:-https://github.com/MetaCubeX/metacubexd.git}"
  if src="$(clash_find_metacubex_source_dir "$root")" && [[ -f "$src/index.html" ]]; then
    _clash_as_root find "$ui_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    _clash_as_root cp -a "$src"/. "$ui_dir"/
    return 0
  fi
  if [[ -n "${src:-}" && -d "$src" && ! -f "$src/index.html" ]]; then
    echo "[WARN] $src 不是 gh-pages 静态目录（缺少 index.html），改为官方 clone 到 $ui_dir" >&2
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "[WARN] 未安装 git，无法执行: git clone -b gh-pages $url $ui_dir" >&2
    return 1
  fi
  _clash_as_root rm -rf "${ui_dir:?}"
  _clash_as_root mkdir -p "$(dirname "$ui_dir")"
  _clash_as_root git clone --depth 1 -b gh-pages "$url" "$ui_dir"
  return 0
}
