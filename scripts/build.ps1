# build.ps1 — cfopt 交叉编译脚本 (PowerShell)
#
# 用法:
#   .\scripts\build.ps1                                 # 编译全部 6 个平台矩阵
#   $env:GOOS="linux"; $env:GOARCH="amd64"; .\scripts\build.ps1   # 仅编译单个平台
#
# 中国网络环境下，首次构建前请设置 Go 代理以加速模块下载:
#   $env:GOPROXY="https://goproxy.cn,direct"
#   （设置后可再执行 go build；本脚本本身只负责编译与版本注入）
#
# 说明:
#   - 交叉编译矩阵: CGO_ENABLED=0 × {linux,darwin,windows} × {amd64,arm64}
#   - 产物输出到: dist/cfopt-<goos>-<goarch>[.exe]
#   - 版本号从 version.txt 首行 (VERSION:<ver>) 注入到 cfopt/cmd.Version
#   - 每个二进制构建后打印绝对路径并用 Get-FileHash -Algorithm SHA256 输出校验值
#   - 使用 CGO_ENABLED=0 生成纯静态二进制，便于跨平台无依赖分发

$ErrorActionPreference = "Stop"

# 切到仓库根目录（脚本可放于 scripts/ 任意位置调用）
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

# ---------------------------------------------------------------------------
# 读取版本号（version.txt 首行: VERSION:<ver>）
# 若文件缺失或首行无版本，则回退为 dev
# ---------------------------------------------------------------------------
$Version = "dev"
if (Test-Path "version.txt") {
  $firstLine = (Get-Content "version.txt" -TotalCount 1)
  if ($firstLine -match '^VERSION:(.+)$') {
    $Version = $Matches[1]
  }
}

# 版本注入：cmd.Version 由 cmd/version.go 提供，供 ldflags 覆盖
$Ldflags = "-X cfopt/cmd.Version=$Version"

# ---------------------------------------------------------------------------
# Build-One: 编译单个平台并输出路径 + SHA256
# ---------------------------------------------------------------------------
function Build-One {
  param(
    [string]$goos,
    [string]$goarch
  )

  $ext = ""
  if ($goos -eq "windows") { $ext = ".exe" }
  $out = "dist/cfopt-$goos-$goarch$ext"

  New-Item -ItemType Directory -Force -Path "dist" | Out-Null

  Write-Host "==> 构建 $out ($goos/$goarch)"
  $env:CGO_ENABLED = "0"
  $env:GOOS = $goos
  $env:GOARCH = $goarch
  & go build -trimpath -ldflags $Ldflags -o $out .
  if ($LASTEXITCODE -ne 0) {
    throw "go build 失败: $goos/$goarch (exit=$LASTEXITCODE)"
  }

  # 输出产物绝对路径与 SHA256 校验值
  $abs = Join-Path $Root $out
  Write-Host "产物: $abs"
  $hash = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLower()
  Write-Host "SHA256: $hash"
  Write-Host ""
}

# ---------------------------------------------------------------------------
# 入口：若已通过环境变量指定单平台则仅编译该平台，否则遍历完整矩阵
# ---------------------------------------------------------------------------
if ($env:GOOS -and $env:GOARCH) {
  Build-One $env:GOOS $env:GOARCH
} else {
  $Gooses = @("linux", "darwin", "windows")
  $Goarchs = @("amd64", "arm64")
  foreach ($goos in $Gooses) {
    foreach ($goarch in $Goarchs) {
      Build-One $goos $goarch
    }
  }
}

Write-Host "全部构建完成。产物位于 dist/"
