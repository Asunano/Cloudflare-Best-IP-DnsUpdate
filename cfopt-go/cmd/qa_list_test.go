package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cfopt/internal/prompt"
)

// TestRunListConfigs_dirNotExist 验证配置目录不存在时静默跳过并显示「未配置任何域名」。
func TestRunListConfigs_dirNotExist(t *testing.T) {
	tmp := t.TempDir()
	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)
	if !bytes.Contains(out, []byte("未配置任何域名")) {
		t.Fatalf("目录不存在时应提示「未配置任何域名」，实际输出:\n%s", string(out))
	}
	// 应显示统计行
	if !bytes.Contains(out, []byte("共 0 个域名")) {
		t.Fatalf("输出应含「共 0 个域名」，实际:\n%s", string(out))
	}
}

// TestRunListConfigs_emptyDir 验证目录存在但无 .conf 文件时显示空的统计。
func TestRunListConfigs_emptyDir(t *testing.T) {
	tmp := t.TempDir()
	// 创建两个空目录（模拟已初始化但无配置）
	_ = os.MkdirAll(filepath.Join(tmp, "cf-dns"), 0755)
	_ = os.MkdirAll(filepath.Join(tmp, "dnspod"), 0755)

	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)
	if !bytes.Contains(out, []byte("未配置任何域名")) {
		t.Fatalf("空目录时应提示「未配置任何域名」，实际输出:\n%s", string(out))
	}
	if !bytes.Contains(out, []byte("共 0 个域名")) {
		t.Fatalf("输出应含「共 0 个域名」，实际:\n%s", string(out))
	}
}

// TestRunListConfigs_listsDomains 验证目录中有 .conf 文件时会正确列出域名。
func TestRunListConfigs_listsDomains(t *testing.T) {
	tmp := t.TempDir()

	// 创建 cf-dns 和 dnspod 目录，各放一个 .conf 文件
	cfDir := filepath.Join(tmp, "cf-dns")
	dpDir := filepath.Join(tmp, "dnspod")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.MkdirAll(dpDir, 0755)

	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), []byte("dns_token=xxx"), 0600)
	_ = os.WriteFile(filepath.Join(cfDir, "test.org.conf"), []byte("dns_token=yyy"), 0600)
	_ = os.WriteFile(filepath.Join(dpDir, "mydomain.cn.conf"), []byte("id=xxx\ntoken=yyy"), 0600)
	// 非 .conf 文件应被忽略
	_ = os.WriteFile(filepath.Join(dpDir, "ignored.txt"), []byte("noise"), 0600)

	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)

	// 应包含所有域名
	for _, domain := range []string{"example.com", "test.org", "mydomain.cn"} {
		if !bytes.Contains(out, []byte(domain)) {
			t.Fatalf("输出应包含域名 %q，实际输出:\n%s", domain, string(out))
		}
	}
	// 不应包含非 .conf 文件
	if bytes.Contains(out, []byte("ignored")) {
		t.Errorf("非 .conf 文件不应被列出，实际输出:\n%s", string(out))
	}
	// 应显示统计
	if !bytes.Contains(out, []byte("共 3 个域名")) {
		t.Fatalf("输出应含「共 3 个域名」，实际:\n%s", string(out))
	}
	// 不应显示「未配置任何域名」
	if bytes.Contains(out, []byte("未配置任何域名")) {
		t.Errorf("有域名配置时不应提示「未配置任何域名」")
	}
}

// TestRunListConfigs_oneDirMissingOneDirExists 验证一个目录缺失、另一个有文件时的混合场景。
func TestRunListConfigs_oneDirMissingOneDirExists(t *testing.T) {
	tmp := t.TempDir()

	// 只创建 cf-dns，不创建 dnspod
	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "onlycf.com.conf"), []byte("dns_token=xxx"), 0600)

	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)

	if !bytes.Contains(out, []byte("onlycf.com")) {
		t.Fatalf("输出应包含域名 onlycf.com，实际:\n%s", string(out))
	}
	if !bytes.Contains(out, []byte("Cloudflare")) {
		t.Fatalf("输出应包含 Cloudflare 标签，实际:\n%s", string(out))
	}
	if !bytes.Contains(out, []byte("共 1 个域名")) {
		t.Fatalf("输出应含「共 1 个域名」，实际:\n%s", string(out))
	}
	// DNSPod 目录不存在，无条目，不应报错
	if bytes.Contains(out, []byte("警告")) {
		t.Errorf("缺失目录不应输出警告，实际:\n%s", string(out))
	}
}

// TestRunListConfigs_ignoresSubdirectories 验证子目录被忽略（只列出文件）。
func TestRunListConfigs_ignoresSubdirectories(t *testing.T) {
	tmp := t.TempDir()
	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(filepath.Join(cfDir, "subdir"), 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "real.conf"), []byte("dns_token=xxx"), 0600)

	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)

	if !bytes.Contains(out, []byte("real")) {
		t.Fatalf("输出应包含 real.conf 的域名，实际:\n%s", string(out))
	}
	if !bytes.Contains(out, []byte("共 1 个域名")) {
		t.Fatalf("输出应含「共 1 个域名」，实际:\n%s", string(out))
	}
}

// TestRunListConfigs_nonInteractiveNoMenus 验证非交互终端只打印列表，不进入管理菜单。
func TestRunListConfigs_nonInteractiveNoMenus(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	// 创建 cf-dns 目录和一个 .conf 文件
	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), []byte(`{"dns_token":"xxx"}`), 0600)

	// 强制非交互
	prompt.SetInteractiveFunc(func() bool { return false })
	defer prompt.SetInteractiveFunc(nil)

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = runListConfigs()
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}
	out, _ := io.ReadAll(r)
	s := string(out)

	// 应显示域名
	if !bytes.Contains(out, []byte("example.com")) {
		t.Fatalf("非交互终端应列出域名，实际:\n%s", s)
	}
	// 不应包含交互式管理文本
	if bytes.Contains(out, []byte("选择要管理的域名")) {
		t.Errorf("非交互终端不应显示管理选择，实际:\n%s", s)
	}
}

// TestDisplayConfDetail_cloudflare 验证 displayConfDetail 正确显示 Cloudflare 配置详情。
func TestDisplayConfDetail_cloudflare(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)

	// 准备 CF 配置文件
	cfConf := map[string]interface{}{
		"api": map[string]interface{}{
			"zone_id": "zone-abc",
		},
		"dns": map[string]interface{}{
			"record_name": "www",
		},
	}
	data, _ := json.MarshalIndent(cfConf, "", "  ")
	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), data, 0600)

	// 准备 cf-ip.json（含 colo）
	cfIP := map[string]interface{}{
		"cfst": map[string]interface{}{
			"colo": "HKG,NRT",
		},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: filepath.Join(cfDir, "example.com.conf"),
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = displayConfDetail(entry)
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("displayConfDetail 不应失败: %v", err)
	}
	out, _ := io.ReadAll(r)
	s := string(out)

	if !bytes.Contains(out, []byte("Zone ID")) {
		t.Errorf("应显示 Zone ID，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("zone-abc")) {
		t.Errorf("应显示 zone-abc，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("子域名")) {
		t.Errorf("应显示子域名，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("www")) {
		t.Errorf("应显示 www，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("测速地区")) {
		t.Errorf("应显示测速地区，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("HKG,NRT")) {
		t.Errorf("应显示 HKG,NRT，实际:\n%s", s)
	}
}

// TestDisplayConfDetail_dnspod 验证 displayConfDetail 正确显示 DNSPod 配置详情。
func TestDisplayConfDetail_dnspod(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	dpDir := filepath.Join(tmp, "dnspod")
	_ = os.MkdirAll(dpDir, 0755)

	dpConf := map[string]interface{}{
		"sub_domain": "www",
		"mode":       "single",
	}
	data, _ := json.MarshalIndent(dpConf, "", "  ")
	_ = os.WriteFile(filepath.Join(dpDir, "mydomain.cn.conf"), data, 0600)

	entry := domainEntry{
		provider: "DNSPod",
		domain:   "mydomain.cn",
		confPath: filepath.Join(dpDir, "mydomain.cn.conf"),
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	err = displayConfDetail(entry)
	_ = w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatalf("displayConfDetail 不应失败: %v", err)
	}
	out, _ := io.ReadAll(r)
	s := string(out)

	if !bytes.Contains(out, []byte("子域名")) {
		t.Errorf("应显示子域名，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("www")) {
		t.Errorf("应显示 www，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("模式")) {
		t.Errorf("应显示模式，实际:\n%s", s)
	}
	if !bytes.Contains(out, []byte("single")) {
		t.Errorf("应显示 single，实际:\n%s", s)
	}
}

// TestDisplayConfDetail_fileNotExists 验证 conf 文件不存在时不 panic，返回错误。
func TestDisplayConfDetail_fileNotExists(t *testing.T) {
	tmp := t.TempDir()
	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "ghost.com",
		confPath: filepath.Join(tmp, "cf-dns", "ghost.com.conf"),
	}

	err := displayConfDetail(entry)
	if err == nil {
		t.Error("conf 文件不存在时应返回错误")
	}
}

// TestDeleteDomainConfig_defaultNo 验证删除确认默认返回 No（不删除）。
func TestDeleteDomainConfig_defaultNo(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: confPath,
	}

	// 模拟交互终端 + 输入回车（默认 No）
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("\n"))
	defer prompt.SetInput(nil)

	err := deleteDomainConfig(entry)
	if err != nil {
		t.Fatalf("deleteDomainConfig 不应失败: %v", err)
	}

	// 文件应仍然存在
	if _, err := os.Stat(confPath); err != nil {
		t.Errorf("取消删除后文件仍应存在: %v", err)
	}
}

// TestDeleteDomainConfig_confirmYes 验证确认 Y 后实际删除文件。
func TestDeleteDomainConfig_confirmYes(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: confPath,
	}

	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("y\n"))
	defer prompt.SetInput(nil)

	err := deleteDomainConfig(entry)
	if err != nil {
		t.Fatalf("deleteDomainConfig 不应失败: %v", err)
	}

	// 文件应已被删除
	if _, err := os.Stat(confPath); !os.IsNotExist(err) {
		t.Errorf("确认删除后文件应被删除，err=%v", err)
	}
}

// TestEditColoForDomain_callsSaveColoToConfig 验证 editColoForDomain 调用 saveColoToConfig 更新 colo。
func TestEditColoForDomain_callsSaveColoToConfig(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	// 准备 cf-ip.json
	cfIP := map[string]interface{}{
		"cfst": map[string]interface{}{
			"directory": "./assets/cfst",
		},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: confPath,
	}

	// 模拟交互：选择 colo 选项 2（HKG,NRT,LAX）
	// commonColos = ["HKG,NRT", "HKG,NRT,LAX", "HKG", "NRT", "LAX", "SJC", "SEA", ""]
	// 选项 2 = "HKG,NRT,LAX"
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("2\n"))
	defer prompt.SetInput(nil)

	err := editColoForDomain(entry)
	if err != nil {
		t.Fatalf("editColoForDomain 不应失败: %v", err)
	}

	// 验证 cf-ip.json 的 colo 已更新
	updated, _ := os.ReadFile(filepath.Join(tmp, "cf-ip.json"))
	var parsed map[string]interface{}
	_ = json.Unmarshal(updated, &parsed)
	cfst, _ := parsed["cfst"].(map[string]interface{})
	colo, _ := cfst["colo"].(string)
	if colo != "HKG,NRT,LAX" {
		t.Fatalf("cfst.colo 应为 HKG,NRT,LAX，got=%q", colo)
	}
}

// TestEditColoForDomain_clearColo 验证 editColoForDomain 选择空选项可清除 colo。
func TestEditColoForDomain_clearColo(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	cfIP := map[string]interface{}{
		"cfst": map[string]interface{}{
			"directory": "./assets/cfst",
			"colo":      "HKG,NRT",
		},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: confPath,
	}

	// commonColos 最后一个（选项 8）是空串 "不限"
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("8\n"))
	defer prompt.SetInput(nil)

	err := editColoForDomain(entry)
	if err != nil {
		t.Fatalf("editColoForDomain 不应失败: %v", err)
	}

	updated, _ := os.ReadFile(filepath.Join(tmp, "cf-ip.json"))
	var parsed map[string]interface{}
	_ = json.Unmarshal(updated, &parsed)
	cfst, _ := parsed["cfst"].(map[string]interface{})
	colo, _ := cfst["colo"].(string)
	if colo != "" {
		t.Fatalf("cfst.colo 应为空，got=%q", colo)
	}
}

// TestRunListConfigs_interactiveEditColo 验证交互终端下完整流：选择域名 → 修改 colo → 返回。
func TestRunListConfigs_interactiveEditColo(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), []byte(`{"dns_token":"xxx"}`), 0600)

	cfIP := map[string]interface{}{
		"cfst": map[string]interface{}{
			"directory": "./assets/cfst",
		},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	// 交互流：选择域名 1 → 选择"修改 colo"（1）→ 选择 colo 选项 3（HKG）→ 选择"返回主菜单"（4）
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("1\n1\n3\n4\n"))
	defer prompt.SetInput(nil)

	err := runListConfigs()

	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}

	// 验证 cf-ip.json 的 colo 已更新为 HKG
	updated, _ := os.ReadFile(filepath.Join(tmp, "cf-ip.json"))
	var parsed map[string]interface{}
	_ = json.Unmarshal(updated, &parsed)
	cfst, _ := parsed["cfst"].(map[string]interface{})
	colo, _ := cfst["colo"].(string)
	if colo != "HKG" {
		t.Fatalf("交互编辑后 cfst.colo 应为 HKG，got=%q", colo)
	}
}

// TestRunListConfigs_interactiveDeleteConfirmed 验证交互终端下完整流：选择域名 → 删除 → 确认删除。
func TestRunListConfigs_interactiveDeleteConfirmed(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	// 交互流：选择域名 1 → 选择"删除此配置"（3）→ 确认 "y"
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("1\n3\ny\n"))
	defer prompt.SetInput(nil)

	err := runListConfigs()
	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}

	// 文件应已被删除
	if _, err := os.Stat(confPath); !os.IsNotExist(err) {
		t.Errorf("确认删除后 conf 文件应被删除，err=%v", err)
	}
}

// TestRunListConfigs_interactiveDeleteCancelled 验证交互终端下：选择域名 → 删除 → 取消（默认 No）。
func TestRunListConfigs_interactiveDeleteCancelled(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	confPath := filepath.Join(cfDir, "example.com.conf")
	_ = os.WriteFile(confPath, []byte(`{}`), 0600)

	// 交互流：选择域名 1 → 选择"删除此配置"（3）→ 默认 No（回车）
	// 删除取消后 manageDomainConfig 返回 nil（deleteDomainConfig 返回 nil）
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("1\n3\n\n"))
	defer prompt.SetInput(nil)

	err := runListConfigs()
	if err != nil {
		t.Fatalf("runListConfigs 应返回 nil，got=%v", err)
	}

	// 文件应仍然存在
	if _, err := os.Stat(confPath); err != nil {
		t.Errorf("取消删除后文件应存在: %v", err)
	}
}

// TestManageDomainConfig_dirNotFound 验证 cfgDir 目录缺失时静默跳过（已由 TestRunListConfigs_dirNotExist 覆盖）。
// TestManageDomainConfig_confFileNotExist 验证 conf 文件缺失时不 panic，由 displayConfDetail 返回错误。
func TestManageDomainConfig_confFileNotExist(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "ghost.com",
		confPath: filepath.Join(tmp, "cf-dns", "ghost.com.conf"),
	}

	// 不 panic 即可
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	// 选择"返回主菜单"（4）退出
	prompt.SetInput(strings.NewReader("4\n"))
	defer prompt.SetInput(nil)

	err := manageDomainConfig(entry)
	if err != nil {
		t.Fatalf("manageDomainConfig 不应 panic，err=%v", err)
	}
}

// TestManageDomainConfig_hasCfipOption 验证 manageDomainConfig 子菜单包含「修改 CF-IP 参数」选项。
func TestManageDomainConfig_hasCfipOption(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	// 创建必要的配置目录和文件
	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), []byte(`{}`), 0600)
	// 创建 cf-ip.json（runConfigCFIP 需要）
	cfIP := map[string]interface{}{
		"cfst":       map[string]interface{}{},
		"speed_test": map[string]interface{}{},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: filepath.Join(cfDir, "example.com.conf"),
	}

	// 捕获 stdout 验证选项文字
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	// 选 2（修改 CF-IP 参数）→ runConfigCFIP 输入 0 保存退出 → 选 4（返回主菜单）
	prompt.SetInput(strings.NewReader("2\n0\n4\n"))
	defer prompt.SetInput(nil)

	_ = manageDomainConfig(entry)
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	s := string(out)

	// 验证选项文字出现在输出中
	if !strings.Contains(s, "CF-IP") && !strings.Contains(s, "线程/端口/同步数量") {
		t.Errorf("子菜单应包含 CF-IP 参数选项，实际输出:\n%s", s)
	}
}

// TestManageDomainConfig_selectCfipOption 验证 manageDomainConfig 选「修改 CF-IP 参数」后调用 runConfigCFIP。
func TestManageDomainConfig_selectCfipOption(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	cfDir := filepath.Join(tmp, "cf-dns")
	_ = os.MkdirAll(cfDir, 0755)
	_ = os.WriteFile(filepath.Join(cfDir, "example.com.conf"), []byte(`{}`), 0600)
	// 创建 cf-ip.json（runConfigCFIP 需要）
	cfIP := map[string]interface{}{
		"cfst":       map[string]interface{}{},
		"speed_test": map[string]interface{}{},
	}
	ipData, _ := json.MarshalIndent(cfIP, "", "  ")
	_ = os.WriteFile(filepath.Join(tmp, "cf-ip.json"), ipData, 0644)

	entry := domainEntry{
		provider: "Cloudflare",
		domain:   "example.com",
		confPath: filepath.Join(cfDir, "example.com.conf"),
	}

	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	// 选 2（修改 CF-IP 参数）→ runConfigCFIP 输入 0 保存退出 → 选 4（返回主菜单）
	prompt.SetInput(strings.NewReader("2\n0\n4\n"))
	defer prompt.SetInput(nil)

	err := manageDomainConfig(entry)
	if err != nil {
		t.Fatalf("manageDomainConfig 调用 CF-IP 后不应失败，got=%v", err)
	}
}
