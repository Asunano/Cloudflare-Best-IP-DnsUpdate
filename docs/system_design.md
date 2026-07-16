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
# 1) 放置 Go sidecar 二进制到 tauri/binaries/cfopt-go-<target-triple>[.exe]
#    （externalBin 在 tauri.conf.json 中声明为 "binaries/cfopt-go"）
# 2) 添加应用图标到 tauri/icons/（tauri icon <png> 生成）
# 3) 安装前端依赖并构建
npm --prefix src install && npm --prefix src run build
# 4) Tauri 开发 / 打包
cd tauri && cargo tauri dev      # 或 cargo tauri build
```

> 说明：本仓库此前未提交的 `docs/system_design.md` / `docs/class-diagram.mermaid` /
> `docs/sequence-diagram.mermaid` 在本轮由工程师依据**实际落地代码**补齐，确保文档与实现一致。
