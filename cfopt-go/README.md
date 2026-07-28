# cfopt-go · 终端 / GUI 双形态

`cfopt-go` 是 Cloudflare-Best-IP-DnsUpdate 的 **Go 重写核心**。它提供 **两种对等操控方式**，共用同一套纯 Go 领域层（`internal/`）：

- **终端模式（CLI）**：`cfopt-go` 子命令，直接在同一进程调用核心。
- **GUI 模式（Tauri v2 + SvelteKit）**：桌面应用，经本地 IPC（JSON-RPC over TCP loopback）调用同一套核心。

> **一句话**：终端能做的 GUI 都能做，反之亦然。两者走的是同一份业务逻辑，只是入口不同。

> **🪟 平台提示（Windows 用户必读）**：本仓库命令默认给出**跨平台写法**。在 Windows 上请使用 **cmd / PowerShell**，注意：
> - 没有 `pwsh`？用系统自带的 `powershell`（Win10/11 内置 5.1 即可），加 `-ExecutionPolicy Bypass`。
> - 没有 `python3`？用 `python`。
> - 没有 `nc`(netcat)？用仓库根 `scripts/ipc-smoke.ps1` 做冒烟测试（已封装读端口 + 发送 + 打印）。
> - 别直接复制 bash 的 `$(...)` / `printf` 到 cmd，会报"不是内部或外部命令"。

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

### 3.3 安装（Install）与卸载（Uninstall）

`cfopt install` / `cfopt uninstall` 采用**便携优先、系统级可选**的二态设计。

#### 便携 vs 系统级对照表

| 维度 | 便携模式（默认 `cfopt install`） | 系统级模式（`cfopt install --system`） |
|---|---|---|
| 二进制落点 | 当前二进制所在目录（可用 `--dir` 显式指定） | `%LOCALAPPDATA%\cfopt`（Win）/ `/usr/local/bin`（其他） |
| 配置目录 | `dir/conf`（与默认 `--config-dir=conf` 从 `dir` 运行天然对齐） | 全局 `--config-dir`（默认 `conf`，cwd 相对） |
| 全局命令（PATH/软链） | **不写** | 写用户级 PATH / 软链 |
| 调度（系统服务） | **不注册**（`--schedule` 被忽略并提示） | `--schedule` 时注册并启动（默认每 6 小时） |
| cfst 落点 | `dir/assets/cfst` | `dir/assets/cfst` |
| 卸载 | 删除便携目录即干净退出 | 停止调度 → 移除全局命令 → 删除安装目录（可选全清配置） |
| 互斥 | `--system` 优先于 `--dir`（忽略 `--dir` 并警告） | — |

#### 常用安装/卸载命令

```bash
# 便携（默认）：二进制 + conf 骨架 + cfst 同目录落盘，不写系统目录
cfopt-go install
cfopt-go install --dir ./myportable     # 显式便携目录（沙箱/临时目录可端到端验证）

# 系统级：自安置 + 用户级 PATH（+ 可选常驻调度）
cfopt-go install --system
cfopt-go install --system --schedule

# 卸载
cfopt-go uninstall                       # 便携：删当前二进制目录（默认防误删，Confirm 默认 No）
cfopt-go uninstall --dir ./myportable --force   # 便携强制删目录
cfopt-go uninstall --system              # 系统级：清 PATH 与调度（可选全清配置）
```

#### 标志说明

- `--dir <路径>`：便携目标目录（仅便携模式有意义）；缺省取**当前二进制所在目录**。
- `--system`：显式走系统级行为（自安置 + 写 PATH）。与 `--dir` 互斥，以 `--system` 为准并忽略 `--dir` 且警告。
- `--schedule`：仅系统级生效，注册并启动常驻调度；便携模式传此标志会被**忽略并提示**（Q-C1）。
- `--force`：跳过确认直接执行（适合脚本/CI）；卸载默认防误删（Confirm 默认 No）。

#### Windows GUI 推荐提示

在 **Windows** 下运行 `cfopt install`（含便携默认）与无参主菜单 `cfopt` 时，会打印一句纯 CLI 提示，引导优先使用 GUI 版本：

> 💡 提示：在 Windows 上，推荐直接使用图形界面（GUI）版本完成安装与部署……您当前使用的是命令行（CLI）模式。

非 Windows 不打印该提示（避免噪音）。该提示**不改任何 IPC/GUI 契约**；GUI 向导本身为前端后续项，本次仅在 CLI 侧输出文案。

#### 便携 `conf` 默认路径含义

`cfopt` 默认 `--config-dir=conf`（相对当前工作目录）。便携安装时 `cfgDir = dir/conf`，故**从便携目录 `dir` 直接运行 `cfopt`** 即可自动发现 `dir/conf/global.json` 等配置，无需额外参数——实现真正的「下载即用、删目录即走」。

### 3.4 IPC / serve 模式（供 GUI 与冒烟测试）

GUI 启动时会自动拉起 `serve`。你也可以手动拉起，用它测试 13 个 IPC 方法。

> **⚠️ 端口文件路径**：`--ipc-port-file` 现在会自动创建父目录。建议用**当前目录的相对路径** `cfopt.ipc`，最直观（Windows 下 `/tmp/...` 会解析成 `D:\tmp\...`，虽然也能自动创建但较隐蔽）。

**启动 serve（CLI）**

```bash
# Linux / macOS / Git Bash
./cfopt-go serve --ipc-port-file cfopt.ipc
# Windows cmd / PowerShell（保持此窗口运行，不要关、不要 Ctrl+C）
go run . serve --ipc-port-file cfopt.ipc
```

**快速冒烟测试**（读端口 → 发 JSON-RPC）。协议为 JSON-RPC 2.0 + JSON Lines（每行一个 JSON，以 `\n` 结尾）：

- **推荐（跨平台脚本）**：仓库根 `scripts/ipc-smoke.{ps1,sh}` 已封装好读端口 + 发请求 + 打印响应（含 `sync.run` 的 progress 事件流）。脚本默认读**当前目录**下的 `cfopt.ipc`，所以要在写好端口文件的 `cfopt-go/` 目录里运行：

  ```bash
  cd cfopt-go          # 端口文件 cfopt.ipc 就在这里

  # Windows PowerShell
  powershell -ExecutionPolicy Bypass -File ..\scripts\ipc-smoke.ps1
  powershell -ExecutionPolicy Bypass -File ..\scripts\ipc-smoke.ps1 -Method version
  powershell -ExecutionPolicy Bypass -File ..\scripts\ipc-smoke.ps1 -Method sync.run -ParamsJson '{"providers":["cf"]}'

  # Linux / macOS / Git Bash
  bash ../scripts/ipc-smoke.sh
  bash ../scripts/ipc-smoke.sh version
  bash ../scripts/ipc-smoke.sh sync.run '{"providers":["cf"]}'
  ```

  > 不想切目录？用绝对路径（把 `D:\code\...` 换成你的实际仓库路径）：
  > `powershell -ExecutionPolicy Bypass -File D:\code\Cloudflare-Best-IP-DnsUpdate\scripts\ipc-smoke.ps1 -PortFile D:\code\Cloudflare-Best-IP-DnsUpdate\cfopt-go\cfopt.ipc`

- **手动（Windows PowerShell，无 netcat 时）**：

  ```powershell
  $port = (Get-Content cfopt.ipc).Trim()
  $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
  $ns = $tcp.GetStream()
  $sw = New-Object System.IO.StreamWriter($ns); $sw.AutoFlush = $true
  $sw.WriteLine('{"jsonrpc":"2.0","id":1,"method":"ping"}')
  Start-Sleep -Milliseconds 500
  $sr = New-Object System.IO.StreamReader($ns); $sr.ReadLine(); $tcp.Close()
  # => {"jsonrpc":"2.0","id":1,"result":{"pong":true}}
  ```

- **手动（Linux / macOS / Git Bash，有 netcat）**：

  ```bash
  PORT=$(cat cfopt.ipc)
  printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | nc 127.0.0.1 "$PORT"
  # => {"jsonrpc":"2.0","id":1,"result":{"pong":true}}
  ```

**13 个 IPC 方法一览**

| 方法 | 参数 | 返回 |
|---|---|---|
| `ping` | — | `{"pong":true}` |
| `version` | — | `VersionInfo{version,commit,built_at}` |
| `config.get` | — | `Config` |
| `config.validate` | `Config`（可选；缺省校验当前已加载配置） | `{"ok":true}` |
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
#    Windows 上 Python 命令通常是 python（不是 python3）
python scripts/gen-icons.py          # 或 python3 scripts/gen-icons.py
#    => tauri/icons/{32x32,128x128,128x128@2x,icon}.png + icon.ico + icon.icns

# 2) 构建并放置 Go sidecar 到 tauri/binaries/
#    Windows（产出 x86_64-pc-windows-msvc.exe）：用系统自带 powershell 即可
powershell -ExecutionPolicy Bypass -File scripts/setup-sidecar.ps1
#    （若你装了 PowerShell 7，也可：pwsh scripts/setup-sidecar.ps1）
#    Linux / macOS：
#    bash scripts/setup-sidecar.sh

# 3) 安装前端依赖并构建
npm --prefix src install && npm --prefix src run build
```

> `setup-sidecar` 会把二进制命名为 `cfopt-go-<target-triple>[.exe]`，与
> `tauri/tauri.conf.json` 中 `externalBin: ["binaries/cfopt-go"]` 配套，Tauri 据此按平台选取。
> 交叉编译示例：`powershell -ExecutionPolicy Bypass -File scripts/setup-sidecar.ps1 -Target macos`。

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
- [ ] **终端冒烟**：`go run . serve --ipc-port-file cfopt.ipc`（保持运行），另开窗口 `powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1` 收到 `{"pong":true}`
- [ ] **CLI 对等**：`go run . dns cf` 与 `sync.run {"providers":["cf"]}` 结果一致
- [ ] **图标生成**：`python scripts/gen-icons.py` 后 `tauri/icons/` 含 6 个文件
- [ ] **sidecar 放置**：`powershell -ExecutionPolicy Bypass -File scripts/setup-sidecar.ps1` 后 `tauri/binaries/` 含 `cfopt-go-x86_64-pc-windows-msvc.exe`
- [ ] **GUI 启动**：`cd tauri && cargo tauri dev`，主页一键同步进度条实时更新

---

## 7. 常见问题

- **`cargo tauri build` 报找不到 sidecar**：先跑 `setup-sidecar`，确认 `tauri/binaries/cfopt-go-<triple>[.exe]` 存在且 triple 匹配当前平台。
- **图标缺失导致打包失败**：先跑 `gen-icons.py`；如需自制图标，准备 1024×1024 PNG 后执行 `cargo tauri icon <your.png>` 覆盖 `tauri/icons/`。
- **IPC 连不上**：确认 `serve` 已启动且 `--ipc-port-file` 指向的路径存在、内容为单行端口号；GUI 会自动读取该文件做端口发现。
