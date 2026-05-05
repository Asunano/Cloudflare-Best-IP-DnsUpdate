#!/bin/bash
# ==============================================================================
# cfopt - Cloudflare IP 优选与 DNS 管理套件 (主入口)
# Version: 0.1
# Description: 自动化测速、IP 同步及 DNS 记录更新的综合管理入口
# Author: cfopt Team
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

# --- 终端颜色定义 (必须最先定义，防止 set -u 报错) ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ====================== 【统一错误处理系统】 ======================

# 记录错误日志
log_error() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${RED}[ERROR] ${timestamp} - ${message}${NC}" >&2
    
    # 同时写入日志文件（如果存在）
    if [[ -n "${INSTALL_DIR:-}" ]] && [[ -d "${INSTALL_DIR}/logs" ]]; then
        echo "[${timestamp}] ERROR: ${message}" >> "${INSTALL_DIR}/logs/error.log" 2>/dev/null || true
    fi
}

# 记录警告信息
log_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARN] ${message}${NC}"
}

# 记录成功信息
log_success() {
    local message="$1"
    echo -e "${GREEN}[OK] ${message}${NC}"
}

# 记录信息
log_info() {
    local message="$1"
    echo -e "${CYAN}[INFO] ${message}${NC}"
}

# 触发回滚
trigger_rollback() {
    log_warning "检测到严重错误，尝试回滚到上一版本..."
    if rollback_on_failure; then
        log_success "回滚成功，系统已恢复"
    else
        log_error "回滚失败，请手动修复或重新安装"
    fi
}

# 安全执行命令（带错误检查）
safe_execute() {
    local description="$1"
    shift
    
    if "$@"; then
        return 0
    else
        local exit_code=$?
        log_error "${description} (退出码: ${exit_code})"
        return 1
    fi
}

# 安全的文件移动（带备份和验证）
safe_move() {
    local source="$1"
    local target="$2"
    local description="${3:-文件移动}"
    
    # 检查源文件是否存在
    if [[ ! -f "${source}" ]]; then
        log_error "${description}: 源文件不存在 (${source})"
        return 1
    fi
    
    # 确保目标目录存在
    local target_dir
    target_dir="$(dirname "${target}")"
    if ! mkdir -p "${target_dir}" 2>/dev/null; then
        log_error "${description}: 无法创建目标目录 (${target_dir})"
        return 1
    fi
    
    # 执行移动
    if mv "${source}" "${target}" 2>/dev/null; then
        # 验证目标文件是否存在且非空
        if [[ -f "${target}" ]] && [[ -s "${target}" ]]; then
            return 0
        else
            log_error "${description}: 目标文件验证失败"
            return 1
        fi
    else
        log_error "${description}: 移动失败"
        return 1
    fi
}

# 安全的文件复制（带验证）
safe_copy() {
    local source="$1"
    local target="$2"
    local description="${3:-文件复制}"
    
    # 检查源文件/目录是否存在
    if [[ ! -e "${source}" ]]; then
        log_error "${description}: 源路径不存在 (${source})"
        return 1
    fi
    
    # 确保目标目录存在
    local target_dir
    target_dir="$(dirname "${target}")"
    if ! mkdir -p "${target_dir}" 2>/dev/null; then
        log_error "${description}: 无法创建目标目录 (${target_dir})"
        return 1
    fi
    
    # 执行复制
    if cp -r "${source}" "${target}" 2>/dev/null; then
        # 验证目标是否存在
        if [[ -e "${target}" ]]; then
            return 0
        else
            log_error "${description}: 目标验证失败"
            return 1
        fi
    else
        log_error "${description}: 复制失败"
        return 1
    fi
}

# 安全的目录删除（带确认和保护）
safe_remove_dir() {
    local dir_path="$1"
    local description="${2:-目录删除}"
    
    # 安全检查：防止误删重要目录
    if [[ -z "${dir_path}" ]] || [[ "${dir_path}" = "/" ]] || [[ "${dir_path}" = "/root" ]] || [[ "${dir_path}" = "/home" ]]; then
        log_error "${description}: 拒绝删除危险路径 (${dir_path})"
        return 1
    fi
    
    if [[ -d "${dir_path}" ]]; then
        if rm -rf "${dir_path}" 2>/dev/null; then
            return 0
        else
            log_error "${description}: 删除失败 (${dir_path})"
            return 1
        fi
    else
        log_warning "${description}: 目录不存在，跳过 (${dir_path})"
        return 0
    fi
}

# --- 全局配置区 ---
SCRIPT_VERSION="0.1"

# GitHub 原始地址和镜像地址（用于加速国内访问）
REMOTE_URL="https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main"
# 自定义镜像源（优先使用）
REMOTE_URL_MIRROR="https://mirror.drxian.qzz.io/scripts/Cloudflare-Best-IP-DnsUpdate"
VERSION_FILE_REMOTE="${REMOTE_URL}/version.txt"

# 根据用户权限动态确定安装目录
if [[ "${EUID}" -eq 0 ]]; then
    INSTALL_DIR="/root/cfopt"
else
    INSTALL_DIR="${HOME}/cfopt"
fi

# --- 自动归位逻辑：确保脚本在标准目录下运行 ---
CURRENT_SCRIPT_PATH="$(readlink -f "$0")"
TARGET_SCRIPT_PATH="${INSTALL_DIR}/cfopt.sh"

if [[ "${CURRENT_SCRIPT_PATH}" != "${TARGET_SCRIPT_PATH}" ]]; then
    echo -e "${CYAN}[INFO] 检测到脚本位于非标准目录，正在迁移至: ${INSTALL_DIR}${NC}"
    mkdir -p "${INSTALL_DIR}"
    
    # 移动脚本并保留执行权限
    if safe_move "${CURRENT_SCRIPT_PATH}" "${TARGET_SCRIPT_PATH}" "脚本迁移"; then
        chmod +x "${TARGET_SCRIPT_PATH}"
        log_success "迁移成功，正在从新位置启动..."
        # 使用 exec 替换当前进程，从新位置重新启动
        exec bash "${TARGET_SCRIPT_PATH}"
    else
        log_error "迁移失败，请检查权限。"
        exit 1
    fi
fi

echo -e "${CYAN}----------------------------------------${NC}"
echo -e "   ${YELLOW}Cloudflare IP 优选工具 - 智能启动器${NC}"
echo -e "${CYAN}----------------------------------------${NC}"

# --- 系统命令安装逻辑 ---
SYSTEM_CMD_PATH="/usr/local/bin/cfopt"

# 检查全局命令是否有效
check_system_cmd() {
    if [[ -L "${SYSTEM_CMD_PATH}" ]] || [[ -x "${SYSTEM_CMD_PATH}" ]]; then
        # 检查符号链接是否指向正确位置
        local target
        target="$(readlink -f "${SYSTEM_CMD_PATH}" 2>/dev/null)"
        if [[ -n "${target}" ]] && [[ -f "${target}" ]]; then
            return 0
        fi
    fi
    return 1
}

# 修复或安装全局命令
fix_system_cmd() {
    local script_path="$1"
    
    # 确保目标目录存在
    if ! mkdir -p "$(dirname "${SYSTEM_CMD_PATH}")" 2>/dev/null; then
        log_error "无法创建目录: $(dirname "${SYSTEM_CMD_PATH}")"
        return 1
    fi
    
    # 删除旧的全局命令（如果存在）
    if [[ -e "${SYSTEM_CMD_PATH}" ]]; then
        rm -f "${SYSTEM_CMD_PATH}" 2>/dev/null || true
    fi
    
    # 创建符号链接（优先）或复制文件
    if ln -sf "${script_path}" "${SYSTEM_CMD_PATH}" 2>/dev/null; then
        chmod +x "${SYSTEM_CMD_PATH}" 2>/dev/null || true
        if [[ -x "${SYSTEM_CMD_PATH}" ]]; then
            log_success "全局命令已安装: ${SYSTEM_CMD_PATH} -> ${script_path}"
            return 0
        fi
    fi
    
    # 如果符号链接失败，尝试复制文件
    log_warning "符号链接创建失败，尝试复制文件..."
    if cp "${script_path}" "${SYSTEM_CMD_PATH}" 2>/dev/null && chmod +x "${SYSTEM_CMD_PATH}"; then
        log_success "全局命令已安装（复制模式）: ${SYSTEM_CMD_PATH}"
        return 0
    fi
    
    log_error "全局命令安装失败"
    return 1
}

install_system_cmd() {
    # 若已安装且有效，则跳过
    if check_system_cmd; then
        local current_target
        current_target="$(readlink -f "${SYSTEM_CMD_PATH}" 2>/dev/null)"
        local script_path
        script_path="$(readlink -f "$0" 2>/dev/null)"
        
        # 检查是否指向正确的脚本
        if [[ "${current_target}" = "${script_path}" ]]; then
            return 0
        fi
    fi
    
    # 处于临时运行环境（如 wget 管道），则跳过
    if [[ ! -f "$0" ]]; then
        return 0
    fi

    echo ""
    log_info "建议将 'cfopt' 安装为系统全局命令。"
    echo "       (安装后可在任意终端直接输入 cfopt 运行)"
    read -r -p "是否现在安装？(y/n，默认y): " INSTALL_CMD
    INSTALL_CMD="${INSTALL_CMD:-y}"

    if [[ "${INSTALL_CMD}" =~ ^[Yy]$ ]]; then
        local script_path
        script_path="$(readlink -f "$0")"
        
        # 非 Root 用户尝试提权处理
        if [[ "${EUID}" -ne 0 ]]; then
            if command -v sudo >/dev/null 2>&1; then
                if safe_execute "安装全局命令" sudo bash -c "ln -sf '${script_path}' '${SYSTEM_CMD_PATH}' && chmod +x '${SYSTEM_CMD_PATH}'"; then
                    if check_system_cmd; then
                        log_success "全局命令已安装: ${SYSTEM_CMD_PATH}"
                        return 0
                    else
                        log_error "全局命令安装验证失败"
                        return 1
                    fi
                else
                    log_error "需要 root 权限或 sudo 支持。"
                    return 1
                fi
            else
                log_error "需要 root 权限或 sudo 支持。"
                return 1
            fi
        else
            if fix_system_cmd "${script_path}"; then
                return 0
            else
                log_error "安装失败，请检查权限。"
                return 1
            fi
        fi
    fi
}

# --- 网络健康检查系统 ---
# 在执行下载前检查网络连通性，快速失败避免长时间等待
check_network_health() {
    local test_urls=(
        "${REMOTE_URL_MIRROR}"
        "${REMOTE_URL}"
        "https://api.github.com"
    )
    
    echo -e "${CYAN}[INFO] 正在执行网络健康检查...${NC}"
    
    for url in "${test_urls[@]}"; do
        if curl -s --connect-timeout 5 --max-time 10 "${url}" > /dev/null 2>&1; then
            echo -e "${GREEN}[OK] 网络连接正常: ${url}${NC}"
            return 0
        fi
    done
    
    echo -e "${RED}[ERROR] 网络连接异常，请检查以下项：${NC}"
    echo -e "  1. 服务器是否可以访问外网"
    echo -e "  2. DNS 解析是否正常（尝试 ping 8.8.8.8）"
    echo -e "  3. 防火墙是否阻止了 HTTPS 流量"
    echo -e "  4. 代理设置是否正确（如使用代理）"
    return 1
}


# --- 辅助函数：带重试的下载与校验（支持镜像回退） ---
download_with_retry() {
    local url="$1"
    local output="$2"
    local expected_hash="${3:-}"  # 可选参数：预期的 SHA256 哈希值
    local max_retries=3
    local retry_count=0
    
    # 判断是否为 GitHub raw 链接，如果是则启用镜像回退
    local use_mirror=false
    if [[ "${url}" == *"raw.githubusercontent.com"* ]]; then
        use_mirror=true
        # 将原始 URL 转换为镜像 URL
        local mirror_url="${REMOTE_URL_MIRROR}${url#*main}"
    fi
    
    while [[ "${retry_count}" -lt "${max_retries}" ]]; do
        # 确保输出文件的父目录存在且可写
        local output_dir
        output_dir="$(dirname "${output}")"
        if ! mkdir -p "${output_dir}" 2>/dev/null; then
            echo -e "${RED}[ERROR] 无法创建目录: ${output_dir}${NC}"
            return 1
        fi
        
        # 优先使用镜像下载（如果启用），失败后回退到原始 URL
        local current_url="${url}"
        if [[ "${use_mirror}" == true ]] && [[ "${retry_count}" -eq 0 ]]; then
            current_url="${mirror_url}"
            echo -e "${CYAN}[INFO] 尝试使用镜像加速...${NC}"
        elif [[ "${use_mirror}" == true ]] && [[ "${retry_count}" -ge 1 ]]; then
            current_url="${url}"
            echo -e "${YELLOW}[INFO] 镜像失败，回退到原始地址...${NC}"
        fi
        
        # 使用 curl 进行下载，仅显示进度条
        local http_code
        http_code=$(curl -sfL --connect-timeout 10 --max-time 60 --create-dirs -o "${output}" -w "%{http_code}" "${current_url}" 2>/dev/null)
        local curl_exit=$?
        
        if [[ ${curl_exit} -eq 0 ]] && [[ "${http_code}" = "200" ]]; then
            # 【增强】多重完整性校验
            
            # 1. 文件非空检查
            if [[ ! -s "${output}" ]]; then
                echo -e "${YELLOW}[WARN] 下载的文件为空，正在重试...${NC}"
                continue
            fi
            
            local file_size
            file_size="$(wc -c < "${output}")"
            
            # 2. 最小文件大小检查（小于 100 bytes 可能是错误页面）
            if [[ ${file_size} -lt 100 ]]; then
                echo -e "${YELLOW}[WARN] 文件过小 (${file_size} bytes)，可能是错误页面，正在重试...${NC}"
                continue
            fi
            
            # 3. HTML 错误页检查（增强版）
            # 先检查是否为有效的 Shell 脚本
            local is_valid_script=false
            if [[ "${output}" == *.sh ]]; then
                local first_line
                first_line="$(head -1 "${output}" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//')"
                if [[ "${first_line}" == "#!"* ]]; then
                    is_valid_script=true
                fi
            fi
            
            # 如果是有效的 Shell 脚本，跳过 HTML 检查
            if [[ "${is_valid_script}" = false ]]; then
                # 非脚本文件才进行 HTML 检查
                if grep -q "403 Forbidden" "${output}" 2>/dev/null || \
                   grep -q "404 Not Found" "${output}" 2>/dev/null || \
                   grep -qi "^<html" "${output}" 2>/dev/null || \
                   grep -qi "^<!DOCTYPE" "${output}" 2>/dev/null || \
                   grep -qi "rate limit" "${output}" 2>/dev/null; then
                    echo -e "${YELLOW}[WARN] 下载到 HTML 错误页或受限内容，正在重试...${NC}"
                    # 显示前100个字符帮助调试
                    local preview
                    preview=$(head -c 100 "${output}" 2>/dev/null | tr -d '\n')
                    echo -e "${GRAY}[DEBUG] 响应预览: ${preview}...${NC}"
                    continue
                fi
            fi
            
            # 4. Shell 脚本基本语法检查（如果是 .sh 文件）
            if [[ "${output}" == *.sh ]]; then
                local first_line
                # 自动删除 BOM (UTF-8 Byte Order Mark)
                first_line="$(head -1 "${output}" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//')"
                if [[ "${first_line}" != "#!"* ]]; then
                    echo -e "${YELLOW}[WARN] 文件不是有效的 Shell 脚本（第一行: ${first_line}），正在重试...${NC}"
                    continue
                fi
            fi
            
            # 5. 哈希校验（如果提供了哈希值）
            if [[ -n "${expected_hash}" ]]; then
                local actual_hash
                actual_hash="$(sha256sum "${output}" | awk '{print $1}')"
                if [[ "${actual_hash}" = "${expected_hash}" ]]; then
                    echo -e "${GREEN}[OK] 下载成功 (${file_size} bytes) - 哈希校验通过${NC}"
                    return 0
                else
                    echo -e "${YELLOW}[WARN] 哈希校验失败，正在重试...${NC}"
                    continue
                fi
            else
                echo -e "${GREEN}[OK] 下载成功 (${file_size} bytes) - 完整性校验通过${NC}"
                return 0
            fi
        else
            local curl_exit_code=${curl_exit}
            echo -e "${YELLOW}[WARN] 下载失败 (HTTP ${http_code:-N/A}, 退出码: ${curl_exit_code})，正在重试...${NC}"
            if [[ "${curl_exit_code}" -eq 23 ]]; then
                echo -e "${RED}[ERROR] 写入错误：请检查磁盘空间或目录权限${NC}"
            elif [[ "${http_code}" = "403" ]]; then
                echo -e "${YELLOW}[INFO] GitHub 速率限制，请稍后重试${NC}"
            elif [[ "${http_code}" = "404" ]]; then
                echo -e "${RED}[ERROR] 文件不存在，请检查 version.txt 配置${NC}"
            fi
        fi
        retry_count=$((retry_count + 1))
        if [[ "${retry_count}" -lt "${max_retries}" ]]; then
            # 指数退避：第1次重试2秒，第2次重试4秒
            local wait_time=$((2 ** retry_count))
            echo -e "${CYAN}[INFO] 等待 ${wait_time} 秒后重试...${NC}"
            sleep ${wait_time}
        fi
    done
    
    echo -e "${RED}[ERROR] 下载失败: $(basename "${url}")${NC}"
    rm -f "${output}" 2>/dev/null
    return 1
}

# --- 环境检测与依赖安装 ---
check_environment() {
    echo -e "${CYAN}━━ 正在执行系统环境检测 ━━${NC}"
    local has_error=false
    local missing_tools=()
    
    # 检查必要的系统命令
    local required_cmds=("curl" "openssl" "grep" "sed" "awk" "jq")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            missing_tools+=("${cmd}")
            has_error=true
        fi
    done
    
    if [[ "${has_error}" = true ]]; then
        echo -e "${RED}[ERROR] 缺失必要工具: ${missing_tools[*]}${NC}"
        echo -e "${YELLOW}[INFO] 正在尝试自动安装...${NC}"
        
        local install_cmd=""
        if command -v apt-get &> /dev/null; then
            install_cmd="apt-get install -y"
        elif command -v yum &> /dev/null; then
            install_cmd="yum install -y"
        elif command -v apk &> /dev/null; then
            install_cmd="apk add"
        fi

        if [[ -n "${install_cmd}" ]]; then
            sudo bash -c "${install_cmd} ${missing_tools[*]}" 2>/dev/null || true
        fi
        
        # 安装后二次检查，若仍缺失则报错退出
        for cmd in "${missing_tools[@]}"; do
            if ! command -v "${cmd}" &> /dev/null; then
                echo -e "${RED}[ERROR] ${cmd} 安装失败，请手动安装后重试。${NC}"
                exit 1
            fi
        done
    fi
    echo -e "${GREEN}[OK] 环境检测通过，开始初始化...${NC}"
}

# --- 辅助函数：获取模块状态图标 ---
get_module_status() {
    local conf_file="$1"
    local data_file="$2"
    
    # 1. 检查配置文件是否存在且已启用
    if [[ -f "${conf_file}" ]]; then
        # 支持 JSON 和旧格式
        local enabled="false"
        if [[ "${conf_file}" == *.json ]]; then
            # JSON 格式：使用 jq 读取
            if command -v jq &>/dev/null; then
                enabled=$(jq -r '.enabled // false' "${conf_file}")
            fi
        else
            # 旧格式：source 加载
            # shellcheck disable=SC1090
            source "${conf_file}"
        fi
        
        if [[ "${enabled}" = "true" ]]; then
            # 2. 检查数据文件是否新鲜 (24小时内)
            if [[ -n "${data_file}" ]] && [[ -f "${data_file}" ]]; then
                local now
                now="$(date +%s)"
                local file_time
                file_time="$(stat -c %Y "${data_file}" 2>/dev/null || stat -f %m "${data_file}" 2>/dev/null)"
                if [[ $((now - file_time)) -lt 86400 ]]; then
                    echo -e "${GREEN}[正常]${NC}"
                else
                    echo -e "${YELLOW}[待更新]${NC}"
                fi
            else
                echo -e "${CYAN}[已配置]${NC}"
            fi
        else
            echo -e "${GRAY}[已禁用]${NC}"
        fi
    else
        echo -e "${RED}[未配置]${NC}"
    fi
}

# ====================== 【系统健康检测与修复】 ======================

# 全面的系统检测与修复函数
system_health_check() {
    clear
    local has_issues=false
    
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}系统健康检测与修复${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 1. 检查全局命令
    echo -n "[1/5] 检查全局命令... "
    if check_system_cmd; then
        local target
        target="$(readlink -f "${SYSTEM_CMD_PATH}" 2>/dev/null)"
        echo -e "${GREEN}正常${NC} (${SYSTEM_CMD_PATH} -> ${target})"
    else
        if [[ -e "${SYSTEM_CMD_PATH}" ]]; then
            echo -e "${RED}失效${NC} (文件存在但不可用)"
            has_issues=true
        else
            echo -e "${YELLOW}未安装${NC}"
        fi
    fi
    
    # 2. 检查核心模块
    echo -n "[2/5] 检查核心模块... "
    local missing_modules=()
    local required_modules=("cf-ip/menu.sh" "cf-dns/setup.sh" "dnspod-dns/setup.sh" "scheduler/run.sh")
    
    for module in "${required_modules[@]}"; do
        if [[ ! -f "${INSTALL_DIR}/modules/${module}" ]]; then
            missing_modules+=("${module}")
        fi
    done
    
    if [[ ${#missing_modules[@]} -eq 0 ]]; then
        echo -e "${GREEN}正常${NC} (${#required_modules[@]} 个模块)"
    else
        echo -e "${RED}缺失${NC}"
        for mod in "${missing_modules[@]}"; do
            echo -e "       ${RED}- modules/${mod}${NC}"
        done
        has_issues=true
    fi
    
    # 3. 检查配置文件
    echo -n "[3/5] 检查配置文件... "
    local missing_configs=()
    local required_configs=("cf-ip.json" "cf-dns.json" "dnspod.json" "global.json")
    
    for config in "${required_configs[@]}"; do
        if [[ ! -f "${INSTALL_DIR}/conf/${config}" ]]; then
            missing_configs+=("${config}")
        fi
    done
    
    if [[ ${#missing_configs[@]} -eq 0 ]]; then
        echo -e "${GREEN}正常${NC} (${#required_configs[@]} 个配置)"
    else
        echo -e "${YELLOW}部分缺失${NC}"
        for cfg in "${missing_configs[@]}"; do
            echo -e "       ${YELLOW}- conf/${cfg}${NC}"
        done
    fi
    
    # 4. 检查依赖工具
    echo -n "[4/5] 检查依赖工具... "
    local missing_tools=()
    local required_tools=("curl" "jq" "openssl" "grep" "sed" "awk")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            missing_tools+=("${tool}")
        fi
    done
    
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        echo -e "${GREEN}正常${NC} (${#required_tools[@]} 个工具)"
    else
        echo -e "${RED}缺失${NC}"
        for tool in "${missing_tools[@]}"; do
            echo -e "       ${RED}- ${tool}${NC}"
        done
        has_issues=true
    fi
    
    # 5. 检查目录权限
    echo -n "[5/5] 检查目录权限... "
    local permission_issues=()
    local check_dirs=("${INSTALL_DIR}" "${INSTALL_DIR}/conf" "${INSTALL_DIR}/modules" "${INSTALL_DIR}/logs")
    
    for dir in "${check_dirs[@]}"; do
        if [[ -d "${dir}" ]] && [[ ! -w "${dir}" ]]; then
            permission_issues+=("${dir}")
        fi
    done
    
    if [[ ${#permission_issues[@]} -eq 0 ]]; then
        echo -e "${GREEN}正常${NC}"
    else
        echo -e "${RED}权限问题${NC}"
        for dir in "${permission_issues[@]}"; do
            echo -e "       ${RED}- ${dir} (不可写)${NC}"
        done
        has_issues=true
    fi
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 显示检测结果并提供修复
    if [[ "${has_issues}" = true ]]; then
        echo -e " ${RED}[警告] 检测到系统问题${NC}"
        echo ""
        echo -e "${YELLOW}是否立即执行自动修复？${NC}"
        read -r -p "请输入 y 确认修复 (默认n): " FIX_CHOICE
        
        if [[ "${FIX_CHOICE}" =~ ^[Yy]$ ]]; then
            echo ""
            log_info "开始执行自动修复..."
            echo ""
            
            # 执行修复
            local fixed_count=0
            
            # 修复全局命令
            if [[ -e "${SYSTEM_CMD_PATH}" ]] && ! check_system_cmd; then
                echo -n "正在修复全局命令... "
                if fix_system_cmd "$(readlink -f "$0")"; then
                    echo -e "${GREEN}成功${NC}"
                    ((fixed_count++))
                else
                    echo -e "${RED}失败${NC}"
                fi
            fi
            
            # 修复缺失模块（通过更新功能）
            if [[ ${#missing_modules[@]} -gt 0 ]]; then
                echo -e "${CYAN}[INFO] 请使用主菜单的 '5. 检查组件更新' 来下载缺失的模块${NC}"
            fi
            
            # 修复缺失配置
            if [[ ${#missing_configs[@]} -gt 0 ]]; then
                echo -e "${CYAN}[INFO] 请使用各模块的配置向导来生成配置文件${NC}"
            fi
            
            # 修复依赖
            if [[ ${#missing_tools[@]} -gt 0 ]]; then
                echo -n "正在安装依赖工具... "
                local install_cmd=""
                if command -v apt-get &>/dev/null; then
                    install_cmd="apt-get install -y"
                elif command -v yum &>/dev/null; then
                    install_cmd="yum install -y"
                elif command -v apk &>/dev/null; then
                    install_cmd="apk add"
                fi
                
                if [[ -n "${install_cmd}" ]]; then
                    if sudo bash -c "${install_cmd} ${missing_tools[*]}" &>/dev/null; then
                        echo -e "${GREEN}成功${NC}"
                        ((fixed_count++))
                    else
                        echo -e "${RED}失败${NC} (请手动安装)"
                    fi
                else
                    echo -e "${YELLOW}跳过${NC} (无法识别包管理器)"
                fi
            fi
            
            echo ""
            if [[ ${fixed_count} -gt 0 ]]; then
                log_success "已完成 ${fixed_count} 项修复，请重新运行检测确认"
            else
                log_warning "没有执行任何修复操作"
            fi
            echo ""
            read -r -p "按回车键返回主菜单..."
        else
            echo ""
            log_info "已取消修复"
            echo ""
            read -r -p "按回车键返回主菜单..." || true
        fi
    else
        echo -e " ${GREEN}[OK] 所有检测项均正常${NC}"
        echo ""
        read -r -p "按回车键返回主菜单..." || true
    fi
}

# --- 主菜单逻辑 ---
show_main_menu() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e " ${GRAY}版本: v${SCRIPT_VERSION}  |  项目仓库: ${CYAN}https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 加载状态配置
    STATUS_CONF="${INSTALL_DIR}/conf/status.conf"
    if [[ -f "${STATUS_CONF}" ]]; then
        # shellcheck disable=SC1090
        source "${STATUS_CONF}"
    fi
    
    # 【新增】检测并自动下载 cfst（如果缺失）
    local cfst_bin="${INSTALL_DIR}/assets/cfst/cfst"
    if [[ ! -f "${cfst_bin}" ]]; then
        echo -e "${YELLOW}[INFO] 检测到测速程序 cfst 缺失，正在自动下载...${NC}"
        echo ""
        
        # 使用自定义镜像源下载（仅支持 amd64，服务器主流架构）
        local cfst_url="http://mirror.drxian.qzz.io/resource/cfst_linux_amd64.tar.gz"
        local cfst_temp="/tmp/cfst_download.tar.gz"
        
        mkdir -p "${INSTALL_DIR}/assets/cfst"
        
        if curl -sfL --connect-timeout 10 --max-time 60 -o "${cfst_temp}" "${cfst_url}" 2>/dev/null; then
            if tar -xzf "${cfst_temp}" -C "${INSTALL_DIR}/assets/cfst/" 2>/dev/null; then
                local cfst_file
                cfst_file=$(find "${INSTALL_DIR}/assets/cfst/" -name "cfst" -type f 2>/dev/null | head -1)
                if [[ -n "${cfst_file}" ]] && [[ -f "${cfst_file}" ]]; then
                    chmod +x "${cfst_file}"
                    log_success "cfst 测速程序已安装: ${cfst_file}"
                else
                    log_warning "cfst 解压后未找到可执行文件"
                fi
            else
                log_warning "cfst 解压失败"
            fi
            rm -f "${cfst_temp}"
        else
            log_warning "cfst 下载失败，请检查网络连接或手动安装"
        fi
        
        echo ""
        read -r -p "按回车键继续..."
        clear
    fi
    
    # 获取各模块状态
    local cf_ip_status
    cf_ip_status="$(get_module_status "${INSTALL_DIR}/conf/cf-ip.json" "${INSTALL_DIR}/assets/data/cf-ip/result.csv")"
    local cf_dns_status
    cf_dns_status="$(get_module_status "${INSTALL_DIR}/conf/cf-dns.json" "${INSTALL_DIR}/assets/data/cf-dns/ip_list.txt")"
    local dnspod_status
    dnspod_status="$(get_module_status "${INSTALL_DIR}/conf/dnspod.json" "${INSTALL_DIR}/assets/data/dnspod-dns/ip_list.txt")"
    local scheduler_status="${SCHEDULER_ENABLED:-false}"
    if [[ "${scheduler_status}" = "true" ]]; then
        scheduler_status="$(echo -e "${GREEN}[RUN]${NC}")"
    else
        scheduler_status="$(echo -e "${GRAY}[STOP]${NC}")"
    fi

    echo -e " ${CYAN}[系统状态]${NC}"
    echo -e "   CF-IP 测速: ${cf_ip_status}   |   自动化调度: ${scheduler_status}"
    echo -e "   CF DNS 更新: ${cf_dns_status}   |   DNSPod 更新: ${dnspod_status}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    echo -e " ${GREEN}➤${NC} 1. 快速部署向导     ${CYAN}- 5分钟完成 CF-IP + DNS 配置${NC}"
    echo -e " ${GREEN}➤${NC} 2. CF IP 优选管理     ${CYAN}- 测速程序、参数配置、定时任务${NC}"
    echo -e " ${GREEN}➤${NC} 3. CF DNS 记录更新    ${CYAN}- 将优选 IP 同步到 Cloudflare DNS${NC}"
    echo -e " ${GREEN}➤${NC} 4. DNSPod DNS 更新    ${CYAN}- 腾讯云 DNSPod 分线路解析管理${NC}"
    echo -e " ${GREEN}➤${NC} 5. 自动化调度中心    ${CYAN}- 一键执行全链路测速、同步与更新${NC}"
    echo -e " ${GREEN}➤${NC} 6. 检查组件更新       ${CYAN}- 同步远程最新版本${NC}"
    echo -e " ${GREEN}➤${NC} 7. 系统健康检测       ${CYAN}- 检测并修复系统问题${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 9. 一键跑路         ${CYAN}- 删除脚本及相关配置${NC}"
    echo -e " ${RED}➤${NC} 0. 退出程序"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 确保从终端读取输入，防止管道安装时 stdin 被占用
    local input_device="/dev/tty"
    if [[ ! -e "${input_device}" ]]; then
        input_device="/dev/stdin"
    fi

    read -r -p "请选择功能 [0-7, 9]: " choice < "${input_device}"

    case "${choice}" in
        1)
            export CF_OPT_ENTRY="main_menu"
            bash "${INSTALL_DIR}/modules/quick-deploy/setup.sh" || true
            ;;
        2)
            export CF_OPT_ENTRY="main_menu"
            bash "${INSTALL_DIR}/modules/cf-ip/menu.sh" || true
            ;;
        3)
            export CF_OPT_ENTRY="main_menu"
            bash "${INSTALL_DIR}/modules/cf-dns/setup.sh" || true
            ;;
        4)
            export CF_OPT_ENTRY="main_menu"
            bash "${INSTALL_DIR}/modules/dnspod-dns/setup.sh" || true
            ;;
        5)
            manage_scheduler
            ;;
        6)
            check_and_update_components
            ;;
        7)
            system_health_check
            ;;
        9)
            uninstall_cfopt
            ;;
        0)
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重试。${NC}"
            sleep 1
            # 不递归，由外层 while 循环继续
            ;;
    esac
}

# ====================== 【组件更新逻辑】 ======================

# --- 自动化调度管理逻辑 ---
manage_scheduler() {
    while true; do
        clear
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        echo -e " ${YELLOW}自动化调度管理中心${NC}"
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        
        # 检测当前定时任务状态
        local cron_status="未配置"
        local cron_info
        cron_info="$(crontab -l 2>/dev/null | grep "scheduler/run.sh" || true)"
        if [[ -n "${cron_info}" ]]; then
            cron_status="${GREEN}已启用${NC}"
        else
            cron_status="${RED}未启用${NC}"
        fi
        
        echo -e " 当前状态: ${cron_status}"
        echo -e " 执行脚本: ${INSTALL_DIR}/modules/scheduler/run.sh"
        echo ""
        echo -e " ${GREEN}➤${NC} 1. 立即执行一次       ${CYAN}- 手动触发全链路测速与更新${NC}"
        echo -e " ${GREEN}➤${NC} 2. 启用/修改定时任务   ${CYAN}- 设置自动运行间隔${NC}"
        echo -e " ${GREEN}➤${NC} 3. 停止定时任务       ${CYAN}- 取消后台自动执行${NC}"
        echo -e " ${GREEN}➤${NC} 4. 查看调用命令       ${CYAN}- 获取宝塔/1Panel Cron 指令${NC}"
        echo ""
        echo -e " ${RED}➤${NC} 0. 返回主菜单"
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        read -r -p "请选择功能 [0-4]: " sched_choice
        
        case "${sched_choice}" in
            1)
                clear
                if [[ -f "${INSTALL_DIR}/modules/scheduler/run.sh" ]]; then
                    bash "${INSTALL_DIR}/modules/scheduler/run.sh"
                else
                    echo -e "${RED}[ERROR] 调度组件不存在。${NC}"
                fi
                read -r -p "按回车键继续..."
                ;;
            2)
                setup_auto_cron
                ;;
            3)
                if crontab -l 2>/dev/null | grep -q "scheduler/run.sh"; then
                    (crontab -l 2>/dev/null | grep -v "scheduler/run.sh") | crontab -
                    echo -e "${GREEN}[OK] 定时任务已停止。${NC}"
                else
                    echo -e "${YELLOW}[INFO] 当前没有正在运行的定时任务。${NC}"
                fi
                read -r -p "按回车键继续..."
                ;;
            4)
                show_panel_commands
                ;;
            0)
                break
                ;;
        esac
    done
}

# --- 定时任务配置逻辑 ---
setup_auto_cron() {
    # 检查系统是否安装 crontab
    if ! command -v crontab &> /dev/null; then
        echo -e "${RED}[ERROR] 系统未检测到 crontab 组件。${NC}"
        echo -e "${YELLOW}提示:${NC} 定时任务依赖于 cronie (CentOS) 或 cron (Debian/Ubuntu)."
        read -r -p "是否现在尝试自动安装？(y/n，默认y): " INSTALL_CRON
        INSTALL_CRON="${INSTALL_CRON:-y}"
        
        if [[ "${INSTALL_CRON}" =~ ^[Yy]$ ]]; then
            local install_cmd=""
            if command -v apt-get &> /dev/null; then
                install_cmd="apt-get update && apt-get install -y cron"
            elif command -v yum &> /dev/null; then
                install_cmd="yum install -y cronie"
            elif command -v dnf &> /dev/null; then
                install_cmd="dnf install -y cronie"
            elif command -v apk &> /dev/null; then
                install_cmd="apk add --no-cache busybox-suid openrc && rc-update add cron default && service cron start"
            fi

            if [[ -n "${install_cmd}" ]]; then
                echo -e "${CYAN}[INFO] 正在执行安装命令...${NC}"
                if sudo bash -c "${install_cmd}"; then
                    # 尝试启动服务
                    sudo systemctl enable crond 2>/dev/null || sudo service cron start 2>/dev/null || true
                    echo -e "${GREEN}[OK] 安装成功！正在进入配置界面...${NC}"
                else
                    echo -e "${RED}[ERROR] 自动安装失败，请手动安装后重试。${NC}"
                    read -r -p "按回车键继续..."
                    return
                fi
            else
                echo -e "${RED}[ERROR] 无法识别当前系统的包管理器，请手动安装 cron。${NC}"
                read -r -p "按回车键继续..."
                return
            fi
        else
            echo -e "${YELLOW}[INFO] 已取消安装。${NC}"
            read -r -p "按回车键继续..."
            return
        fi
    fi

    echo ""
    echo -e "${YELLOW}请选择执行频率：${NC}"
    echo "  1) 每 4 小时执行一次 (推荐，保持最优速度)"
    echo "  2) 每 6 小时执行一次 (平衡性能与资源)"
    echo "  3) 每天凌晨 3:00 (低频，节省资源)"
    echo "  4) 每天凌晨 3:00 和下午 3:00 (每日两次)"
    echo "  5) 每小时执行一次 (极致追新，适合高要求)"
    echo "  6) 自定义 Cron 表达式"
    echo ""
    read -r -p "请输入选项 [1-6] (默认 1): " freq_choice
    freq_choice="${freq_choice:-1}"
    
    local cron_expr="0 */4 * * *"
    case "${freq_choice}" in
        1) cron_expr="0 */4 * * *" ;;
        2) cron_expr="0 */6 * * *" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3,15 * * *" ;;
        5) cron_expr="0 * * * *" ;;
        6) 
            echo -e "${CYAN}提示:${NC} Cron 格式为 '分 时 日 月 周'"
            read -r -p "请输入 Cron 表达式: " custom_cron
            if [[ -n "${custom_cron}" ]]; then
                cron_expr="${custom_cron}"
            fi
            ;;
    esac
    
    local log_file="${INSTALL_DIR}/logs/scheduler.log"
    mkdir -p "$(dirname "${log_file}")"
    local full_cmd="${cron_expr} /bin/bash ${INSTALL_DIR}/modules/scheduler/run.sh >> ${log_file} 2>&1"
    
    # 移除旧的定时任务，添加新的
    (crontab -l 2>/dev/null | grep -v "scheduler/run.sh"; echo "${full_cmd}") | crontab -
    
    echo ""
    echo -e "${GREEN}[OK] 定时任务已成功设置！${NC}"
    echo -e "   频率: ${YELLOW}${cron_expr}${NC}"
    echo -e "   日志: ${CYAN}${log_file}${NC}"
    read -r -p "按回车键继续..."
}

# --- 面板命令生成器 ---
show_panel_commands() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}面板 Cron 命令生成器 (宝塔/1Panel)${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${YELLOW}操作说明:${NC}"
    echo "  1. 在面板中选择【计划任务】->【添加任务】->【Shell脚本】"
    echo "  2. 设置好执行周期（如每天 3:00）"
    echo "  3. 将下方的【脚本内容】复制粘贴到输入框中"
    echo ""
    echo -e "${GREEN}--- 脚本内容 (直接复制下方整行) ---${NC}"
    echo "/bin/bash ${INSTALL_DIR}/modules/scheduler/run.sh >> ${INSTALL_DIR}/logs/scheduler.log 2>&1"
    echo -e "${GREEN}-------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}提示:${NC} 请确保面板中的执行用户有权限访问 ${INSTALL_DIR} 目录。"
    read -r -p "按回车键返回..."
}

# ====================== 【安装全局命令】 ======================
install_system_cmd() {
    if [[ "${EUID}" -eq 0 ]]; then
        # root 用户，直接创建链接
        ln -sf "${INSTALL_DIR}/cfopt.sh" "${SYSTEM_CMD_PATH}" 2>/dev/null
        chmod +x "${SYSTEM_CMD_PATH}" 2>/dev/null
        if [[ -x "${SYSTEM_CMD_PATH}" ]]; then
            echo -e "${GREEN}[OK] 全局命令已安装: ${SYSTEM_CMD_PATH}${NC}"
        else
            echo -e "${YELLOW}[WARN] 全局命令安装失败，请手动执行: ln -sf ${INSTALL_DIR}/cfopt.sh ${SYSTEM_CMD_PATH}${NC}"
        fi
    elif command -v sudo >/dev/null 2>&1; then
        # 非 root 用户，尝试使用 sudo
        echo -e "${CYAN}[INFO] 正在尝试安装全局命令 (需要 sudo 权限)...${NC}"
        if sudo ln -sf "${INSTALL_DIR}/cfopt.sh" "${SYSTEM_CMD_PATH}" 2>/dev/null && \
           sudo chmod +x "${SYSTEM_CMD_PATH}" 2>/dev/null; then
            if [[ -x "${SYSTEM_CMD_PATH}" ]]; then
                echo -e "${GREEN}[OK] 全局命令已安装: ${SYSTEM_CMD_PATH}${NC}"
            else
                echo -e "${YELLOW}[WARN] 全局命令安装失败${NC}"
            fi
        else
            echo -e "${YELLOW}[WARN] 无法获取 sudo 权限，跳过全局命令安装${NC}"
            echo -e "${YELLOW}[提示] 您可以手动执行: sudo ln -sf ${INSTALL_DIR}/cfopt.sh ${SYSTEM_CMD_PATH}${NC}"
        fi
    else
        echo -e "${YELLOW}[WARN] 未找到 sudo，跳过全局命令安装${NC}"
    fi
}

# --- 一键跑路逻辑 (卸载清理) ---
uninstall_cfopt() {
    clear
    echo -e "${RED}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}[警告] 即将执行卸载清理 (一键跑路)${NC}"
    echo -e "${RED}+------------------------------------------------------------+${NC}"
    echo ""
    echo "此操作将永久删除以下内容："
    echo "  1. 安装目录: ${INSTALL_DIR}"
    echo "     - modules/ (所有模块文件)"
    echo "     - conf/ (所有配置文件)"
    echo "     - assets/ (测速数据和 IP 列表)"
    echo "     - logs/ (运行日志)"
    echo "  2. 全局命令: /usr/local/bin/cfopt"
    echo "  3. 定时任务: 所有包含 'cfopt' 的 Crontab 项"
    echo ""
    echo -e "${YELLOW}注意:${NC} 此操作不会卸载系统级组件 (如 crontab, wget 等)。"
    echo ""
    read -r -p "确认要彻底删除并跑路吗？(输入 yes 确认): " CONFIRM_UNINSTALL
    
    if [[ "${CONFIRM_UNINSTALL}" != "yes" ]]; then
        echo -e "${GREEN}[INFO] 已取消卸载，欢迎继续使用。${NC}"
        read -r -p "按回车键返回主菜单..."
        return
    fi

    # 1. 清理所有相关的 Crontab 定时任务
    echo -e "${CYAN}[INFO] 正在清理 Crontab 定时任务...${NC}"
    if command -v crontab &> /dev/null; then
        local current_cron
        current_cron=$(crontab -l 2>/dev/null || true)
        if [[ -n "${current_cron}" ]]; then
            # 清理所有包含 cfopt 路径的任务（更全面）
            local cleaned_cron
            cleaned_cron=$(echo "${current_cron}" | grep -v "cfopt" | grep -v "scheduler/run.sh")
            if [[ -n "${cleaned_cron}" ]]; then
                echo "${cleaned_cron}" | crontab -
            else
                crontab -r 2>/dev/null || echo "" | crontab -
            fi
            log_success "Crontab 定时任务已清理"
        else
            log_info "未检测到 Crontab 任务"
        fi
    fi

    # 2. 删除全局命令链接
    echo -e "${CYAN}[INFO] 正在删除全局命令链接...${NC}"
    if [[ -L /usr/local/bin/cfopt ]] || [[ -f /usr/local/bin/cfopt ]]; then
        if rm -f /usr/local/bin/cfopt 2>/dev/null; then
            log_success "全局命令已删除"
        else
            log_warning "删除全局命令失败，可能需要手动清理: sudo rm -f /usr/local/bin/cfopt"
        fi
    else
        log_info "全局命令不存在，跳过"
    fi

    # 3. 清理用户配置文件中的别名和环境变量（可选）
    echo -e "${CYAN}[INFO] 检查用户配置文件...${NC}"
    local config_files=("${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile")
    for config_file in "${config_files[@]}"; do
        if [[ -f "${config_file}" ]]; then
            if grep -q "cfopt" "${config_file}" 2>/dev/null; then
                log_warning "检测到 ${config_file} 中包含 cfopt 相关配置"
                log_warning "请手动清理以下行："
                grep "cfopt" "${config_file}" | sed 's/^/  /'
            fi
        fi
    done

    # 4. 删除安装目录及所有数据
    log_info "正在删除安装目录及所有数据..."
    if [[ -d "${INSTALL_DIR}" ]]; then
        # 显示将要删除的详细内容
        local dir_size
        dir_size=$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1)
        log_info "即将删除: ${INSTALL_DIR} (${dir_size})"
        
        # 列出主要子目录
        if [[ -d "${INSTALL_DIR}/modules" ]]; then
            local modules_count
            modules_count=$(find "${INSTALL_DIR}/modules" -type f 2>/dev/null | wc -l)
            echo -e "  ${CYAN}- modules/${NC} (${modules_count} 个文件)"
        fi
        if [[ -d "${INSTALL_DIR}/conf" ]]; then
            echo -e "  ${CYAN}- conf/${NC} (配置文件)"
        fi
        if [[ -d "${INSTALL_DIR}/assets" ]]; then
            local assets_size
            assets_size=$(du -sh "${INSTALL_DIR}/assets" 2>/dev/null | cut -f1)
            echo -e "  ${CYAN}- assets/${NC} (${assets_size})"
        fi
        if [[ -d "${INSTALL_DIR}/logs" ]]; then
            echo -e "  ${CYAN}- logs/${NC} (日志文件)"
        fi
        echo ""
        
        # 执行删除
        log_info "正在删除安装目录..."
        
        # 【关键修复】使用后台延迟删除，避免脚本文件被占用
        # 先创建一个临时脚本，在后台执行删除
        local cleanup_script
        cleanup_script=$(mktemp /tmp/cfopt_cleanup.XXXXXX.sh)
        
        cat > "${cleanup_script}" << 'CLEANUP_EOF'
#!/bin/bash
# 等待 3 秒，确保主脚本已完全退出
sleep 3

# 强制删除整个目录
INSTALL_DIR="$1"
LOG_FILE="/tmp/cfopt_cleanup.log"

echo "[$(date)] 开始清理: ${INSTALL_DIR}" >> "${LOG_FILE}"

if [[ -d "${INSTALL_DIR}" ]]; then
    # 第一遍：尝试终止所有相关进程（排除当前清理脚本）
    echo "[$(date)] 第1步: 终止相关进程" >> "${LOG_FILE}"
    # 使用更精确的匹配，只终止 cfopt.sh 主程序，不终止清理脚本
    pkill -9 -f "/cfopt\.sh" 2>/dev/null || true
    sleep 1
    
    # 第二遍：删除所有文件（包括隐藏文件）
    echo "[$(date)] 第2步: 删除所有文件" >> "${LOG_FILE}"
    find "${INSTALL_DIR}" -type f -exec rm -f {} \; 2>/dev/null || true
    
    # 第三遍：删除符号链接
    echo "[$(date)] 第3步: 删除符号链接" >> "${LOG_FILE}"
    find "${INSTALL_DIR}" -type l -delete 2>/dev/null || true
    
    # 第四遍：从内到外删除目录（深度优先）
    echo "[$(date)] 第4步: 删除目录结构" >> "${LOG_FILE}"
    find "${INSTALL_DIR}" -depth -type d -exec rmdir {} \; 2>/dev/null || true
    
    # 第五遍：强制删除根目录
    echo "[$(date)] 第5步: 强制删除根目录" >> "${LOG_FILE}"
    rm -rf "${INSTALL_DIR}" 2>/dev/null || true
    
    # 第六遍：如果还存在，使用更暴力的方法
    if [[ -d "${INSTALL_DIR}" ]]; then
        echo "[$(date)] 第6步: 使用 mount --bind 技巧" >> "${LOG_FILE}"
        # 创建一个空目录并挂载覆盖
        tmp_empty=$(mktemp -d)
        mount --bind "${tmp_empty}" "${INSTALL_DIR}" 2>/dev/null && {
            umount "${INSTALL_DIR}" 2>/dev/null
            rm -rf "${INSTALL_DIR}" 2>/dev/null
        } || true
        rm -rf "${tmp_empty}" 2>/dev/null || true
    fi
    
    # 验证删除结果
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        echo "[$(date)] [OK] cfopt 目录已完全删除" >> "${LOG_FILE}"
    else
        echo "[$(date)] [ERROR] 目录仍然存在: $(ls -la ${INSTALL_DIR} 2>/dev/null)" >> "${LOG_FILE}"
        echo "[$(date)] [WARN] 请手动执行: sudo rm -rf ${INSTALL_DIR}" >> "${LOG_FILE}"
    fi
else
    echo "[$(date)] [INFO] 目录不存在，无需清理" >> "${LOG_FILE}"
fi

# 清理临时脚本
rm -f "$0" 2>/dev/null || true
echo "[$(date)] 清理脚本执行完毕" >> "${LOG_FILE}"
CLEANUP_EOF
        
        chmod +x "${cleanup_script}"
        
        # 【关键修复】使用 setsid 确保后台进程独立于当前会话
        # 即使主脚本退出，清理进程也会继续运行
        if command -v setsid >/dev/null 2>&1; then
            # 优先使用 setsid（创建新会话）
            setsid bash "${cleanup_script}" "${INSTALL_DIR}" >> /tmp/cfopt_cleanup.log 2>&1 &
        else
            # 备用方案：使用 nohup + disown
            nohup bash "${cleanup_script}" "${INSTALL_DIR}" >> /tmp/cfopt_cleanup.log 2>&1 &
            disown 2>/dev/null || true
        fi
        local cleanup_pid=$!
        
        log_info "已启动后台清理进程 (PID: ${cleanup_pid})"
        log_info "脚本将在 3 秒后自动退出并删除目录..."
        log_info "详细日志: /tmp/cfopt_cleanup.log"
        
        # 注意：删除是异步执行的，不在此处验证
        log_success "卸载指令已发送，目录将在后台清理"
    else
        log_info "安装目录不存在，跳过"
    fi

    echo ""
    echo -e "${GREEN}+------------------------------------------------------------+${NC}"
    echo -e " ${GREEN}[OK] 清理完成！cfopt 已从您的系统中消失。${NC}"
    echo -e "${GREEN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${YELLOW}感谢曾经的陪伴，再见！${NC}"
    echo ""
    
    # 如果是通过全局命令运行的，提示用户
    if [[ "$(readlink -f "$0" 2>/dev/null)" = "/usr/local/bin/cfopt" ]]; then
        echo -e "${YELLOW}[提示] 如果您是通过 'cfopt' 命令运行的，该命令已被删除${NC}"
        echo ""
    fi
    
    exit 0
}

# --- 组件更新逻辑（委托给 updater 模块）---
check_and_update_components() {
    clear
    bash "${INSTALL_DIR}/modules/updater/update.sh" update
    # updater 模块已有"按回车键返回"提示，无需重复
    show_main_menu
}

# --- 初始化流程 ---
init_cfopt() {
    # 0. 检查是否有待应用的新版本 cfopt.sh
    if [[ -f "${INSTALL_DIR}/cfopt.sh.new" ]]; then
        log_info "检测到新版本主脚本，正在应用..."
        if mv "${INSTALL_DIR}/cfopt.sh.new" "${INSTALL_DIR}/cfopt.sh" 2>/dev/null; then
            chmod +x "${INSTALL_DIR}/cfopt.sh"
            log_success "主脚本已更新到最新版本"
            echo ""
            log_info "正在重新启动以加载新版本..."
            echo ""
            # 使用 exec 替换当前进程，自动进入主菜单
            exec bash "${INSTALL_DIR}/cfopt.sh"
        else
            log_error "应用新版本失败，请手动执行: mv ${INSTALL_DIR}/cfopt.sh.new ${INSTALL_DIR}/cfopt.sh"
            echo ""
        fi
    fi
    
    # 1. 环境检测
    check_environment

    # 2. 智能启动检测
    STATUS_CONF="${INSTALL_DIR}/conf/status.conf"
    
    # 核心判断：如果状态文件存在、标记为已安装、且核心模块文件齐全，则直接进入主菜单
    if [[ -f "${STATUS_CONF}" ]] && \
       grep -q '^INSTALL_CHECKED="true"' "${STATUS_CONF}" && \
       [[ -f "${INSTALL_DIR}/modules/cf-ip/menu.sh" ]] && \
       [[ -f "${INSTALL_DIR}/modules/scheduler/run.sh" ]] && \
       [[ -f "${INSTALL_DIR}/modules/updater/update.sh" ]]; then
        # 已安装完成，直接进入主菜单循环
        while true; do
            show_main_menu
        done
    fi
    
    # 否则，继续执行初始化安装流程
    
    # 3. 安装前确认
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}安装前确认${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " 即将执行以下操作："
    echo -e "   1. 创建安装目录: ${GREEN}${INSTALL_DIR}${NC}"
    echo -e "   2. 下载并配置核心组件 (CF-IP, DNS, Scheduler)"
    if [[ "${EUID}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        echo -e "   3. 尝试安装全局命令: ${GREEN}/usr/local/bin/cfopt${NC} (需要 sudo 权限)"
    elif [[ "${EUID}" -eq 0 ]]; then
        echo -e "   3. 安装全局命令: ${GREEN}/usr/local/bin/cfopt${NC}"
    fi
    echo ""
    read -r -p "是否继续安装？(y/n，默认y): " CONFIRM_INSTALL < /dev/tty
    CONFIRM_INSTALL="${CONFIRM_INSTALL:-y}"
        
    if [[ ! "${CONFIRM_INSTALL}" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[INFO] 已取消安装。${NC}"
        exit 0
    fi
    
    # 4. 安装全局命令
    install_system_cmd

    # 4. 创建目录结构
    mkdir -p "${INSTALL_DIR}/modules/manager" \
             "${INSTALL_DIR}/modules/quick-deploy" \
             "${INSTALL_DIR}/modules/cf-ip" \
             "${INSTALL_DIR}/modules/cf-dns" \
             "${INSTALL_DIR}/modules/dnspod-dns" \
             "${INSTALL_DIR}/modules/scheduler" \
             "${INSTALL_DIR}/modules/ip-sync" \
             "${INSTALL_DIR}/modules/updater" \
             "${INSTALL_DIR}/assets/cfst" \
             "${INSTALL_DIR}/assets/data/cf-ip" \
             "${INSTALL_DIR}/assets/data/cf-dns" \
             "${INSTALL_DIR}/assets/data/dnspod-dns" \
             "${INSTALL_DIR}/conf/templates" \
             "${INSTALL_DIR}/logs"

    # 4.1 下载 updater 模块（用于后续更新检查）
    echo -e "${CYAN}[INFO] 正在下载核心组件...${NC}"
    
    # 定义需要下载的核心模块列表
    local core_modules=(
        "modules/updater/update.sh"
        "modules/quick-deploy/setup.sh"
        "modules/cf-ip/menu.sh"
        "modules/cf-ip/core.sh"
        "modules/cf-dns/core.sh"
        "modules/cf-dns/setup.sh"
        "modules/dnspod-dns/core.sh"
        "modules/dnspod-dns/setup.sh"
        "modules/scheduler/run.sh"
        "modules/ip-sync/sync.sh"
    )
    
    local download_success=true
    for module_path in "${core_modules[@]}"; do
        local module_name
        module_name=$(basename "${module_path}")
        echo -e "  ${CYAN}[INFO] 正在下载 ${module_name}...${NC}"
        
        # 优先使用镜像源
        if ! download_with_retry "${REMOTE_URL_MIRROR}/${module_path}" \
                                 "${INSTALL_DIR}/${module_path}"; then
            # 镜像源失败，尝试官方源
            if ! download_with_retry "${REMOTE_URL}/${module_path}" \
                                     "${INSTALL_DIR}/${module_path}"; then
                log_warning "${module_name} 下载失败"
                download_success=false
            fi
        fi
        chmod +x "${INSTALL_DIR}/${module_path}" 2>/dev/null || true
    done
    
    if [[ "${download_success}" = true ]]; then
        log_success "所有核心组件下载完成"
    else
        log_warning "部分组件下载失败，稍后可通过菜单手动更新"
    fi
    
    # 4.2 下载 cfst 测速程序（CF-IP 核心依赖）
    echo -e "${CYAN}[INFO] 正在下载 cfst 测速程序...${NC}"
    local cfst_url="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareST_linux_amd64.tar.gz"
    local cfst_temp="/tmp/cfst_download.tar.gz"
    
    if curl -sfL --connect-timeout 10 --max-time 60 -o "${cfst_temp}" "${cfst_url}" 2>/dev/null; then
        # 解压并移动到目标位置
        if tar -xzf "${cfst_temp}" -C "${INSTALL_DIR}/assets/cfst/" 2>/dev/null; then
            # 找到解压后的 cfst 文件
            local cfst_file
            cfst_file=$(find "${INSTALL_DIR}/assets/cfst/" -name "cfst" -type f 2>/dev/null | head -1)
            if [[ -n "${cfst_file}" ]] && [[ -f "${cfst_file}" ]]; then
                chmod +x "${cfst_file}"
                log_success "cfst 测速程序已安装: ${cfst_file}"
            else
                log_warning "cfst 解压后未找到可执行文件"
            fi
        else
            log_warning "cfst 解压失败"
        fi
        rm -f "${cfst_temp}"
    else
        log_warning "cfst 下载失败，请手动运行 CF-IP 测速以自动安装"
    fi

    # 初始化状态配置文件 (如果不存在)
    STATUS_CONF="${INSTALL_DIR}/conf/status.conf"
    if [[ ! -f "${STATUS_CONF}" ]]; then
        cat > "${STATUS_CONF}" << 'EOF'
# cfopt 模块状态配置文件
CF_IP_ENABLED="true"
CF_DNS_ENABLED="false"
DNSPOD_ENABLED="false"
SCHEDULER_ENABLED="false"
LAST_UPDATE_TIME=""
INSTALL_CHECKED="true"
EOF
    else
        # 如果文件已存在但未标记，则追加标记
        if ! grep -q '^INSTALL_CHECKED=' "${STATUS_CONF}"; then
            echo 'INSTALL_CHECKED="true"' >> "${STATUS_CONF}"
        fi
    fi

    # 5. 初次安装完成，直接进入主菜单
    log_info "初始化完成，正在进入主菜单..."
    echo ""

    # 7. 进入主菜单循环
    clear
    while true; do
        show_main_menu
        # show_main_menu 是递归函数，选择 0 时会 exit
        # 其他选项执行完毕后会自动继续循环
    done
}

# 启动执行
init_cfopt
