# cfopt 系统设计文档（模块化 Provider + Tauri v2 GUI）

> 本文档描述 `cfopt-go`（Go 核心层）与 `tauri/`（Rust Tauri v2 桥接）+ `src/`（SvelteKit 前端）的整体架构。
> 设计目标：一套核心业务逻辑，三种操控方式（Bash 已弃用 / CLI `cmd` / GUI Tauri），共用同一套纯 Go 领域层。

---

## 1. 总体分层

```
┌──────────────────────────────────────────────────────────────┐
│ GUI 集成层（tauri/ + src/）                                    │
│  Tauri(Rust) 仅做 UI + IPC 桥接，spawn Go 二进制并 JSON-RPC 通信 │
└───────────────────────┬──────────────────────────────────────┘
                         │ JSON-RPC 2.0 over TCP loopback / JSON Lines
┌───────────────────────┴──────────────────────────────────────┐
│ CLI 层（cfopt-go/cmd/，cobra 子命令）                           │
│  speedtest / dns / sync / schedule / config / serve / version   │
└───────────────────────┬──────────────────────────────────────┘
                         │ 直接调用（同进程）
┌───────────────────────┴──────────────────────────────────────┐
│ 核心领域层（cfopt-go/internal/，纯 Go，零 UI 依赖）             │
│  config / common / speedtest / dns / ipsource / sync /          │
│  scheduler / history                                          │
└──────────────────────────────────────────────────────────────┘
```

**关键约束（依赖方向，编译期保证）**：
- `internal/dns` → 可依赖 `internal/config` / `internal/speedtest` 等；反向禁止。
- `pkg/ipc`（GUI 接缝）可依赖 `internal/*`；**严禁** `import cmd`，避免 import cycle。
- `cmd` 可依赖 `pkg/ipc` 与 `internal/*`。
- `config` 包**严禁** `import internal/dns`：新增 provider 的校验下沉到模块自身（见 §3）。

---

## 2. 模块化 DNS Provider（SyncModule + Registry）

中心编排（`internal/sync`）只依赖 `dns.SyncModule` 接口与 `dns.Registry`，**完全不感知具体 DNS 商**。
新增一个 provider = 实现 `SyncModule` + 注册进 `Registry`，中心逻辑零改动。

```go
// internal/dns 定义
type SyncModule interface {
    ID() string                                  // 唯一标识，如 "cloudflare" / "dnspod"
    Enabled(cfg *config.Config) bool             // 是否启用（读全局配置）
    IPSourceFiles(cfg *config.Config) []string   // 需要从中心写入最优 IP 的源文件
    Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error)
}

type Registry struct { ... }
func NewRegistry() *Registry
func (r *Registry) Register(m SyncModule)
func (r *Registry) RegisterAll([]SyncModule)
func (r *Registry) Modules() []SyncModule

// 内置模块；外部 provider 通过 append 注入即可，无需改动中心。
var BuiltinModules = []SyncModule{ cfModule{}, dnspodModule{} }
```

`Syncer.SyncAll(ctx, cfg, onProgress, providers...)` 主链路：
1. `tester.Run` 测速（失败自动重测一次）
2. `ExtractBestIPs` 取最优 N
3. 将最优 IP 写入各选中模块的 IP 源文件（`IPSourceFiles`）
4. 依次遍历选中模块并 `Sync`（各模块以 `ID()` 作为 progress phase）
5. 累加 `SyncResult` 进 `SyncSummary`，写历史

`providers` 过滤：空→全部启用模块；非空→仅指定且 `Enabled` 的 ID（向后兼容 CLI 行为）。

---

## 3. IPC 契约（GUI 接缝）

传输：**TCP loopback**（`127.0.0.1:<port>`，随机端口），**JSON-RPC 2.0** 语义，
**JSON Lines** 帧（每个 JSON 值独占一行，以 `\n` 结尾）。`id` 为整数。

服务端 `cfopt-go/pkg/ipc`（`cfopt serve`）：
- 监听 `127.0.0.1:0`（系统分配随机端口），并把实际端口写入 `--ipc-port-file`（单行整数，tmp+rename 原子写）。
- `sync.run` 执行期间，在最终响应之前于**同一连接**上穿插推送 `progress` 通知（`{"method":"progress","params":ProgressEvent}`），由 `req_id` 关联回请求。

### 13 个方法

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

### 关键类型（全部 snake_case）

- `ProgressEvent{ req_id:i64, phase:string, cur:i64, total:i64, message:string }`
- `SyncSummary{ best_ip_count, updated, created, deleted:i64, errors:[]string }`
- `SpeedResult{ ip, sent, received:i64, loss, latency, speed:f64, colo:string }`
- `HistoryEntry{ ts:string, action:string, detail:string, success:bool }`
- `Config{ global, cf_ip, cf_dns, dnspod, modules:map[string]json.RawMessage }`

---

## 4. GUI（Tauri v2 + SvelteKit）

### 目录

```
repo/
├── tauri/                     # Rust（Tauri v2）后端 / IPC 桥接
│   ├── Cargo.toml
│   ├── build.rs
│   ├── tauri.conf.json        # externalBin 声明 Go 二进制（cfopt-go）
│   ├── capabilities/default.json
│   └── src/
│       ├── main.rs
│       ├── lib.rs             # AppState + ipc_request 命令（路由 13 方法）
│       ├── ipc.rs             # IpcClient：TCP JSON-RPC 客户端 + 13 类型化方法 + snake_case 结构
│       └── daemon.rs          # sidecar 生命周期：spawn / 端口发现 / stop
└── src/                       # SvelteKit 前端（srcDir='.'）
    ├── package.json / svelte.config.js / vite.config.ts / tsconfig.json
    ├── app.html / app.css / app.d.ts
    ├── lib/
    │   ├── ipc-types.ts       # 与 IPC 契约对齐的 TS 类型
    │   ├── tauri.ts           # invoke('ipc_request') 桥接 + onProgress 订阅
    │   ├── api.ts             # 13 方法的类型化封装
    │   └── stores.ts          # 进度/状态 svelte store
    └── routes/                # +layout + 6 页面（概览/同步/测速/配置/历史/守护进程）
```

### 运行链路

1. 前端 `invoke('ipc_request', { method, params })`（见 `src/lib/tauri.ts`）。
2. Rust `ipc_request`（`tauri/src/lib.rs`）确保 Go 守护进程已启动：
   - 通过 `tauri-plugin-shell` 以 **sidecar** 拉起 `cfopt-go serve --ipc-addr 127.0.0.1:0 --ipc-port-file <path> [--config-dir <dir>]`；
   - 轮询读取端口文件完成**端口发现**，写入 `IpcClient` 地址。
3. Rust `IpcClient`（`tauri/src/ipc.rs`）建立 TCP 连接，发送 JSON-RPC 请求：
   - 普通方法：单次请求-响应。
   - `sync.run`：同一连接上消费 `progress` 事件，通过 `app.emit("sync-progress", pe)` 转发给前端；最终响应作为结果返回。
4. 前端 `listen('sync-progress', ...)` 实时刷新进度条（`src/routes/sync/+page.svelte`）。

### 设计原则

- **Rust 零业务逻辑**：仅做 UI 渲染、参数透传、IPC 桥接、sidecar 生命周期。
- **snake_case 全链路对齐**：Go 契约、Rust 结构、TS 类型三处字段名一致。
- **扩展 provider**：新增 DNS 商只需在 Go 端实现 `SyncModule` 并 append 进 `BuiltinModules`（或手动 `Registry.Register`），GUI 无需改动。

---

## 5. 构建与运行（待本地工具链验证）

```bash
# Go 核心（已通过 QA：build/vet/test=0，62 用例）
cd cfopt-go && go build ./... && go test ./...

# 桌面端 GUI（需 Rust + Node 工具链，沙箱未提供，源码先行）
# 0) 生成占位图标（纯 Python 标准库，无需 Pillow / ImageMagick）
python3 scripts/gen-icons.py     # 产出 tauri/icons/{32x32,128x128,128x128@2x,icon}.png + icon.ico + icon.icns
# 1) 构建并放置 Go sidecar → tauri/binaries/cfopt-go-<target-triple>[.exe]
#    （externalBin 在 tauri.conf.json 中声明为 "binaries/cfopt-go"）
pwsh scripts/setup-sidecar.ps1   # Windows（默认产出 x86_64-pc-windows-msvc.exe）
# bash scripts/setup-sidecar.sh  # Linux / macOS
# 2) 安装前端依赖并构建
npm --prefix src install && npm --prefix src run build
# 3) Tauri 开发 / 打包
cd tauri && cargo tauri dev      # 或 cargo tauri build
```

> 说明：本仓库此前未提交的 `docs/system_design.md` / `docs/class-diagram.mermaid` /
> `docs/sequence-diagram.mermaid` 在本轮由工程师依据**实际落地代码**补齐，确保文档与实现一致。

---

## 6. 功能对等矩阵（CLI ↔ IPC ↔ GUI）

> 13 个 IPC 方法：`ping, version, config.get, config.validate, config.save, sync.run, speedtest.run, history.list, daemon.install, daemon.uninstall, daemon.start, daemon.stop, daemon.status`

| 能力 | CLI 命令 | IPC 方法 | GUI 操作入口 | 对等性 |
|---|---|---|---|---|
| 启动 daemon/IPC | `cfopt-go serve --ipc-port-file` | （server 本身） | 应用启动拉起 Go sidecar (`serve`) | GUI 隐式等价 ✓ |
| 心跳/连通 | — | `ping` | 连接状态指示灯 | GUI 独有监控 ✓ |
| 版本 | `cfopt-go version` | `version` | 关于页 | 双向 ✓ |
| 配置读取/生成 | `cfopt-go config init` / `config validate` | `config.get` | 设置页加载 | `init` 由 GUI `save` 替代（可接受） |
| 配置校验 | `cfopt-go config validate` | `config.validate` | 保存前校验 | 双向 ✓ |
| 配置保存 | （编辑文件） | `config.save` | 设置页保存 | 双向 ✓ |
| 单 DNS 商同步 | `cfopt-go dns cf` / `cfopt-go dns dnspod` | `sync.run` `{providers:["cf"\|"dnspod"]}` | 高级→仅同步 CF / 仅同步 DNSPod | **经 `providers` 过滤实现对等** ✓ |
| 一键全同步 | `cfopt-go sync` | `sync.run`（默认全量） | 主页「一键同步」 | 双向 ✓ |
| 测速 | `cfopt-go speedtest [--output]` | `speedtest.run` | 测速页 | CLI 额外写 `.iplist`；IPC 端已补写 `.iplist`（一致） |
| 历史 | （日志文件） | `history.list` | 历史页 | 双向 ✓ |
| 服务注册 | `cfopt-go schedule install` | `daemon.install` | 服务管理→安装 | 双向 ✓ |
| 服务注销 | `cfopt-go schedule uninstall` | `daemon.uninstall` | 服务管理→卸载 | 双向 ✓ |
| 服务启动 | `cfopt-go schedule start` | `daemon.start` | 服务管理→启动 | 双向 ✓ |
| 服务停止 | `cfopt-go schedule stop` | `daemon.stop` | 服务管理→停止 | 双向 ✓ |
| 服务状态 | — | `daemon.status` | 服务管理→状态 | GUI 独有监控 ✓ |
| 前台调度 | `cfopt-go schedule run [--once]` | （daemon 前台，GUI 不暴露） | — | GUI 用系统服务+sidecar 替代前台 `run` |

**结论**：CLI 的每条命令/子命令均有对应 IPC 方法或 GUI 入口；GUI 经 `sync.run {providers:[...]}` 可精确复现 CLI 的 `dns cf` / `dns dnspod` 细分；CLI 无直接 `daemon.status` / `ping` 等价（GUI 监控增强，不削弱 CLI）。**终端能做的 GUI 都能做，反之亦然**（仅 `config init` / `wizard` 为 TTY/文件便捷工具，GUI 以 `save` 覆盖其"生成配置"语义）。

---

## 7. 已确认决策（用户拍板，2026-07-16，均已 resolved）

1. **测速实现路径**：继续用 `cfst` 外部 sidecar（放弃原生重写）。
2. **GUI 方案**：Tauri v2 + Go sidecar（Rust 仅做 UI + IPC 桥接）。
3. **前端技术栈**：SvelteKit（轻量、最小依赖）。
4. **调度形态**：常驻轻量 daemon + 系统服务注册（Windows Service / systemd / launchd）。
5. **cfst 二进制来源**：各平台二进制置于 `assets/cfst/`，运行时按 `GOOS/GOARCH` 选择。
6. **配置/日志/锁目录**：沿用既有默认位置约定（模块化）。
7. **代码落位**：Go 代码放在 `cfopt-go/`，不直接替换 Bash 代码。
8. **协议命名统一**：`config.Config` 顶部字段补 snake_case 标签（`global/cf_ip/cf_dns/dnspod`）+ `modules` 扩展钩子；`pkg/ipc` 既有 snake_case 契约以测试锁死。
9. **模块化 Provider**：中心 `internal/sync` 仅依赖 `SyncModule` 接口与 `Registry`；新增 DNS 商（如阿里云）只需实现 `SyncModule` + 在 `BuiltinModules` 追加一行（或运行时 `Registry.Register`），GUI 零改动。
10. **`sync.run` 的 `providers` 过滤**：接受此轻量协议扩展（仍在 13 方法边界内），用于对等于 CLI `dns cf` / `dns dnspod`。
11. **`speedtest.run` 写文件**：IPC 端补写 `.iplist`，与 CLI 行为保持一致。
12. **新增 provider 配置校验位置**：因 `config` 包不可 import `dns`，校验下沉到 `SyncModule`（模块内 `Sync` 中校验）。
13. **接入文档**：不写阿里云示例实现，改交付中/英双语接入文档 `docs/providers-guide.zh.md` / `docs/providers-guide.en.md`，指导开发者自行扩展。
