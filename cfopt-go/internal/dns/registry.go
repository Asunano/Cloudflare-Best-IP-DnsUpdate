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

// LineSpeedtestJob 单条线路的独立测速任务。
type LineSpeedtestJob struct {
	Line      string             // 线路名（如 默认/联通/移动/电信）
	CFST      *config.CFSTConfig // 该线路独立测速参数（可为 nil，由 buildPerLineCFIP 合并全局）
	IPFiles   []string           // 测速结果应写入的 IP 文件（与 resolver.IPFilesForLine 对应）
	SubDomain string             // 该线路解析出的子域名（便于调试/记录）
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
func (dnspodModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil {
		return res, nil
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		r, err := NewDNSPodProvider(cfg.DNSPod).Sync(ctx, cfg.DNSPod)
		mergeSyncResult(res, r)
		if err != nil {
			res.Errors = append(res.Errors, "dnspod:"+err.Error())
		}
	}
	for _, d := range cfg.DNSPodDomains {
		if d == nil || !d.Enabled {
			continue
		}
		r, err := NewDNSPodProvider(d).Sync(ctx, d)
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

// mergeSyncResult 将单次同步统计累加到目标（计数相加、错误合并）。
func mergeSyncResult(dst *SyncResult, src *SyncResult) {
	if dst == nil || src == nil {
		return
	}
	dst.Updated += src.Updated
	dst.Created += src.Created
	dst.Deleted += src.Deleted
	dst.Errors = append(dst.Errors, src.Errors...)
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
func dnspodJobsForConfig(d *config.DNSPodConfig) []LineSpeedtestJob {
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
			IPFiles:   ipFilesOfISP(conf),
			SubDomain: resolveSubDomain(line, d.SubDomain, d.SubDomains),
		}
		if conf.SpeedTest != nil {
			job.CFST = &config.CFSTConfig{
				Colo:            conf.SpeedTest.Colo,
				Threads:         conf.SpeedTest.Threads,
				DisableDownload: conf.SpeedTest.DisableDownload,
				IPFile:          conf.SpeedTest.IPFile,
			}
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
		jobs = append(jobs, dnspodJobsForConfig(cfg.DNSPod)...)
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled {
			jobs = append(jobs, dnspodJobsForConfig(d)...)
		}
	}
	return jobs
}
