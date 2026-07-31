package update

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
)

// 防更新循环保护（对标 Bash 原版 cfopt.sh 的 `.restart_count`）：
// 当 `cfopt update` 连续失败达到阈值时，中止后续更新尝试，避免「坏版本反复下载→反复失败」的死循环。
// 成功更新后计数清零；计数文件与二进制同目录，便于随卸载一起清理。

const (
	// MaxConsecutiveFailures 连续失败达到该次数后触发防循环保护。
	MaxConsecutiveFailures = 3
	// failureCountFileSuffix 计数文件后缀，拼在 currentBin 之后。
	failureCountFileSuffix = ".update_failures"
)

// ErrUpdateLoop 连续更新失败过多，触发防循环保护时返回。
var ErrUpdateLoop = errors.New("update: 连续更新失败过多，已触发防循环保护（请手动排查后删除计数文件再试）")

// failureCountPath 返回计数文件完整路径（与二进制同目录）。
func failureCountPath(bin string) string {
	return bin + failureCountFileSuffix
}

// loadFailureCount 读取连续失败计数；文件不存在或内容非法时回退 0。
func loadFailureCount(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// bumpFailureCount 将连续失败计数 +1 并落盘。
func bumpFailureCount(path string) {
	n := loadFailureCount(path) + 1
	_ = os.WriteFile(path, []byte(strconv.Itoa(n)), 0o644)
}

// resetFailureCount 清零连续失败计数。
func resetFailureCount(path string) {
	_ = os.Remove(path)
}

// RunGuarded 执行一次受防循环保护的自更新：
//   - 若连续失败计数已达阈值，直接返回 ErrUpdateLoop，不发起任何下载；
//   - 否则执行 DownloadAndReplace；成功则清零计数，失败则计数 +1。
//
// 调用方（`cmd/update.go`）应优先使用本函数而非直接调用 DownloadAndReplace，
// 以获得更新循环保护。
func RunGuarded(u *Updater, ctx context.Context, currentBin string, info *ReleaseInfo, opts Options) error {
	statePath := failureCountPath(currentBin)
	if loadFailureCount(statePath) >= MaxConsecutiveFailures {
		return ErrUpdateLoop
	}
	err := u.DownloadAndReplace(ctx, currentBin, info, opts)
	if err != nil {
		bumpFailureCount(statePath)
		return err
	}
	resetFailureCount(statePath)
	return nil
}
