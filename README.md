# Cloudflare-Best-IP-DnsUpdate

> **警告：本项目正在积极开发中，功能尚未稳定，代码结构可能随时发生重大变化。**
> 
> **强烈建议不要在生产环境中使用！仅供测试和技术交流。**

[![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Status](https://img.shields.io/badge/Status-Developing-orange.svg)]()

---

## 项目简介

Cloudflare-Best-IP-DnsUpdate 是一款全自动化的 **Cloudflare IP 优选与 DNS 记录管理工具**，致力于实现从 IP 测速优选到 DNS 解析记录自动更新的全链路自动化流程。

### 核心功能

- **智能 IP 优选**：集成高性能测速核心，支持分运营商（移动/联通/电信）专项优化
- **DNS 自动更新**：支持 Cloudflare 和 DNSPod 双平台，自动同步优选 IP 到 DNS 记录
- **全链路自动化**：内置调度中心，支持 Cron 定时任务，实现无人值守运行
- **安全完整性校验**：采用 SHA256 机制校验所有组件，确保下载与更新安全
- **模块化设计**：清晰的功能划分，便于二次开发与维护

---

## 快速开始

### 系统要求

- 操作系统：Linux（Debian/Ubuntu/CentOS/Alpine 等主流发行版）
- 必要工具：curl、bash、crontab
- 权限要求：root 或具有 sudo 权限的用户

### 一键安装

```bash
curl -sL https://blog.drxian.cn/scripts/Cloudflare-Best-IP-DnsUpdate/cfopt.sh -o cfopt.sh && bash cfopt.sh
```

安装完成后，脚本会自动：
1. 迁移至标准目录（`/root/cfopt` 或 `$HOME/cfopt`）
2. 下载并配置所有核心组件
3. 创建全局命令（可在任意终端输入 `cfopt` 启动）

### 启动程序

```bash
cfopt
```

---

## 功能模块

进入主菜单后，可选择以下功能：

| 选项 | 功能名称 | 说明 |
| :--- | :--- | :--- |
| **1** | **CF IP 优选管理** | 配置测速节点（Colo）、运行测速程序及管理测速定时任务 |
| **2** | **CF DNS 记录更新** | 将优选 IP 自动同步更新至 Cloudflare DNS 记录 |
| **3** | **DNSPod DNS 更新** | 腾讯云 DNSPod 分线路（ISP）解析管理与自动更新 |
| **4** | **自动化调度中心** | 一键触发全链路流程或设置后台 Cron 自动运行 |
| **5** | **检查组件更新** | 从远程仓库同步最新版本脚本及补丁 |
| **9** | **一键卸载** | 删除脚本及相关配置，清理所有数据 |

---

## 配置指南

### 配置文件位置

所有配置文件位于 `$HOME/cfopt/conf/` 目录下，首次运行时会自动生成。

| 文件名 | 说明 |
| :--- | :--- |
| `cfdns.conf` | Cloudflare API 令牌 (Token)、区域 ID (Zone ID) 及目标域名 |
| `dnspod.conf` | DNSPod API ID/Token 及目标域名 |
| `status.conf` | 系统内部状态记录，通常无需手动修改 |

### 获取 API 凭证

#### Cloudflare
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 进入 **My Profile** -> **API Tokens**
3. 创建自定义令牌，权限需包含 **Zone.DNS - Edit**
4. 记录 Token 和 Zone ID（在域名概述页面可查看）

#### DNSPod（腾讯云）
1. 登录 [DNSPod 控制台](https://console.dnspod.cn/)
2. 进入 **账号中心** -> **密钥管理**
3. 创建 API 密钥，记录 ID 和 Token

> **注意**：请妥善保管 API 凭证，不要泄露给他人。

---

## 项目结构

```
Cloudflare-Best-IP-DnsUpdate/
├── cfopt.sh               # 主入口脚本（自动安装、归位及初始化）
├── version.txt            # 远程版本索引（含版本号与 SHA256 校验值）
── modules/               # 核心功能模块
│   ├── cf-ip/             # CF IP 测速模块 (menu.sh, core.sh)
│   ├── cf-dns/            # Cloudflare DNS 更新模块
│   ├── dnspod-dns/        # DNSPod DNS 更新模块
│   ├── scheduler/         # 自动化调度与任务编排
│   └── ip-sync/           # IP 数据同步与分发
└── conf/                  # 配置文件目录
```

---

## 开发与贡献

### 开发状态

本项目目前处于**积极开发阶段**，存在以下特点：
- 功能可能随时调整或重构
- API 接口和配置文件格式可能发生变化
- 不建议用于生产环境或关键业务

### 贡献方式

欢迎通过以下方式参与项目：
- 提交 [Issue](https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate/issues) 报告 Bug 或提出建议
- 提交 [Pull Request](https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate/pulls) 贡献代码
- 完善文档或提供使用反馈

---

## 许可证与致谢

### 开源协议

本项目基于 **GPL-3.0 License** 开源。

### 特别致谢

本项目的开发得益于以下优秀开源项目：

1. **[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)**
   - 核心测速功能依赖该项目提供的测速程序
   - 向原作者表示诚挚感谢

2. **[ZhiXuanWang/cf-speed-dns](https://github.com/ZhiXuanWang/cf-speed-dns)**
   - Cloudflare 与 DNSPod DNS 更新模块基于该项目的 Python 脚本逻辑改写
   - 感谢原作者的分享与贡献

本项目在上述优秀工作的基础上，专注于自动化调度、IP 数据处理、模块化封装及多平台兼容性的扩展。

---

## 免责声明

**本项目仅供学习和技术研究使用，使用本工具产生的任何后果由使用者自行承担。**

- 请遵守当地法律法规，不得用于任何违法违规用途
- 使用前请仔细阅读 Cloudflare 和 DNSPod 的服务条款
- 频繁更新 DNS 记录可能触发平台的风控机制，请合理设置更新频率
- 作者不对因使用本工具导致的任何损失或损害负责

---
