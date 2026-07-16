#!/usr/bin/env bash
# ipc-smoke.sh - 向本地 cfopt IPC 服务发送 JSON-RPC 请求并打印响应（Linux / macOS / Git Bash）
#
# 用法:
#   bash scripts/ipc-smoke.sh
#   bash scripts/ipc-smoke.sh version
#   bash scripts/ipc-smoke.sh sync.run '{"providers":["cf"]}'
#
# 前置: 先在另一个窗口运行 `go run . serve --ipc-port-file cfopt.ipc`
set -euo pipefail

PORT_FILE="${PORT_FILE:-cfopt.ipc}"
METHOD="${1:-ping}"
PARAMS_JSON="${2:-}"
PORT="$(cat "$PORT_FILE")"

REQ="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$METHOD\"}"
if [ -n "$PARAMS_JSON" ]; then
  REQ="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$METHOD\",\"params\":$PARAMS_JSON}"
fi

echo ">> 连接到 127.0.0.1:$PORT  方法=$METHOD"
echo ">> 发送: $REQ"

if command -v nc >/dev/null 2>&1; then
  printf '%s\n' "$REQ" | nc 127.0.0.1 "$PORT"
elif command -v ncat >/dev/null 2>&1; then
  printf '%s\n' "$REQ" | ncat 127.0.0.1 "$PORT"
else
  # 退而求其次：用 /dev/tcp（bash 内置）
  exec 3<>/dev/tcp/127.0.0.1/"$PORT"
  printf '%s\n' "$REQ" >&3
  sleep 0.6
  cat <&3
  exec 3<&-
fi
