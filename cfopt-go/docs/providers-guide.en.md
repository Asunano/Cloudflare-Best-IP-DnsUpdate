# Adding a New DNS Provider — Integration Guide (English)

> Applies to: cfopt-go modular architecture (`internal/dns` + `internal/sync` + `pkg/ipc`)
> Audience: developers who want to add a new DNS vendor (e.g. Aliyun, Huawei Cloud, Route53) to cfopt
> Hard dependency rule:
> - `internal/dns` MAY import `internal/config`; `internal/config` MUST NOT import `internal/dns`.
> - Therefore **config validation for a new provider MUST sink into the module itself**, not into the `config` package.

This guide walks you through implementing a complete DNS module that is uniformly invoked by both
`cfopt sync` (CLI) and `sync.run` (IPC / GUI).

---

## 1. Core Concepts

The central orchestrator `internal/sync.Syncer` depends only on one interface, `dns.SyncModule`, and one
registry, `dns.Registry`. It has **zero knowledge of which DNS vendor** you are using. One `SyncAll` pipeline is:

```
speedtest → extract best N IPs → write best IPs into each module's IP source files → iterate Registry.Modules() and Sync each
```

Each `SyncModule` must answer four things:

| Method | Meaning | How the center uses it |
|---|---|---|
| `ID() string` | lowercase short id, e.g. `cf` / `dnspod` / `aliyun` | registry key, history `action` prefix (`sync.<id>`), progress `phase` value |
| `Enabled(cfg *config.Config) bool` | whether this module is enabled | if not, skip and don't count it as a stage |
| `IPSourceFiles(cfg *config.Config) []string` | IP source files this module consumes | the center writes the best IPs into these files before `sync` |
| `Sync(ctx, cfg) (*dns.SyncResult, error)` | full smart sync | reuse your own Provider, return statistics |

`SyncResult` (in `internal/dns/model.go`):

```go
type SyncResult struct {
    Updated int      `json:"updated"`
    Created int      `json:"created"`
    Deleted int      `json:"deleted"`
    Errors  []string `json:"errors,omitempty"`
}
```

---

## 2. Step 1: Implement `dns.SyncModule`

Create `internal/dns/<yourprovider>.go` (using a fictional `mockProvider` as the example).

```go
package dns

import (
    "context"
    "encoding/json"

    "cfopt/internal/common"
    "cfopt/internal/config"
)

// mockModule is a minimal, runnable example provider (id=mock).
type mockModule struct{}

func (mockModule) ID() string { return "mock" }

// Enabled: enabled only when modules.json declares mock with enabled=true.
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

// IPSourceFiles: the IP source file(s) this module consumes (center writes best IPs there).
func (mockModule) IPSourceFiles(cfg *config.Config) []string {
    raw, ok := cfg.Modules["mock"]
    if !ok {
        return nil
    }
    var sub struct {
        IPFile string `json:"ip_file"`
    }
    _ = json.Unmarshal(raw, &sub) // module validates itself; ignore error -> zero value
    if sub.IPFile == "" {
        return nil
    }
    return []string{sub.IPFile}
}

// Sync: full smart sync. This is a stub; a real impl should call your own Provider.Sync.
func (mockModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
    raw, ok := cfg.Modules["mock"]
    if !ok {
        return &SyncResult{}, nil
    }
    var sub mockConfig
    if err := json.Unmarshal(raw, &sub); err != nil {
        return &SyncResult{Errors: []string{err.Error()}}, err
    }
    // Validating own config inside the module (config pkg cannot import dns, so it sinks here).
    if err := sub.Validate(); err != nil {
        return &SyncResult{Errors: []string{err.Error()}}, err
    }
    // Real case: return NewMockProvider(sub).Sync(ctx, sub)
    return &SyncResult{}, nil
}

// mockConfig is the provider's own sub-config (parsed from the "mock" key of modules.json).
type mockConfig struct {
    Enabled bool   `json:"enabled"`
    IPFile  string `json:"ip_file"`
    APIKey  string `json:"api_key"`
}

// Validate validates the provider's own config internally (not in the config package).
func (c mockConfig) Validate() error {
    if c.APIKey == "" {
        return common.New("mock:validate", "api_key must not be empty")
    }
    return nil
}
```

> Note: `common` comes from `cfopt/internal/common`. For real DNS API calls, follow the
> "read IP source file → dedupe & validate → compare with live records → in-place update / delete+create"
> pattern found in `internal/dns/cloudflare.go` and `internal/dns/dnspod.go`'s `Provider.Sync`.

---

## 3. Step 2: Plug the module into the Registry (pick one)

### Option A: Append to builtins (recommended, simplest)

Add one line to `BuiltinModules` in `internal/dns/registry.go`:

```go
var BuiltinModules = []SyncModule{cfModule{}, dnspodModule{}, mockModule{}}
```

`Syncer.BuildSyncerFromConfig` automatically builds the Registry from `BuiltinModules` — no other changes needed.

### Option B: Register at runtime from an external package

If your provider lives outside `internal/dns` (e.g. a separate plugin), you have two injection styles:

**(1) Append to the package-level var** (simplest; run once before building the Syncer):

```go
import "cfopt/internal/dns"

func init() {
    // BuiltinModules is a package-level var and can be appended (order = iteration order).
    dns.BuiltinModules = append(dns.BuiltinModules, &external.MyModule{})
}
```

**(2) Build the Registry yourself and inject into the Syncer** (fine-grained control):

```go
reg := dns.NewRegistry()
reg.RegisterAll(dns.BuiltinModules)   // register all builtins first
reg.Register(&external.MyModule{})    // then append the external module

syncer := sync.NewSyncer(tester, reg, hist)
```

> Note: `Register` / `RegisterAll` are methods on `Registry`. This architecture does **not** expose a
> package-level `RegisterModule` function, so external modules should use either "append `dns.BuiltinModules`"
> or "construct the Registry manually".

---

## 4. Step 3: Provide the config source

Do **not** add new fields to the top-level `config.Config` (that would break the snake_case contract and the
dependency direction). Two recommended approaches:

### 4.1 Use `modules.json` (recommended)

Create `modules.json` in the config directory, keyed by the provider's `ID`:

```json
{
  "mock": {
    "enabled": true,
    "ip_file": "./assets/data/mock/ip_list.iplist",
    "api_key": "xxxxxxxx"
  }
}
```

`config.loadDir` reads `modules.json` **additively** and fills `Config.Modules` (`map[string]json.RawMessage`),
without touching `cf-dns.json` / `dnspod.json`. The module parses/validates `cfg.Modules["mock"]` itself.

### 4.2 Use a separate sub-config file

You may also load from your own file (e.g. `mock.json`) inside the module's init, decoupled from the `config` package.

---

## 5. Why config validation sinks into the module

The `internal/config` package MUST NOT import `internal/dns` (to avoid an import cycle). Therefore `config`
cannot know about concrete `dns.SyncModule` types and cannot validate unknown providers. By design, validation
is the responsibility of each `SyncModule` (e.g. `mockConfig.Validate()` above): the module parses
`cfg.Modules["<id>"]` inside `Sync` (or `Enabled` / `IPSourceFiles`) and validates required fields / formats,
returning errors via both `*dns.SyncResult.Errors` and the `error` value, which the center aggregates into
`SyncSummary.Errors`.

---

## 6. Verify your provider

```bash
cd cfopt-go
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=off
go build ./...
go vet ./...
go test ./internal/dns/... ./internal/sync/... ./internal/config/...
```

- Confirm that `sync.run` (IPC) and `cfopt sync` (CLI) correctly iterate, invoke, and record history for your provider.
- Use the `providers` parameter of `sync.run` to run only your module:
  `{"method":"sync.run","params":{"providers":["mock"]}}`, mirroring the CLI's per-provider sync.

---

## 7. Minimal skeleton cheat-sheet

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
        return &SyncResult{Errors: []string{"api_key must not be empty"}}, common.New("my:validate", "api_key must not be empty")
    }
    return &SyncResult{}, nil // real impl: call your Provider.Sync
}

type myConfig struct {
    Enabled bool   `json:"enabled"`
    IPFile  string `json:"ip_file"`
    APIKey  string `json:"api_key"`
}
```

Plug in: `var BuiltinModules = []SyncModule{cfModule{}, dnspodModule{}, myModule{}}`. Done.
