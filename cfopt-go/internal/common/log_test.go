package common

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotatingWriter_RotatesAtMaxSize(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "sub", "test.log")

	w, err := newRotatingWriter(logPath, 20) // 小上限便于触发轮转
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	defer w.Close()

	// 首次写入 15 字节，未超阈值，不应轮转。
	if _, err := w.Write([]byte("aaaaaaaaaaaaaaa")); err != nil {
		t.Fatalf("write1: %v", err)
	}
	if _, err := os.Stat(logPath + ".old"); err == nil {
		t.Fatalf("不应在首次未超阈值时轮转")
	}

	// 第二次写入使累计超过 20，触发轮转：旧内容 → .old，新文件重建。
	if _, err := w.Write([]byte("bbbbbbbbbbbbbbb")); err != nil {
		t.Fatalf("write2: %v", err)
	}
	if _, err := os.Stat(logPath + ".old"); err != nil {
		t.Fatalf("应已生成 .old: %v", err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read new: %v", err)
	}
	if !strings.Contains(string(data), "bbbbbbbbbbbbbbb") {
		t.Fatalf("新文件内容错误: %q", string(data))
	}
	if strings.Contains(string(data), "aaaaaaaaaaaaaaa") {
		t.Fatalf("新文件不应含旧内容: %q", string(data))
	}
}
