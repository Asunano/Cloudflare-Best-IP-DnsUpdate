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
SCRIPT_VERSION="0.1.1"

# 直接使用 GitHub 原始地址，避免缓存导致的更新延迟
REMOTE_URL="https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main"
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
        "https://raw.githubusercontent.com"
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

# --- 自动回滚机制 ---
# 备份当前版本，更新失败时可快速恢复
backup_current_version() {
    local backup_dir="${INSTALL_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
    
    # 如果安装目录不存在，无需备份
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        return 0
    fi
    
    mkdir -p "${backup_dir}"
    
    # 备份配置文件
    if [[ -d "${INSTALL_DIR}/conf" ]]; then
        if ! safe_copy "${INSTALL_DIR}/conf" "${backup_dir}/conf" "备份配置文件"; then
            log_warning "配置文件备份失败，继续执行..."
        fi
    fi
    
    # 备份模块文件
    if [[ -d "${INSTALL_DIR}/modules" ]]; then
        if ! safe_copy "${INSTALL_DIR}/modules" "${backup_dir}/modules" "备份模块文件"; then
            log_warning "模块文件备份失败，继续执行..."
        fi
    fi
    
    # 记录版本信息
    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${backup_dir}/timestamp.txt"
    echo "Backup created at: $(date)" >> "${backup_dir}/README.txt"
    
    echo -e "${GREEN}[OK] 备份完成: ${backup_dir}${NC}"
}

# 更新失败时回滚到上一版本
rollback_on_failure() {
    local latest_backup
    latest_backup=$(ls -t "${INSTALL_DIR}/backups/" 2>/dev/null | head -1)
    
    if [[ -n "${latest_backup}" ]] && [[ -d "${INSTALL_DIR}/backups/${latest_backup}" ]]; then
        log_warning "检测到更新失败，正在回滚到上一版本..."
        
        # 回滚配置文件
        if [[ -d "${INSTALL_DIR}/backups/${latest_backup}/conf" ]]; then
            if safe_remove_dir "${INSTALL_DIR}/conf" "清理旧配置" && \
               safe_copy "${INSTALL_DIR}/backups/${latest_backup}/conf" "${INSTALL_DIR}/conf" "恢复配置"; then
                log_success "配置文件已回滚"
            else
                log_error "配置文件回滚失败"
            fi
        fi
        
        # 回滚模块文件
        if [[ -d "${INSTALL_DIR}/backups/${latest_backup}/modules" ]]; then
            if safe_remove_dir "${INSTALL_DIR}/modules" "清理旧模块" && \
               safe_copy "${INSTALL_DIR}/backups/${latest_backup}/modules" "${INSTALL_DIR}/modules" "恢复模块"; then
                log_success "模块文件已回滚"
            else
                log_error "模块文件回滚失败"
            fi
        fi
        
        log_success "回滚成功，系统已恢复到: ${latest_backup}"
        return 0
    else
        log_error "无可用备份，请手动修复或重新安装"
        return 1
    fi
}

# --- 辅助函数：带重试的下载与校验 ---
download_with_retry() {
    local url="$1"
    local output="$2"
    local expected_hash="${3:-}"  # 可选参数：预期的 SHA256 哈希值
    local max_retries=3
    local retry_count=0
    
    while [[ "${retry_count}" -lt "${max_retries}" ]]; do
        # 确保输出文件的父目录存在且可写
        local output_dir
        output_dir="$(dirname "${output}")"
        if ! mkdir -p "${output_dir}" 2>/dev/null; then
            echo -e "${RED}[ERROR] 无法创建目录: ${output_dir}${NC}"
            return 1
        fi
        
        # 使用 curl 进行下载，仅显示进度条
        if curl -sfL --connect-timeout 10 --max-time 60 --create-dirs -o "${output}" "${url}" 2>/dev/null; then
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
            
            # 3. HTML 错误页检查
            if grep -q "403 Forbidden" "${output}" 2>/dev/null || \
               grep -q "404 Not Found" "${output}" 2>/dev/null || \
               grep -q "<html" "${output}" 2>/dev/null || \
               grep -q "<!DOCTYPE" "${output}" 2>/dev/null; then
                echo -e "${YELLOW}[WARN] 下载到 HTML 错误页，正在重试...${NC}"
                continue
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
            local curl_exit_code=$?
            echo -e "${YELLOW}[WARN] 下载失败 (退出码: ${curl_exit_code})，正在重试...${NC}"
            if [[ "${curl_exit_code}" -eq 23 ]]; then
                echo -e "${RED}[ERROR] 写入错误：请检查磁盘空间或目录权限${NC}"
            fi
        fi
        retry_count=$((retry_count + 1))
        if [[ "${retry_count}" -lt "${max_retries}" ]]; then
            sleep 2
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
    echo -e " ${YELLOW}cfopt - Cloudflare 优选与 DNS 管理套件 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 加载状态配置
    STATUS_CONF="${INSTALL_DIR}/conf/status.conf"
    if [[ -f "${STATUS_CONF}" ]]; then
        # shellcheck disable=SC1090
        source "${STATUS_CONF}"
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
    echo "  2. 全局命令: /usr/local/bin/cfopt"
    echo "  3. 定时任务: 所有包含 'scheduler/run.sh' 的 Crontab 项"
    echo ""
    echo -e "${YELLOW}注意:${NC} 此操作不会卸载系统级组件 (如 crontab, wget 等)。"
    echo ""
    read -r -p "确认要彻底删除并跑路吗？(输入 yes 确认): " CONFIRM_UNINSTALL
    
    if [[ "${CONFIRM_UNINSTALL}" != "yes" ]]; then
        echo -e "${GREEN}[INFO] 已取消卸载，欢迎继续使用。${NC}"
        read -r -p "按回车键返回主菜单..."
        return
    fi

    echo -e "${CYAN}[INFO] 正在清理 Crontab 定时任务...${NC}"
    if command -v crontab &> /dev/null; then
        (crontab -l 2>/dev/null | grep -v "scheduler/run.sh") | crontab -
    fi

    echo -e "${CYAN}[INFO] 正在删除全局命令链接...${NC}"
    if [[ -f /usr/local/bin/cfopt ]]; then
        if ! rm -f /usr/local/bin/cfopt 2>/dev/null; then
            log_warning "删除全局命令失败，可能需要手动清理"
        fi
    fi

    log_info "正在删除安装目录及所有数据..."
    if ! safe_remove_dir "${INSTALL_DIR}" "卸载清理"; then
        log_error "卸载失败，请手动删除: ${INSTALL_DIR}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}[OK] 清理完成！cfopt 已从您的系统中消失。${NC}"
    echo -e "${YELLOW}感谢曾经的陪伴，再见！${NC}"
    echo ""
    exit 0
}

# --- 组件更新逻辑 ---
check_and_update_components() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}正在检查组件更新...${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    echo -e "${CYAN}[INFO] 正在连接远程服务器获取版本信息...${NC}"
    echo -e "${GRAY}[DEBUG] URL: ${VERSION_FILE_REMOTE}${NC}"
    
    # 添加时间戳参数避免 CDN 缓存
    REMOTE_VERSIONS="$(curl -sfL --connect-timeout 10 --max-time 30 "${VERSION_FILE_REMOTE}?t=$(date +%s)" 2>&1)"
    local curl_exit=$?
    
    if [[ "${curl_exit}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] 连接远程服务器失败 (退出码: ${curl_exit})${NC}"
        echo -e "${YELLOW}[DEBUG] 请检查网络连接或防火墙设置${NC}"
        echo ""
        read -r -p "按回车键返回主菜单..."
        show_main_menu
        return
    fi
    
    if [[ -z "${REMOTE_VERSIONS}" ]]; then
        echo -e "${RED}[ERROR] 远程服务器返回空数据${NC}"
        echo ""
        read -r -p "按回车键返回主菜单..."
        show_main_menu
        return
    fi
    
    echo -e "${GREEN}[OK] 版本信息获取成功${NC}"
    echo ""

    # 定义模块映射: [KEY]="本地路径:远程文件"
    declare -A MODULE_MAP
    MODULE_MAP=(
        ["QUICK_DEPLOY"]="${INSTALL_DIR}/modules/quick-deploy/setup.sh:modules/quick-deploy/setup.sh"
        ["CF_IP_MENU"]="${INSTALL_DIR}/modules/cf-ip/menu.sh:modules/cf-ip/menu.sh"
        ["CF_IP_CORE"]="${INSTALL_DIR}/modules/cf-ip/core.sh:modules/cf-ip/core.sh"
        ["CF_DNS_CORE"]="${INSTALL_DIR}/modules/cf-dns/core.sh:modules/cf-dns/core.sh"
        ["CF_DNS_SETUP"]="${INSTALL_DIR}/modules/cf-dns/setup.sh:modules/cf-dns/setup.sh"
        ["DNSPOD_CORE"]="${INSTALL_DIR}/modules/dnspod-dns/core.sh:modules/dnspod-dns/core.sh"
        ["DNSPOD_SETUP"]="${INSTALL_DIR}/modules/dnspod-dns/setup.sh:modules/dnspod-dns/setup.sh"
        ["SCHEDULER_RUN"]="${INSTALL_DIR}/modules/scheduler/run.sh:modules/scheduler/run.sh"
        ["IP_SYNC"]="${INSTALL_DIR}/modules/ip-sync/sync.sh:modules/ip-sync/sync.sh"
        ["CFOPT_ENTRY"]="${INSTALL_DIR}/cfopt.sh:cfopt.sh"
    )

    HAS_UPDATE=false
    HAS_ERROR=false
    TEMP_DIR="$(mktemp -d)"
    
    # 计数器：用于显示进度
    TOTAL_FILES=${#MODULE_MAP[@]}
    CURRENT_FILE=0
    
    for KEY in "${!MODULE_MAP[@]}"; do
        CURRENT_FILE=$((CURRENT_FILE + 1))
        IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
        
        REMOTE_INFO="$(echo "${REMOTE_VERSIONS}" | grep "^${KEY}=" | cut -d'=' -f2)"
        REMOTE_VER="$(echo "${REMOTE_INFO}" | cut -d':' -f1)"
        REMOTE_HASH="$(echo "${REMOTE_INFO}" | cut -d':' -f2)"
        
        LOCAL_VER="0.0"
        LOCAL_HASH=""
        if [[ -f "${LOCAL_PATH}" ]]; then
            LOCAL_VER="$(grep -m1 "^SCRIPT_VERSION=" "${LOCAL_PATH}" | awk -F'"' '{print $2}')"
            [[ -z "${LOCAL_VER}" ]] && LOCAL_VER="0.0"
            # 计算本地文件哈希
            LOCAL_HASH="$(sha256sum "${LOCAL_PATH}" | awk '{print $1}')"
        fi

        # 【核心逻辑】判断是否需要下载：
        # 1. 文件不存在 -> 必须下载
        # 2. 版本号不同 -> 以云端为准，需要更新
        # 3. 版本号相同但哈希不同 -> 内容已变更，需要更新
        NEED_DOWNLOAD=false
        if [[ ! -f "${LOCAL_PATH}" ]]; then
            NEED_DOWNLOAD=true
            echo -e "${CYAN}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 下载 ${KEY}...${NC}"
        elif [[ -n "${REMOTE_VER}" ]] && [[ "${REMOTE_VER}" != "${LOCAL_VER}" ]]; then
            # 版本号不同，以云端为准
            NEED_DOWNLOAD=true
            echo -e "${CYAN}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 更新 ${KEY} (v${LOCAL_VER} -> v${REMOTE_VER})...${NC}"
        elif [[ -n "${REMOTE_HASH}" ]] && [[ -n "${LOCAL_HASH}" ]] && [[ "${REMOTE_HASH}" != "${LOCAL_HASH}" ]]; then
            # 版本号相同但哈希不同，说明内容已修改
            NEED_DOWNLOAD=true
            echo -e "${YELLOW}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 更新 ${KEY} (内容已变更)...${NC}"
        fi

        if [[ "${NEED_DOWNLOAD}" = true ]]; then
            # 确保目标目录存在
            mkdir -p "$(dirname "${LOCAL_PATH}")" 2>/dev/null
            
            # 下载到临时目录进行验证
            local temp_file="${TEMP_DIR}/${REMOTE_FILE}"
            mkdir -p "$(dirname "${temp_file}")" 2>/dev/null
            
            if download_with_retry "${REMOTE_URL}/${REMOTE_FILE}" "${temp_file}" "${REMOTE_HASH}"; then
                HAS_UPDATE=true
                # 验证通过后，标记为待应用
            else
                HAS_ERROR=true
                echo -e "  ${RED}[FAIL]${NC}   ${KEY} 更新失败 (请检查 version.txt 哈希值或网络)"
                rm -f "${temp_file}" 2>/dev/null
            fi
        else
            echo -e "  ${GREEN}[OK]${NC}      ${KEY}: ${LOCAL_VER} (最新)"
        fi
    done

    echo ""
    if [[ "${HAS_UPDATE}" = true ]]; then
        read -r -p "是否立即应用已下载的更新？(y/n，默认y): " APPLY_UPDATE
        APPLY_UPDATE="${APPLY_UPDATE:-y}"
        
        if [[ "${APPLY_UPDATE}" =~ ^[Yy]$ ]]; then
            # 应用更新前先清屏，让用户看到最新内容
            clear
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            echo -e " ${YELLOW}正在应用更新...${NC}"
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            
            local CFOPT_UPDATED=false
            
            for KEY in "${!MODULE_MAP[@]}"; do
                IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
                if [[ -f "${TEMP_DIR}/${REMOTE_FILE}" ]]; then
                    # 特殊处理 cfopt.sh 自身
                    if [[ "${REMOTE_FILE}" = "cfopt.sh" ]]; then
                        # 将新版本的 cfopt.sh 复制到安装目录
                        cp "${TEMP_DIR}/${REMOTE_FILE}" "${INSTALL_DIR}/cfopt.sh.new" 2>/dev/null
                        chmod +x "${INSTALL_DIR}/cfopt.sh.new" 2>/dev/null
                        CFOPT_UPDATED=true
                        log_success "cfopt.sh 已准备更新（将在重启后生效）"
                    else
                        # 其他文件直接替换
                        if ! safe_move "${TEMP_DIR}/${REMOTE_FILE}" "${LOCAL_PATH}" "应用更新: ${KEY}"; then
                            log_error "更新应用失败: ${KEY}"
                            HAS_ERROR=true
                        else
                            chmod +x "${LOCAL_PATH}"
                        fi
                    fi
                fi
            done
            
            echo ""
            if [[ "${CFOPT_UPDATED}" = true ]]; then
                echo -e "${YELLOW}[提示] cfopt.sh 主脚本已更新，请重新运行 'cfopt' 以应用最新版本${NC}"
                echo ""
            fi
            echo -e "${GREEN}[OK] 更新已应用！${NC}"
        fi
    elif [[ "${HAS_ERROR}" = true ]]; then
        echo -e "${YELLOW}[WARN] 部分组件更新失败，请检查网络连接或远程文件完整性。${NC}"
    else
        echo -e "${GREEN}[OK] 所有组件已是最新版本。${NC}"
    fi
    
    rm -rf "${TEMP_DIR}"
    echo ""
    read -r -p "按回车键返回主菜单..."
    # 【修复】返回主菜单而不是退出
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
    
    # 核心判断：如果状态文件存在、标记为已安装、且核心模块目录齐全，则直接启动
    if [[ -f "${STATUS_CONF}" ]] && \
       grep -q '^INSTALL_CHECKED="true"' "${STATUS_CONF}" && \
       [[ -d "${INSTALL_DIR}/modules/cf-ip" ]] && \
       [[ -d "${INSTALL_DIR}/modules/scheduler" ]]; then
        while true; do
            show_main_menu
        done
        return
    fi
    
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
             "${INSTALL_DIR}/assets/cfst" \
             "${INSTALL_DIR}/assets/data/cf-ip" \
             "${INSTALL_DIR}/assets/data/cf-dns" \
             "${INSTALL_DIR}/assets/data/dnspod-dns" \
             "${INSTALL_DIR}/conf/templates" \
             "${INSTALL_DIR}/logs"

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

    # 5. 静默版本检测与更新
    echo -e "${CYAN}[INFO] 正在下载组件文件...${NC}"
    
    # 【修复】仅在已安装的情况下才执行备份（通过检查核心模块是否存在判断）
    if [[ -d "${INSTALL_DIR}/modules/cf-ip" ]] || [[ -d "${INSTALL_DIR}/modules/scheduler" ]]; then
        backup_current_version
    fi
    
    # 下载 version.txt（增加超时和进度提示）
    echo -e "${CYAN}[INFO] 正在获取版本索引...${NC}"
    # 添加时间戳参数避免 CDN 缓存
    REMOTE_VERSIONS="$(curl -sL --connect-timeout 10 --max-time 30 "${VERSION_FILE_REMOTE}?t=$(date +%s)" 2>/dev/null)"
    
    if [[ -z "${REMOTE_VERSIONS}" ]]; then
        echo -e "${YELLOW}[WARN] 无法获取 version.txt，将跳过哈希校验直接下载...${NC}"
    else
        echo -e "${GREEN}[OK] 版本索引获取成功！${NC}"
    fi
    
    declare -A MODULE_MAP
    MODULE_MAP=(
        ["QUICK_DEPLOY"]="${INSTALL_DIR}/modules/quick-deploy/setup.sh:modules/quick-deploy/setup.sh"
        ["CF_IP_MENU"]="${INSTALL_DIR}/modules/cf-ip/menu.sh:modules/cf-ip/menu.sh"
        ["CF_IP_CORE"]="${INSTALL_DIR}/modules/cf-ip/core.sh:modules/cf-ip/core.sh"
        ["CF_DNS_CORE"]="${INSTALL_DIR}/modules/cf-dns/core.sh:modules/cf-dns/core.sh"
        ["CF_DNS_SETUP"]="${INSTALL_DIR}/modules/cf-dns/setup.sh:modules/cf-dns/setup.sh"
        ["DNSPOD_CORE"]="${INSTALL_DIR}/modules/dnspod-dns/core.sh:modules/dnspod-dns/core.sh"
        ["DNSPOD_SETUP"]="${INSTALL_DIR}/modules/dnspod-dns/setup.sh:modules/dnspod-dns/setup.sh"
        ["SCHEDULER_RUN"]="${INSTALL_DIR}/modules/scheduler/run.sh:modules/scheduler/run.sh"
        ["IP_SYNC"]="${INSTALL_DIR}/modules/ip-sync/sync.sh:modules/ip-sync/sync.sh"
    )

    HAS_UPDATE=false
    # 计数器：用于显示进度
    TOTAL_FILES=${#MODULE_MAP[@]}
    CURRENT_FILE=0
    
    if [[ -n "${REMOTE_VERSIONS}" ]]; then
        # 有 version.txt，进行版本对比和哈希校验
        for KEY in "${!MODULE_MAP[@]}"; do
            CURRENT_FILE=$((CURRENT_FILE + 1))
            IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
            REMOTE_INFO="$(echo "${REMOTE_VERSIONS}" | grep "^${KEY}=" | cut -d'=' -f2)"
            REMOTE_VER="$(echo "${REMOTE_INFO}" | cut -d':' -f1)"
            REMOTE_HASH="$(echo "${REMOTE_INFO}" | cut -d':' -f2)"
            
            LOCAL_VER="0.0"
            LOCAL_HASH=""
            if [[ -f "${LOCAL_PATH}" ]]; then
                LOCAL_VER="$(grep -m1 "^SCRIPT_VERSION=" "${LOCAL_PATH}" | awk -F'"' '{print $2}')"
                [[ -z "${LOCAL_VER}" ]] && LOCAL_VER="0.0"
                # 计算本地文件哈希
                LOCAL_HASH="$(sha256sum "${LOCAL_PATH}" | awk '{print $1}')"
            fi

            # 【修复】判断是否需要下载：文件不存在 OR 版本不同 OR 哈希不同
            NEED_DOWNLOAD=false
            if [[ ! -f "${LOCAL_PATH}" ]]; then
                NEED_DOWNLOAD=true
                echo -e "${CYAN}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 下载 ${KEY}...${NC}"
            elif [[ -n "${REMOTE_VER}" ]] && [[ "${REMOTE_VER}" != "${LOCAL_VER}" ]]; then
                # 版本号不同，需要更新
                NEED_DOWNLOAD=true
                echo -e "${CYAN}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 更新 ${KEY} (v${LOCAL_VER} -> v${REMOTE_VER})...${NC}"
            elif [[ -n "${REMOTE_HASH}" ]] && [[ -n "${LOCAL_HASH}" ]] && [[ "${REMOTE_HASH}" != "${LOCAL_HASH}" ]]; then
                # 【新增】版本号相同但哈希不同，说明内容已修改
                NEED_DOWNLOAD=true
                echo -e "${YELLOW}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 更新 ${KEY} (内容已变更)...${NC}"
            fi

            if [[ "${NEED_DOWNLOAD}" = true ]]; then
                # 确保目标目录存在
                mkdir -p "$(dirname "${LOCAL_PATH}")" 2>/dev/null
                
                # 直接在目标位置下载
                if download_with_retry "${REMOTE_URL}/${REMOTE_FILE}" "${LOCAL_PATH}" "${REMOTE_HASH}"; then
                    HAS_UPDATE=true
                else
                    echo -e "${RED}[ERROR] ${KEY} 下载失败，请检查网络或稍后重试。${NC}"
                    # 清理可能的残留文件
                    rm -f "${LOCAL_PATH}" 2>/dev/null
                fi
            fi
        done
    else
        # 无 version.txt，跳过哈希校验直接下载所有文件（首次安装或网络问题）
        for KEY in "${!MODULE_MAP[@]}"; do
            CURRENT_FILE=$((CURRENT_FILE + 1))
            IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
            
            # 仅下载不存在的文件
            if [[ ! -f "${LOCAL_PATH}" ]]; then
                echo -e "${CYAN}[INFO] [${CURRENT_FILE}/${TOTAL_FILES}] 下载 ${KEY}...${NC}"
                # 确保目标目录存在
                mkdir -p "$(dirname "${LOCAL_PATH}")" 2>/dev/null
                
                # 直接在目标位置下载
                if download_with_retry "${REMOTE_URL}/${REMOTE_FILE}" "${LOCAL_PATH}" ""; then
                    HAS_UPDATE=true
                else
                    echo -e "${RED}[ERROR] ${KEY} 下载失败，请检查网络连接。${NC}"
                    # 清理可能的残留文件
                    rm -f "${LOCAL_PATH}" 2>/dev/null
                    
                    # 【新增】下载失败时回滚
                    echo -e "${YELLOW}[WARN] 检测到组件下载失败，正在执行回滚...${NC}"
                    rollback_on_failure
                    exit 1
                fi
            fi
        done
    fi
    
    # 6. 下载配置文件模板（仅在首次安装时执行）
    if [[ "${HAS_UPDATE}" = true ]] && [[ ! -f "${INSTALL_DIR}/conf/.templates_downloaded" ]]; then
        echo -e "${CYAN}[INFO] 正在初始化配置文件...${NC}"
        declare -A CONF_TEMPLATES
        CONF_TEMPLATES=(
            ["cf-ip.json"]="conf/templates/cf-ip.json.example"
            ["cf-dns.json"]="conf/templates/cf-dns.json.example"
            ["dnspod.json"]="conf/templates/dnspod.json.example"
            ["global.json"]="conf/templates/global.json.example"
        )
        
        for CONF_NAME in "${!CONF_TEMPLATES[@]}"; do
            LOCAL_CONF="${INSTALL_DIR}/conf/${CONF_NAME}"
            REMOTE_TEMPLATE="${CONF_TEMPLATES[$CONF_NAME]}"
            
            # 仅在配置文件不存在时下载模板
            if [[ ! -f "${LOCAL_CONF}" ]]; then
                mkdir -p "${INSTALL_DIR}/conf" 2>/dev/null
                
                # 下载模板文件
                TEMP_TEMPLATE="$(mktemp)"
                if download_with_retry "${REMOTE_URL}/${REMOTE_TEMPLATE}" "${TEMP_TEMPLATE}" ""; then
                    # 重命名为 .json（去掉 .example 后缀）
                    mv "${TEMP_TEMPLATE}" "${LOCAL_CONF}"
                    chmod 600 "${LOCAL_CONF}"
                else
                    rm -f "${TEMP_TEMPLATE}" 2>/dev/null
                fi
            fi
        done
        
        # 标记已下载模板（防止重复下载）
        touch "${INSTALL_DIR}/conf/.templates_downloaded"
    fi

    if [[ "${HAS_UPDATE}" = true ]]; then
        echo -e "${GREEN}[OK] 组件安装完成！${NC}"
        # 有内容更新时自动清屏，让用户看到最新内容
        clear
    else
        echo -e "${YELLOW}[WARN] 没有可更新的组件。${NC}"
    fi

    # 7. 进入主菜单循环
    while true; do
        show_main_menu
        # show_main_menu 是递归函数，选择 0 时会 exit
        # 其他选项执行完毕后会自动继续循环
    done
}

# 启动执行
init_cfopt
