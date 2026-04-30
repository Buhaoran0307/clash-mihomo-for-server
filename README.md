# clash-nogui

轻量化 Mihomo 部署项目，目标是：在一台全新 Linux 机器上，快速安装内核、配置订阅更新，并通过 MetaCubeXD 管理页面使用。

## 功能

- 一键部署到 `/opt/clash`
- 自动安装/更新 Mihomo 内核（优先 `source/*mihomo*.gz`）
- 使用 `systemd` 托管服务（`clash-core.service`）
- 使用 MetaCubeXD 作为前端（`external-ui: /opt/clash/ui`）
- 订阅更新脚本：`/opt/clash/scripts/update-subscription.sh`
- 更新后自动做配置覆盖、节点清理、自动选可用节点

## 准备文件

放在仓库内：

- `config.yaml`：你的基础运行配置（含 `external-controller`、`secret`、`external-ui` 等）
- `source/order_url`：订阅链接（单行）
- `source/Country.mmdb`：离线 GeoIP 文件（必需）
- 可选：`source/mihomo-*.gz` 内核包（有则优先用本地包）
- 可选：`source/metacubexd`（gh-pages 静态文件，根目录应有 `index.html`）

## 安装

```bash
sudo bash scripts/bootstrap.sh
```

安装完成后：

- 核心目录：`/opt/clash`
- 服务名：`clash-core`
- UI 地址：`http://<external-controller>/ui/`

## 日常使用

- 更新订阅：

```bash
sudo /opt/clash/scripts/update-subscription.sh
```

- 检查运行状态：

```bash
sudo systemctl status clash-core
```

- 查看日志：

```bash
sudo journalctl -u clash-core -f
```

## 常见命令

- 重启服务：`sudo systemctl restart clash-core`
- 更新 MetaCubeXD：
  `sudo git -C /opt/clash/ui pull -r`
