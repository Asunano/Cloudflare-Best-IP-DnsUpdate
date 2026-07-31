# 新增 DNS 提供商接入指南（中文）

> 适用版本：cfopt 模块化架构（`internal/dns` + `internal/sync` + `pkg/ipc`）
> 目标读者：希望为 cfopt 接入新 DNS 服务商（如阿里云、华为云、Route53 等）的开发者
> 前置依赖方向铁律：
> - `internal/dns` 可 import `internal/config`；`internal/config` **严禁** import `internal/dns`。
> - 因此**新 provider 的配置校验必须下沉到模块自身**，而非放进 `config` 包。

本指南将带你从零实现一个完整、可被 `cfopt sync`（CLI）与 `sync.run`（IPC / GUI）统一调用的 DNS 模块。

---

## 1. 核心概念

中心编排器 `internal/sync.Syncer` 只依赖一个接口 `dns.SyncModule` 与一个注册表 `dns.Registry`，
**完全不感知具体 DNS 商是哪家**。一次 `SyncAll` 的链路为：

```
测速(speedtest) → 提取最优 N 个 IP → 把最优 IP 写入各模块的 IP 源文件 → 遍历 Registry.Modules() 逐个 Sync
```

每个 `SyncModule` 需要回答四件事：

| 方法 | 含义 | 中心如何使用 |
|---|---|---|
| `ID() string` | 小写短标识，如 `cf` / `dnspod` / `aliyun` | 注册键、历史 `action` 前缀（`sync.<id>`）、progress `phase` 值 |
| `Enabled(cfg *config.Config) bool` | 该模块是否启用 | 未启用→跳过，且不计入总阶段数 |
| `IPSourceFiles(cfg *config.Config) []string` | 该模块消费的 IP 源文件 | 中心在 `sync` 前把最优 IP 写入这些文件 |
| `Sync(ctx, cfg) (*dns.SyncResult, error)` | 完整智能同步 | 复用你自己的 Provider，返回统计结果 |

`SyncResult` 结构（`internal/dns/model.go`）：

```go
type SyncResult struct {
    Updated  int      `json:"updated"`
    Created  int      `json:"created"`
    Deleted  int      `json:"deleted"`
    Errors   []string `json:"errors,omitempty"`
    Warnings []string `json:"warnings,omitempty"`
}
```

---

## 2. 步骤一：实现 `dns.SyncModule`

新建 `internal/dns/<yourprovider>.go`（以虚构的 `mockProvider` 为例）。

```go
package dns

import (
    "context"

    "cfopt/internal/config"
)

// mockModule 是一个最小化可运行的示例 provider（id=mock）。
type mockModule struct{}

func (mockModule) ID() string { return "mock" }

// Enabled：仅当 modules.json 中声明了 mock 且 enabled=true 时启用。
func (mockModule) Enabled(cfg *config.Config) bool {
    raw, ok := cfg.Modules["mock"]
    if !ok {
        return false
    }
    var sub struct {
        Enabled bool `json:"enabled"`
    }
    if err := json.Unmarshal(raw, &sub); err != nil {
        return false
    }
    return sub.Enabled
}

// IPSourceFiles：本模块消费的 IP 源文件（中心会先把最优 IP 写进去）。
func (mockModule) IPSourceFiles(cfg *config.Config) []string {
    raw, ok := cfg.Modules["mock"]
    if !ok {
        return nil
    }
    var sub struct {
        IPFile string `json:"ip_file"`
    }
    _ = json.Unmarshal(raw, &sub) // 模块内自行校验，忽略错误即用零值
    if sub.IPFile == "" {
        return nil
    }
    return []string{sub.IPFile}
}

// Sync：完整智能同步。这里只是示例，真实实现应调用你自己的 Provider.Sync。
func (mockModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
    raw, ok := cfg.Modules["mock"]
    if !ok {
        return &SyncResult{}, nil
    }
    var sub mockConfig
    if err := json.Unmarshal(raw, &sub); err != nil {
        return &SyncResult{Errors: []string{err.Error()}}, err
    }
    // 模块内负责校验自有配置（config 包不可 import dns，故校验在此下沉）。
    if err := sub.Validate(); err != nil {
        return &SyncResult{Errors: []string{err.Error()}}, err
    }
    // 真实场景：return NewMockProvider(sub).Sync(ctx, sub)
    // 此处仅返回空统计，表示“成功但未变更”。
    return &SyncResult{}, nil
}

// mockConfig 是 mock provider 的自有配置子结构（从 modules.json 的 "mock" 键解析）。
type mockConfig struct {
    Enabled bool   `json:"enabled"`
    IPFile  string `json:"ip_file"`
    APIKey  string `json:"api_key"`
}

// Validate 在模块内校验自有配置（不下沉到 config 包）。
func (c mockConfig) Validate() error {
    if c.APIKey == "" {
        return common.New("mock:validate", "api_key 不能为空")
    }
    return nil
}
```

> 说明：上面的 `common` 来自 `cfopt/internal/common`；若需调用真实 DNS API，
> 请参考 `internal/dns/cloudflare.go` 与 `internal/dns/dnspod.go` 中 `Provider.Sync` 的「读 IP 源文件 → 去重校验 → 与线上对比 → 就地更新/删除+创建」实现范式。

---

## 3. 步骤二：把模块接入 Registry（二选一）

### 方式 A：内置追加（推荐，最简洁）

在 `internal/dns/registry.go` 的 `BuiltinModules` 追加一行：

```go
var BuiltinModules = []SyncModule{cfModule{}, dnspodModule{}, mockModule{}}
```

`BuildSyncerFromConfig`（包级函数）会自动用 `BuiltinModules` 构建 Registry，无需任何其它改动。

### 方式 B：外部包运行时挂载

若你的 provider 在 `internal/dns` 之外的包（例如独立插件），有两种注入方式：

**(1) 追加到包级变量**（最简单，需在构建 Syncer 之前执行一次）：

```go
import "cfopt/internal/dns"

func init() {
    // BuiltinModules 是包级 var，可直接追加（顺序即遍历顺序）。
    dns.BuiltinModules = append(dns.BuiltinModules, &external.MyModule{})
}
```

**(2) 自行构造 Registry 后注入 Syncer**（适合需要精细控制注册表的场景）：

```go
reg := dns.NewRegistry()
reg.RegisterAll(dns.BuiltinModules)   // 先注册所有内置模块
reg.Register(&external.MyModule{})    // 再追加外部模块

syncer := sync.NewSyncer(tester, reg, hist)
```

> 注意：`Register` / `RegisterAll` 是 `Registry` 的方法；本架构**未**提供包级 `RegisterModule` 函数，
> 因此外部模块请使用「追加 `dns.BuiltinModules`」或「手动构造 Registry」两种方式之一。

---

## 4. 步骤三：提供配置来源

新 provider 的配置**不要**新增到 `config.Config` 顶层（会破坏 snake_case 契约与依赖方向）。
推荐两种方式：

### 4.1 使用 `modules.json`（推荐）

在配置目录新建 `modules.json`，键为 provider 的 `ID`：

```json
{
  "mock": {
    "enabled": true,
    "ip_file": "./assets/data/mock/ip_list.iplist",
    "api_key": "xxxxxxxx"
  }
}
```

`config.loadDir` 会**增量**读取 `modules.json` 并填入 `Config.Modules`（`map[string]json.RawMessage`），
完全不触碰 `cf-dns.json` / `dnspod.json` 等既有分支。模块内部用 `cfg.Modules["mock"]` 自行解析与校验。

### 4.2 使用独立子配置文件

也可在自己的模块初始化时从独立文件（如 `mock.json`）读取，由模块函数自行加载，与 `config` 包解耦。

---

## 5. 配置校验为何下沉到模块内

`internal/config` 包**严禁** import `internal/dns`（避免依赖环）。因此 `config` 包无法感知
`dns.SyncModule` 的具体结构，也就无法为未知 provider 做校验。设计上把校验职责下放给每个
`SyncModule` 自身（如上面的 `mockConfig.Validate()`）：模块在 `Sync`（或 `Enabled`/`IPSourceFiles`）
内部解析 `cfg.Modules["<id>"]` 并做必填项/格式校验，错误直接以 `*dns.SyncResult.Errors` 与 `error` 返回，
由中心统一汇总进 `SyncSummary.Errors`。

---

## 6. 验证你的 provider

```bash
# 在仓库根目录执行（Go 模块名为 cfopt，cfopt-go 已合并到仓库根）
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=off
go build ./...
go vet ./...
go test ./internal/dns/... ./internal/sync/... ./internal/config/...
```

- 确认 `sync.run`（IPC）与 `cfopt sync`（CLI）在启用你的 provider 时能正确遍历、调用、写历史。
- 用 `sync.run` 的 `providers` 参数可只跑你的模块：`{"method":"sync.run","params":{"providers":["mock"]}}`，
  与 CLI 的 `cfopt dns <mock>` 细分对等。

---

## 7. 最小骨架速查

```go
package dns

import (
    "context"
    "encoding/json"

    "cfopt/internal/common"
    "cfopt/internal/config"
)

type myModule struct{}

func (myModule) ID() string { return "my" }
func (myModule) Enabled(cfg *config.Config) bool {
    raw, ok := cfg.Modules["my"]
    if !ok { return false }
    var s struct{ Enabled bool `json:"enabled"` }
    _ = json.Unmarshal(raw, &s)
    return s.Enabled
}
func (myModule) IPSourceFiles(cfg *config.Config) []string {
    raw, ok := cfg.Modules["my"]
    if !ok { return nil }
    var s struct{ IPFile string `json:"ip_file"` }
    _ = json.Unmarshal(raw, &s)
    return []string{s.IPFile}
}
func (myModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
    raw, ok := cfg.Modules["my"]
    if !ok { return &SyncResult{}, nil }
    var sub myConfig
    if err := json.Unmarshal(raw, &sub); err != nil {
        return &SyncResult{Errors: []string{err.Error()}}, err
    }
    if sub.APIKey == "" {
        return &SyncResult{Errors: []string{"api_key 不能为空"}}, common.New("my:validate", "api_key 不能为空")
    }
    return &SyncResult{}, nil // 真实实现：调用你的 Provider.Sync
}

type myConfig struct {
    Enabled bool   `json:"enabled"`
    IPFile  string `json:"ip_file"`
    APIKey  string `json:"api_key"`
}
```

接入：`var BuiltinModules = []SyncModule{cfModule{}, dnspodModule{}, myModule{}}`。完成。
