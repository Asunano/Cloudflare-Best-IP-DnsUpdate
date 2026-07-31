# cfopt CLI 命令参考

本文档列出 `cfopt` 全部 CLI 子命令，并重点说明**桌面 GUI 集成**时最常使用的命令（尤其是 `cfopt schedule run --once` 与 `cfopt serve`）。终端与桌面 GUI 共用同一套核心逻辑，两者行为完全一致。

> 二进制名统一为 `cfopt`（Windows 为 `cfopt.exe`）。下文以 `cfopt` 代指。

---

## 全局参数（所有子命令可用）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--config-dir <dir>` | `conf`（相对当前工作目录） | 配置文件目录，含 `global.json` / `cf-dns.json` / `dnspod.json` 及 `cf-dns/`、`dnspod/` 子目录 |
| `--log-level <lvl>` | `info` | 日志级别：`debug` \| `info` \| `warn` \| `error` |
| `--lock-dir <dir>` | 取 `global.lock_dir` | 进程锁目录（多实例互斥）；通常无需手动指定 |

示例：

```bash
cfopt --config-dir /root/test/conf sync
```

---

## 退出码约定

| 退出码 | 含义 |
|---|---|
| `0` | 成功（含 `schedule run --once` 单次同步成功完成） |
| `1` | 致命错误（配置加载失败、同步异常等），错误信息打印到 `stderr` |

> GUI 通过子进程调用时，建议直接依据退出码判断成败；结构化日志见 `logs/cfopt.log` 与 `assets/data/history.jsonl`。

---

## 子命令总览

| 命令 | 说明 |
|---|---|
| `cfopt sync` | 一键全同步：测速 → 提取最优 IP → 写入各 DNS 模块 → 同步 → 写历史 |
| `cfopt speedtest` | 单次测速（仅产出 IP 列表，不写 DNS） |
| `cfopt dns cf` | 仅同步 Cloudflare DNS |
| `cfopt dns dnspod` | 仅同步 DNSPod DNS（含多运营商分流） |
| `cfopt dns dnspod switch` | 交互式切换 DNSPod 工作模式 / 子域策略 |
| `cfopt config init\|validate\|wizard\|cfip\|migrate` | 配置管理（生成模板 / 校验 / 向导 / 配置优选参数 / 迁移旧配置） |
| `cfopt schedule [run\|install\|uninstall\|start\|stop\|status\|install-cron\|uninstall-cron\|install-schtasks\|uninstall-schtasks\|panel-cron]` | 调度 / 常驻 daemon 管理 |
| `cfopt install` | 安装（便携模式自安置 / 可选系统级 PATH + 调度） |
| `cfopt uninstall` | 卸载 |
| `cfopt serve` | 启动 IPC 服务（JSON-RPC 2.0 over TCP loopback），供 GUI 调用 |
| `cfopt update` | 自更新（GitHub release → SHA256 校验 → 原子替换） |
| `cfopt cfst fetch` | 下载并安装 cfst 测速二进制（SHA256 校验） |
| `cfopt health` | 系统健康检测（cfst/配置/网络/调度等） |
| `cfopt logs` | 查看运行日志 / 同步历史 |
| `cfopt version` | 版本、commit、构建时间 |
| `cfopt quickdeploy` | 快速部署单域名（CF/DNSPod，单/多线路） |

---

## GUI 集成重点命令

GUI 触发的「同步」有两种等价实现，**推荐优先使用 IPC（见下），`schedule run --once` 作为子进程调用或兜底方案**。

### `cfopt schedule run --once`

执行**一次完整同步**（等同于一次 `cfopt sync` 的链路：测速 → 提取最优 IP → 逐线路即时同步 → 统一同步 → 写历史），完成后立即退出。

```bash
cfopt schedule run --once
cfopt --config-dir /root/test/conf schedule run --once
```

特性：

- **前台、单次、退出**：不常驻、不注册系统服务，适合被外部调度器（cron / 计划任务 / 面板 / GUI 子进程）直接唤醒。
- 退出码 `0` 成功、`1` 失败（错误输出到 `stderr`）。
- 这正是 `cfopt schedule install-cron`（Linux crontab）、`install-schtasks`（Windows 计划任务）、`panel-cron`（宝塔/1Panel）在计划任务中实际执行的命令。
- 可与 `--config-dir` 组合指定配置目录。

GUI「立即同步」按钮的两种接法：

```bash
# 方式 A：直接子进程调用（简单，吞掉 stdout，看退出码）
cfopt schedule run --once
echo $?   # 0 成功 / 1 失败

# 方式 B（推荐）：通过 cfopt serve 的 IPC sync.run 方法，可拿到 progress 事件流
```

### `cfopt serve`（推荐 GUI 集成路径）

启动一个 JSON-RPC 2.0（JSON Lines 帧）IPC 服务，监听 `127.0.0.1` 随机端口，供 GUI（Tauri Rust 桥接 / 前端）调用同一套领域层。

```bash
cfopt serve --ipc-port-file cfopt.ipc
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--ipc-addr` | `127.0.0.1:0` | 监听地址；端口为 `0` 表示随机分配，实际端口写入端口文件 |
| `--ipc-port-file` | （空） | 将实际端口以单行整数写入此文件（tmp + rename 原子写），供 GUI 发现 |

可用 IPC 方法：`ping`、`version`、`config.get`、`config.validate`、`config.save`、`sync.run`(支持 `providers` 过滤 + `progress` 事件流)、`speedtest.run`、`history.list`、`daemon.install`/`uninstall`/`start`/`stop`/`status`。

GUI 集成建议：

1. 启动 `cfopt serve --ipc-port-file <tmp>/cfopt.ipc`（作为后台子进程）。
2. 读取端口文件获得端口，建立 TCP loopback 连接。
3. 「立即同步」→ 发送 `sync.run`（可带 `{"providers":["cf","dnspod"]}` 过滤），订阅 `progress` 事件流刷新进度条。
4. 查询历史 / 配置 / 健康 / 调度状态均走对应 IPC 方法，无需再起子进程。
5. 关闭 GUI 时终止 `serve` 子进程即可。

> 若 IPC 不可用（老环境 / 调试），退回子进程调用 `cfopt schedule run --once` 同样可完成同步。

---

## 调度管理（systemd / crontab / 计划任务 / 面板）

| 命令 | 说明 |
|---|---|
| `cfopt schedule` 或 `cfopt schedule run` | 前台运行：默认常驻 daemon（带看门狗超时保护），加 `--once` 则单次退出 |
| `cfopt schedule install` | 注册系统服务（systemd/launchd/Windows Service） |
| `cfopt schedule uninstall` | 注销系统服务 |
| `cfopt schedule start` / `stop` | 启动 / 停止系统服务 |
| `cfopt schedule status` | 查看服务运行状态与最近历史（含 systemd 崩溃重启循环甄别） |
| `cfopt schedule install-cron [freq]` | 安装 Linux crontab 调度（底层即注册 `... schedule run --once`），freq 可为 `4h`/`6h`/`daily`/`twice`/`hourly`/自定义 5 字段表达式 |
| `cfopt schedule uninstall-cron` | 卸载 crontab 调度 |
| `cfopt schedule install-schtasks [freq]` | 安装 Windows 计划任务（底层注册 `... schedule run --once`），仅 Windows |
| `cfopt schedule uninstall-schtasks` | 卸载 Windows 计划任务 |
| `cfopt schedule panel-cron [--bin <path>]` | 生成宝塔/1Panel 面板可粘贴的 Shell 脚本（执行 `cd <dir> && <bin> schedule run --once`） |

调度间隔取自 `global.schedule.interval`（Go duration 字符串，如 `6h`），默认 `6h`。

---

## 其他常用示例

```bash
# 生成配置模板（首次使用）
cfopt config init

# 校验当前配置 schema
cfopt config validate --config-dir /root/test/conf

# 查看系统健康（含 systemd 服务状态、cron 备选状态）
cfopt health --config-dir /root/test/conf

# 查看最近同步历史
cfopt logs --config-dir /root/test/conf

# 仅同步 Cloudflare
cfopt dns cf --config-dir /root/test/conf

# 版本信息
cfopt version
```
