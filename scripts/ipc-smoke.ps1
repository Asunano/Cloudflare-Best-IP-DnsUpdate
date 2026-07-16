# ipc-smoke.ps1 - 向本地 cfopt IPC 服务发送 JSON-RPC 请求并打印响应（Windows / PowerShell）
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1 -Method version
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1 -Method sync.run -ParamsJson '{"providers":["cf"]}'
#
# 前置: 先在另一个窗口运行 `go run . serve --ipc-port-file cfopt.ipc`
param(
  [string]$PortFile = "cfopt.ipc",
  [string]$Method = "ping",
  [string]$ParamsJson = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PortFile)) {
  Write-Error "端口文件不存在: $PortFile`n请先在另一个窗口运行: go run . serve --ipc-port-file $PortFile"
  exit 1
}

$port = ([string](Get-Content $PortFile)).Trim()
Write-Host ">> 连接到 127.0.0.1:$port  方法=$Method"

$req = [ordered]@{
  jsonrpc = "2.0"
  id      = 1
  method  = $Method
}
if ($ParamsJson -ne "") {
  $req.params = ($ParamsJson | ConvertFrom-Json)
}

$body = (ConvertTo-Json -InputObject $req -Compress -Depth 4) + "`n"
Write-Host ">> 发送: $body"

$tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
try {
  $ns = $tcp.GetStream()
  $sw = New-Object System.IO.StreamWriter($ns)
  $sw.AutoFlush = $true
  $sw.Write($body)

  # 读取 3 秒内的所有响应行（含 sync.run 期间穿插的 progress 事件）
  $sr = New-Object System.IO.StreamReader($ns)
  $deadline = [datetime]::Now.AddSeconds(3)
  while ([datetime]::Now -lt $deadline) {
    if ($ns.DataAvailable) {
      $line = $sr.ReadLine()
      if ($line) { Write-Output $line }
    } else {
      Start-Sleep -Milliseconds 50
    }
  }
} finally {
  $tcp.Close()
}
