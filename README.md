# Cloudflare-Best-IP-DnsUpdate

[![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

Cloudflare IP 优选 + DNS 记录自动更新工具。采用 **Go** 编写，提供 **CLI 终端**与 **桌面 GUI（Tauri v2 + SvelteKit）** 两种使用方式。

> **终端能做的 GUI 都能做，反之亦然。** 两者共用同一套业务逻辑，只是入口不同。

---

## 快速开始

```bash
go build -o cfopt .      # 编译
./cfopt sync              # 一键：测速→取最优 IP→DNS 同步
```

---

## 核心特性

- **智能 IP 优选**：集成 cfst 测速核心，支持分运营商（移动/联通/电信）专项优化
- **DNS 自动更新**：支持 Cloudflare 和 DNSPod 双平台，自动同步优选 IP 到 DNS 记录
- **多运营商分流**：DNSPod 支持单线路/多线路（运营商）模式，各线路独立测速与 TTL
- **全链路自动化**：系统服务 daemon（systemd/launchd/Windows Service）+ Crontab 兼容层
- **桌面 GUI**：基于 Tauri v2 + SvelteKit，开箱即用
- **跨平台**：Linux / Windows / macOS，6 平台二进制 (amd64 + arm64)
- **安全完整性校验**：SHA256 校验 + 密钥脱敏日志 + 并发安全自更新守卫

---

## CLI 子命令

| 命令 | 说明 |
|---|---|
| `cfopt sync` | 一键全同步（测速→提取→DNS 同步→写历史） |
| `cfopt speedtest` | 单次测速 |
| `cfopt dns cf` | Cloudflare DNS 同步 |
| `cfopt dns dnspod` | DNSPod DNS 同步 |
| `cfopt dns dnspod switch` | 切换 DNSPod 模式/策略 |
| `cfopt config init/validate/wizard/cfip/migrate` | 配置管理 |
| `cfopt schedule` | 调度/daemon 管理（含一次性同步与计划任务） |
| `cfopt install` | 安装（便携/系统级） |
| `cfopt uninstall` | 卸载 |
| `cfopt update` | 自更新 |
| `cfopt cfst fetch` | cfst 二进制管理 |
| `cfopt health` | 系统健康检测 |
| `cfopt logs` | 日志/历史查看 |
| `cfopt version` | 版本信息 |
| `cfopt quickdeploy` | 快速部署向导 |

> 完整命令列表、全局参数、退出码与 GUI 集成说明见 **[`docs/commands.md`](docs/commands.md)**。

---

## 文档

| 文档 | 说明 |
|---|---|
| [`docs/commands.md`](docs/commands.md) | CLI 命令参考（含 GUI 集成说明） |

---

## 系统要求

| 形态 | 需要 |
|---|---|
| 终端（CLI） | Go 1.24+（编译）或使用预编译二进制 |
| GUI | 预编译桌面客户端（或 Go 1.24+ + Rust/cargo + Node.js 自行构建） |

---

## 许可证

GPL-3.0 License

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 核心测速程序
