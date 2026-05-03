---
trigger: always_on
---
# 禁止使用 PowerShell 执行脚本以防止中文乱码

## 规则说明
在处理涉及中文字符的文件操作、脚本执行或终端命令时，严禁使用 PowerShell (`pwsh` 或 `powershell`)，因为其默认编码行为可能导致中文乱码。

## 替代方案
1. **优先使用 Git Bash 或 WSL (Windows Subsystem for Linux)**：
   - 这些环境通常默认使用 UTF-8 编码，能更好地处理中文字符。
   - 示例：`git bash -c "your_command"`

2. **如果必须使用 Windows CMD**：
   - 确保在执行前设置代码页为 UTF-8：`chcp 65001`
   - 示例：`cmd /c "chcp 65001 && your_command"`

3. **Python 脚本中处理文件**：
   - 始终显式指定编码为 `utf-8`。
   - 示例：
     with open('file.txt', 'r', encoding='utf-8') as f:
         content = f.read()

4. **Node.js 脚本中处理文件**：
   - 读取文件时指定编码。
   - 示例：
     const fs = require('fs');
     const content = fs.readFileSync('file.txt', 'utf-8');

## 禁止的操作
- ❌ 不要使用 `powershell -Command "..."` 或 `pwsh -Command "..."` 执行包含中文路径或内容的命令。
- ❌ 不要在 PowerShell 中直接重定向输出到包含中文的文件，除非已明确设置 `$OutputEncoding = [System.Text.Encoding]::UTF8` 且确认接收端兼容。
- ❌ 避免在 PowerShell 中使用 `Get-Content` 或 `Set-Content` 处理中文文件而不指定 `-Encoding UTF8`。

## 推荐的最佳实践
- 在所有跨平台脚本中，统一使用 UTF-8 无 BOM 格式保存文件。
- 在 CI/CD 流水线中，配置环境变量 `PYTHONIOENCODING=utf-8` 和 `LANG=en_US.UTF-8`（Linux/Mac）或等效设置。
- 对于 Windows 用户，建议在 `.bashrc` 或 `.profile` 中设置 `export LANG=zh_CN.UTF-8` 或 `en_US.UTF-8` 以确保一致性。
