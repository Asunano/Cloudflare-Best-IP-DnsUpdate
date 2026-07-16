// Package dns 实现 DNS 提供方抽象与 Cloudflare / DNSPod 具体实现。
// Cloudflare 与 DNSPod 复用同一套 Record 类型、共享 HTTP 客户端(common/http.go)
// 与 common.ValidateIP / common 日志，避免重复实现传输层与 IP 校验逻辑。
//
// 本文件提供「可挂载 DNS 模块」机制：中心编排（internal/sync）只依赖
// SyncModule 接口与 Registry，完全不感知具体 DNS 商。新增 DNS 商只需：
//  1. 实现 SyncModule 接口；
//  2. 在 BuiltinModules 追加一行（或运行时通过 RegisterAll 注入）；
//  3. 提供自有配置（从 cfg.Modules["<id>"] 或独立子配置读取）。
package dns

import (
	"context"
	"sync"

	"cfopt/internal/config"
)

// SyncModule 可挂载的 DNS 同步模块。internal/sync 中心编排只依赖此接口，不感知具体 DNS 商。
type SyncModule interface {
	// ID 小写短标识（cf / dnspod / aliyun），作为注册键、历史 action 前缀（sync.<id>）、progress phase 值。
	ID() string
	// Enabled 是否启用（未启用→中心跳过，不计入阶段数）。
	Enabled(cfg *config.Config) bool
	// IPSourceFiles 本模块消费的 IP 源文件（中心在 sync 前把最优 IP 写入这些文件）。
	IPSourceFiles(cfg *config.Config) []string
	// Sync 完整智能同步；复用既有 Provider.Sync，返回统计结果 SyncResult。
	Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error)
}

// Registry 持有已注册的 SyncModule，按注册顺序维护（顺序决定 progress 阶段顺序与历史可读性）。
type Registry struct {
	mu      sync.RWMutex
	modules map[string]SyncModule
	order   []string
}

// NewRegistry 构造空 Registry。
func NewRegistry() *Registry {
	return &Registry{modules: make(map[string]SyncModule)}
}

// Register 注册单个模块。重复 ID 覆盖（不重复追加顺序）。
func (r *Registry) Register(m SyncModule) {
	if m == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	id := m.ID()
	if _, ok := r.modules[id]; !ok {
		r.order = append(r.order, id)
	}
	r.modules[id] = m
}

// RegisterAll 批量注册（按切片顺序，逐个 Register）。
func (r *Registry) RegisterAll(ms []SyncModule) {
	for _, m := range ms {
		r.Register(m)
	}
}

// Modules 按注册顺序返回全部已注册模块（无 enabled 过滤）。
func (r *Registry) Modules() []SyncModule {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]SyncModule, 0, len(r.order))
	for _, id := range r.order {
		if m, ok := r.modules[id]; ok {
			out = append(out, m)
		}
	}
	return out
}

// Get 按 ID 取模块；不存在时 (nil, false)。
func (r *Registry) Get(id string) (SyncModule, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.modules[id]
	return m, ok
}

// BuiltinModules 内置模块（显式、确定性顺序）。新增内置 provider：在此追加一行即可。
var BuiltinModules = []SyncModule{cfModule{}, dnspodModule{}}

// ---------------------------------------------------------------------------
// cfModule：薄封装 CloudflareProvider.Sync（零逻辑改动）。
// ---------------------------------------------------------------------------

type cfModule struct{}

// ID 返回模块标识 "cf"。
func (cfModule) ID() string { return "cf" }

// Enabled 当 cf-dns 配置启用时返回 true。
func (cfModule) Enabled(cfg *config.Config) bool {
	return cfg != nil && cfg.CFDNS != nil && cfg.CFDNS.Enabled
}

// IPSourceFiles 返回本模块消费的 IP 源文件（cf-dns.ip_source.file_path）。
func (cfModule) IPSourceFiles(cfg *config.Config) []string {
	if cfg == nil || cfg.CFDNS == nil {
		return nil
	}
	return []string{cfg.CFDNS.IPSource.FilePath}
}

// Sync 复用既有 CloudflareProvider.Sync，保持原逻辑不变。
func (cfModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	return NewCloudflareProvider(cfg.CFDNS).Sync(ctx, cfg.CFDNS)
}

// ---------------------------------------------------------------------------
// dnspodModule：薄封装 DNSPodProvider.Sync（零逻辑改动）。
// ---------------------------------------------------------------------------

type dnspodModule struct{}

// ID 返回模块标识 "dnspod"。
func (dnspodModule) ID() string { return "dnspod" }

// Enabled 当 dnspod 配置启用时返回 true。
func (dnspodModule) Enabled(cfg *config.Config) bool {
	return cfg != nil && cfg.DNSPod != nil && cfg.DNSPod.Enabled
}

// IPSourceFiles 按 mode 返回消费的 IP 源文件：
//   - isp_lines：各线路首个 IP 文件（复用 dnspod 包内 firstIPFile 辅助）
//   - 单线路：ip_file
func (dnspodModule) IPSourceFiles(cfg *config.Config) []string {
	if cfg == nil || cfg.DNSPod == nil {
		return nil
	}
	if cfg.DNSPod.Mode == "isp_lines" {
		var files []string
		for _, conf := range cfg.DNSPod.ISP {
			if f := firstIPFile(conf); f != "" {
				files = append(files, f)
			}
		}
		return files
	}
	return []string{cfg.DNSPod.IPFilePath}
}

// Sync 复用既有 DNSPodProvider.Sync，保持原逻辑不变。
func (dnspodModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	return NewDNSPodProvider(cfg.DNSPod).Sync(ctx, cfg.DNSPod)
}
