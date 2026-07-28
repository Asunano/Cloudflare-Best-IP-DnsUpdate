package cmd

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// ============================================================================
// F3: System status bar (menu.go - buildStatusLine)
// ============================================================================

// TestBuildStatusLine_allOk all modules normal -> empty string.
func TestBuildStatusLine_allOk(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	// 1) CF-IP: create cf-ip.json
	if err := os.WriteFile(filepath.Join(tmp, "cf-ip.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 2) CF DNS: create cf-dns dir with .conf
	cfDNSDir := filepath.Join(tmp, "cf-dns")
	if err := os.MkdirAll(cfDNSDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfDNSDir, "example.conf"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 3) DNSPod: create dnspod dir with .conf
	dnspodDir := filepath.Join(tmp, "dnspod")
	if err := os.MkdirAll(dnspodDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dnspodDir, "example.conf"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 4) cfst: preset binary
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	cfstDir := filepath.Join(tmp, "assets", "cfst")
	if err := os.MkdirAll(cfstDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}

	line := buildStatusLine()
	if line != "" {
		t.Fatalf("all ok should return empty string, got %q", line)
	}
}

// TestBuildStatusLine_missingCFIP missing cf-ip.json -> shows X CF-IP.
func TestBuildStatusLine_missingCFIP(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	// Create other items
	cfDNSDir := filepath.Join(tmp, "cf-dns")
	os.MkdirAll(cfDNSDir, 0o755)
	os.WriteFile(filepath.Join(cfDNSDir, "example.conf"), []byte("{}"), 0o644)

	dnspodDir := filepath.Join(tmp, "dnspod")
	os.MkdirAll(dnspodDir, 0o755)
	os.WriteFile(filepath.Join(dnspodDir, "example.conf"), []byte("{}"), 0o644)

	line := buildStatusLine()
	if !strings.Contains(line, "\u2717 CF-IP") { // ✗ CF-IP
		t.Fatalf("missing cf-ip.json should contain [✗ CF-IP], got %q", line)
	}
	if !strings.HasPrefix(line, "[\u7cfb\u7edf\u72b6\u6001]") { // [系统状态]
		t.Fatalf("status line should start with [系统状态], got %q", line)
	}
}

// TestBuildStatusLine_missingCFDNS no cf-dns .conf -> shows X CF DNS.
func TestBuildStatusLine_missingCFDNS(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	os.WriteFile(filepath.Join(tmp, "cf-ip.json"), []byte("{}"), 0o644)
	os.MkdirAll(filepath.Join(tmp, "cf-dns"), 0o755) // empty dir

	dnspodDir := filepath.Join(tmp, "dnspod")
	os.MkdirAll(dnspodDir, 0o755)
	os.WriteFile(filepath.Join(dnspodDir, "example.conf"), []byte("{}"), 0o644)

	line := buildStatusLine()
	if !strings.Contains(line, "\u2717 CF DNS") { // ✗ CF DNS
		t.Fatalf("missing cf-dns .conf should contain [✗ CF DNS], got %q", line)
	}
	if !strings.Contains(line, "\u2713 CF-IP") { // ✓ CF-IP
		t.Fatalf("CF-IP ok should show checkmark, got %q", line)
	}
}

// TestBuildStatusLine_missingDNSPod no dnspod .conf -> shows X DNSPod.
func TestBuildStatusLine_missingDNSPod(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	os.WriteFile(filepath.Join(tmp, "cf-ip.json"), []byte("{}"), 0o644)
	cfDNSDir := filepath.Join(tmp, "cf-dns")
	os.MkdirAll(cfDNSDir, 0o755)
	os.WriteFile(filepath.Join(cfDNSDir, "example.conf"), []byte("{}"), 0o644)
	// No dnspod dir

	line := buildStatusLine()
	if !strings.Contains(line, "\u2717 DNSPod") { // ✗ DNSPod
		t.Fatalf("missing dnspod should contain [✗ DNSPod], got %q", line)
	}
}

// TestBuildStatusLine_missingCFST missing cfst binary -> shows X cfst.
func TestBuildStatusLine_missingCFST(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	os.WriteFile(filepath.Join(tmp, "cf-ip.json"), []byte("{}"), 0o644)
	cfDNSDir := filepath.Join(tmp, "cf-dns")
	os.MkdirAll(cfDNSDir, 0o755)
	os.WriteFile(filepath.Join(cfDNSDir, "example.conf"), []byte("{}"), 0o644)
	dnspodDir := filepath.Join(tmp, "dnspod")
	os.MkdirAll(dnspodDir, 0o755)
	os.WriteFile(filepath.Join(dnspodDir, "example.conf"), []byte("{}"), 0o644)
	// No cfst binary

	line := buildStatusLine()
	if !strings.Contains(line, "\u2717 cfst") { // ✗ cfst
		t.Fatalf("missing cfst should contain [✗ cfst], got %q", line)
	}
}

// TestBuildStatusLine_fourModules status line contains all 4 module indicators.
func TestBuildStatusLine_fourModules(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	line := buildStatusLine()
	modules := []string{"CF-IP", "CF DNS", "DNSPod", "cfst"}
	for _, m := range modules {
		if !strings.Contains(line, m) {
			t.Errorf("status line should contain %q, got %q", m, line)
		}
	}
}

// TestBuildStatusLine_allMissing all modules missing -> all X marks.
func TestBuildStatusLine_allMissing(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	line := buildStatusLine()

	if !strings.HasPrefix(line, "[\u7cfb\u7edf\u72b6\u6001]") { // [系统状态]
		t.Errorf("status line should start with [系统状态], got %q", line)
	}
	if !strings.Contains(line, "\u2717 CF-IP") {
		t.Errorf("should show X CF-IP, got %q", line)
	}
	if !strings.Contains(line, "\u2717 CF DNS") {
		t.Errorf("should show X CF DNS, got %q", line)
	}
	if !strings.Contains(line, "\u2717 DNSPod") {
		t.Errorf("should show X DNSPod, got %q", line)
	}
	if !strings.Contains(line, "\u2717 cfst") {
		t.Errorf("should show X cfst, got %q", line)
	}
}
