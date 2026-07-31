#!/usr/bin/env bash
#
# build.sh — cfopt 交叉编译脚本 (POSIX bash)
#
# 用法:
#   ./scripts/build.sh                                   # 编译全部 6 个平台矩阵
#   GOOS=linux  GOARCH=amd64 ./scripts/build.sh          # 仅编译单个平台
#
# 中国网络环境下，首次构建前请设置 Go 代理以加速模块下载:
#   export GOPROXY=https://goproxy.cn,direct
#   （设置后可再执行 go build；本脚本本身只负责编译与版本注入）
#
# 说明:
#   - 交叉编译矩阵: CGO_ENABLED=0 × {linux,darwin,windows} × {amd64,arm64}
#   - 产物输出到: dist/cfopt-<goos>-<goarch>[.exe]
#   - 版本号从 version.txt 首行 (VERSION:<ver>) 注入到 cfopt/cmd.Version
#   - 每个二进制构建后打印绝对路径并用 sha256sum 输出其 SHA256 校验值
#   - 使用 CGO_ENABLED=0 生成纯静态二进制，便于跨平台无依赖分发
#
set -euo pipefail

# 切到仓库根目录（脚本可放于 scripts/ 任意位置调用）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 读取版本号（version.txt 首行: VERSION:<ver>）
# 若文件缺失或首行无版本，则回退为 dev
# ---------------------------------------------------------------------------
if [ -f version.txt ]; then
  VERSION="$(head -1 version.txt | cut -d: -f2)"
fi
if [ -z "${VERSION:-}" ]; then
  VERSION="dev"
fi

# 构建元信息：git commit 与构建时间（可经环境变量 COMMIT / BUILT_AT 覆盖）。
# 仅在未显式指定时自动探测，避免无 git 环境或离线时失败。
if [ -z "${COMMIT:-}" ] && command -v git >/dev/null 2>&1; then
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
fi
if [ -z "${BUILT_AT:-}" ]; then
  BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# 版本注入：cmd.Version / Commit / BuiltAt 由 cmd/version.go 提供，供 ldflags 覆盖
LDFLAGS="-X cfopt/cmd.Version=${VERSION} -X cfopt/cmd.Commit=${COMMIT} -X cfopt/cmd.BuiltAt=${BUILT_AT}"

# ---------------------------------------------------------------------------
# build_one: 编译单个平台并输出路径 + SHA256
#   $1 = GOOS
#   $2 = GOARCH
# ---------------------------------------------------------------------------
build_one() {
  local goos="$1"
  local goarch="$2"
  local ext=""

  if [ "$goos" = "windows" ]; then
    ext=".exe"
  fi

  local out="dist/cfopt-${goos}-${goarch}${ext}"

  mkdir -p dist

  echo "==> 构建 ${out} (${goos}/${goarch})"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "$LDFLAGS" -o "$out" .

  # 输出产物绝对路径与 SHA256 校验值
  echo "产物: $(pwd)/${out}"
  echo "SHA256: $(sha256sum "$out" | cut -d' ' -f1)"
  echo
}

# ---------------------------------------------------------------------------
# 入口：若已通过环境变量指定单平台则仅编译该平台，否则遍历完整矩阵
# ---------------------------------------------------------------------------
if [ -n "${GOOS:-}" ] && [ -n "${GOARCH:-}" ]; then
  build_one "$GOOS" "$GOARCH"
else
  for goos in linux darwin windows; do
    for goarch in amd64 arm64; do
      build_one "$goos" "$goarch"
    done
  done
fi

echo "全部构建完成。产物位于 dist/"
