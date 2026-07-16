module cfopt

go 1.22

require (
	github.com/cenkalti/backoff/v4 v4.3.0
	github.com/kardianos/service v1.2.2
	github.com/spf13/cobra v1.8.1
	github.com/stretchr/testify v1.9.0
)

require (
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/spf13/pflag v1.0.5 // indirect
	golang.org/x/sys v0.0.0-20201015000850-e3ed0017c211 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// 依赖说明：
//   - github.com/cenkalti/backoff/v4 : dns/http.go 统一重试 + 指数退避（429 重试、401 不重试）。
//   - github.com/kardianos/service   : T8 常驻 daemon 跨平台系统服务注册（Windows Service / systemd / launchd）。
//   - github.com/spf13/cobra         : T10（cmd 子命令树）使用。
//   - github.com/stretchr/testify    : 将在 T13（单元测试）使用。
// 此处按设计文档预先声明；本地首次编译请执行 `go mod tidy` 拉取依赖并生成 go.sum
// （kardianos/service 会带入其依赖，如 github.com/go-ole/go-ole 等，tidy 后会自动补全）。
// 中国网络环境建议：GOPROXY=https://goproxy.cn,direct
