package speedtest

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/ipsource"
)

const DefaultSpeedtestTimeout = 300 * time.Second

var cloudflareRangeURLs = []string{
	"https://www.cloudflare.com/ips-v4",
	"https://www.cloudflare.com/ips-v6",
}

// CFSTTester 封装外部 cfst 二进制测速。
type CFSTTester struct {
	binPath string

	// HTTPing 为 true 时启用 HTTPing 测速模式（配合 -httping），此时 -cfcolo 地区过滤生效，
	// 且不执行下载测速（结果按延迟排序，无下载速度数据）。
	HTTPing bool

	// Colo 地区过滤（逗号分隔 IATA 码，如 "HKG,NRT"），仅 HTTPing=true 时生效。
	// 空字符串不过滤。
	Colo string

	// Threads 延迟测速线程数（对应 cfst -n），0 表示使用 cfst 内置默认值 200。
	Threads int
}

// NewCFSTTester 自动探测 cfst 二进制路径并返回默认测试器。
// 使用 TCPing + 下载测速模式，不限地区，线程数由 cfst 默认。
func NewCFSTTester() (*CFSTTester, error) {
	t, err := resolveBinary()
	if err != nil {
		return nil, err
	}
	return &CFSTTester{binPath: t}, nil
}

// NewCFSTTesterWithOptions 构造带自定义参数的 CFST 测试器。
//   - colo: 逗号分隔 IATA 地区码，空=不限
//   - httping: true=HTTPing 模式（-cfcolo 仅在此模式下生效），false=TCPing+下载
//   - threads: 测速线程数，0=cfst 内置默认 200
func NewCFSTTesterWithOptions(colo string, httping bool, threads int) (*CFSTTester, error) {
	t, err := resolveBinary()
	if err != nil {
		return nil, err
	}
	return &CFSTTester{binPath: t, Colo: colo, HTTPing: httping, Threads: threads}, nil
}

// resolveBinary 探测 cfst 二进制路径。
func resolveBinary() (string, error) {
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}

	candidates := []string{
		binName,
		filepath.Join("assets", "cfst", binName),
	}
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(exeDir, binName),
			filepath.Join(exeDir, "assets", "cfst", binName),
		)
	}

	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			common.Debug("speedtest:cfst:resolve", "found cfst", "bin", p)
			return p, nil
		}
	}
	return "", common.Wrap("speedtest:cfst:resolve", fmt.Errorf(
		"cfst 二进制不存在\n提示：可运行 `cfopt cfst fetch` 自动下载"))
}

// Run 执行一次 cfst 测速。outputDir 为输出目录。
// 按 CFSTTester 字段构建参数：-o / -f 固定；-httping / -n / -cfcolo 按字段可选。
func (t *CFSTTester) Run(ctx context.Context, outputDir string, progress ProgressFunc) ([]SpeedResult, error) {
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return nil, common.Wrap("speedtest:cfst:mkdir", err)
	}
	ts := time.Now().Format("20060102_150405")
	output := filepath.Join(outputDir, "result_"+ts+".csv")

	ipFile, err := resolveIPFile(ctx, outputDir)
	if err != nil {
		return nil, common.Wrap("speedtest:cfst:ipfile", err)
	}

	// 构建 cfst 参数
	args := []string{"-o", output, "-f", ipFile}

	// HTTPing 模式（-cfcolo 仅在 HTTPing 模式下生效）
	if t.HTTPing {
		args = append(args, "-httping")
	}

	// 线程数
	if t.Threads > 0 {
		args = append(args, "-n", fmt.Sprintf("%d", t.Threads))
	}

	// 地区过滤（仅 HTTPing 模式有效，但传了无害）
	if strings.TrimSpace(t.Colo) != "" {
		args = append(args, "-cfcolo", strings.TrimSpace(t.Colo))
	}

	common.Info("speedtest: 启动 cfst 测速", "bin", t.binPath, "output", output, "args", args)
	if progress != nil {
		progress("speedtest", 0, 1)
	}

	cmd := exec.CommandContext(ctx, t.binPath, args...)
	logFile := filepath.Join(outputDir, "cfst_"+ts+".log")
	logF, err := os.Create(logFile)
	if err != nil {
		return nil, common.Wrap("speedtest:cfst:log", err)
	}
	cmd.Stdout = logF
	cmd.Stderr = logF

	if err := cmd.Run(); err != nil {
		logF.Close()
		return nil, common.Wrap("speedtest:cfst:run", err)
	}
	logF.Close()

	if progress != nil {
		progress("speedtest", 1, 1)
	}
	common.Info("speedtest: 测速完成", "output", output)
	return t.ParseOutput(output)
}

// resolveIPFile 决定传给 cfst -f 的 IP 数据文件：优先 ip.txt 缓存，否则从 Cloudflare 官方拉取。
func resolveIPFile(ctx context.Context, outputDir string) (string, error) {
	defaultPath := filepath.Join(outputDir, "ip.txt")
	if _, err := os.Stat(defaultPath); err == nil {
		return defaultPath, nil
	}
	var sb strings.Builder
	client := &http.Client{Timeout: 30 * time.Second}
	for i, u := range cloudflareRangeURLs {
		// IPv4 与 IPv6 内容间确保换行分隔，否则末行 IPv4 + 首行 IPv6 会粘连成无效 CIDR。
		if i > 0 {
			sb.WriteByte('\n')
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return "", common.Wrap("speedtest:cfst:fetch", err)
		}
		resp, err := client.Do(req)
		if err != nil {
			return "", common.Wrap("speedtest:cfst:fetch "+u, err)
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return "", common.Wrap("speedtest:cfst:fetch "+u, fmt.Errorf("HTTP %d", resp.StatusCode))
		}
		if _, err := io.Copy(&sb, resp.Body); err != nil {
			resp.Body.Close()
			return "", common.Wrap("speedtest:cfst:fetch", err)
		}
		resp.Body.Close()
	}
	// 确保文件末尾有换行（Cloudflare ips-v4 末尾无换行，直接拼会粘连到下一段）。
	sb.WriteByte('\n')
	if err := os.MkdirAll(filepath.Dir(defaultPath), 0o755); err != nil {
		return "", common.Wrap("speedtest:cfst:fetch:mkdir", err)
	}
	if err := os.WriteFile(defaultPath, []byte(sb.String()), 0o644); err != nil {
		return "", common.Wrap("speedtest:cfst:fetch:write", err)
	}
	return defaultPath, nil
}

func (t *CFSTTester) ParseOutput(path string) ([]SpeedResult, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, common.Wrap("speedtest:parse", err)
	}
	defer f.Close()

	var results []SpeedResult
	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		lineNo++
		if lineNo == 1 {
			continue
		}
		if line == "" {
			continue
		}
		parts := strings.Split(line, ",")
		if len(parts) < 7 {
			continue
		}
		s := SpeedResult{
			IP:      strings.TrimSpace(parts[0]),
			Latency: parseFloat(strings.TrimSpace(parts[4])),
			Speed:   parseFloat(strings.TrimSpace(parts[5])),
			Colo:    strings.TrimSpace(parts[6]),
		}
		results = append(results, s)
	}
	return results, scanner.Err()
}

func (t *CFSTTester) ToIPList(results []SpeedResult) []ipsource.IPRecord {
	out := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		out = append(out, ipsource.IPRecord{IP: r.IP, Latency: r.Latency, Speed: r.Speed, Colo: r.Colo})
	}
	return out
}

func parseFloat(s string) float64 {
	s = strings.TrimRight(s, "\r\n ")
	var v float64
	if _, err := fmt.Sscanf(s, "%f", &v); err != nil {
		return 0
	}
	return v
}
