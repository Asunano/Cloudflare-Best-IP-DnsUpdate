# CODEBUDDY.md

This file provides guidance to CodeBuddy Code when working with code in this repository.

## 项目概览

Cloudflare-Best-IP-DnsUpdate 是一个 Cloudflare IP 优选 + DNS 记录自动更新工具。仓库内含**三种形态**的代码，**只有 Go 重写版是活跃开发目标**，其余进入维护态：

| 形态 | 位置 | 状态 |
|---|---|---|
| Go 核心（CLI + 领域层） | `cfopt-go/` | **活跃开发**：新功能优先在此落地，`go build/vet/test ./...` 全绿（约 62 用例） |
| 桌面 GUI（Tauri v2 + SvelteKit） | `tauri/` + `src/` | 基于 Go 核心的 sidecar，经 IPC 调用同一套领域层 |
| Bash 原版 | `cfopt.sh` + `modules/*.sh` + `lib/common.sh` | 维护态，不建议新增功能 |

核心设计目标：**一套纯 Go 领域层（`cfopt-go/internal/`），被 CLI（`cmd/`）与 GUI（Tauri 桥接）共用**。终端能做的 GUI 都能做，反之亦然。

## 常用命令

### Go 核心（主要开发面）

```bash
cd cfopt-go

go build ./...                 # 编译所有包
go build -o cfopt-go .         # 产出二进制 cfopt-go（或 .exe）
go vet ./...                   # 静态检查
go test ./...                  # 运行全部测试（约 60+ 测试文件 / 370+ 用例）
go test ./internal/dns/ -run TestDnspod -v   # 运行单个包的单个测试（用 -run 过滤，testify 断言）
go test ./cmd/ -run TestQA -v -count=1       # 跳过缓存跑某组 QA 测试

go run . version
go run . sync                          # 一键：测速→取最优 IP→同步全部启用模块
go run . speedtest [--output out.iplist]
go run . dns cf                        # 仅同步 Cloudflare
go run . dns dnspod                    # 仅同步 DNSPod（含多运营商分流）
go run . config init                   # 生成配置模板
go run . config validate               # 校验当前配置
go run . schedule install|uninstall|start|stop|status|run   # 平台无关子命令；另有 install-cron/uninstall-cron（Linux）、install-schtasks/uninstall-schtasks（Windows）
go run . serve --ipc-port-file cfopt.ipc   # 拉起 IPC 服务（供 GUI / 冒烟测试）
```

> 模块名为 `cfopt`，要求 Go 1.25+。中国网络环境首次拉依赖：`GOPROXY=https://goproxy.cn,direct go mod tidy`。

### GUI（Tauri v2，需 Rust + cargo + Node 工具链）

```bash
python scripts/gen-icons.py                 # 生成占位图标到 tauri/icons/
powershell -ExecutionPolicy Bypass -File scripts/setup-sidecar.ps1   # Win：构建 Go sidecar → tauri/binaries/
bash scripts/setup-sidecar.sh               # Linux/macOS
npm --prefix src install && npm --prefix src run build
cd tauri && cargo tauri dev                 # 开发模式（热重载）
# 或 cargo tauri build                       # 打包
```

### IPC 冒烟测试

```bash
cd cfopt-go
go run . serve --ipc-port-file cfopt.ipc &   # 后台启动
bash ../scripts/ipc-smoke.sh                  # 读端口→发 ping，期望 {"pong":true}
bash ../scripts/ipc-smoke.sh sync.run '{"providers":["cf"]}'
```

### Bash 原版（维护态，仅本地排障用）

```bash
bash cfopt.sh                                # 主菜单（交互向导）
bash modules/cf-ip/core.sh                   # 非交互测速（供调度器调用）
bash modules/scheduler/run.sh                # 完整调度流程
# 依赖：bash、curl、jq、crontab
```

## 架构（需要跨文件理解的部分）

### 分层与依赖方向（编译期铁律）

```
GUI 集成层：tauri/(Rust 桥接) + src/(SvelteKit)  ──JSON-RPC 2.0 over TCP loopback──┐
CLI 层：cfopt-go/cmd/（cobra 子命令）────────────────────────────────────────────┤
核心领域层：cfopt-go/internal/（纯 Go，零 UI 依赖）◄──────────────────────────────┘
```

依赖方向（违反会 import cycle 或编译失败）：
- `internal/dns` → 可依赖 `internal/config`、`internal/speedtest`；**反向禁止**。
- `pkg/ipc`（GUI 接缝）→ 可依赖 `internal/*`；**严禁 `import cmd`**。
- `cmd` 可依赖 `pkg/ipc` 与 `internal/*`。
- `internal/config` **严禁 `import internal/dns`**：新 provider 的配置校验必须下沉到模块自身的 `Sync` 内（见下）。
- `internal/install`（SelfPlace/ProvisionConf/ensureCFST/HealthPing/RunUninstall）**严禁 `import cmd`、不得调用 `runSchedule`**；调度注册仅由 `cmd/install.go`、`cmd/uninstall.go` 在 `--system` 时触发。

### 模块化 DNS Provider 模式（最重要的扩展点）

中心编排 `internal/sync.Syncer` 只依赖接口 `dns.SyncModule` 与 `dns.Registry`，**完全不感知具体 DNS 商**。一次 `SyncAll` 链路：

```
speedtest.Run → ExtractBestIPs(取最优 N) → 把最优 IP 写入各模块 IPSourceFiles → 遍历 Registry.Modules() 逐个 Sync → 累加 SyncResult 写历史
```

`SyncModule` 四方法：`ID()` / `Enabled(cfg)` / `IPSourceFiles(cfg)` / `Sync(ctx, cfg)`。

新增一个 DNS 商 = 实现 `SyncModule` + 在 `internal/dns` 注册进 `dns.BuiltinModules`（或运行时 `Registry.Register`），中心逻辑零改动，GUI 零改动。详细步骤见 `docs/providers-guide.zh.md`。内置模块：`cfModule`（Cloudflare）、`dnspodModule`（腾讯云，支持单/多运营商分流）。

### 关键 internal 包职责

- `config`：配置加载/校验（loader.go），顶部字段带 snake_case JSON 标签（`global/cf_ip/cf_dns/dnspod`）+ `modules` 扩展钩子。
- `speedtest` + `cfst`：调用外部 `cfst` sidecar 测速，解析结果写 `.iplist`；二进制按 `assets/cfst/cfst-<goos>-<goarch>[.exe]` 探测。
- `dns`：provider 实现 + Registry（cloudflare.go / dnspod*.go / registry.go / model.go）。
- `ipsource`：IP 列表读写（iplist.go / csv.go）。
- `sync`：编排（sync_registry / extract / 单/多线路 sync_perline）。
- `history`：同步历史记录存取（`store.go`），由 `sync` 写入、支撑 IPC 的 `history.list` 方法。
- `scheduler`：常驻 daemon（kardianos/service，跨平台 systemd/launchd/Windows Service）。
- `install` / `update` / `deploy`：安置、升级、部署校验。
- `common`：errors / fslock（进程锁）/ ip 等基础工具。
- `prompt`：TTY 交互路由（交互式向导 vs 非交互）。

### IPC 契约（GUI 接缝）

`cfopt serve` 监听 `127.0.0.1:0`（随机端口），端口写入 `--ipc-port-file`（单行整数，tmp+rename 原子写）。协议：**JSON-RPC 2.0 + JSON Lines**（`\n` 帧，`id` 整数）。13 个方法（全部 snake_case，Go/Rust/TS 三处字段名一致）。深入的契约与类图/时序图见 `docs/system_design.md` 与 `cfopt-go/README.md`：

`ping`、`version`、`config.get`/`config.validate`/`config.save`、`sync.run`(支持 `providers` 过滤 + `progress` 事件流)、`speedtest.run`、`history.list`、`daemon.install`/`uninstall`/`start`/`stop`/`status`。

契约由 `pkg/ipc/*_test.go` 锁死；改动协议必须同步更新 `src/lib/ipc-types.ts` 与 `tauri/src/ipc.rs`。

### 配置与运行约定

- CLI 全局 flag：`--config-dir`（默认 `conf`，相对 cwd）、`--log-level`、`--lock-dir`。
- 配置文件：`conf/{global,cf-ip,cf-dns,dnspod}.json`，模板在 `conf/templates/`，首次运行从模板生成。
- `conf/*.json`、`logs/`、`assets/data/`、`assets/cfst/cfst-*` 均被 `.gitignore` 忽略（运行时产物不入库）。
- 便携安装（`cfopt install`，默认）把二进制+conf 骨架+cfst 同目录落盘，删目录即干净卸载；`--system` 写 PATH 并可选 `--schedule` 常驻。

## 开发约定

- 遵循 ShellCheck（Bash 版）、中文注释、KISS 原则。
- 所有 Go 配置/协议结构使用 snake_case 字段；新增 provider 校验下沉到模块自身。
- 测试用 `testify`；`qa_*` 测试（`cmd/`）覆盖安装/卸载/调度/菜单等端到端场景，可用 `-run TestQA` 过滤。
- 不要直接用 `cmd` 内联调度或安装逻辑；保持 `internal/install` 与 `cmd` 的分层边界。
