# Cloudflare-Best-IP-DnsUpdate

> **警告：本项目正在积极开发中，功能尚未稳定，切勿在生产环境中使用！**

[![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

一款全自动化的 **Cloudflare IP 优选与 DNS 记录管理工具**。它集成了多线程测速、智能 IP 同步以及多平台（Cloudflare / DNSPod）DNS 记录更新功能，旨在为用户提供稳定、高速的 CDN 接入体验。

## 核心特性

*   **一键安装与自动归位**：支持 `curl` 一键下载，脚本会自动迁移至标准目录并配置全局命令，无需复杂配置。
*   **高效多线程测速**：集成高性能测速核心，支持分运营商（移动/联通/电信）专项优化及并发测速，精准锁定最优节点。
*   **全链路自动化闭环**：内置调度中心，支持 Cron 定时任务，实现"测速 -> 同步 -> 更新"无人值守运行。
*   **安全完整性校验**：采用 SHA256 机制校验所有组件，确保远程下载与更新的绝对安全，防止篡改或损坏。
*   **实时状态监控面板**：直观的主菜单界面，实时显示各模块启用状态、数据新鲜度及系统运行情况。
*   **多线路解析支持**：完美适配 Cloudflare 单线路及 DNSPod 多线路分运营商解析场景，满足不同网络环境需求。

---

## 快速开始

### 1. 安装
在终端执行以下命令即可完成一键安装（测试中，请勿使用！!!!!）：
```bash
curl -sL https://blog.drxian.cn/scripts/Cloudflare-Best-IP-DnsUpdate/cfopt.sh -o cfopt.sh && bash cfopt.sh
```

### 2. 启动程序
安装完成后，脚本会自动配置全局命令。在任何位置输入以下命令即可启动：
```bash
cfopt
```

### 3. 功能模块说明
进入主菜单后，你可以根据需求选择以下功能：

| 选项 | 功能名称 | 说明 |
| :--- | :--- | :--- |
| **1** | **CF IP 优选管理** | 配置测速节点（Colo）、运行测速程序及管理测速定时任务。 |
| **2** | **CF DNS 记录更新** | 将本地优选出的最佳 IP 自动同步更新至 Cloudflare DNS 记录。 |
| **3** | **DNSPod DNS 更新** | 支持腾讯云 DNSPod 的分线路（ISP）解析管理与自动更新。 |
| **4** | **自动化调度中心** | 一键触发全链路流程（测速+同步+更新）或设置后台 Cron 自动运行。 |
| **5** | **检查组件更新** | 从远程仓库同步最新版本脚本及补丁，保持系统处于最新状态。 |

---

## 配置指南

所有配置文件均位于 `$HOME/cfopt/conf/` 目录下。首次运行时，脚本会自动生成示例配置文件。

| 文件名 | 说明 |
| :--- | :--- |
| `cfdns.conf` | 配置 Cloudflare API 令牌 (Token)、区域 ID (Zone ID) 及目标域名。 |
| `dnspod.conf` | 配置 DNSPod API ID/Token 及目标域名。 |
| `status.conf` | 系统内部状态记录文件，由程序自动维护，通常无需手动修改。 |

> **提示**：在配置 DNS 更新前，请确保你已在对应的云平台创建了正确的 API 凭证，并赋予了相应的 DNS 编辑权限。

---

## 项目结构

本项目采用模块化设计，逻辑清晰，便于二次开发与维护：

```text
Cloudflare-Best-IP-DnsUpdate/
├── cfopt.sh               # 主入口脚本（含自动安装、归位及初始化逻辑）
├── deploy.sh              # 版本哈希生成工具（用于生成 version.txt）
├── version.txt            # 远程版本索引文件（包含版本号与 SHA256 校验值）
├── modules/               # 核心功能模块目录
│   ├── cf-ip/             # CF IP 测速模块 (menu.sh, core.sh)
│   ├── cf-dns/            # Cloudflare DNS 更新模块
│   ├── dnspod-dns/        # DNSPod DNS 更新模块
│   ├── scheduler/         # 自动化调度与任务编排模块
│   └── ip-sync/           # IP 数据同步与分发模块
└── conf/                  # 配置文件存放目录
```

---

## 贡献与支持

如果你希望贡献代码、报告 Bug 或提出改进建议，欢迎提交 [Issue](https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate/issues) 或 [Pull Request](https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate/pulls)。

---

## 许可证与致谢

本项目基于 **GPL-3.0 License** 开源。

**特别说明与致谢：**

本项目的开发得益于以下优秀开源项目的启发与支持：

1.  **[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)**：本项目核心测速功能依赖于该项目提供的优秀测速程序，在此向原作者表示诚挚感谢！
2.  **[ZhiXuanWang/cf-speed-dns](https://github.com/ZhiXuanWang/cf-speed-dns)**：本项目的 Cloudflare 与 DNSPod DNS 记录更新模块，是基于该仓库的 Python 脚本逻辑改写并优化为 Shell 版本的。感谢原作者的分享与贡献！

本工具在上述项目的基础上，主要负责自动化调度、IP 数据处理、模块化封装及多平台兼容性的扩展。

---