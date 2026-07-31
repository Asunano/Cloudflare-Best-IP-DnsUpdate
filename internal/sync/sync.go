package sync

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// Syncer 编排「测速 → 提取最优 IP → 写入各模块 IP 源文件 → 遍历 Registry 同步 → 写历史」主链路。
//
// 中心只依赖 dns.SyncModule 接口与 dns.Registry，完全不感知具体 DNS 商；
// 新增 provider 只需实现 SyncModule 并注册进 Registry，本文件逻辑零改动。
//
// 若某模块实现了可选的 dns.PerLineSpeedtester 且 UsePerLineSpeedtest 为真，
// 则对该模块执行「逐线路独立测速」（各线路用各自 colo 测速并写各自 IP 文件），
// 并跳过全局 writeBestIPs（否则全局 best 会覆盖 per-line 各自文件）。
type Syncer struct {
	tester               speedtest.SpeedTester
	registry             *dns.Registry
	history              history.HistoryStore
	perLineTesterFactory func(colo string, httping bool, threads int) (speedtest.SpeedTester, error)
	// SpeedtestProgress 可选测速进度回调（CLI 渲染进度条 / GUI 推送事件），可为 nil。
	SpeedtestProgress speedtest.ProgressFunc
	// DomainFilter 当不为空时，按域名独立测速和模块同步仅处理该域名（供单域名同步使用）。
	DomainFilter string
}

// NewSyncer 构造 Syncer。
func NewSyncer(tester speedtest.SpeedTester, registry *dns.Registry, hist history.HistoryStore) *Syncer {
	return &Syncer{
		tester:   tester,
		registry: registry,
		history:  hist,
		perLineTesterFactory: func(colo string, httping bool, threads int) (speedtest.SpeedTester, error) {
			return speedtest.NewCFSTTesterWithOptions(colo, httping, threads)
		},
	}
}

// BuildSyncerFromConfig 从配置构造 Syncer（自动构建 CFSTTester 并以 BuiltinModules 注册 Registry）。
// 测速参数由域名配置（speed_test_colo / take_ip_num）驱动，不再需要独立配置文件。
func BuildSyncerFromConfig(cfg *config.Config, hist history.HistoryStore) (*Syncer, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}
	tester, err := speedtest.NewCFSTTester()
	if err != nil {
		return nil, common.Wrap("sync:build:tester", err)
	}
	reg := dns.NewRegistry()
	reg.RegisterAll(dns.BuiltinModules)
	// 注入 history 给 cf 模块（覆盖 BuiltinModules 中的零值 cfModule，启用漂移/过期保护）。
	reg.Register(dns.NewCFModule(hist))
	return NewSyncer(tester, reg, hist), nil
}

// SyncSummary 汇总一次 SyncAll 的执行结果，供 CLI/GUI 展示与历史记录。
// JSON 标签使用 snake_case，与 IPC 协议（GUI/Rust sidecar）约定一致。
type SyncSummary struct {
	Updated  int      `json:"updated"`
	Created  int      `json:"created"`
	Deleted  int      `json:"deleted"`
	Errors   []string `json:"errors"`
	Warnings []string `json:"warnings"`
}

// ProgressFunc 进度回调：phase 为阶段名，cur/total 为已完成/总阶段计数。
type ProgressFunc func(phase string, cur, total int)

// selectModules 确定本次要同步的模块：按注册顺序，要求 Enabled(cfg) 且（providers 为空 或 ID 命中 providers）。
func (s *Syncer) selectModules(cfg *config.Config, providers []string) []dns.SyncModule {
	filter := make(map[string]bool, len(providers))
	for _, p := range providers {
		if p = strings.TrimSpace(p); p != "" {
			filter[p] = true
		}
	}
	onlyFilter := len(filter) > 0

	out := make([]dns.SyncModule, 0, len(s.registry.Modules()))
	for _, m := range s.registry.Modules() {
		if !m.Enabled(cfg) {
			continue
		}
		if onlyFilter && !filter[m.ID()] {
			continue
		}
		out = append(out, m)
	}
	return out
}

// globalScoreOutputDir 全局测速输出目录。
const globalScoreOutputDir = "./assets/data/cf-ip"

// SyncAll 执行完整主链路，返回汇总结果（即使部分失败也尽量返回汇总）。
//  1. 全局模块：tester.Run 测速（失败自动重测）→ ExtractBestIPs → 写各自 IP 文件
//  2. 逐线路模块（dns.PerLineSpeedtester 且启用）：各线路独立测速 → 写各自 IP 文件（跳过全局 best）
//  3. 依次遍历选中模块并 Sync（各模块按 ID 作为 phase 推送进度、以 sync.<id> 写历史）
//  4. 把每次 Sync 的 SyncResult 累加进 summary
//
// onProgress 为可选进度回调（单参，可传 nil）。
// providers 为可选过滤：为空→全部启用模块；非空→仅指定且 Enabled 的 ID。
func (s *Syncer) SyncAll(ctx context.Context, cfg *config.Config, onProgress ProgressFunc, providers ...string) (*SyncSummary, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}

	selected := s.selectModules(cfg, providers)

	var perLineMods []dns.SyncModule
	for _, m := range selected {
		if pl, ok := m.(dns.PerLineSpeedtester); ok && pl.UsePerLineSpeedtest(cfg) {
			perLineMods = append(perLineMods, m)
		}
	}

	var phases []string
	for _, m := range perLineMods {
		pl := m.(dns.PerLineSpeedtester)
		for _, job := range pl.SpeedtestJobs(cfg) {
			phases = append(phases, "speedtest:"+job.Line)
		}
	}
	for _, m := range selected {
		phases = append(phases, m.ID())
	}
	total := len(phases)
	cur := 0
	progress := func(phase string) {
		cur++
		if onProgress != nil {
			onProgress(phase, cur, total)
		}
	}

	summary := &SyncSummary{}

	// ① 按域名独立测速：为每个启用的域名测速并写入其 IP 文件。
	//    不再执行全局测速——每个域名应根据自身配置独立测速，避免浪费时间。
	//    当 s.DomainFilter 非空时只测指定域名。
	//    当 providers 非空时只测选中提供商的域名。
	s.runPerDomainSpeedtest(ctx, cfg, providers...)

	// ② 逐线路模块：各线路独立测速 → 提取 → 写入各自 IP 文件。
	for _, m := range perLineMods {
		pl := m.(dns.PerLineSpeedtester)
		for _, job := range pl.SpeedtestJobs(cfg) {
			if s.DomainFilter != "" && job.Domain != s.DomainFilter {
				continue
			}
			progress("speedtest:" + job.Line)
			outputDir := filepath.Join(globalScoreOutputDir, "perline", sanitizeLine(job.Line))
			httping := true // 一直用 httping（兼容更多线路/地区）
			tester, err := s.perLineTesterFactory(job.Colo, httping, 50)
			if err != nil {
				errMsg := "perline:" + job.Line + ": " + err.Error()
				common.Warn("sync:perline: 构造测速器失败", "line", job.Line, "err", err.Error())
				summary.Errors = append(summary.Errors, errMsg)
				continue
			}
			results, err := tester.Run(ctx, outputDir, s.SpeedtestProgress)
			if err != nil {
				errMsg := "perline:" + job.Line + ": " + err.Error()
				common.Warn("sync:perline: 测速失败", "line", job.Line, "err", err.Error())
				summary.Errors = append(summary.Errors, errMsg)
				continue
			}
			// 如全部下载速度为零，重新完整测速
			if !hasNonZeroSpeed(results) {
				common.Warn("sync:perline: 测速结果全部下载速度为零，重新完整测速", "line", job.Line)
				results, err = tester.Run(ctx, outputDir, s.SpeedtestProgress)
				if err != nil {
					errMsg := "perline:" + job.Line + ":retry: " + err.Error()
					common.Warn("sync:perline: 重测失败", "line", job.Line, "err", err.Error())
					summary.Errors = append(summary.Errors, errMsg)
					continue
				}
			}
			best := ExtractBestIPs(results, takeIPNum(cfg))
			if len(best) == 0 {
				summary.Errors = append(summary.Errors, "perline:"+job.Line+": 未提取到有效 IP")
				common.Warn("sync:perline: 未提取到有效 IP", "line", job.Line)
				continue
			}
			common.Info("sync: 逐线路测速完成", "line", job.Line, "count", len(best))
			if err := s.writeIPListToFiles(best, job.IPFiles); err != nil {
				return summary, common.Wrap("sync:perline:write:"+job.Line, err)
			}
			// 逐线路即时同步：本线路测速完成并写入 iplist 后，立即同步该线路 DNS 记录
			// （而非等全部线路测完再统一 Sync）；统一子域在所有线路测完后的 SyncUnified 收尾。
			if syncer, ok := m.(dns.PerLineSyncer); ok && pl.UsePerLineSpeedtest(cfg) {
				s.syncPerLineNow(ctx, cfg, syncer, job, summary)
			}
		}
	}

	// 逐线路即时同步收尾：所有线路测速完成后，写统一子域记录（需聚合全部线路 IP）。
	for _, m := range perLineMods {
		if syncer, ok := m.(dns.PerLineSyncer); ok {
			s.syncUnifiedNow(ctx, cfg, syncer, summary)
		}
	}

	// ③ 依次同步选中模块（per-line 与 global 一并），并写入历史。
	//     某模块失败不影响其余模块同步，错误汇总到 summary.Errors 中。
	//     逐线路即时同步模块（PerLineSyncer）的 isp_lines 配置已在 step② 逐线路记录历史，
	//     此处仅在该模块整模块 Sync 有实际活动（如单线路配置）时才记一条汇总历史，
	//     避免纯 isp_lines 配置在末尾产生 updated=0 的空历史条目。
	for _, m := range selected {
		progress(m.ID())
		res, err := m.Sync(ctx, cfg)
		accumulate(summary, res)
		if _, isPerLine := m.(dns.PerLineSyncer); !isPerLine || hasActivity(res) {
			s.appendHistory("sync."+m.ID(), res, err)
		}
		if err != nil {
			errMsg := m.ID() + ": " + err.Error()
			common.Warn("sync: 模块同步失败", "module", m.ID(), "err", err.Error())
			summary.Errors = append(summary.Errors, errMsg)
		}
	}

	return summary, nil
}

// SpeedtestJobCount 估算一次 SyncAll 将串行的 cfst 测速次数（供看门狗超时估算）。
// 含：① 按域名独立测速（CF / DNSPod 单线路） + ② 逐线路测速（DNSPod isp_lines）。
// 这两类测速均为串行执行（-n 50 HTTPing），单次耗时可达数分钟，故看门狗必须按总次数估算，
// 而不能像旧公式那样被「线程数」除小——否则多线路域名会结构性超时（见 Task#12）。
// providers 过滤语义与 SyncAll 一致：为空→全部；非空→仅指定且启用的提供商。
func (s *Syncer) SpeedtestJobCount(cfg *config.Config, providers ...string) int {
	count := 0
	if len(providers) == 0 || sliceContains(providers, "cf") {
		count += len(cfDomainColoJobs(cfg))
	}
	if len(providers) == 0 || sliceContains(providers, "dnspod") {
		// dnspodDomainSpeedtestJobs 已对 isp_lines 域名跳过（仅单线路域名计入域名级测速）。
		count += len(dnspodDomainSpeedtestJobs(cfg))
	}
	for _, m := range s.selectModules(cfg, providers) {
		if pl, ok := m.(dns.PerLineSpeedtester); ok && pl.UsePerLineSpeedtest(cfg) {
			count += len(pl.SpeedtestJobs(cfg))
		}
	}
	if count < 1 {
		count = 1
	}
	return count
}

// takeIPNum 返回提取最优 IP 数量。优先读取域名配置的 take_ip_num，默认 5。
func takeIPNum(cfg *config.Config) int {
	n := 5
	if cfg == nil {
		return n
	}
	// 遍历 CF 和 DNSPod 配置，取首个非零 take_ip_num。
	if cfg.CFDNS != nil && cfg.CFDNS.TakeIPNum > 0 {
		return cfg.CFDNS.TakeIPNum
	}
	if cfg.DNSPod != nil && cfg.DNSPod.TakeIPNum > 0 {
		return cfg.DNSPod.TakeIPNum
	}
	for _, d := range cfg.CFDNSDomains {
		if d != nil && d.TakeIPNum > 0 {
			return d.TakeIPNum
		}
	}
	for _, d := range cfg.DNSPodDomains {
		if d != nil && d.TakeIPNum > 0 {
			return d.TakeIPNum
		}
	}
	return n
}
func sanitizeLine(line string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_", " ", "_")
	return replacer.Replace(line)
}

// hasNonZeroSpeed 检查测速结果中是否存在下载速度 > 0 的条目。
func hasNonZeroSpeed(results []speedtest.SpeedResult) bool {
	for _, r := range results {
		if r.Speed > 0 {
			return true
		}
	}
	return false
}

// writeIPListToFiles 将最优 IP 列表写入指定 IP 文件集合（用于逐线路模块）。
func (s *Syncer) writeIPListToFiles(best []ipsource.IPRecord, files []string) error {
	for _, f := range files {
		if strings.TrimSpace(f) == "" {
			continue
		}
		if err := WriteIPList(best, f); err != nil {
			return common.Wrap("sync:write:file:"+f, err)
		}
	}
	return nil
}

// syncPerLineNow 逐线路即时同步：本线路测速完成并写入 iplist 后立即同步该线路 DNS，并记历史。
func (s *Syncer) syncPerLineNow(ctx context.Context, cfg *config.Config, syncer dns.PerLineSyncer, job dns.LineSpeedtestJob, summary *SyncSummary) {
	res, err := syncer.SyncLine(ctx, cfg, job)
	accumulate(summary, res)
	s.appendHistory("sync.dnspod."+sanitizeLine(job.Line), res, err)
	if err != nil {
		common.Warn("sync: 逐线路同步失败", "line", job.Line, "err", err.Error())
		summary.Errors = append(summary.Errors, "perline:"+job.Line+":sync: "+err.Error())
	}
}

// syncUnifiedNow 逐线路即时同步收尾：所有线路测速完成后写统一子域记录，并记历史。
func (s *Syncer) syncUnifiedNow(ctx context.Context, cfg *config.Config, syncer dns.PerLineSyncer, summary *SyncSummary) {
	res, err := syncer.SyncUnified(ctx, cfg)
	accumulate(summary, res)
	if hasActivity(res) {
		s.appendHistory("sync.dnspod.unified", res, err)
	}
	if err != nil {
		common.Warn("sync: 统一子域同步失败", "err", err.Error())
		summary.Errors = append(summary.Errors, "unified:sync: "+err.Error())
	}
}

// hasActivity 判断同步结果是否有实际活动（更新/创建/删除或错误），用于避免记录空历史条目。
func hasActivity(res *dns.SyncResult) bool {
	if res == nil {
		return false
	}
	return res.Updated > 0 || res.Created > 0 || res.Deleted > 0 || len(res.Errors) > 0
}

// accumulate 将单次 Sync 结果累加到汇总中。
func accumulate(summary *SyncSummary, res *dns.SyncResult) {
	if summary == nil || res == nil {
		return
	}
	summary.Updated += res.Updated
	summary.Created += res.Created
	summary.Deleted += res.Deleted
	if len(res.Errors) > 0 {
		summary.Errors = append(summary.Errors, res.Errors...)
	}
	if len(res.Warnings) > 0 {
		summary.Warnings = append(summary.Warnings, res.Warnings...)
	}
}

// cfDomainSpeedtestJob 单个 CF 域名的独立测速任务（按 SpeedTestColo 覆盖测速地区）。
type cfDomainSpeedtestJob struct {
	Domain    string
	Colo      string
	Files     []string
	TakeIPNum int // 来自域配置的 take_ip_num
}

// cfDomainColoJobs 收集启用 CF 域名中配置了 SpeedTestColo 者。
func cfDomainColoJobs(cfg *config.Config) []cfDomainSpeedtestJob {
	var jobs []cfDomainSpeedtestJob
	if cfg == nil {
		return jobs
	}
	add := func(d *config.CFDNSConfig) {
		if d != nil && d.Enabled && strings.TrimSpace(d.SpeedTestColo) != "" {
			tip := d.TakeIPNum
			if tip <= 0 {
				tip = 5
			}
			jobs = append(jobs, cfDomainSpeedtestJob{
				Domain:    d.DNS.Domain,
				Colo:      d.SpeedTestColo,
				Files:     []string{d.IPSource.FilePath},
				TakeIPNum: tip,
			})
		}
	}
	add(cfg.CFDNS)
	for _, d := range cfg.CFDNSDomains {
		add(d)
	}
	return jobs
}

// dnspodDomainSpeedtestJobs 收集启用的 DNSPod 域名，为其生成独立的测速任务（写入域名 IP 文件）。
func dnspodDomainSpeedtestJobs(cfg *config.Config) []cfDomainSpeedtestJob {
	var jobs []cfDomainSpeedtestJob
	if cfg == nil {
		return jobs
	}
	add := func(d *config.DNSPodConfig) {
		// 多线路模式由逐线路测速（step ②）处理，跳过域名级测速避免写无用文件。
		if d != nil && d.Enabled && strings.TrimSpace(d.Domain) != "" && !strings.EqualFold(d.Mode, "isp_lines") {
			tip := d.TakeIPNum
			if tip <= 0 {
				tip = 5
			}
			files := []string{}
			if strings.TrimSpace(d.IPFilePath) != "" {
				files = append(files, d.IPFilePath)
			}
			if len(files) > 0 {
				jobs = append(jobs, cfDomainSpeedtestJob{
					Domain:    d.Domain,
					Colo:      strings.TrimSpace(d.SpeedTestColo), // DNSPod 的 SpeedTestColo（非空时限定测速地区）
					Files:     files,
					TakeIPNum: tip,
				})
			}
		}
	}
	if cfg.DNSPod != nil {
		add(cfg.DNSPod)
	}
	for k, d := range cfg.DNSPodDomains {
		// 多线路模式由逐线路测速（step ②）处理，跳过域名级测速避免写无用文件（与 add 闭包一致）。
		if d != nil && d.Enabled && strings.TrimSpace(d.Domain) != "" && !strings.EqualFold(d.Mode, "isp_lines") {
			tip := d.TakeIPNum
			if tip <= 0 {
				tip = 5
			}
			files := []string{}
			if strings.TrimSpace(d.IPFilePath) != "" {
				files = append(files, d.IPFilePath)
			}
			if len(files) > 0 {
				jobs = append(jobs, cfDomainSpeedtestJob{
					Domain:    k, // 用 map key（完整子域名），确保与 DomainFilter 匹配
					Colo:      strings.TrimSpace(d.SpeedTestColo),
					Files:     files,
					TakeIPNum: tip,
				})
			}
		}
	}
	return jobs
}

// runPerDomainSpeedtest 对启用了独立测速的域名跑测速，覆写该域名 IP 文件。
// 当 s.DomainFilter 不为空时，只测该域名。
// providers 非空时仅测指定提供商的域名（如 "cf"、"dnspod"），用于 quickdeploy 避免串扰。
func (s *Syncer) runPerDomainSpeedtest(ctx context.Context, cfg *config.Config, providers ...string) error {
	var jobs []cfDomainSpeedtestJob
	if len(providers) == 0 || sliceContains(providers, "cf") {
		jobs = append(jobs, cfDomainColoJobs(cfg)...)
	}
	if len(providers) == 0 || sliceContains(providers, "dnspod") {
		jobs = append(jobs, dnspodDomainSpeedtestJobs(cfg)...)
	}
	// 按 DomainFilter 过滤（单域名同步场景）
	if s.DomainFilter != "" {
		filtered := make([]cfDomainSpeedtestJob, 0, len(jobs))
		for _, j := range jobs {
			if j.Domain == s.DomainFilter {
				filtered = append(filtered, j)
			}
		}
		jobs = filtered
	}
	if len(jobs) == 0 {
		return nil
	}
	var firstErr error
	for _, job := range jobs {
		outputDir := filepath.Join(globalScoreOutputDir, "perdomain", sanitizeLine(job.Domain))
		tester, terr := speedtest.NewCFSTTesterWithOptions(job.Colo, true, 50)
		if terr != nil {
			common.Warn("sync:perdomain: 构造测速器失败", "domain", job.Domain, "err", terr.Error())
			if firstErr == nil {
				firstErr = terr
			}
			continue
		}
		results, rerr := tester.Run(ctx, outputDir, s.SpeedtestProgress)
		if rerr != nil {
			common.Warn("sync:perdomain: 测速失败", "domain", job.Domain, "err", rerr.Error())
			if firstErr == nil {
				firstErr = rerr
			}
			continue
		}
		if !hasNonZeroSpeed(results) {
			common.Warn("sync:perdomain: 测速结果全部下载速度为零，重新完整测速", "domain", job.Domain)
			results, rerr = tester.Run(ctx, outputDir, s.SpeedtestProgress)
			if rerr != nil {
				common.Warn("sync:perdomain: 重测失败", "domain", job.Domain, "err", rerr.Error())
				if firstErr == nil {
					firstErr = rerr
				}
				continue
			}
		}
		best := ExtractBestIPs(results, job.TakeIPNum)
		if len(best) == 0 {
			common.Warn("sync:perdomain: 未提取到有效 IP", "domain", job.Domain)
			if firstErr == nil {
				firstErr = common.New("sync:perdomain:"+job.Domain, "未提取到有效 IP")
			}
			continue
		}
		if werr := s.writeIPListToFiles(best, job.Files); werr != nil {
			common.Warn("sync:perdomain: 写入 IP 文件失败", "domain", job.Domain, "err", werr.Error())
			if firstErr == nil {
				firstErr = werr
			}
			continue
		}
		common.Info("sync: 按域名独立测速完成", "domain", job.Domain, "colo", job.Colo, "count", len(best))
	}
	return firstErr
}

// sliceContains 检查字符串切片是否包含目标值。
func sliceContains(slice []string, target string) bool {
	for _, s := range slice {
		if s == target {
			return true
		}
	}
	return false
}

// appendHistory 将一次 Sync 统计写入历史（成功/失败均记录）。
func (s *Syncer) appendHistory(action string, res *dns.SyncResult, syncErr error) {
	if s.history == nil {
		return
	}
	if res == nil {
		res = &dns.SyncResult{}
	}
	detail := fmt.Sprintf("updated=%d created=%d deleted=%d", res.Updated, res.Created, res.Deleted)
	if syncErr != nil {
		detail += " err=" + syncErr.Error()
	}
	if len(res.Errors) > 0 {
		detail += " sub=" + strings.Join(res.Errors, ";")
	}
	entry := history.HistoryEntry{Action: action, Detail: detail, Success: syncErr == nil}
	if err := s.history.Append(entry); err != nil {
		common.Warn("sync: 写入历史失败", "err", err.Error())
	}
}
