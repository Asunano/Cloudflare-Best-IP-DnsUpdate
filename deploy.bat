@echo off
chcp 65001 >nul

:: ==============================================================================
:: cfopt - 部署辅助工具 (Deploy Script - Windows Version)
:: Version: 2.0
:: Description: 自动化计算项目组件 SHA256 并生成版本索引文件 (version.txt)
:: Usage: deploy.bat
:: ==============================================================================

echo +------------------------------------------------------------+
echo  cfopt - 版本哈希生成器 v2.0 (Windows)
echo +------------------------------------------------------------+
echo.
echo [INFO] 正在计算文件哈希值并生成 version.txt...
echo.

:: 调用 PowerShell 执行完整逻辑
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-version.ps1"

echo.
echo +------------------------------------------------------------+
echo  [OK] 生成完成！
echo +------------------------------------------------------------+
echo  请将生成的 version.txt 推送至 GitHub 仓库。
echo.

pause
