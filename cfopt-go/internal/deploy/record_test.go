package deploy

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDeployRecord_AppendAndRead(t *testing.T) {
	dir := t.TempDir()

	require.False(t, IsDomainDeployed(dir, "example.com"), "初始不应有部署记录")

	require.NoError(t, AppendDeployRecord(dir, DeployRecord{
		Provider: "cloudflare", Domain: "example.com", ConfPath: "cf-dns/example.com.conf",
	}))
	// 大小写不敏感匹配
	require.True(t, IsDomainDeployed(dir, "Example.COM"))
	// 重复部署仍可追加（更新语义）
	require.NoError(t, AppendDeployRecord(dir, DeployRecord{
		Provider: "dnspod", Domain: "test.org", ConfPath: "dnspod/test.org.conf",
	}))

	recs, err := ReadDeployRecords(dir)
	require.NoError(t, err)
	require.Len(t, recs, 2)
	assert.False(t, recs[0].CreatedAt.IsZero(), "CreatedAt 应自动填充")

	_, err = os.Stat(filepath.Join(dir, "deploy_record.json"))
	require.NoError(t, err)

	// 读回内容包含域名
	found := map[string]bool{}
	for _, r := range recs {
		found[r.Domain] = true
	}
	assert.True(t, found["example.com"])
	assert.True(t, found["test.org"])
}
