# cfopt-go · 终端 / GUI 双形态

`cfopt-go` 是 Cloudflare-Best-IP-DnsUpdate 的 **Go 重写核心**。它提供 **两种对等操控方式**，共用同一套纯 Go 领域层（`internal/`）：

- **终端模式（CLI）**：`cfopt-go` 子命令，直接在同一进程调用核心。
- **GUI 模式（Tauri v2 + SvelteKit）**：桌面应用，经本地 IPC（JSON-RPC over TCP loopback）调用同一套核心。

> **一句话**：终端能做的 GUI 都能做，反之亦然。两者走的是同一份业务逻辑，只是入口不同。

完整架构与 13 个 IPC 方法契约见 [`../docs/system_design.md`](../docs/system_design.md)；新增 DNS 商接入见 [`../docs/providers-guide.zh.md`](../docs/providers-guide.zh.md)。

---

## 1. 仓库布局

```
repo/
├── cfopt-go/            # Go 核心（cmd + internal + pkg/ipc）
│   ├── cmd/             # cobra CLI（终端模式入口）
│   ├── internal/        # 纯 Go 领域层（零 UI 依赖）
│   ├── pkg/ipc/         # IPC 服务（GUI 接缝）
│   └── main.go
├── tauri/               # Rust（Tauri v2）后端 + IPC 桥接
│   ├── src/{lib,ipc,daemon}.rs
│   ├── tauri.conf.json  # externalBin 声明 Go 二进制
│   └── icons/           # 应用图标（由 scripts/gen-icons.py 生成）
├── src/                 # SvelteKit 前端
└── scripts/             # 构建辅助
    ├── gen-icons.py     # 生成占位图标（纯标准库）
    └── setup-sidecar.*  # 构建并放置 Go sidecar 到 tauri/binaries/
```

---

## 2. 环境要求

| 形态 | 需要 |
|---|---|
| 终端（CLI） | Go 1.22+ |
| GUI | Go 1.22+（编译 sidecar）+ Rust + cargo（Tauri CLI）+ Node（前端） |

> 本项目 Go 核心层已通过 QA：**`go build/vet/test ./...` 全绿，62 用例通过**。

---

## 3. 终端模式（CLI）

### 3.1 构建

```bash
cd cfopt-go
go build -o cfopt-go .      # 产出 cfopt-go（或 cfopt-go.exe）
```

### 3.2 常用命令

```bash
./cfopt-go version                       # 版本信息
./cfopt-go speedtest [--output out.iplist]   # 测速，生成 .iplist
./cfopt-go dns cf                        # 仅同步 Cloudflare
./cfopt-go dns dnspod                    # 仅同步 DNSPod（含多运营商分流）
./cfopt-go sync                          # 一键：测速→取最优 IP→同步全部启用模块
./cfopt-go config init                   # 生成配置模板
./cfopt-go config validate               # 校验当前配置
./cfopt-go schedule install|start|stop|status   # 守护进程（系统服务）管理
```

### 3.3 IPC / serve 模式（供 GUI 与冒烟测试）

GUI 启动时会自动拉起 `serve`。你也可以手动拉起，用它测试 13 个 IPC 方法：

```bash
# 监听随机端口，把实际端口原子写入 --ipc-port-file
./cfopt-go serve --ipc-port-file /tmp/cfopt.ipc
# 可选：--ipc-addr 127.0.0.1:0   --config-dir <dir>
```

> 你此前已验证该命令可正常监听随机端口（`addr=127.0.0.1:65343`），命令正确。

**快速冒烟测试**（读端口 → 发 JSON-RPC）。协议为 JSON-RPC 2.0 + JSON Lines（每行一个 JSON，以 `\n` 结尾）：

```bash
PORT=$(cat /tmp/cfopt.ipc)

# 心跳
printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | nc 127.0.0.1 "$PORT"
# => {"jsonrpc":"2.0","id":1,"result":{"pong":true}}

# 版本
printf '{"jsonrpc":"2.0","id":2,"method":"version"}\n' | nc 127.0.0.1 "$PORT"

# 仅同步 Cloudflare（providers 过滤，等价 CLI 的 dns cf）
printf '{"jsonrpc":"2.0","id":3,"method":"sync.run","params":{"providers":["cf"]}}\n' | nc 127.0.0.1 "$PORT"
# sync.run 期间会在最终响应前穿插 progress 事件：{"method":"progress","params":{...}}
```

> 没有 `nc`？用任意 TCP 客户端（如 `ncat`、`socat`，或 Python `socket`）发送同样的单行 JSON 即可。
> Windows PowerShell 下端口文件路径可用 `$env:TEMP\cfopt.ipc`。

**13 个 IPC 方法一览**

| 方法 | 参数 | 返回 |
|---|---|---|
| `ping` | — | `{"pong":true}` |
| `version` | — | `VersionInfo{version,commit,built_at}` |
| `config.get` | — | `Config` |
| `config.validate` | `Config` | `{"ok":true}` |
| `config.save` | `Config` | `{"ok":true}` |
| `sync.run` | `{"providers":[...]}`（可选） | `SyncSummary`（含 progress 事件流） |
| `speedtest.run` | — | `[]SpeedResult`（同时补写 `.iplist`） |
| `history.list` | `{"n":int}` | `[]HistoryEntry` |
| `daemon.install` | — | `{"ok":true}` |
| `daemon.uninstall` | — | `{"ok":true}` |
| `daemon.start` | — | `{"ok":true}` |
| `daemon.stop` | — | `{"ok":true}` |
| `daemon.status` | — | `DaemonStatus{state}` |

所有结构体字段均为 **snake_case**（Go / Rust / TypeScript 三处一致）。

---

## 4. GUI 模式（Tauri v2）

### 4.1 一次性准备

```bash
# 1) 生成占位图标（纯 Python 标准库，无需 Pillow / ImageMagick）
python3 scripts/gen-icons.py
#    => tauri/icons/{32x32,128x128,128x128@2x,icon}.png + icon.ico + icon.icns

# 2) 构建并放置 Go sidecar 到 tauri/binaries/
#    Windows（产出 x86_64-pc-windows-msvc.exe）：
pwsh scripts/setup-sidecar.ps1
#    Linux / macOS：
#    bash scripts/setup-sidecar.sh

# 3) 安装前端依赖并构建
npm --prefix src install && npm --prefix src run build
```

> `setup-sidecar` 会把二进制命名为 `cfopt-go-<target-triple>[.exe]`，与
> `tauri/tauri.conf.json` 中 `externalBin: ["binaries/cfopt-go"]` 配套，Tauri 据此按平台选取。
> 交叉编译示例：`pwsh scripts/setup-sidecar.ps1 -Target macos`。

### 4.2 运行 / 打包

```bash
cd tauri
cargo tauri dev      # 开发模式（热重载）
# 或
cargo tauri build    # 打包为安装包
```

应用启动后会在后台拉起 Go sidecar（`serve`），前端经 `invoke('ipc_request')` → Rust → Go IPC
完成全部功能。进度条由 Go 推送的 `progress` 事件实时驱动。

---

## 5. 终端 ↔ GUI 对等性

| 能力 | CLI | GUI 入口 |
|---|---|---|
| 全量同步 | `cfopt-go sync` | 主页「一键同步」 |
| 仅同步某 DNS 商 | `cfopt-go dns cf` / `dns dnspod` | 高级 → 仅同步 CF / DNSPod（经 `sync.run {providers:[...]}` 实现） |
| 测速 | `cfopt-go speedtest` | 测速页 |
| 配置读写 | 编辑 JSON / `config` 子命令 | 设置页（config.get/save） |
| 守护进程 | `schedule install/start/stop/status` | 服务管理页 |
| 历史 | 日志文件 | 历史页 |

---

## 6. 测试清单（方便你本地验证）

- [ ] **Go 核心**：`cd cfopt-go && go build ./... && go test ./...`（应全绿）
- [ ] **终端冒烟**：`go run . serve --ipc-port-file /tmp/cfopt.ipc`，另开终端 `nc` 发 `ping` 收到 `{"pong":true}`
- [ ] **CLI 对等**：`go run . dns cf` 与 `sync.run {"providers":["cf"]}` 结果一致
- [ ] **图标生成**：`python3 scripts/gen-icons.py` 后 `tauri/icons/` 含 6 个文件
- [ ] **sidecar 放置**：`pwsh scripts/setup-sidecar.ps1` 后 `tauri/binaries/` 含 `cfopt-go-x86_64-pc-windows-msvc.exe`
- [ ] **GUI 启动**：`cd tauri && cargo tauri dev`，主页一键同步进度条实时更新

---

## 7. 常见问题

- **`cargo tauri build` 报找不到 sidecar**：先跑 `setup-sidecar`，确认 `tauri/binaries/cfopt-go-<triple>[.exe]` 存在且 triple 匹配当前平台。
- **图标缺失导致打包失败**：先跑 `gen-icons.py`；如需自制图标，准备 1024×1024 PNG 后执行 `cargo tauri icon <your.png>` 覆盖 `tauri/icons/`。
- **IPC 连不上**：确认 `serve` 已启动且 `--ipc-port-file` 指向的路径存在、内容为单行端口号；GUI 会自动读取该文件做端口发现。
