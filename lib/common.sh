#!/bin/bash
# ==============================================================================
# cfopt - 公共函数库 (Common Library)
# Version: 1.0
# Description: 所有模块共享的工具函数，避免重复定义
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# ==============================================================================

# 防止重复加载
[[ "${_CFOPT_COMMON_LOADED:-}" == "true" ]] && return 0
_CFOPT_COMMON_LOADED="true"

# ==================== 终端颜色定义 ====================
if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# ==================== 跨平台文件大小获取 ====================
# 兼容 Linux、macOS、BSD 系统，返回字节数
get_file_size() {
    local file="$1"
    local size

    if [[ ! -f "${file}" ]]; then
        echo "0"
        return
    fi

    if stat -f %z "${file}" >/dev/null 2>&1; then
        # macOS/BSD stat
        size=$(stat -f %z "${file}" 2>/dev/null)
    elif stat -c %s "${file}" >/dev/null 2>&1; then
        # Linux stat
        size=$(stat -c %s "${file}" 2>/dev/null)
    else
        # fallback: wc -c
        size=$(wc -c < "${file}" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "${size}" ]] || [[ ! "${size}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${size}"
    fi
}

# ==================== 跨平台文件修改时间获取 ====================
# 兼容 Linux、macOS、BSD 系统，返回 Unix 时间戳
stat_file_mtime() {
    local file="$1"
    local mtime

    if [[ ! -f "${file}" ]]; then
        echo "0"
        return
    fi

    if stat -f %m "${file}" >/dev/null 2>&1; then
        mtime=$(stat -f %m "${file}" 2>/dev/null)
    elif stat -c %Y "${file}" >/dev/null 2>&1; then
        mtime=$(stat -c %Y "${file}" 2>/dev/null)
    else
        if date -r "${file}" +%s >/dev/null 2>&1; then
            mtime=$(date -r "${file}" +%s 2>/dev/null)
        else
            echo "0"
            return
        fi
    fi

    if [[ -z "${mtime}" ]] || [[ ! "${mtime}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${mtime}"
    fi
}

# ==================== 跨平台查找最新文件 ====================
# 参数: $1=目录路径, $2=文件名模式
# 返回: 最新文件的完整路径
find_latest_file() {
    local search_dir="$1"
    local pattern="$2"

    if [[ ! -d "${search_dir}" ]]; then
        echo ""
        return
    fi

    if stat -f '%m' /dev/null >/dev/null 2>&1; then
        # macOS/BSD
        find "${search_dir}" -maxdepth 1 -name "${pattern}" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | \
            sort -rn | head -n 1 | awk '{print $2}'
    elif stat -c '%Y' /dev/null >/dev/null 2>&1; then
        # Linux
        find "${search_dir}" -maxdepth 1 -name "${pattern}" -type f -exec stat -c '%Y %n' {} \; 2>/dev/null | \
            sort -rn | head -n 1 | awk '{print $2}'
    else
        # fallback: ls -t
        # 【修复】使用双引号保护 search_dir，pattern 保持不加引号以支持 glob 展开
        # shellcheck disable=SC2086,SC2012
        ls -t "${search_dir}"/${pattern} 2>/dev/null | head -n 1
    fi
}

# ==================== 跨平台反向读取文件 ====================
# 兼容 Linux（tac）和 macOS（tail -r）
reverse_read() {
    local file="$1"
    if command -v tac &>/dev/null; then
        tac "$file"
    else
        tail -r "$file" 2>/dev/null || cat "$file"
    fi
}

# ==================== 日志轮转 ====================
# 参数: $1=日志文件路径, $2=最大大小(字节，默认10MB)
rotate_log() {
    local log_file="$1"
    local max_size=${2:-$((10 * 1024 * 1024))}

    if [[ -f "$log_file" ]]; then
        local file_size
        file_size=$(get_file_size "$log_file")

        if [[ "$file_size" -gt "$max_size" ]]; then
            mv "$log_file" "${log_file}.old"
            rm -f "${log_file}.old.old"
            touch "$log_file"
        fi
    fi
}

# ==================== 从文件读取 IP 列表 ====================
# 支持多种格式: 纯 IP、.iplist（IP|延迟|速度|地区码）、逗号/空格分隔
# 参数: $1=IP文件路径, $2=最大数量限制(可选, 0=不限制)
# 输出: 空格分隔的 IP 列表
# 返回: 0=成功, 1=失败
read_ips_from_file() {
    local ip_file="$1"
    local max_ips="${2:-0}"

    if [[ ! -f "${ip_file}" ]]; then
        echo -e "${RED}[ERROR]${NC} IP 文件不存在: ${ip_file}" >&2
        return 1
    fi

    # 读取文件内容，支持多种格式:
    # 1. 纯 IP（每行一个）
    # 2. .iplist 格式（IP|延迟|速度|地区码）
    # 3. 逗号/空格分隔
    # 4. 注释行（# 开头）自动跳过
    local content
    content=$(awk '!/^#/ && !/^$/ { gsub(/#.*/, ""); split($0, a, "|"); gsub(/,/, " ", a[1]); gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[1]); printf "%s ", a[1] }' "${ip_file}" | sed 's/ *$//')

    if [[ -z "${content}" ]]; then
        echo -e "${RED}[ERROR]${NC} IP 文件为空: ${ip_file}" >&2
        return 1
    fi

    # 限制 IP 数量
    if [[ "${max_ips}" -gt 0 ]]; then
        IFS=' ' read -ra ip_array <<< "${content}"
        local total_ips=${#ip_array[@]}

        if [[ "${total_ips}" -gt "${max_ips}" ]]; then
            echo -e "${YELLOW}[WARN]${NC} IP 文件包含 ${total_ips} 个 IP，超出限制 ${max_ips} 个，已截取前 ${max_ips} 个" >&2

            local limited_ips=""
            for ((i=0; i<max_ips && i<total_ips; i++)); do
                if [[ -z "${limited_ips}" ]]; then
                    limited_ips="${ip_array[$i]}"
                else
                    limited_ips="${limited_ips} ${ip_array[$i]}"
                fi
            done
            echo "${limited_ips}"
        else
            echo "${content}"
        fi
    else
        echo "${content}"
    fi

    return 0
}

# ==================== 验证 IPv4 地址格式 ====================
# 参数: $1=IP地址
# 返回: 0=有效, 1=无效
# IP 地址格式验证
# 验证 IPv4 地址格式和合法性，拒绝 0.0.0.0 和 255.255.255.255 等无效地址
validate_ip() {
    local ip="$1"

    # 基本格式检查
    if [[ ! "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        return 1
    fi
    
    # 检查每个字段的范围（0-255）
    local i
    for i in 1 2 3 4; do
        if [[ "${BASH_REMATCH[$i]}" -gt 255 ]]; then
            return 1
        fi
    done
    
    # 拒绝特殊地址
    # 0.0.0.0：无效地址
    if [[ "${ip}" == "0.0.0.0" ]]; then
        return 1
    fi
    
    # 255.255.255.255：广播地址，不能作为目标 IP
    if [[ "${ip}" == "255.255.255.255" ]]; then
        return 1
    fi
    
    return 0
}

# ==================== 统一日志函数 ====================
# 参数: $1=模块名, $2=日志文件路径(可选), $3=级别, $4+=消息
# 如果 $2 为空或未设置，只输出到终端
_cfopt_log() {
    local module="$1"
    local log_file="$2"
    local level="$3"
    shift 3
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # 写入日志文件（剥离 ANSI 颜色码）
    if [[ -n "${log_file}" ]]; then
        # 【修复】确保日志目录存在
        local log_dir
        log_dir="$(dirname "${log_file}")"
        mkdir -p "${log_dir}" 2>/dev/null || true

        local plain_message
        plain_message=$(echo "$*" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\\033\[[0-9;]*m//g')
        printf "[%s] [%-5s] [%s] %s\n" "$timestamp" "$level" "$module" "$plain_message" >> "$log_file" 2>/dev/null || true
    fi

    # 终端输出（带颜色）
    printf "[%s] [%-5s] [%s] %s\n" "$timestamp" "$level" "$module" "$*"
}

# 便捷日志函数（需要先设置 _LOG_MODULE 和 _LOG_FILE 变量）
log_info()  { _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "INFO" "$@"; }
log_warn()  { _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "WARN" "$@"; }
log_error() { _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "ERROR" "$@"; }
log_success() { _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "OK" "$@"; }

# 向后兼容别名（dnspod-dns 使用 log_msg）
# 【修复】添加智能级别判断，与 log() 函数保持一致
log_msg() {
    # 如果没有参数，直接返回
    [[ $# -eq 0 ]] && return 0

    local first_arg="$1"
    case "${first_arg}" in
        INFO|WARN|ERROR|OK)
            # 标准调用: log_msg "INFO" "message..."
            _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "$@"
            ;;
        *)
            # 简化调用: log_msg "some message"
            # 整个内容作为消息，级别设为 INFO
            _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "INFO" "$@"
            ;;
    esac
}

# 通用日志函数（智能级别判断）
# 支持两种调用方式：
#   1. 标准调用: log "INFO" "message..."
#   2. 简化调用: log "message..." （自动识别为 INFO 级别）
#
# 设计说明：
# - cf-dns/core.sh 中大量使用 log "${RED}[ERROR]..." 和 log "" 格式
# - 为了向后兼容，如果第一个参数不是已知级别（INFO/WARN/ERROR/OK），
#   则将其作为消息而非级别处理
# - 推荐使用 log_info/log_warn/log_error/log_success 以获得更清晰的代码
log() {
    # 如果没有参数，直接返回
    [[ $# -eq 0 ]] && return 0

    local first_arg="$1"
    case "${first_arg}" in
        INFO|WARN|ERROR|OK)
            # 标准调用: log "INFO" "message..."
            _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "$@"
            ;;
        *)
            # 简化调用: log "some message" 或 log ""
            # 整个内容作为消息，级别设为 INFO
            _cfopt_log "${_LOG_MODULE:-cfopt}" "${_LOG_FILE:-}" "INFO" "$@"
            ;;
    esac
}
