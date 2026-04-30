#!/usr/bin/env python3
"""将 overlay YAML 的顶层键合并进目标 Clash 配置（用于 repo 根目录 config.yaml 覆盖 external-controller 等）。"""
import sys
import yaml

def main() -> None:
    if len(sys.argv) != 3:
        print("usage: merge-clash-overlay.py <overlay.yaml> <target.yaml>", file=sys.stderr)
        sys.exit(2)
    overlay_path, target_path = sys.argv[1], sys.argv[2]
    with open(overlay_path, "r", encoding="utf-8") as f:
        overlay = yaml.safe_load(f)
    if not isinstance(overlay, dict) or not overlay:
        return
    with open(target_path, "r", encoding="utf-8") as f:
        target = yaml.safe_load(f)
    if not isinstance(target, dict):
        target = {}
    for k, v in overlay.items():
        target[k] = v
    with open(target_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(target, f, allow_unicode=True, sort_keys=False)


if __name__ == "__main__":
    main()
