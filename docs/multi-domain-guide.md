# 多域名支持使用指南

## 📋 概述

CF-DNS 和 DNSPod DNS 模块现已支持**多域名管理**，可以同时为多个域名（如 a.com、b.com、c.com）配置独立的 DNS 更新策略。

---

## 🏗️ 架构设计

### 配置文件结构

```
conf/
├── cf-dns/                    # Cloudflare DNS 配置目录
│   ├── a.com.json            # a.com 的配置
│   ├── b.com.json            # b.com 的配置
│   └── c.com.json            # c.com 的配置
├── dnspod/                   # DNSPod DNS 配置目录
│   ├── a.com.json            # a.com 的配置
│   ├── b.com.json            # b.com 的配置
│   └── c.com.json            # c.com 的配置
├── cf-dns.json               # （保留）向后兼容的默认配置
└── dnspod.json               # （保留）向后兼容的默认配置
```

### 核心特性

- ✅ **独立配置**：每个域名有独立的配置文件，互不干扰
- ✅ **批量更新**：自动遍历所有域名配置执行更新
- ✅ **进程隔离**：每个域名有独立的进程锁，防止并发冲突
- ✅ **向后兼容**：保留旧的单文件配置方式

---

## 🚀 使用方法

### 方法 1：快速部署向导（推荐）

运行快速部署向导，系统会自动创建多域名配置：

```bash
cfopt
# 选择 "快速部署向导"
```

向导会：
1. 询问 DNS 服务商（Cloudflare / DNSPod）
2. 收集域名和 API 凭证
3. 自动生成 `conf/{cf-dns,dnspod}/{domain}.json`
4. 记录到 `conf/deployments.json`

**示例：部署第二个域名**

第一次部署 a.com 后，可以再次运行向导部署 b.com：

```bash
cfopt
# 选择 "快速部署向导"
# 输入新域名 b.com
# 系统会创建 conf/cf-dns/b.com.json
```

---

### 方法 2：手动创建配置文件

#### Cloudflare DNS

1. 创建配置目录：
```bash
mkdir -p conf/cf-dns
```

2. 复制模板并修改：
```bash
cp conf/templates/cf-dns.json.example conf/cf-dns/example.com.json
```

3. 编辑配置文件：
```json
{
  "_comment": "Cloudflare DNS 更新器配置",
  "_version": "0.1",
  "enabled": true,
  "api": {
    "token": "your_api_token_here",
    "zone_id": "your_zone_id_here"
  },
  "dns": {
    "domain": "example.com",
    "sub_domain": "@",
    "record_type": "A",
    "ttl": 600,
    "max_ips_per_record": 2
  },
  "ip_source": {
    "file": "./assets/data/cf-dns/ip_list.txt"
  }
}
```

#### DNSPod DNS

1. 创建配置目录：
```bash
mkdir -p conf/dnspod
```

2. 复制模板并修改：
```bash
cp conf/templates/dnspod.json.example conf/dnspod/example.com.json
```

3. 编辑配置文件（单线路模式）：
```json
{
  "_comment": "DNSPod DNS 更新器配置",
  "_version": "0.1",
  "enabled": true,
  "api": {
    "id": "your_api_id_here",
    "token": "your_api_token_here",
    "timeout": 10,
    "max_retries": 5
  },
  "dns": {
    "domain": "example.com",
    "sub_domain": "dns",
    "record_type": "A",
    "ttl": 600,
    "max_ips_per_record": 2,
    "mode": "single"
  },
  "ip_source": {
    "file_path": "./assets/data/dnspod-dns/ip_list.txt"
  }
}
```

---

### 方法 3：命令行直接调用

#### 指定配置文件路径

```bash
# Cloudflare DNS
bash modules/cf-dns/core.sh conf/cf-dns/a.com.json

# DNSPod DNS
bash modules/dnspod-dns/core.sh conf/dnspod/b.com.json
```

#### 使用环境变量

```bash
# Cloudflare DNS
CF_DNS_DOMAIN=a.com bash modules/cf-dns/core.sh

# DNSPod DNS
DNSPOD_DOMAIN=b.com bash modules/dnspod-dns/core.sh
```

---

## 🔄 批量更新

### 自动批量更新（调度器）

调度器会自动检测并批量更新所有域名：

```bash
bash modules/scheduler/run.sh
```

执行流程：
1. IP 测速（单线路或多线路）
2. IP 数据同步
3. **Cloudflare DNS 批量更新**（遍历 conf/cf-dns/*.json）
4. **DNSPod DNS 批量更新**（遍历 conf/dnspod/*.json）

### 手动批量更新

```bash
# Cloudflare DNS 批量更新
bash modules/cf-dns/batch.sh

# DNSPod DNS 批量更新
bash modules/dnspod-dns/batch.sh
```

输出示例：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Cloudflare DNS 批量更新器 v0.1
 启动时间: 2026-05-05 10:30:00
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[OK] 找到 3 个域名配置

+------------------------------------------------------------+
 正在处理域名: a.com
+------------------------------------------------------------+
[INFO] 启动 CF-DNS 更新进程...
[OK] 域名 a.com 更新成功

+------------------------------------------------------------+
 正在处理域名: b.com
+------------------------------------------------------------+
[INFO] 启动 CF-DNS 更新进程...
[OK] 域名 b.com 更新成功

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 批量更新完成报告
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 总计配置: 3
 成功: 3
 失败: 0
 跳过: 0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 🔒 进程锁机制

### 独立锁文件

每个域名有独立的进程锁，防止同一域名的并发更新：

```
modules/cf-dns/.core_a_com.lock
modules/cf-dns/.core_b_com.lock
modules/dnspod-dns/.core_example_com.lock
```

### 并发安全

- ✅ **同一域名**：串行执行（防止冲突）
- ✅ **不同域名**：可以并行执行（提高效率）

示例：
```bash
# 这两个命令可以同时运行（不同域名）
CF_DNS_DOMAIN=a.com bash modules/cf-dns/core.sh &
CF_DNS_DOMAIN=b.com bash modules/cf-dns/core.sh &

# 这两个命令不能同时运行（相同域名）
CF_DNS_DOMAIN=a.com bash modules/cf-dns/core.sh &
CF_DNS_DOMAIN=a.com bash modules/cf-dns/core.sh  # 会被拒绝
```

---

## 📊 查看已部署的域名

### 查看部署记录

```bash
cat conf/deployments.json | jq '.domains[]'
```

输出示例：
```json
{
  "domain": "a.com",
  "dns_type": "cloudflare",
  "mode": "single",
  "deploy_time": "2026-05-05 10:00:00"
}
{
  "domain": "b.com",
  "dns_type": "dnspod",
  "mode": "multi",
  "deploy_time": "2026-05-05 10:15:00"
}
```

### 列出所有配置文件

```bash
# Cloudflare DNS
ls -la conf/cf-dns/

# DNSPod DNS
ls -la conf/dnspod/
```

---

## ⚙️ 高级配置

### 禁用某个域名

在配置文件中设置 `"enabled": false`：

```json
{
  "enabled": false,
  "api": { ... },
  "dns": { ... }
}
```

批量更新时会自动跳过禁用的域名：
```
[SKIP] 域名 example.com 已禁用 (enabled=false)
```

### 混合使用新旧配置

系统支持同时存在新旧两种配置格式：

```
conf/
├── cf-dns.json              # 旧格式（默认配置）
├── cf-dns/                  # 新格式（多域名）
│   ├── a.com.json
│   └── b.com.json
```

**优先级规则**：
1. 如果 `conf/cf-dns/` 目录存在且有配置文件，优先使用新格式
2. 否则回退到 `conf/cf-dns.json`（向后兼容）

---

## 🛠️ 故障排查

### 问题 1：找不到配置文件

**错误信息**：
```
[ERROR] 未找到任何 Cloudflare DNS 配置文件
```

**解决方案**：
```bash
# 检查配置目录是否存在
ls -la conf/cf-dns/

# 如果没有，创建目录并添加配置
mkdir -p conf/cf-dns
cp conf/templates/cf-dns.json.example conf/cf-dns/example.com.json
```

### 问题 2：进程锁冲突

**错误信息**：
```
[ERROR] 检测到另一个 CF-DNS 更新进程正在运行 (PID: 12345, Domain: a.com)
```

**解决方案**：
```bash
# 检查进程是否还在运行
ps aux | grep core.sh

# 如果进程已结束但锁文件残留，删除锁文件
rm -f modules/cf-dns/.core_a_com.lock
```

### 问题 3：批量更新部分失败

**查看日志**：
```bash
# Cloudflare DNS 日志
ls -la logs/cf-dns/

# DNSPod DNS 日志
ls -la logs/dnspod-dns/

# 查看最新的日志文件
tail -f logs/cf-dns/cf_dns_*.log
```

---

## 📝 最佳实践

### 1. 使用快速部署向导

推荐使用向导管理域名，避免手动配置出错：

```bash
cfopt
# 选择 "快速部署向导"
```

### 2. 定期备份配置

```bash
# 备份所有配置文件
tar czf conf-backup-$(date +%Y%m%d).tar.gz conf/cf-dns/ conf/dnspod/
```

### 3. 监控批量更新状态

在 crontab 中添加批量更新任务：

```cron
0 3 * * * CF_OPT_ENTRY=scheduler /bin/bash /root/cfopt/modules/scheduler/run.sh >> /root/cfopt/logs/scheduler/cron.log 2>&1
```

### 4. 分离不同业务的域名

建议按业务类型分组管理：

```
conf/cf-dns/
├── blog.example.com.json      # 博客
├── shop.example.com.json      # 电商
└── api.example.com.json       # API 服务
```

---

## 🎯 总结

多域名支持让您可以：

- ✅ 同时管理多个域名的 DNS 记录
- ✅ 每个域名独立配置，互不干扰
- ✅ 批量更新所有域名，提高效率
- ✅ 进程锁隔离，保证并发安全
- ✅ 向后兼容，不影响现有配置

**开始使用多域名功能**：

```bash
cfopt
# 选择 "快速部署向导"
# 部署您的第一个域名
# 再次运行向导，部署第二个域名
# 享受自动化管理的便利！
```
