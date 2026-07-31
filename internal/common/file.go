package common

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// FindLatestFile 在 dir 中按扩展名 exts 过滤，返回 mtime 最新文件的完整路径。
// exts 为扩展名（含点，如 ".csv"）；为空时匹配目录下所有文件。
// 未找到时返回空字符串与 nil 错误。
func FindLatestFile(dir string, exts ...string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", Wrap("file:readdir", err)
	}
	type cand struct {
		path string
		mod  time.Time
	}
	var cands []cand
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if len(exts) > 0 && !matchExt(e.Name(), exts) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		cands = append(cands, cand{path: filepath.Join(dir, e.Name()), mod: info.ModTime()})
	}
	if len(cands) == 0 {
		return "", nil
	}
	sort.Slice(cands, func(i, j int) bool {
		return cands[i].mod.After(cands[j].mod)
	})
	return cands[0].path, nil
}

// matchExt 判断文件名是否匹配给定扩展名（大小写不敏感）。
func matchExt(name string, exts []string) bool {
	for _, ext := range exts {
		if strings.EqualFold(filepath.Ext(name), ext) {
			return true
		}
	}
	return false
}

// ReverseLines 倒序读取文件（用切片反转替代 tac / tail -r），返回行切片（不含换行符）。
func ReverseLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, Wrap("file:open", err)
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, Wrap("file:scan", err)
	}
	// 原地反转
	for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
		lines[i], lines[j] = lines[j], lines[i]
	}
	return lines, nil
}

// FileSize 返回文件字节大小。
func FileSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, Wrap("file:stat", err)
	}
	return info.Size(), nil
}

// MTime 返回文件修改时间。
func MTime(path string) (time.Time, error) {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}, Wrap("file:stat", err)
	}
	return info.ModTime(), nil
}
