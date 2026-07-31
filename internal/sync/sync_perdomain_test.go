package sync

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"cfopt/internal/config"
)

// TestDNSPodDomainSpeedtestJobs_SkipsISPLines 锁死 Task#11 修复：
// isp_lines（多线路）模式的 DNSPod 域名不得进入域名级独立测速（runPerDomainSpeedtest），
// 否则会多跑一次 ~5.5min 的 per-domain 测速，且写好文件也被 step② 逐线路测速覆盖。
// 旧实现中多域名 map 分支漏了 !EqualFold(Mode,"isp_lines") 判断，导致该场景仍生成任务。
func TestDNSPodDomainSpeedtestJobs_SkipsISPLines(t *testing.T) {
	legacy := &config.DNSPodConfig{
		Domain:       "legacy.example.com",
		Enabled:      true,
		Mode:         "isp_lines",
		IPFilePath:   "assets/data/dnspod-dns/legacy.example.com-电信.iplist",
		SpeedTestColo: "HKG",
		TakeIPNum:    5,
	}
	multi := map[string]*config.DNSPodConfig{
		"www.example.com": {
			Domain:        "www.example.com",
			Enabled:       true,
			Mode:          "isp_lines",
			IPFilePath:    "assets/data/dnspod-dns/www.example.com-电信.iplist",
			SpeedTestColo: "HKG",
			TakeIPNum:     5,
		},
		"api.example.com": {
			Domain:        "api.example.com",
			Enabled:       true,
			Mode:          "single", // 单线路：应保留域名级测速
			IPFilePath:    "assets/data/dnspod-dns/api.example.com.iplist",
			SpeedTestColo: "HKG",
			TakeIPNum:     5,
		},
	}
	cfg := &config.Config{DNSPod: legacy, DNSPodDomains: multi}

	jobs := dnspodDomainSpeedtestJobs(cfg)
	var domains []string
	for _, j := range jobs {
		domains = append(domains, j.Domain)
	}

	// isp_lines 的两个域名必须跳过。
	assert.NotContains(t, domains, "legacy.example.com", "legacy isp_lines 域名不应生成域名级测速任务")
	assert.NotContains(t, domains, "www.example.com", "多域名 isp_lines 域名不应生成域名级测速任务")
	// 单线路域名仍应保留。
	assert.Contains(t, domains, "api.example.com", "单线路域名应保留域名级测速任务")
}
