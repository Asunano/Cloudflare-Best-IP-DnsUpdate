# assets/cfst — cfst 测速二进制存放目录

`cfst` 是本项目用于测量 Cloudflare 边缘节点延迟/丢包/下载速度的外部 sidecar 二进制
（设计决策见 redesign 文档 §11 第 1 条：保留 `cfst` 外部二进制，不重写原生测速）。

Go 代码本身**不内置** `cfst`，需要用户按目标平台**自行提供**对应二进制并放置于本目录。

## 放置约定

按 `GOOS/GOARCH` 命名，文件名严格如下：

| 平台 | 文件名 |
|---|---|
| linux/amd64 | `cfst-linux-amd64` |
| linux/arm64 | `cfst-linux-arm64` |
| darwin/amd64 | `cfst-darwin-amd64` |
| darwin/arm64 | `cfst-darwin-arm64` |
| windows/amd64 | `cfst-windows-amd64.exe` |
| windows/arm64 | `cfst-windows-arm64.exe` |

即通用规则：`cfst-<goos>-<goarch>[.exe]`（Windows 需带 `.exe` 后缀）。

## 代码如何探测

- 探测逻辑位于 `internal/speedtest/cfst.go`。
- `NewCFSTTester(cfg)` 在构造时解析 `cfst` 路径：
  1. 优先使用 `cfg.CFSTPath`（即 `cf-ip.json` 中的 `cfst_path` 字段）——可覆盖默认探测；
  2. 否则按 `assets/cfst/cfst-<goos>-<goarch>[.exe]` 自动探测当前运行平台。
- `NewCFSTTester` 会**校验二进制是否存在**；文件不存在时返回明确错误，不会静默失败。

## 用 cf-ip.json 覆盖路径

在 `cf-ip.json` 中可通过 `cfst_path` 字段指定任意绝对/相对路径的 `cfst` 二进制，
从而绕过上面的默认目录探测。示例：

```json
{
  "cfst_path": "/opt/cfst/cfst-linux-amd64",
  "cfst": {
    "directory": "assets/cfst",
    "threads": 50
  }
}
```

> 提示：本目录默认不随仓库分发二进制（体积大且有平台绑定）。
> 从设计文档 §11 第 5 条可知，各平台二进制的获取渠道与版本绑定由 `scripts/version.sh`
> 在 `version.txt` 中记录其 SHA256，可用于客户端完整性校验。
