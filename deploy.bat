@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ==============================================================================
:: cfopt - 部署辅助工具 (Deploy Script - Windows Version)
:: Version: 1.0
:: Description: 自动化计算项目组件 SHA256 并生成版本索引文件 (version.txt)
:: Usage: deploy.bat
:: ==============================================================================

echo +------------------------------------------------------------+
echo  cfopt - 版本哈希生成器 v1.0 (Windows)
echo +------------------------------------------------------------+
echo.
echo [INFO] 正在计算文件哈希值并生成 version.txt...
echo.

:: 获取脚本所在目录
set "SCRIPT_DIR=%~dp0"

:: 调用 PowerShell 执行核心生成逻辑（兼容 Unix LF 换行符）
powershell -NoProfile -Command ^
"$ErrorActionPreference = 'Stop';" ^
"$scriptDir = '%SCRIPT_DIR%';" ^
"$outputFile = Join-Path $scriptDir 'version.txt';" ^
"" ^
"Write-Host '  [INFO] 正在扫描 modules/ 目录...';" ^
"" ^
"$header = @" ^
"# ============================================================" ^
"# Cloudflare IP 优选工具 - 统一版本管理中心" ^
"# 格式: KEY=VERSION:SHA256" ^
"# 说明：由 deploy.bat 自动生成，请勿手动修改" ^
"# ============================================================" ^
"" ^
"@;" ^
"Set-Content -Path $outputFile -Value $header -Encoding UTF8;" ^
"" ^
"$fileMap = @{" ^
"    'CFOPT' = 'cfopt.sh';" ^
"    'CF_IP_MENU' = 'modules/cf-ip/menu.sh';" ^
"    'CF_IP_CORE' = 'modules/cf-ip/core.sh';" ^
"    'CF_DNS_CORE' = 'modules/cf-dns/core.sh';" ^
"    'CF_DNS_SETUP' = 'modules/cf-dns/setup.sh';" ^
"    'DNSPOD_CORE' = 'modules/dnspod-dns/core.sh';" ^
"    'DNSPOD_SETUP' = 'modules/dnspod-dns/setup.sh';" ^
"    'SCHEDULER_RUN' = 'modules/scheduler/run.sh';" ^
"    'IP_SYNC' = 'modules/ip-sync/sync.sh';" ^
"};" ^
"" ^
"foreach ($key in $fileMap.Keys) {" ^
"    $file = $fileMap[$key];" ^
"    $fullPath = Join-Path $scriptDir $file;" ^
"    if (Test-Path $fullPath) {" ^
"        $content = Get-Content $fullPath -Raw;" ^
"        $ver = '0.1';" ^
"        if ($content -match 'SCRIPT_VERSION=\"([^\"]+)\"') { $ver = $matches[1]; }" ^
"        $hash = (Get-FileHash $fullPath -Algorithm SHA256).Hash;" ^
"        $line = \"$key=$ver`:$hash\";" ^
"        Add-Content -Path $outputFile -Value $line -Encoding UTF8;" ^
"        Write-Host \"  [INFO] $key : v$ver\";" ^
"    } else {" ^
"        Write-Host \"  [WARN] $key : 文件不存在 ($file)\" -ForegroundColor Yellow;" ^
"    }" ^
"};" ^
"" ^
"Write-Host '';" ^
"Write-Host '[OK] version.txt 已更新，请同步至 GitHub 仓库。' -ForegroundColor Green;"

echo.
echo +------------------------------------------------------------+
echo  [OK] 生成完成！
echo +------------------------------------------------------------+
echo  请将生成的 version.txt 推送至 GitHub 仓库。
echo.

endlocal
pause
