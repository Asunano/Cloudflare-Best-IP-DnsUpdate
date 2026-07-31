#!/usr/bin/env bash
# 构建 Go sidecar 并放置到 tauri/binaries/cfopt-go-<target-triple>[.exe]
#
# 用法:
#   ./scripts/setup-sidecar.sh              # 按当前系统自动构建 (host)
#   ./scripts/setup-sidecar.sh windows      # 交叉编译 Windows amd64
#   ./scripts/setup-sidecar.sh macos        # macOS arm64 (Apple Silicon)
#   ./scripts/setup-sidecar.sh macos-intel  # macOS amd64
#   ./scripts/setup-sidecar.sh linux        # Linux amd64
#   ./scripts/setup-sidecar.sh linux-arm64  # Linux arm64
#   TARGET_TRIPLE=x86_64-apple-darwin ./scripts/setup-sidecar.sh   # 直接指定 triple
#
# 生成的文件名必须与 tauri.conf.json 中 externalBin 声明的 "binaries/cfopt-go" 配套，
# 即 cfopt-go-<target-triple>[.exe]。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_SRC="$REPO_ROOT"                  # Go 源码在根目录
BIN_DIR="$REPO_ROOT/tauri/binaries"
SCRIPT_NAME="cfopt-go"               # 与 tauri.conf.json 中 externalBin 名称一致

# 目标 -> goos/goarch/ext
case "${1:-host}" in
  host)        GOOS="$(go env GOOS)";  GOARCH="$(go env GOARCH)"; EXE="" ;;
  windows)     GOOS=windows;  GOARCH=amd64;  EXE=".exe" ;;
  macos)       GOOS=darwin;   GOARCH=arm64;  EXE="" ;;
  macos-intel) GOOS=darwin;   GOARCH=amd64;  EXE="" ;;
  linux)       GOOS=linux;    GOARCH=amd64;  EXE="" ;;
  linux-arm64) GOOS=linux;    GOARCH=arm64;  EXE="" ;;
  *) echo "未知目标: $1" >&2; exit 1 ;;
esac

# 若显式指定 TARGET_TRIPLE，则覆盖推导
if [ -n "${TARGET_TRIPLE:-}" ]; then
  case "$TARGET_TRIPLE" in
    x86_64-pc-windows-msvc|x86_64-pc-windows-gnu)     GOOS=windows; GOARCH=amd64; EXE=".exe" ;;
    aarch64-pc-windows-msvc|aarch64-pc-windows-gnu)   GOOS=windows; GOARCH=arm64; EXE=".exe" ;;
    x86_64-apple-darwin)                              GOOS=darwin;  GOARCH=amd64; EXE="" ;;
    aarch64-apple-darwin)                             GOOS=darwin;  GOARCH=arm64; EXE="" ;;
    x86_64-unknown-linux-gnu|x86_64-unknown-linux-musl)   GOOS=linux; GOARCH=amd64; EXE="" ;;
    aarch64-unknown-linux-gnu|aarch64-unknown-linux-musl) GOOS=linux; GOARCH=arm64; EXE="" ;;
    *) echo "未知 TARGET_TRIPLE: $TARGET_TRIPLE" >&2; exit 1 ;;
  esac
fi

# 推导 Tauri 期望的文件名 triple
if [ "$GOOS" = "windows" ]; then
  TRIPLE="x86_64-pc-windows-msvc"; [ "$GOARCH" = "arm64" ] && TRIPLE="aarch64-pc-windows-msvc"
elif [ "$GOOS" = "darwin" ]; then
  TRIPLE="aarch64-apple-darwin"; [ "$GOARCH" = "amd64" ] && TRIPLE="x86_64-apple-darwin"
else
  TRIPLE="x86_64-unknown-linux-gnu"; [ "$GOARCH" = "arm64" ] && TRIPLE="aarch64-unknown-linux-gnu"
fi

DEST_NAME="${SCRIPT_NAME}-${TRIPLE}${EXE}"
mkdir -p "$BIN_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> 构建 $SCRIPT_NAME ($GOOS/$GOARCH) ..."
( cd "$GO_SRC" && GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 go build -o "$TMP/$SCRIPT_NAME$EXE" . )

echo ">> 放置到 $BIN_DIR/$DEST_NAME"
cp "$TMP/$SCRIPT_NAME$EXE" "$BIN_DIR/$DEST_NAME"
echo "✅ 完成: $BIN_DIR/$DEST_NAME"
