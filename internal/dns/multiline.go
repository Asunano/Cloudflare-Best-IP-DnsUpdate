package dns

import (
	"context"
	"errors"
	"io/fs"
	"sort"
	"strings"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/ipsource"
)

// LineResolver 把「线路名」解析为子域名与 IP 源文件集合，供 SyncMultiLine 复用。
// 新增 DNS 提供方只需实现 LineResolver + LineAwareProvider 即可接入多线路同步，
// 无需关心集合差算法细节。
type LineResolver interface {
	// ResolveSubDomain 返回某线路对应的子域名（如 DNSPod 线路→子域映射）。
	ResolveSubDomain(line string) string
	// Lines 返回全部待测线路名（如 ["默认","联通","移动","电信"]）。
	Lines() []string
	// IPFilesForLine 返回某线路对应的 IP 源文件集合（用于读取最优 IP）。
	IPFilesForLine(line string) []string
}

// LineAwareProvider 支持「按线路」列/增/删记录的 DNS 提供方（如 DNSPod）。
type LineAwareProvider interface {
	// ListLineRecords 列出某子域名+线路下的 A 记录。
	ListLineRecords(ctx context.Context, domain, subDomain, line string) ([]Record, error)
	// UpsertLineRecord 创建或更新一条记录（按 value 查找已有记录修改，否则新建）。
	UpsertLineRecord(ctx context.Context, domain, subDomain, line, value string, ttl int) error
	// UpdateLineRecord 直接更新指定 ID 的记录为新的 IP 值（不进⾏内部 List，减少 API 调用）。
	// subDomain/line 用于构造 API 请求（DNSPod ModifyRecord 需要这些参数）。
	UpdateLineRecord(ctx context.Context, domain, recordID, subDomain, line, value string, ttl int) error
	// DeleteLineRecord 删除指定 ID 的记录。
	DeleteLineRecord(ctx context.Context, domain, recordID string) error
}

// MultiLineOptions 多线路同步选项。
type MultiLineOptions struct {
	// UnifiedSubDomain 非空时额外写一条统一子域记录（IP 取 DefaultLine 线路 IP；无 DefaultLine 用首线路 IP）。
	UnifiedSubDomain string
	// DefaultLine 统一子域取该线路的 IP（也是 DeleteMode=unified-non-default 的保护线路）。
	DefaultLine string
	// DeleteMode 删除策略：none 不删 | unified 仅删统一子域 | unified-non-default 删统一+非默认线路（保留默认线路）。
	DeleteMode string
	// UnifiedMode 统一子域取 IP 模式："first_line"（默认，取 DefaultLine/首线路 IP）| "global_best"（取全局最优 IP 文件首行）。
	UnifiedMode string
	// GlobalBestFile 统一子域 global_best 模式读取的全局最优 IP 文件（首行 IP）。
	GlobalBestFile string
}

// dnspodNoDataError DNSPod API 的「无数据」特型错误（记录不存在，非认证/参数错误）。
// listRecords 遇此错误视为空列表返回，而非向上抛错。
type dnspodNoDataError struct {
	code string
	msg  string
}

func (e *dnspodNoDataError) Error() string {
	return "dnspod:nodata: " + e.code + ": " + e.msg
}

// IsNoDataError 判断 err 是否为 DNSPod 无数据特型错误。
func IsNoDataError(err error) bool {
	var nd *dnspodNoDataError
	return errors.As(err, &nd)
}

// noDataCodes DNSPod API 的「无数据」错误码集合（记录不存在，确定性错误，无需重试）。
var noDataCodes = map[string]bool{
	"ResourceNotFound.NoDataOfRecord": true,
	"ResourceNotFound.RecordNotFound": true,
	"InvalidParameter.RecordNotFound": true,
	"RecordNotFound":                  true,
}

// SyncMultiLine 多线路集合法 diff 同步（公共抽象，供所有 LineAwareProvider 复用）：
//   - 记录数一致 → 就地更新（UpsertLineRecord 修改已有记录，无 churn）
//   - 否则 → 删多余(旧∩¬目标) + 建缺失(目标∩¬旧)，绝不索引复用已删除记录
//
// 删除是否执行由 DeleteMode 决定（见 isLineDeletable）。UnifiedSubDomain 非空时
// 额外 Upsert 一条统一子域记录。返回累计统计 *SyncResult（保持现有字段，不新增 Skipped）。
func SyncMultiLine(ctx context.Context, resv LineResolver, prov LineAwareProvider, domain string, ttl int, maxPerRecord int, opts MultiLineOptions) *SyncResult {
	res := &SyncResult{}
	// 逐线路同步（每条线路独立 diff）。
	for _, line := range resv.Lines() {
		syncLineDiff(ctx, resv, prov, domain, line, ttl, maxPerRecord, opts, res)
	}
	// 统一子域（可选）收尾。
	syncUnified(ctx, resv, prov, domain, ttl, maxPerRecord, opts, res)
	return res
}

// syncLineDiff 对单条线路执行集合 diff 并写入 res（供 SyncMultiLine 与逐线路即时同步复用）。
func syncLineDiff(ctx context.Context, resv LineResolver, prov LineAwareProvider, domain, line string, ttl, maxPerRecord int, opts MultiLineOptions, res *SyncResult) {
	sub := resv.ResolveSubDomain(line)
	targetIPs, err := readTargetIPs(resv.IPFilesForLine(line), maxPerRecord)
	if err != nil {
		res.Errors = append(res.Errors, line+": "+err.Error())
		return
	}
	if len(targetIPs) == 0 {
		common.Warn("dns: 线路无有效 IP，跳过", "line", line)
		return
	}
	existing, err := prov.ListLineRecords(ctx, domain, sub, line)
	if err != nil {
		res.Errors = append(res.Errors, line+": "+err.Error())
		return
	}
	applyLineDiff(ctx, prov, domain, sub, line, existing, targetIPs, ttl, isLineDeletable(opts, line), res)
}

// syncUnified 统一子域（可选）收尾：在所有线路测速完成后，用聚合 IP 写一条统一子域记录。
// 仅在 opts.UnifiedSubDomain 非空时生效。结果追加进 res。
func syncUnified(ctx context.Context, resv LineResolver, prov LineAwareProvider, domain string, ttl, maxPerRecord int, opts MultiLineOptions, res *SyncResult) {
	if opts.UnifiedSubDomain == "" {
		return
	}
	ip := unifiedIP(resv, opts, maxPerRecord)
	if ip == "" {
		common.Warn("dns: 统一子域无可用 IP，跳过", "sub", opts.UnifiedSubDomain)
		return
	}
	// 统一子域记录的线路：优先 DefaultLine，否则首线路（与 unifiedIP 读取所用线路保持一致）。
	effLine := opts.DefaultLine
	if effLine == "" {
		if ls := resv.Lines(); len(ls) > 0 {
			effLine = ls[0]
		}
	}
	existing, err := prov.ListLineRecords(ctx, domain, opts.UnifiedSubDomain, effLine)
	if err != nil {
		res.Errors = append(res.Errors, "unified: "+err.Error())
		return
	}
	// 统一子域目标为单条记录（取 DefaultLine/首线路 IP）。
	allowDelete := opts.DeleteMode != "none"
	applyLineDiff(ctx, prov, domain, opts.UnifiedSubDomain, effLine, existing, []string{ip}, ttl, allowDelete, res)
}

// applyLineDiff 对单条线路执行集合 diff 并落盘，累计进 res。
// allowDelete=false 时仅创建/更新，绝不删除（固化语义，避免误删线上记录）。
//
// 设计：当线上集合与目标集合「完全相同」（数量与内容均一致）→ 仅按需刷新 TTL，
// 不做任何删除/创建（就地更新，无 churn）；其余情况一律：
//   ① 复用现有记录槽位（UpdateLineRecord 就地更新 IP，避免 Create 触发套餐限制）
//   ② 多余目标则创建、多余旧记录则删除
// 智能更新（①）始终执行，与 allowDelete 无关；删除（③）由 allowDelete 控制。
func applyLineDiff(ctx context.Context, prov LineAwareProvider, domain, sub, line string, existing []Record, targetIPs []string, ttl int, allowDelete bool, res *SyncResult) {
	existingIPs := make([]string, 0, len(existing))
	for _, r := range existing {
		existingIPs = append(existingIPs, r.Content)
	}
	if !needsUpdate(existingIPs, targetIPs) {
		// 集合相同 → 仅刷新 TTL（就地更新，无 churn、无删除）。
		for _, rec := range existing {
			if rec.TTL != ttl {
				if err := prov.UpsertLineRecord(ctx, domain, sub, line, rec.Content, ttl); err != nil {
					res.Errors = append(res.Errors, sub+": "+err.Error())
					continue
				}
				res.Updated++
			}
		}
		return
	}

	// 智能更新：
	//   - 始终优先复用已有记录（直接 UpdateLineRecord 改变 IP），避免 Create 触发套餐限制
	//   - 多余目标则创建、多余旧记录则删除
	//   - allowDelete=false 时只增不删（旧记录保留但智能更新仍就地修改 IP）
	// 注意：updateCount 计算独立于 allowDelete，智能更新始终执行。
	updateCount := len(existing)
	if len(targetIPs) < updateCount {
		updateCount = len(targetIPs)
	}

	// ① 复用已有记录（始终执行）：将前 updateCount 条旧记录的 IP 更新为目标 IP
	for i := 0; i < updateCount; i++ {
		if existing[i].Content != targetIPs[i] {
			if err := prov.UpdateLineRecord(ctx, domain, existing[i].ID, sub, line, targetIPs[i], ttl); err != nil {
				res.Errors = append(res.Errors, sub+": "+err.Error())
				continue
			}
			res.Updated++
		}
	}

	// ② 目标多于旧记录 → 创建缺失的
	for i := updateCount; i < len(targetIPs); i++ {
		if err := prov.UpsertLineRecord(ctx, domain, sub, line, targetIPs[i], ttl); err != nil {
			res.Errors = append(res.Errors, sub+": "+err.Error())
			continue
		}
		res.Created++
	}

	// ③ 旧记录多于目标 → 删除多余的（仅 allowDelete=true 时）
	if allowDelete {
		for i := updateCount; i < len(existing); i++ {
			if err := prov.DeleteLineRecord(ctx, domain, existing[i].ID); err != nil {
				res.Errors = append(res.Errors, sub+": "+err.Error())
				continue
			}
			res.Deleted++
		}
	}
}

// isLineDeletable 根据 DeleteMode 判断某线路记录是否允许被删除。
func isLineDeletable(opts MultiLineOptions, line string) bool {
	switch opts.DeleteMode {
	case "none":
		return false
	case "unified":
		// 仅统一子域可回收，per-line 记录固化（不删）。
		return false
	case "unified-non-default":
		// 默认线路受保护，其余线路可回收。
		if opts.DefaultLine != "" && line == opts.DefaultLine {
			return false
		}
		return true
	default:
		// 空 / 未知 → 视为 none（安全默认：不删）。
		return false
	}
}

// readTargetIPs 从多个 IP 源文件读取并去重校验，最多 maxPerRecord 个（<=0 不限制）。
// 任一文件读取失败整体返回错误；全部为空返回 (nil, nil)。
func readTargetIPs(ipFiles []string, maxPerRecord int) ([]string, error) {
	var raw []ipsource.IPRecord
	for _, f := range ipFiles {
		if strings.TrimSpace(f) == "" {
			continue
		}
		recs, err := ipsource.Read(f)
		if err != nil {
			// IP 源文件不存在时记录警告并跳过（非阻断），首次部署时尚未生成 IP 文件属正常情况。
			// 注意必须用 errors.Is 而非 os.IsNotExist：err 经 CFOptError 多层包装，
			// os.IsNotExist 不走 Unwrap 链，会导致该回退永远不触发（历史 bug）。
			if errors.Is(err, fs.ErrNotExist) {
				common.Warn("dns: IP 源文件未找到，跳过", "file", f)
				continue
			}
			return nil, common.Wrap("dns:multiline:read", err)
		}
		raw = append(raw, recs...)
	}
	if len(raw) == 0 {
		return nil, nil
	}
	return dedupeAndValidate(raw, maxPerRecord), nil
}

// unifiedIP 取统一子域应写入的 IP：
//   - UnifiedMode="global_best"：优先读 GlobalBestFile 首行 IP；缺失/空则回退首线路并 Warn。
//   - 其它（含默认 "first_line"）：优先 DefaultLine 线路的 IP，否则首线路 IP。
func unifiedIP(resv LineResolver, opts MultiLineOptions, maxPerRecord int) string {
	if strings.EqualFold(opts.UnifiedMode, "global_best") {
		if ip := readGlobalBestFirstIP(opts.GlobalBestFile); ip != "" {
			return ip
		}
		common.Warn("dns: unified_mode=global_best 但全局最优文件无有效 IP，回退首线路",
			"file", opts.GlobalBestFile)
		// 继续走首线路回退。
	}
	line := opts.DefaultLine
	if line == "" {
		lines := resv.Lines()
		if len(lines) == 0 {
			return ""
		}
		line = lines[0]
	}
	ips, err := readTargetIPs(resv.IPFilesForLine(line), maxPerRecord)
	if err != nil || len(ips) == 0 {
		return ""
	}
	return ips[0]
}

// readGlobalBestFirstIP 读取全局最优 IP 文件（.iplist/.csv/.txt 自动探测）的首条记录 IP。
// 文件不存在/解析失败/为空均返回空串（交由调用方回退）。
func readGlobalBestFirstIP(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	recs, err := ipsource.Read(path)
	if err != nil {
		common.Warn("dns: 读取全局最优文件失败", "file", path, "err", err.Error())
		return ""
	}
	if len(recs) == 0 {
		return ""
	}
	return recs[0].IP
}

// resolveSubDomain 通用「线路 → 子域名」映射（迁自 DNSPodProvider.subDomainForLine）：
// 优先 sub_domains[line]，回退 subDomain，再回退线路名小写。
func resolveSubDomain(line, subDomain string, subDomains map[string]string) string {
	if subDomains != nil {
		if s, ok := subDomains[line]; ok && s != "" {
			return s
		}
	}
	if subDomain != "" {
		return subDomain
	}
	return strings.ToLower(line)
}

// firstIPFile 取 ISPConf.IPSource.Files 中首个文件路径（通用辅助，迁自 dnspod.go）。
func firstIPFile(conf config.ISPConf) string {
	for _, v := range conf.IPSource.Files {
		return v
	}
	return ""
}

// ipFilesOfISP 返回 ISPConf 下全部 IP 源文件路径（有序：按 map key 排序保证确定性）。
func ipFilesOfISP(conf config.ISPConf) []string {
	keys := make([]string, 0, len(conf.IPSource.Files))
	for k := range conf.IPSource.Files {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	files := make([]string, 0, len(keys))
	for _, k := range keys {
		if f := conf.IPSource.Files[k]; f != "" {
			files = append(files, f)
		}
	}
	return files
}
