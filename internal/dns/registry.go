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
	"sort"
	"strings"
	"sync"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
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

// PerLineSpeedtester 可选接口：模块若实现它且 UsePerLineSpeedtest 为真，
// 中心编排（internal/sync）将以「逐线路独立测速」方式处理该模块——
// 为每个线路用各自 CFSTConfig 跑测速并写入各自 IP 文件，并跳过全局 writeBestIPs
// （否则全局 best 会覆盖 per-line 各自文件，复活 P0-2）。
type PerLineSpeedtester interface {
	// UsePerLineSpeedtest 是否启用逐线路测速。
	UsePerLineSpeedtest(cfg *config.Config) bool
	// SpeedtestJobs 返回逐线路测速任务列表（每条线路一个 job）。
	SpeedtestJobs(cfg *config.Config) []LineSpeedtestJob
}

// PerLineSyncer 可选接口：与 PerLineSpeedtester 配套——启用逐线路测速的模块，
// 在「逐线路即时同步」模式下由中心编排于每条线路测速完成后立即同步该线路，
// 并在全部线路测速完成后调用 SyncUnified 收尾（统一子域需聚合全部线路 IP）。
// 实现该接口的模块，其 isp_lines 配置在中心 step③ 的整模块 Sync 中被跳过，避免重复同步。
type PerLineSyncer interface {
	// SyncLine 仅同步单条线路（job.Line）的 per-line 子域记录。
	SyncLine(ctx context.Context, cfg *config.Config, job LineSpeedtestJob) (*SyncResult, error)
	// SyncUnified 在所有线路测速完成后收尾同步（如统一子域记录）。
	SyncUnified(ctx context.Context, cfg *config.Config) (*SyncResult, error)
}

// isPerLineEnabled 单条 DNSPod 配置是否处于「逐线路独立测速 + 逐线路即时同步」模式。
func isPerLineEnabled(d *config.DNSPodConfig) bool {
	return d != nil && d.SpeedTestPerISP && strings.EqualFold(d.Mode, "isp_lines")
}

// LineSpeedtestJob 单条线路的独立测速任务。
type LineSpeedtestJob struct {
	Line      string   // 线路名（如 默认/联通/移动/电信）
	Colo      string   // 该线路覆盖的测速地区（空=不过滤，由 ISPConf.SpeedTestColo 提供）
	IPFiles   []string // 测速结果应写入的 IP 文件（与 resolver.IPFilesForLine 对应）
	SubDomain string   // 该线路解析出的子域名（便于调试/记录）
	Domain    string   // 完整域名（含子域），用于 DomainFilter 过滤
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

// 编译期接口实现断言：确保 dnspodModule 完整实现 PerLineSpeedtester（逐线路测速分流）。
var _ PerLineSpeedtester = (dnspodModule{})

// ---------------------------------------------------------------------------
// cfModule：薄封装 CloudflareProvider.Sync（零逻辑改动）。
// ---------------------------------------------------------------------------

type cfModule struct {
	hist history.HistoryStore // 可选：异常漂移/过期检测（默认 nil → 跳过保护）
}

// NewCFModule 构造带历史存储的 cfModule（供 BuildSyncerFromConfig 注入 history）。
// 历史为 nil 时仍执行 token/hostname 校验红线，仅跳过线上重查与漂移/过期历史。
func NewCFModule(hist history.HistoryStore) SyncModule {
	return cfModule{hist: hist}
}

// ID 返回模块标识 "cf"。
func (cfModule) ID() string { return "cf" }

// Enabled 当单值 cf-dns 启用、或多域名任一域名启用时返回 true。
func (cfModule) Enabled(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		return true
	}
	for _, d := range cfg.CFDNSDomains {
		if d != nil && d.Enabled {
			return true
		}
	}
	return false
}

// IPSourceFiles 返回本模块消费的 IP 源文件（单值 cf-dns + 各启用域名的 ip_source.file_path）。
func (cfModule) IPSourceFiles(cfg *config.Config) []string {
	if cfg == nil {
		return nil
	}
	var files []string
	if cfg.CFDNS != nil {
		files = append(files, cfg.CFDNS.IPSource.FilePath)
	}
	for _, d := range cfg.CFDNSDomains {
		if d != nil && d.Enabled {
			files = append(files, d.IPSource.FilePath)
		}
	}
	return files
}

// cfSyncOne 对单个 CFDNSConfig 执行同步（带/不带历史）。
func (m cfModule) cfSyncOne(ctx context.Context, d *config.CFDNSConfig) (*SyncResult, error) {
	if m.hist != nil {
		return NewCloudflareProviderWithHistory(d, m.hist).Sync(ctx, d)
	}
	return NewCloudflareProvider(d).Sync(ctx, d)
}

// Sync 遍历单值 cf-dns 与各启用域名，逐域名调用 NewCloudflareProvider(d).Sync，累计结果。
func (m cfModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil {
		return res, nil
	}
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		r, err := m.cfSyncOne(ctx, cfg.CFDNS)
		mergeSyncResult(res, r)
		if err != nil {
			res.Errors = append(res.Errors, "cf:"+err.Error())
		}
	}
	for _, d := range cfg.CFDNSDomains {
		if d == nil || !d.Enabled {
			continue
		}
		r, err := m.cfSyncOne(ctx, d)
		mergeSyncResult(res, r)
		if err != nil {
			res.Errors = append(res.Errors, "cf:"+err.Error())
		}
	}
	if len(res.Errors) > 0 {
		return res, common.New("cf:sync", strings.Join(res.Errors, "; "))
	}
	return res, nil
}

// ---------------------------------------------------------------------------
// dnspodModule：薄封装 DNSPodProvider.Sync（零逻辑改动）。
// ---------------------------------------------------------------------------

type dnspodModule struct{}

// ID 返回模块标识 "dnspod"。
func (dnspodModule) ID() string { return "dnspod" }

// Enabled 当单值 dnspod 启用、或多域名任一域名启用时返回 true（Domains map 非空则遍历，各域名 Enabled 过滤）。
func (dnspodModule) Enabled(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		return true
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled {
			return true
		}
	}
	return false
}

// dnspodFilesForConfig 返回单个 DNSPodConfig 消费的 IP 源文件（按 mode：isp_lines 各线路首个 / 单线路 ip_file）。
func dnspodFilesForConfig(d *config.DNSPodConfig) []string {
	if d == nil {
		return nil
	}
	if d.Mode == "isp_lines" {
		var files []string
		for _, conf := range d.ISP {
			if f := firstIPFile(conf); f != "" {
				files = append(files, f)
			}
		}
		return files
	}
	return []string{d.IPFilePath}
}

// IPSourceFiles 按 mode 返回全部（单值 + 各启用域名）消费的 IP 源文件。
func (dnspodModule) IPSourceFiles(cfg *config.Config) []string {
	if cfg == nil {
		return nil
	}
	var files []string
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		files = append(files, dnspodFilesForConfig(cfg.DNSPod)...)
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled {
			files = append(files, dnspodFilesForConfig(d)...)
		}
	}
	return files
}

// Sync 遍历单值 dnspod 与各启用域名，逐域名调用 NewDNSPodProvider(d).Sync（内部仍走 isp_lines 多线路），累计结果。
// 注意：处于「逐线路即时同步」模式的配置（isp_lines + SpeedTestPerISP）由中心编排在 step② 逐线路 SyncLine +
// 末尾 SyncUnified 完成，此处**跳过**以免重复同步；仅同步单线路（及非逐线路）配置。
func (m dnspodModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil {
		return res, nil
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled && !isPerLineEnabled(cfg.DNSPod) {
		r, err := NewDNSPodProviderWithDataDir(cfg.DNSPod, ResolveDataDir(cfg)).Sync(ctx, cfg.DNSPod)
		mergeSyncResult(res, r)
		if err != nil {
			res.Errors = append(res.Errors, "dnspod:"+err.Error())
		}
	}
	for _, d := range cfg.DNSPodDomains {
		if d == nil || !d.Enabled || isPerLineEnabled(d) {
			continue
		}
		r, err := NewDNSPodProviderWithDataDir(d, ResolveDataDir(cfg)).Sync(ctx, d)
		mergeSyncResult(res, r)
		if err != nil {
			res.Errors = append(res.Errors, "dnspod:"+err.Error())
		}
	}
	if len(res.Errors) > 0 {
		return res, common.New("dnspod:sync", strings.Join(res.Errors, "; "))
	}
	return res, nil
}

// findDNSPodConfig 按完整域名（job.Domain，单值取 cfg.DNSPod.Domain，多域名取 map key）定位 DNSPodConfig。
func findDNSPodConfig(cfg *config.Config, domain string) (*config.DNSPodConfig, bool) {
	if cfg == nil {
		return nil, false
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Domain == domain {
		return cfg.DNSPod, true
	}
	if d, ok := cfg.DNSPodDomains[domain]; ok {
		return d, true
	}
	return nil, false
}

// dnspodOptionsForConfig 由单条 DNSPod 配置构造 MultiLineOptions（与 provider.Sync 保持一致）。
func dnspodOptionsForConfig(d *config.DNSPodConfig) MultiLineOptions {
	return MultiLineOptions{
		UnifiedSubDomain: d.SubDomainUnified,
		DefaultLine:      d.DefaultLine,
		DeleteMode:       d.DeleteMode,
		UnifiedMode:      d.SubDomainUnifiedMode,
		GlobalBestFile:   d.UnifiedGlobalBestFile,
	}
}

// SyncLine 逐线路即时同步：仅对 job.Line 的 per-line 子域记录做集合 diff（在中心 step② 每条线路测速完成后调用）。
func (m dnspodModule) SyncLine(ctx context.Context, cfg *config.Config, job LineSpeedtestJob) (*SyncResult, error) {
	d, ok := findDNSPodConfig(cfg, job.Domain)
	if !ok || !isPerLineEnabled(d) {
		return &SyncResult{}, nil
	}
	p := NewDNSPodProviderWithDataDir(d, ResolveDataDir(cfg))
	resv := NewDNSPodLineResolver(d)
	res := &SyncResult{}
	// 注意：job.Domain 是多域名配置的 map key（完整主机名，如 mmmmm.drxian.cn），
	// 仅用于定位配置与 DomainFilter 过滤；传给 DNSPod API 的 Domain 必须是注册主域名（d.Domain，如 drxian.cn），
	// 子域由 resolver 经 d.SubDomain/d.SubDomains 解析后放入 SubDomain 字段。否则 DNSPod 报 DomainNotExists。
	syncLineDiff(ctx, resv, p, d.Domain, job.Line, p.ttl, d.MaxIPsPerRecord, dnspodOptionsForConfig(d), res)
	return res, nil
}

// SyncUnified 逐线路即时同步的收尾：在所有线路测速完成后，对每个启用 isp_lines 配置写统一子域记录。
func (m dnspodModule) SyncUnified(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil {
		return res, nil
	}
	dataDir := ResolveDataDir(cfg)
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled && isPerLineEnabled(cfg.DNSPod) {
		m.syncUnifiedForConfig(ctx, cfg.DNSPod, cfg.DNSPod.Domain, dataDir, res)
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled && isPerLineEnabled(d) {
			// 统一子域收尾同样必须用注册主域名 d.Domain，而非 map key（完整主机名）。
			m.syncUnifiedForConfig(ctx, d, d.Domain, dataDir, res)
		}
	}
	if len(res.Errors) > 0 {
		return res, common.New("dnspod:sync-unified", strings.Join(res.Errors, "; "))
	}
	return res, nil
}

// syncUnifiedForConfig 对单条 isp_lines 配置收尾同步统一子域。
func (m dnspodModule) syncUnifiedForConfig(ctx context.Context, d *config.DNSPodConfig, domain, dataDir string, res *SyncResult) {
	p := NewDNSPodProviderWithDataDir(d, dataDir)
	resv := NewDNSPodLineResolver(d)
	syncUnified(ctx, resv, p, domain, p.ttl, d.MaxIPsPerRecord, dnspodOptionsForConfig(d), res)
}

// mergeSyncResult 将单次同步统计累加到目标（计数相加、错误合并）。
func mergeSyncResult(dst *SyncResult, src *SyncResult) {
	if dst == nil || src == nil {
		return
	}
	dst.Updated += src.Updated
	dst.Created += src.Created
	dst.Deleted += src.Deleted
	dst.Errors = append(dst.Errors, src.Errors...)
	dst.Warnings = append(dst.Warnings, src.Warnings...)
}

// ---- PerLineSpeedtester 实现（逐线路独立测速） ----

// UsePerLineSpeedtest 当单值或任一启用域名开启 speed_test_per_isp 且 mode=isp_lines 时返回 true。
func (dnspodModule) UsePerLineSpeedtest(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	if cfg.DNSPod != nil && cfg.DNSPod.SpeedTestPerISP && strings.EqualFold(cfg.DNSPod.Mode, "isp_lines") {
		return true
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.SpeedTestPerISP && strings.EqualFold(d.Mode, "isp_lines") {
			return true
		}
	}
	return false
}

// dnspodJobsForConfig 按单个 DNSPodConfig 的 ISP map 各线路生成独立测速任务。
func dnspodJobsForConfig(domain string, d *config.DNSPodConfig) []LineSpeedtestJob {
	if d == nil || !strings.EqualFold(d.Mode, "isp_lines") {
		return nil
	}
	lines := make([]string, 0, len(d.ISP))
	for line := range d.ISP {
		lines = append(lines, line)
	}
	sort.Strings(lines)

	jobs := make([]LineSpeedtestJob, 0, len(lines))
	for _, line := range lines {
		conf := d.ISP[line]
		job := LineSpeedtestJob{
			Line:      line,
			Colo:      conf.SpeedTestColo,
			IPFiles:   ipFilesOfISP(conf),
			SubDomain: resolveSubDomain(line, d.SubDomain, d.SubDomains),
			Domain:    domain,
		}
		jobs = append(jobs, job)
	}
	return jobs
}

// SpeedtestJobs 汇总单值与各启用域名的逐线路测速任务。
func (dnspodModule) SpeedtestJobs(cfg *config.Config) []LineSpeedtestJob {
	if cfg == nil {
		return nil
	}
	var jobs []LineSpeedtestJob
	if cfg.DNSPod != nil {
		jobs = append(jobs, dnspodJobsForConfig(cfg.DNSPod.Domain, cfg.DNSPod)...)
	}
	for k, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled {
			jobs = append(jobs, dnspodJobsForConfig(k, d)...)
		}
	}
	return jobs
}
