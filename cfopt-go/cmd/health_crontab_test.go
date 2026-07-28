package cmd

import "testing"

func TestCrontabHasCfopt(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    bool
	}{
		{
			name:    "含 cfopt 调度条目",
			content: "0 */6 * * * cd /opt/cfopt && /opt/cfopt/cfopt schedule run --once >> cfopt-cron.log 2>&1\n",
			want:    true,
		},
		{
			name:    "无关条目",
			content: "*/5 * * * * echo hi\n0 3 * * * /usr/bin/backup\n",
			want:    false,
		},
		{
			name:    "空",
			content: "",
			want:    false,
		},
	}
	for _, c := range cases {
		if got := crontabHasCfopt(c.content); got != c.want {
			t.Errorf("%s: crontabHasCfopt=%v want %v", c.name, got, c.want)
		}
	}
}
