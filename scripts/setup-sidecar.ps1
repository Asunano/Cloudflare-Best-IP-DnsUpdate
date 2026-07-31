# 构建 Go sidecar 并放置到 tauri/binaries/cfopt-go-<target-triple>[.exe]
#
# 用法 (PowerShell):
#   .\scripts\setup-sidecar.ps1                 # 按当前系统自动构建 (Windows -> x86_64-pc-windows-msvc.exe)
#   .\scripts\setup-sidecar.ps1 -Target windows # 同上
#   .\scripts\setup-sidecar.ps1 -Target macos   # 交叉编译 macOS arm64
#   .\scripts\setup-sidecar.ps1 -Target linux   # 交叉编译 Linux amd64
#   .\scripts\setup-sidecar.ps1 -TargetTriple x86_64-apple-darwin
#
# 生成的文件名必须与 tauri.conf.json 中 externalBin 声明的 "binaries/cfopt-go" 配套。
param(
  [string]$Target = "host",
  [string]$TargetTriple = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$GoSrc = $RepoRoot                    # Go 源码在根目录
$BinDir = Join-Path $RepoRoot "tauri\binaries"
$ScriptName = "cfopt-go"

function Resolve-Target([string]$t) {
  switch ($t) {
    "host"        { $goos = go env GOOS; $goarch = go env GOARCH; $ext = "" }
    "windows"     { $goos = "windows";  $goarch = "amd64"; $ext = ".exe" }
    "macos"       { $goos = "darwin";   $goarch = "arm64"; $ext = "" }
    "macos-intel" { $goos = "darwin";   $goarch = "amd64"; $ext = "" }
    "linux"       { $goos = "linux";    $goarch = "amd64"; $ext = "" }
    "linux-arm64" { $goos = "linux";    $goarch = "arm64"; $ext = "" }
    default { Write-Error "未知目标: $t"; exit 1 }
  }
  return $goos, $goarch, $ext
}

if ($TargetTriple -ne "") {
  switch ($TargetTriple) {
    "x86_64-pc-windows-msvc"  { $goos = "windows"; $goarch = "amd64"; $ext = ".exe" }
    "aarch64-pc-windows-msvc" { $goos = "windows"; $goarch = "arm64"; $ext = ".exe" }
    "x86_64-apple-darwin"     { $goos = "darwin";  $goarch = "amd64"; $ext = "" }
    "aarch64-apple-darwin"    { $goos = "darwin";  $goarch = "arm64"; $ext = "" }
    "x86_64-unknown-linux-gnu"   { $goos = "linux"; $goarch = "amd64"; $ext = "" }
    "aarch64-unknown-linux-gnu"  { $goos = "linux"; $goarch = "arm64"; $ext = "" }
    default { Write-Error "未知 TARGET_TRIPLE: $TargetTriple"; exit 1 }
  }
} else {
  $r = Resolve-Target $Target
  $goos = $r[0]; $goarch = $r[1]; $ext = $r[2]
}

# 推导 Tauri 期望的 triple
if ($goos -eq "windows") {
  $triple = if ($goarch -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
} elseif ($goos -eq "darwin") {
  $triple = if ($goarch -eq "amd64") { "x86_64-apple-darwin" } else { "aarch64-apple-darwin" }
} else {
  $triple = if ($goarch -eq "arm64") { "aarch64-unknown-linux-gnu" } else { "x86_64-unknown-linux-gnu" }
}

$DestName = "$ScriptName-$triple$ext"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$TmpDir = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP ("cfopt-sidecar-" + [guid]::NewGuid())) | Select-Object -ExpandProperty FullName
try {
  $TmpBin = Join-Path $TmpDir ($ScriptName + $ext)
  Write-Host ">> 构建 $ScriptName ($goos/$goarch) ..."
  Push-Location $GoSrc
  try {
    $env:GOOS = $goos; $env:GOARCH = $goarch; $env:CGO_ENABLED = "0"
    & go build -o $TmpBin .
    if ($LASTEXITCODE -ne 0) { throw "go build 失败 (exit $LASTEXITCODE)" }
  } finally { Pop-Location }
  $Dest = Join-Path $BinDir $DestName
  Copy-Item $TmpBin $Dest -Force
  Write-Host "✅ 完成: $Dest"
} finally {
  Remove-Item -Recurse -Force $TmpDir
}
