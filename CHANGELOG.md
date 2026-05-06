# Changelog

所有重要的项目变更都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

### Added - 新增

#### CI/CD 工作流增强
- **添加 ShellCheck 静态检查** (2026-05-06)
  - 功能：在 GitHub Actions 中自动运行 ShellCheck 检查所有 .sh 文件
  - 位置：`.github/workflows/update-version.yml` 步骤2
  - 特性：
    - `continue-on-error: true` - 仅报告问题，不阻断流程
    - 自动安装 ShellCheck 工具
    - 递归扫描 `cfopt.sh` 和 `modules/**/*.sh`
    - 生成 GitHub Actions 注解（error/warning/notice）
    - 汇总统计报告（通过/警告/错误数量）
  - 输出示例：
    ```
    ======================================
      ShellCheck 检查汇总
    ======================================
      扫描文件:   10 个
      通过:       7 个
      仅警告:     2 个
      有错误:     1 个
      问题总数:   5 个
    ======================================
    ```
  - 优势：
    - ✅ 提前发现常见 Bash 错误
    - ✅ 统一代码风格和质量
    - ✅ 不影响 SHA256 哈希计算流程
    - ✅ 开发阶段友好（不强制修复）

### Fixed - 修复

#### 代码质量优化 (Code Quality)
- **重构 HTTP 请求函数消除重复** (2026-05-06)
  - 文件：`modules/cf-dns/core.sh`
  - 问题：`http_get`、`http_put`、`http_post` 三个函数约 121 行代码，90% 完全相同
  - 修复：
    - 创建通用函数 `_http_request(method, url, data)`
    - 使用参数化设计，通过 `method` 区分 GET/PUT/POST
    - 使用数组构建 curl 参数，动态添加选项
    - 保留所有原有功能（重试、速率限制、认证错误处理）
  - 效果：
    - ✅ 删除 109 行重复代码
    - ✅ 新增 32 行通用逻辑
    - ✅ 净减少 77 行代码（-64%）
    - ✅ 提高可维护性：修改一处即可影响所有请求
  - 技术亮点：
    ```bash
    # 通用函数
    _http_request() {
        local method="$1"
        local url="$2"
        local data="${3:-}"
        
        # 动态构建 curl 参数
        local -a curl_args=(-s -X "$method" "$url" ...)
        
        # GET 特殊处理
        if [ "$method" = "GET" ]; then
            curl_args=(--connect-timeout 10 "${curl_args[@]}")
        fi
        
        # PUT/POST 添加数据体
        if [[ -n "$data" ]] && [[ "$method" != "GET" ]]; then
            curl_args+=(-d "$data")
        fi
        
        # 统一的重试逻辑
        response=$(curl "${curl_args[@]}")
        # ...
    }
    
    # 简化的包装函数
    http_get()  { _http_request "GET" "$1" "${2:-}"; }
    http_put()  { _http_request "PUT" "$1" "$2"; }
    http_post() { _http_request "POST" "$1" "$2"; }
    ```

#### 安全性修复 (Security)
- **修复 API Token 环境变量泄露** (2026-05-06)
  - 问题：`export CF_API_TOKEN` 和 `export SECRETKEY` 将敏感信息导出为环境变量
  - 影响：所有子进程可通过 `/proc/<pid>/environ` 读取 Token，存在严重安全风险
  - 修复：
    - `modules/cf-dns/core.sh` 第135行：删除 `export`，改为局部变量
    - `modules/dnspod-dns/core.sh` 第152行：删除 `export`，改为局部变量
  - 原理：Bash 中未 export 的变量只在当前 shell 可见，不会传递给子进程
  
- **修复 status.conf 权限缺失** (2026-05-06)
  - 问题：`cfopt.sh` 第1501行创建 `conf/status.conf` 时未设置文件权限
  - 影响：默认权限可能为 644，其他用户可读，存在信息泄露风险
  - 修复：添加 `chmod 600 "${STATUS_CONF}"` 设置严格权限
  - 位置：`cfopt.sh` 第1510行

#### cfopt.sh
- **修复 pkill 误杀问题** (2026-05-06)
  - 问题：`pkill -9 -f "/cfopt\.sh"` 会匹配所有包含 `/cfopt.sh` 的进程
  - 影响：可能误杀其他终端窗口的 cfopt 实例或定时任务
  - 修复：改为 `pkill -9 -f "${INSTALL_DIR}/cfopt\.sh"` 精确路径匹配
  - 位置：第 1201 行

- **修复 install_system_cmd 重复定义** (2026-05-06)
  - 问题：函数定义了两次（第264行完整版 + 第1077行精简版）
  - 影响：后定义的覆盖先定义的，导致代码意图混乱
  - 修复：删除第1077-1103行的精简版，保留第264-321行的完整版
  - 优势：完整版包含交互式提示、智能检测、安全执行

#### modules/cf-ip/core.sh
- **修复进度条不刷新问题** (2026-05-06)
  - 问题：使用 `grep -oE '[0-9]+'` 提取所有数字，导致取值错误
  - 影响：进度条显示 0% 且不刷新
  - 修复：使用 `grep -oP` Perl 正则精确提取目标数字
    - 延迟阶段：`grep -oP '可用:\s*\K[0-9]+'`
    - 下载阶段：`grep -oP '^\s*\K[0-9]+(?=\s*/)'`
  - 优化：日志读取从 100 行减少到 50 行，提高性能

- **修复语法错误** (2026-05-06)
  - 问题：第363行和第388行有多余的 `fi`，导致 if-else 结构错乱
  - 错误：`syntax error near unexpected token 'else'`
  - 修复：删除多余的 `fi`，统一缩进为4空格
  - 位置：parse_and_display_progress() 函数

- **修复 CSV 字段解析错误** (2026-05-06)
  - 问题：使用了错误的列号（$3 而非 $5）
  - 影响：延迟显示为 N/A
  - 修复：根据实际 CSV 格式修正列号
    - $5: 平均延迟
    - $6: 下载速度
    - $7: 地区码
  - 格式：`IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码`

- **修复转义码显示异常** (2026-05-06)
  - 问题：`printf "%s"` 不会解释 `\033` 转义序列
  - 影响：显示原始字符串 `\033[0;36m` 而非颜色
  - 修复：改用 `echo -e` 正确解释转义码
  - 位置：display_progress() 和完成提示

- **修复进度条乱码** (2026-05-06)
  - 问题：Unicode 字符 `█` 和 `░` 在某些终端显示为乱码
  - 影响：进度条显示为 ``
  - 修复：改用 ASCII 字符 `=`（已填充）和 `-`（未填充）
  - 优势：所有终端兼容，零编码问题

- **修复下载阶段进度解析** (2026-05-06)
  - 问题：正则 `'^[0-9]+ / [0-9]+'` 要求行首是数字
  - 影响：cfst 输出有空格时无法匹配
  - 修复：改为 `'[0-9]+\s*/\s*[0-9]+'` 允许行首空格

- **修复目录切换不回退** (2026-05-06)
  - 问题：`cd` 到 cfst 目录后没有返回原目录
  - 影响：上层脚本工作目录被改变
  - 修复：保存 ORIGINAL_DIR，测速完成后 `cd "${ORIGINAL_DIR}"`

- **修复空 CSV 崩溃** (2026-05-06)
  - 问题：CSV 为空时算术运算报错
  - 影响：脚本直接崩溃
  - 修复：添加三层检查
    1. 文件存在性检查
    2. 数据行数检查（至少一行数据）
    3. 优雅退出（exit 0）并给出友好提示

- **修复 Windows 换行符处理** (2026-05-06)
  - 问题：只处理了 region 字段的 `\r`
  - 影响：其他字段可能有残留换行符
  - 修复：所有字段统一使用 `gsub(/\r/, "", $N)` 处理

- **修复小写 colo 不支持** (2026-05-06)
  - 问题：case 语句只匹配大写字母
  - 影响：配置 `"colo": "hkg"` 无法转换为中文
  - 修复：函数开头添加 `tr '[:lower:]' '[:upper:]'` 统一转大写

- **修复数字变量空值** (2026-05-06)
  - 问题：delay/speed 为空时直接显示
  - 影响：显示为 "延迟: ms" 或报错
  - 修复：添加校验，为空时设置为 "N/A"

- **修复 MAX_RETRY 硬编码** (2026-05-06)
  - 问题：重试循环前设置 `MAX_RETRY=5` 覆盖配置
  - 影响：配置文件中的 max_retry 无效
  - 修复：删除硬编码，直接使用配置文件中的值

- **修复重试 IP 列表强制回退** (2026-05-06)
  - 问题：重试时强制使用 `${CFST_DIR}/ip.txt`
  - 影响：无视用户自定义 IP 列表配置
  - 修复：只在设置了 IP_DATA_FILE 时才传递 `-f` 参数

- **修复关闭日志时进度不显示** (2026-05-06)
  - 问题：ENABLE_LOG=false 时 LOG_FILE="/dev/null"
  - 影响：进度监控失效（文件大小始终为0）
  - 修复：创建临时日志文件 `.tmp_cfst_*.log`，测速完成后自动删除

- **修复冗余变量** (2026-05-06)
  - 问题：monitor_progress() 中定义了 last_log_size 但从未使用
  - 影响：代码冗余，增加认知负担
  - 修复：删除 last_log_size，只保留 last_displayed_size

- **修复 LINE_TAG 赋值顺序** (2026-05-06)
  - 问题：先生成文件名再赋值 LINE_TAG
  - 影响：文件名为空或错乱
  - 修复：先赋值 LINE_TAG，再生成文件名

- **修复进程锁 trap 单引号** (2026-05-06)
  - 问题：`trap 'rm -f "${LOCK_FILE}"'` 单引号内变量不解析
  - 影响：退出时无法删除锁文件，永久占用
  - 修复：改为 `trap 'rm -f "'"${LOCK_FILE}"'"'` 混合引号

- **修复 cfst 路径硬编码** (2026-05-06)
  - 问题：CMD=(./cfst ...) 依赖当前目录
  - 影响：路径异常时执行失败
  - 修复：改为 CMD=("${CFST_BIN}" ...) 使用绝对路径

- **修复 stat 兼容性** (2026-05-06)
  - 问题：`stat --version` 在 macOS/BSD 上不支持
  - 影响：获取文件大小报错
  - 修复：优先尝试 `stat -f %z`（macOS/BSD），失败再试 `stat -c %s`（Linux）

- **修复 MAGENTA 颜色缺失** (2026-05-06)
  - 问题：第88行使用 ${MAGENTA} 但未定义
  - 影响：终端输出乱码
  - 修复：添加 `MAGENTA='\033[0;35m'`

---

## 修复分类统计

### 稳定性修复 (15项)
- 空 CSV 崩溃防护
- 语法错误修复（多余 fi）
- 进程锁 trap 变量解析
- 目录切换回退
- 数字变量空值校验
- Windows 换行符处理
- stat 跨平台兼容
- pkill 精确匹配避免误杀

### 功能修复 (8项)
- 进度条不刷新（Perl 正则精确提取）
- CSV 字段列号错误
- 下载阶段正则匹配
- 小写 colo 支持
- MAX_RETRY 配置化
- 重试 IP 列表尊重配置
- 关闭日志时进度显示
- LINE_TAG 赋值顺序

### 用户体验修复 (5项)
- 转义码显示异常
- 进度条乱码（ASCII 替代 Unicode）
- 重复函数定义清理
- 冗余变量删除
- 颜色变量补全

### 代码质量修复 (3项)
- install_system_cmd 重复定义
- 冗余变量 last_log_size
- 代码注释规范化

---

## 技术亮点

1. **Perl 正则精确匹配**：使用 `\K` 和前瞻断言实现精确定位
2. **ASCII 字符兼容性**：所有终端零编码问题
3. **跨平台 stat 支持**：Linux/macOS/BSD 全覆盖
4. **防御性编程**：多层校验确保脚本稳定性
5. **DRY 原则**：消除代码重复，提高可维护性

---

## 待办事项

- [ ] 添加单元测试覆盖核心函数
- [ ] 优化日志解析性能（考虑增量读取）
- [ ] 添加更多的错误恢复机制
- [ ] 完善文档和示例配置

---

**最后更新**: 2026-05-06  
**维护者**: Asunano  
**项目仓库**: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate
