package deploy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// DeployRecord 一条部署记录（对应 Bash 原版 deploy_record.json / deployments.json）。
// 用于部署历史持久化与重复部署检测。
type DeployRecord struct {
	Provider         string    `json:"provider"`          // cloudflare | dnspod
	Domain           string    `json:"domain"`            // 根域名
	SubDomain        string    `json:"sub_domain,omitempty"`
	ZoneID           string    `json:"zone_id,omitempty"`
	Lines            []string  `json:"lines,omitempty"`
	Colo             string    `json:"colo,omitempty"`
	TakeIPNum        int       `json:"take_ip_num,omitempty"`
	ScheduleInterval string    `json:"schedule_interval,omitempty"`
	ConfPath         string    `json:"conf_path"` // 配置文件相对/绝对路径
	CreatedAt        time.Time `json:"created_at"`
}

// deployRecordFile 部署记录文件名（位于 cfgDir 下）。
const deployRecordFile = "deploy_record.json"

func deployRecordPath(cfgDir string) string {
	return filepath.Join(cfgDir, deployRecordFile)
}

// ReadDeployRecords 读取全部部署记录；文件不存在返回空切片（非错误）。
func ReadDeployRecords(cfgDir string) ([]DeployRecord, error) {
	data, err := os.ReadFile(deployRecordPath(cfgDir))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var recs []DeployRecord
	if err := json.Unmarshal(data, &recs); err != nil {
		return nil, err
	}
	return recs, nil
}

// AppendDeployRecord 追加一条部署记录并原子写回（temp + rename）。
func AppendDeployRecord(cfgDir string, r DeployRecord) error {
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now()
	}
	recs, err := ReadDeployRecords(cfgDir)
	if err != nil {
		return err
	}
	recs = append(recs, r)
	data, err := json.MarshalIndent(recs, "", "  ")
	if err != nil {
		return err
	}
	dst := deployRecordPath(cfgDir)
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// IsDomainDeployed 判断某域名是否已部署过（大小写不敏感匹配）。
func IsDomainDeployed(cfgDir, domain string) bool {
	recs, err := ReadDeployRecords(cfgDir)
	if err != nil {
		return false
	}
	d := strings.ToLower(strings.TrimSpace(domain))
	for _, r := range recs {
		if strings.ToLower(strings.TrimSpace(r.Domain)) == d {
			return true
		}
	}
	return false
}
