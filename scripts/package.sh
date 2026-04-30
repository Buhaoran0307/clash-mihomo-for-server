#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PKG_NAME="clash-nogui-bundle-$(date +%Y%m%d_%H%M%S).tar.gz"
MANIFEST_NAME="${PKG_NAME%.tar.gz}.manifest.txt"

mkdir -p "$DIST_DIR"
tar -czf "$DIST_DIR/$PKG_NAME" \
  -C "$ROOT_DIR" \
  systemd \
  tools/verge-sync/Cargo.toml \
  tools/verge-sync/src/main.rs \
  tools/verge-sync/bin/verge-sync \
  scripts/bootstrap.sh \
  scripts/install.sh \
  scripts/lib-clash-assets.sh \
  scripts/merge-clash-overlay.py \
  scripts/verify.sh \
  scripts/update-subscription.sh \
  config.yaml \
  update_clash_config.sh

{
  echo "package: $PKG_NAME"
  echo "created_at: $(date -Iseconds)"
  echo "contents:"
  tar -tzf "$DIST_DIR/$PKG_NAME"
} > "$DIST_DIR/$MANIFEST_NAME"

echo "$DIST_DIR/$PKG_NAME"

