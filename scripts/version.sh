#!/usr/bin/env bash
#
# version.sh — 生成 version.txt（版本号 + 各平台二进制 SHA256）
#
# 用法:
#   ./scripts/version.sh
#
# version.txt 格式（KEY:VALUE，首行必须为 VERSION:<ver>，供 build.sh 读取）:
#   VERSION:<ver>
#   CFOPT_LINUX_AMD64_SHA256:<sha256>
#   CFOPT_LINUX_ARM64_SHA256:<sha256>
#   ...
#
# 说明:
#   - 版本号优先取 `git describe --tags`；仓库无 tag 时回退为 dev
#   - 为每个 build.sh 产出的 dist/ 二进制写入其 SHA256 校验值
#   - 若某平台二进制尚未构建，则写入占位注释行（提示先运行 build.sh）
#   - 零外部依赖：仅使用 coreutils 的 sha256sum（Windows 下等价用 Get-FileHash）
#
set -euo pipefail

# 切到仓库根目录（脚本可放于 scripts/ 任意位置调用）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 1. 解析版本号
# ---------------------------------------------------------------------------
if VER="$(git describe --tags 2>/dev/null)" && [ -n "$VER" ]; then
  : # 使用 git tag 描述
else
  VER="dev"
fi

# ---------------------------------------------------------------------------
# 2. 生成 version.txt
#    首行必须是 VERSION:<ver>（build.sh 通过 head -1 | cut -d: -f2 读取）
# ---------------------------------------------------------------------------
{
  echo "VERSION:${VER}"

  # 3. 各平台二进制 SHA256（与 build.sh 矩阵一致）
  for goos in linux darwin windows; do
    for goarch in amd64 arm64; do
      ext=""
      if [ "$goos" = "windows" ]; then
        ext=".exe"
      fi
      bin="dist/cfopt-${goos}-${goarch}${ext}"
      key="CFOPT_$(echo "${goos}_${goarch}" | tr 'a-z' 'A-Z')_SHA256"
      if [ -f "$bin" ]; then
        sha="$(sha256sum "$bin" | cut -d' ' -f1)"
        echo "${key}:${sha}"
      else
        echo "# ${key}: <placeholder — 尚未构建，请先运行 scripts/build.sh>"
      fi
    done
  done
} > version.txt

echo "已生成 version.txt:"
cat version.txt
