# ipc-smoke.ps1 - send a JSON-RPC request to the local cfopt IPC server (Windows / PowerShell)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1 -Method version
#   powershell -ExecutionPolicy Bypass -File scripts/ipc-smoke.ps1 -Method sync.run -ParamsJson '{"providers":["cf"]}'
#
# Prereq: start the server in another window first:
#   go run . serve --ipc-port-file cfopt.ipc
param(
  [string]$PortFile = "cfopt.ipc",
  [string]$Method = "ping",
  [string]$ParamsJson = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PortFile)) {
  Write-Error "Port file not found: $PortFile. Start the server first: go run . serve --ipc-port-file $PortFile"
  exit 1
}

$port = ([string](Get-Content $PortFile)).Trim()
Write-Host ">> connect 127.0.0.1:$port  method=$Method"

# Build the JSON-RPC request as a raw string (no ConvertTo-Json / ConvertFrom-Json,
# which are finicky on PowerShell 5.1). ParamsJson is inserted verbatim.
$body = "{""jsonrpc"":""2.0"",""id"":1,""method"":""$Method"""
if ($ParamsJson -ne "") {
  $body += ",""params"":$ParamsJson"
}
$body += "}`n"

Write-Host ">> send: $body"

try {
  $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port)
} catch {
  Write-Error "Cannot connect to 127.0.0.1:$port - is the server running?"
  exit 1
}

try {
  $ns = $tcp.GetStream()
  $sw = New-Object System.IO.StreamWriter($ns)
  $sw.AutoFlush = $true
  $sw.Write($body)
  $sw.Flush()

  $sr = New-Object System.IO.StreamReader($ns)
  if ($null -eq $sr) {
    Write-Error "Failed to create stream reader"
    exit 1
  }

  # Read every response line within a 3s window (covers sync.run progress events
  # which the server interleaves before the final result on the same connection).
  $ns.ReadTimeout = 3000
  try {
    while ($true) {
      $line = $sr.ReadLine()
      if ($null -eq $line) { break }
      if ($line.Length -gt 0) { Write-Output $line }
    }
  } catch [System.TimeoutException] {
    # no more data within the window -> done
  } catch [System.IO.IOException] {
    # connection closed by server -> done
  }
} finally {
  $tcp.Close()
}
