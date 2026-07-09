#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - DNSPod DNS 更新核心 (Core)
# Version: 0.1
# Description: 负责将优选 IP 同步至 DNSPod 记录，支持单线路及多运营商分流策略
# Usage: bash modules/dnspod-dns/core.sh
# ==============================================================================
# 【修复】启用严格模式，防止错误传播（原缺失此行导致所有错误被静默吞掉）
set -euo pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 【修复】加载公共函数库
# shellcheck source=../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

# 设置日志模块名
_LOG_MODULE="dnspod"

# ==================== 配置加载逻辑（支持多域名） ====================
# 优先级：
# 1. 命令行参数指定配置文件: bash core.sh /path/to/config.json
# 2. 环境变量指定域名: DNSPOD_DOMAIN=example.com bash core.sh
# 3. 默认：需要传递配置文件路径

if [[ $# -gt 0 ]] && [[ -f "$1" ]]; then
    # 方式 1: 命令行参数指定配置文件
    CONFIG_FILE="$1"
    DOMAIN_NAME=$(basename "$CONFIG_FILE" .json)
    shift  # 【修复】消费掉配置文件参数，避免后续 while 循环将其当作未知参数
elif [[ -n "${DNSPOD_DOMAIN:-}" ]]; then
    # 方式 2: 环境变量指定域名
    DOMAIN_NAME="${DNSPOD_DOMAIN}"
    CONFIG_FILE="$ROOT_DIR/conf/dnspod/${DOMAIN_NAME}.json"
else
    # 方式 3: 错误，必须指定配置文件
    echo -e "${RED}错误${NC}: 未指定配置文件"
    echo "用法:"
    echo "  1. bash core.sh /path/to/config.json"
    echo "  2. DNSPOD_DOMAIN=example.com bash core.sh"
    exit 1
fi

# 【修复】统一锁文件命名规范：.${module_name}_${type}_${identifier}.lock
LOCK_FILE="${ROOT_DIR}/modules/dnspod-dns/.dnspod-dns_core.lock"
acquire_lock() {
    # 根据域名生成独立的锁文件
    local domain_safe
    domain_safe=$(echo "${DOMAIN_NAME:-default}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    LOCK_FILE="${ROOT_DIR}/modules/dnspod-dns/.dnspod-dns_core_${domain_safe}.lock"
    
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "[ERROR] 无法获取锁，另一个 DNSPod 更新进程正在运行 (Domain: ${DOMAIN_NAME:-default})"
        exit 1
    fi
    # 锁会在脚本退出时自动释放（fd 9 关闭）
}

acquire_lock

LOG_DIR="${ROOT_DIR}/logs/dnspod-dns"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/dnspod_$(date +%Y%m%d_%H%M%S).log"
_LOG_FILE="${LOG_FILE}"

# 【修复】日志轮转：使用 lib/common.sh 中的公共 rotate_log
# 轮转旧的 dnspod 日志文件
for old_log in "${LOG_DIR}"/dnspod_*.log.old; do
    [[ -f "$old_log" ]] && rotate_log "$old_log" 5242880  # 5MB
done

# DNSPod IP 数据默认路径
DEFAULT_IP_DIR="${ROOT_DIR}/assets/data/dnspod-dns"

# 【标准化】统一使用 .iplist 格式
get_default_ip_file() {
    local line_name="$1"
    echo "${DEFAULT_IP_DIR}/${line_name}.iplist"
}

# ====================== 【统一结构化日志系统】 ======================
# 【修复】日志函数已移至 lib/common.sh，通过 _LOG_FILE 变量指定日志文件
# log_info, log_warn, log_error, log_success 均由公共库提供

# ====================== 【执行历史记录】 ======================
# 记录 DNSPod 更新结果到 history.jsonl
record_dnspod_update_history() {
    local domain="$1"
    local records_updated="$2"
    local records_created="$3"
    local records_skipped="$4"
    
    local history_file="${ROOT_DIR}/conf/history.jsonl"
    local timestamp
    # 【修复】使用系统本地时区，自动获取正确的时区偏移
    timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    
    # 确保目录存在
    mkdir -p "${ROOT_DIR}/conf"
    
    # 【修复】使用 flock 保护并发写入，防止多进程同时写入导致数据损坏
    # 【安全修复】子 shell 内用 exit 代替 return，外层用 || true 防止 set -e 中断
    (
        flock -n 200 || { log_warn "无法获取历史记录写入锁"; exit 1; }
        printf '{"time":"%s","action":"dnspod_update","domain":"%s","records_updated":%d,"records_created":%d,"records_skipped":%d}\n' \
            "$timestamp" "$domain" "$records_updated" "$records_created" "$records_skipped" >> "$history_file"
    ) 200>"${history_file}.lock" || true
}

# ==================== 主逻辑入口 ====================

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "找不到配置文件 ${CONFIG_FILE}"
    echo ""
    
    # 检测是否为交互式环境（有终端输入）
    if [[ -t 0 ]]; then
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo -e " ${YELLOW}DNSPod DNS 模块首次配置向导"
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        log_info "检测到您尚未配置 DNSPod 模块"
        echo ""
        echo -e "${GREEN}我们将帮助您完成以下配置：${NC}"
        echo "  ✓ DNSPod API ID 和 Token"
        echo "  ✓ 域名和子域名设置"
        echo "  ✓ 单线路/多线路模式选择"
        echo "  ✓ 运营商分流策略（可选）"
        echo ""
        read -r -p "是否立即启动配置向导？[Y/n] (默认: Y): " choice
        choice=${choice:-Y}
        
        if [[ "$choice" =~ ^[Yy]$ ]] || [[ -z "$choice" ]]; then
            echo ""
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            echo -e "${GREEN}正在启动快速配置向导...${NC}"
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            echo ""
            exec bash "$ROOT_DIR/modules/dnspod-dns/setup.sh"
        else
            log_warn "已取消操作"
            exit 1
        fi
    else
        # 非交互式环境（定时任务等），直接退出
        log_warn "请先运行配置向导创建配置文件"
        log_warn "命令: bash $ROOT_DIR/modules/dnspod-dns/setup.sh"
        exit 1
    fi
fi

# 检查 jq 是否可用
if ! command -v jq &> /dev/null; then
    log_error "jq 未安装 (必需工具)"
    log_warn "请安装 jq: apt install jq 或 yum install jq"
    exit 1
fi

# ==================== 【性能优化】一次性读取配置文件 ====================
# 从 JSON 读取配置（【优化】只调用 1 次 jq，避免 20+ 次 fork + 文件 I/O）
declare -A CFG
while IFS='=' read -r key value; do
    [[ -n "$key" ]] && CFG["$key"]="$value"
done < <(jq -r '
    [
        "enabled=\(.enabled // false)",
        "api_id=\(.api.id // "")",
        "api_token=\(.api.token // "")",
        "timeout=\(.api.timeout // 10)",
        "max_retries=\(.api.max_retries // 5)",
        "domain=\(.dns.domain // "")",
        "sub_domain=\(.dns.sub_domain // "www")",
        "ttl=\(.dns.ttl // 600)",
        "ip_file=\(.ip_source.file_path // "")",
        "mode=\(.dns.mode // "single")",
        "max_ips_per_record=\(.dns.max_ips_per_record // 2)",
        "subdomain_strategy=\(.dns.subdomain_strategy // "separate")",
        "sub_domain_unified=\(.dns.sub_domain_unified // "dns")",
        "sub_domain_default=\(.dns.sub_domains.default // "default")",
        "sub_domain_unicom=\(.dns.sub_domains.unicom // "unicom")",
        "sub_domain_mobile=\(.dns.sub_domains.mobile // "mobile")",
        "sub_domain_telecom=\(.dns.sub_domains.telecom // "telecom")",
        "isp_lines=\(.dns.isp_lines // "默认")",
        "ip_file_default=\(.ip_source.files.default // "")",
        "ip_file_unicom=\(.ip_source.files.unicom // "")",
        "ip_file_mobile=\(.ip_source.files.mobile // "")",
        "ip_file_telecom=\(.ip_source.files.telecom // "")"
    ] | .[]
' "$CONFIG_FILE")

export ENABLED="${CFG[enabled]}"

# 检查启用状态
if [[ "${ENABLED}" != "true" ]]; then
    log_info "DNSPod 模块当前处于禁用状态 (enabled=false)。"
    exit 0
fi

# API 配置（【安全修复】不要 export，避免通过 /proc/<pid>/environ 泄露）
SECRETID="${CFG[api_id]}"
SECRETKEY="${CFG[api_token]}"
REQUEST_TIMEOUT="${CFG[timeout]}"
MAX_RETRIES="${CFG[max_retries]}"

# DNS 配置
# 【安全修复】不要 export，避免通过 /proc/<pid>/environ 泄露
DOMAIN="${CFG[domain]}"
SUB_DOMAIN="${CFG[sub_domain]}"
TTL="${CFG[ttl]}"

# IP 源配置
# 【修复】将相对路径转换为绝对路径（相对于项目根目录），防止 cron 调用时工作目录不同
_ip_file_raw="${CFG[ip_file]}"
if [[ -n "${_ip_file_raw}" ]] && [[ "${_ip_file_raw}" != /* ]]; then
    _ip_file_raw="${ROOT_DIR}/${_ip_file_raw#./}"
fi
export IP_FILE="${_ip_file_raw}"

# 多线路模式配置（mode 字段已移至 dns 对象内）
export MODE="${CFG[mode]}"
export MAX_IPS_PER_RECORD="${CFG[max_ips_per_record]}"
export SUBDOMAIN_STRATEGY="${CFG[subdomain_strategy]}"

# 统一模式子域名
export SUB_DOMAIN_UNIFIED="${CFG[sub_domain_unified]}"

# 分离模式子域名
export SUB_DOMAIN_DEFAULT="${CFG[sub_domain_default]}"
export SUB_DOMAIN_UNICOM="${CFG[sub_domain_unicom]}"
export SUB_DOMAIN_MOBILE="${CFG[sub_domain_mobile]}"
export SUB_DOMAIN_TELECOM="${CFG[sub_domain_telecom]}"

# ISP 线路列表（空格分隔的字符串）
export ISP_LINES="${CFG[isp_lines]}"

# 验证必要配置
if [[ -z "${DOMAIN}" ]] || [[ -z "${SECRETID}" ]] || [[ -z "${SECRETKEY}" ]]; then
    log_error "配置文件中缺少必要的配置项 (domain, api.id, api.token)"
    exit 1
fi

log_info "配置文件已加载 ${CONFIG_FILE}"
echo ""

# 删除指定线路的 DNS 记录
delete_record_by_line() {
    local record_id="$1"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --argjson record_id "$record_id" '{"Domain":$domain,"RecordId":$record_id}')
    call_api "DeleteRecord" "${payload}"
}

# ==================== IP 数据文件检测 (启动前校验) ====================
# 【功能增强】根据模式确定要检查的 IP 文件，优先使用 .iplist 格式
IP_FILES_TO_CHECK=()
if [[ "${MODE}" = "single" ]]; then
    # 单线路模式：检查默认 IP 文件
    if [[ -n "${IP_FILE}" ]]; then
        IP_FILES_TO_CHECK+=("${IP_FILE}")
    else
        IP_FILES_TO_CHECK+=("$(get_default_ip_file "ip_list")")
    fi
else
    # 多线路模式：检查所有线路的 IP 文件
    IFS=' ' read -ra lines_array <<< "${ISP_LINES}"
    for line in "${lines_array[@]}"; do
        case "$line" in
            "默认")
                # 【修复】使用预加载的配置，避免重复调用 jq
                ip_file="${CFG[ip_file_default]}"
                [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "default")"
                ;;
            "联通")
                ip_file="${CFG[ip_file_unicom]}"
                [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "unicom")"
                ;;
            "移动")
                ip_file="${CFG[ip_file_mobile]}"
                [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "mobile")"
                ;;
            "电信")
                ip_file="${CFG[ip_file_telecom]}"
                [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "telecom")"
                ;;
            *)
                log_warn "未知线路: ${line}，跳过检查"
                continue
                ;;
        esac
        # 【修复】将相对路径转换为绝对路径，防止 cron 调用时工作目录不同
        if [[ -n "$ip_file" ]] && [[ "$ip_file" != /* ]]; then
            ip_file="${ROOT_DIR}/${ip_file#./}"
        fi
        IP_FILES_TO_CHECK+=("$ip_file")
    done
fi

for ip_file in "${IP_FILES_TO_CHECK[@]}"; do
    if [[ ! -f "${ip_file}" ]]; then
        log_error "IP 文件不存在: ${ip_file}"
        exit 1
    fi
    
    # 有效性检测
    # 【修复】支持 .iplist 格式（带注释行）和纯 IP 格式
    FIRST_LINE=""
    while IFS= read -r _line; do
        # 跳过空行和注释行
        [[ -z "$_line" ]] && continue
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        FIRST_LINE="$_line"
        break
    done < "${ip_file}"
    
    # 提取 IP 部分（支持 IP|延迟|速度|地区码 格式）
    first_ip=$(echo "${FIRST_LINE}" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "${first_ip}" ]] || [[ ! "${first_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "IP 文件格式错误或包含无效数据 (${ip_file}): ${FIRST_LINE:-空}"
        log_warn "这可能是测速程序的临时 Bug，请重新运行测速。"
        exit 1
    fi
done
log_info "IP 数据检查通过"
echo ""

# ==================== 模式检测 ====================
MODE_TYPE="update"  # 默认更新模式
DELETE_LINES=()     # 要删除的线路列表
UNIFIED_SUBDOMAIN=""  # 统一模式子域名

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete|-d)
            MODE_TYPE="delete"
            shift
            # 收集要删除的线路
            while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
                DELETE_LINES+=("$1")
                shift
            done
            ;;
        --delete-unified)
            MODE_TYPE="delete_unified"
            shift
            if [[ -n "$1" ]] && [[ "$1" != --* ]]; then
                UNIFIED_SUBDOMAIN="$1"
                shift
            fi
            ;;
        --delete-unified-non-default)
            MODE_TYPE="delete_unified_non_default"
            shift
            if [[ -n "$1" ]] && [[ "$1" != --* ]]; then
                UNIFIED_SUBDOMAIN="$1"
                shift
            fi
            ;;
        *)
            echo "错误: 未知参数: $1"
            echo "用法:"
            echo "  更新模式: $0"
            echo "  删除分线路记录: $0 --delete [线路名称...]"
            echo "  删除统一模式记录: $0 --delete-unified [子域名]"
            echo "  删除统一模式非默认线路: $0 --delete-unified-non-default [子域名]"
            exit 1
            ;;
    esac
done

# 将 ISP_LINES 字符串转换为数组
if [[ -n "${ISP_LINES}" ]]; then
    IFS=' ' read -ra ISP_LINES <<< "${ISP_LINES}"
else
    log_error "配置文件中缺少 isp_lines"
    exit 1
fi

# 设置默认值（已在 jq 中设置，这里保留以防万一）
TTL=${TTL:-600}
MAX_RETRIES=${MAX_RETRIES:-5}
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-10}
MAX_IPS_PER_RECORD=${MAX_IPS_PER_RECORD:-2}
SUBDOMAIN_STRATEGY=${SUBDOMAIN_STRATEGY:-"separate"}

# 确认工作模式为 multi
if [[ "${MODE}" = "multi" ]]; then
    if [[ "${SUBDOMAIN_STRATEGY}" = "unified" ]]; then
        expected_lines="默认 联通 移动 电信"
        missing_lines=()
        
        for line in ${expected_lines}; do
            # shellcheck disable=SC2076
            if [[ ! " ${ISP_LINES[*]} " =~ " ${line} " ]]; then
                missing_lines+=("${line}")
            fi
        done
        
        if [[ ${#missing_lines[@]} -gt 0 ]]; then
            log_warn "检测到统一模式配置不完整，正在自动补全..."
            ISP_LINES=("默认" "联通" "移动" "电信")
            
            # 【修复】使用变量构建 isp_lines 字符串，避免硬编码（移除 local，因为在函数外）
            isp_lines_str="${ISP_LINES[*]}"
            
            # 更新配置文件（使用 jq）
            temp_file=$(mktemp /tmp/cfopt-dnspod.XXXXXX)
            chmod 600 "${temp_file}"
            if jq --arg lines "$isp_lines_str" '.dns.isp_lines = $lines' "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
                mv "$temp_file" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE"
                log_info "已更新配置文件: isp_lines = \"${isp_lines_str}\""
            else
                rm -f "$temp_file"
                log_error "更新配置文件失败"
            fi
        fi
    fi
fi

# 获取线路对应的子域名
get_subdomain_for_line() {
    local line="$1"
    
    # 如果配置了 SUBDOMAIN_STRATEGY,根据策略选择子域名
    if [[ "${SUBDOMAIN_STRATEGY}" = "unified" ]]; then
        # 统一模式: 所有线路使用相同子域名
        echo "${SUB_DOMAIN_UNIFIED:-dns}"
    else
        # 分离模式: 根据线路选择不同子域名
        case "$line" in
            "默认")
                echo "${SUB_DOMAIN_DEFAULT:-default}"
                ;;
            "联通")
                echo "${SUB_DOMAIN_UNICOM:-unicom}"
                ;;
            "移动")
                echo "${SUB_DOMAIN_MOBILE:-mobile}"
                ;;
            "电信")
                echo "${SUB_DOMAIN_TELECOM:-telecom}"
                ;;
            *)
                # 未知线路,使用小写名称
                echo "${line,,}"
                ;;
        esac
    fi
}

# 获取分离模式的子域名（用于删除分线路记录）
get_separate_subdomain_for_line() {
    local line="$1"
    
    # 总是使用分离模式的子域名映射，忽略当前策略
    case "$line" in
        "默认")
            echo "${SUB_DOMAIN_DEFAULT:-default}"
            ;;
        "联通")
            # 如果 SUB_DOMAIN_UNICOM 未配置，使用 SUB_DOMAIN_DEFAULT
            if [[ -n "${SUB_DOMAIN_UNICOM}" ]]; then
                echo "${SUB_DOMAIN_UNICOM}"
            else
                echo "${SUB_DOMAIN_DEFAULT:-unicom}"
            fi
            ;;
        "移动")
            # 如果 SUB_DOMAIN_MOBILE 未配置，使用 SUB_DOMAIN_DEFAULT
            if [[ -n "${SUB_DOMAIN_MOBILE}" ]]; then
                echo "${SUB_DOMAIN_MOBILE}"
            else
                echo "${SUB_DOMAIN_DEFAULT:-mobile}"
            fi
            ;;
        "电信")
            # 如果 SUB_DOMAIN_TELECOM 未配置，使用 SUB_DOMAIN_DEFAULT
            if [[ -n "${SUB_DOMAIN_TELECOM}" ]]; then
                echo "${SUB_DOMAIN_TELECOM}"
            else
                echo "${SUB_DOMAIN_DEFAULT:-telecom}"
            fi
            ;;
        *)
            # 未知线路,使用小写名称
            echo "${line,,}"
            ;;
    esac
}

# 从文件读取优选 IP (根据线路名)
get_cf_ip_from_file_by_line() {
    local line_name="$1"
    local ip_file=""
    
    # 【性能优化】从预读取的配置中获取 IP 文件路径，避免重复 fork jq
    case "$line_name" in
        "默认")
            ip_file="${CFG[ip_file_default]}"
            [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "default")"
            ;;
        "联通")
            ip_file="${CFG[ip_file_unicom]}"
            [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "unicom")"
            ;;
        "移动")
            ip_file="${CFG[ip_file_mobile]}"
            [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "mobile")"
            ;;
        "电信")
            ip_file="${CFG[ip_file_telecom]}"
            [[ -z "$ip_file" ]] && ip_file="$(get_default_ip_file "telecom")"
            ;;
        *)
            log_error "未知的线路名称: ${line_name}"
            return 1
            ;;
    esac
    
    # 【修复】将相对路径转换为绝对路径，防止 cron 调用时工作目录不同
    if [[ -n "$ip_file" ]] && [[ "$ip_file" != /* ]]; then
        ip_file="${ROOT_DIR}/${ip_file#./}"
    fi
    
    # 调用通用 IP 读取函数
    read_ips_from_file "$ip_file" "$MAX_IPS_PER_RECORD"
}

# 获取指定线路的 DNS 记录
get_record_by_line() {
    local line="$1"
    local subdomain
    subdomain="$(get_subdomain_for_line "${line}")"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$subdomain" --arg line "$line" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","RecordLine":$line,"Limit":100}')
    call_api "DescribeRecordList" "${payload}"
}

# 修改指定线路的 DNS 记录
modify_record_by_line() {
    local record_id="$1"
    local value="$2"
    local line="$3"
    local subdomain
    subdomain="$(get_subdomain_for_line "${line}")"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$subdomain" --arg line "$line" --arg value "$value" --argjson ttl "$TTL" --argjson record_id "$record_id" '{"Domain":$domain,"SubDomain":$subdomain,"RecordType":"A","RecordLine":$line,"Value":$value,"TTL":$ttl,"RecordId":$record_id}')
    call_api "ModifyRecord" "${payload}"
}

# 创建指定线路的 DNS 记录
create_record_by_line() {
    local value="$1"
    local line="$2"
    local subdomain
    subdomain="$(get_subdomain_for_line "${line}")"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$subdomain" --arg line "$line" --arg value "$value" --argjson ttl "$TTL" '{"Domain":$domain,"SubDomain":$subdomain,"RecordType":"A","RecordLine":$line,"Value":$value,"TTL":$ttl}')
    call_api "CreateRecord" "${payload}"
}

# 清屏
clear

# 显示配置摘要
echo -e "${CYAN}+--------------------------------------------------+"
if [[ "${MODE}" = "multi" ]]; then
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 多线路${NC}"
    if [[ "${SUBDOMAIN_STRATEGY}" = "unified" ]]; then
        echo -e " 域名: ${SUB_DOMAIN_UNIFIED:-dns}.${DOMAIN} (统一模式)"
    else
        echo -e " 域名: 分离模式 (各线路独立子域名)"
    fi
    echo -e " 线路: ${ISP_LINES[*]}"
else
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 单线路${NC}"
    echo -e " 域名: ${SUB_DOMAIN}.${DOMAIN}"
    # IP_FILE 已在配置加载时设置，无需重新赋值
fi
echo -e " IP限制: ${MAX_IPS_PER_RECORD} 个/记录"
echo -e "${CYAN}+--------------------------------------------------+${NC}"
echo ""

# ==================== 腾讯云 API 签名 ====================
sha256_hex() {
    # 【修复】使用 printf 替代 echo -n，兼容所有 shell
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        # 【修复】添加 openssl 作为第三级 fallback（macOS 通常预装）
        printf '%s' "$1" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
    else
        echo "错误: 未找到 sha256sum、shasum 或 openssl 命令" >&2
        echo "请安装以下任一工具:" >&2
        echo "  - Linux: apt-get install coreutils (提供 sha256sum)" >&2
        echo "  - macOS: brew install perl (提供 shasum) 或使用系统预装的 openssl" >&2
        exit 1
    fi
}

get_signature_key() {
    local key="$1"
    local date_stamp="$2"
    local service_name="$3"
    
    # 【修复】使用 printf 替代 echo -n，兼容所有 shell
    local k_date
    k_date="$(printf '%s' "${date_stamp}" | openssl dgst -sha256 -hmac "TC3${key}" -hex 2>/dev/null | awk '{print $NF}')"
    local k_service
    k_service="$(printf '%s' "${service_name}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_date}" -hex 2>/dev/null | awk '{print $NF}')"
    local k_signing
    k_signing="$(printf '%s' "tc3_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_service}" -hex 2>/dev/null | awk '{print $NF}')"
    
    echo "${k_signing}"
}

generate_signature() {
    local action="$1"
    local payload="$2"
    
    local timestamp
    timestamp="$(date +%s)"
    local date
    date="$(date -u +"%Y-%m-%d")"
    
    local http_method="POST"
    local canonical_uri="/"
    local canonical_querystring=""
    local content_type="application/json"
    
    local hashed_payload
    hashed_payload="$(sha256_hex "${payload}")"
    
    # 【修复】使用 $'\n' 生成真正的换行符，而非字面字符串 \n
    local newline=$'\n'
    local canonical_headers
    canonical_headers="content-type:${content_type}${newline}host:dnspod.tencentcloudapi.com${newline}x-tc-action:$(echo "${action}" | tr '[:upper:]' '[:lower:]')"
    local signed_headers="content-type;host;x-tc-action"
    
    local canonical_request="${http_method}${newline}${canonical_uri}${newline}${canonical_querystring}${newline}${canonical_headers}${newline}${signed_headers}${newline}${hashed_payload}"
    
    local hashed_canonical_request
    hashed_canonical_request="$(sha256_hex "${canonical_request}")"
    
    local algorithm="TC3-HMAC-SHA256"
    local credential_scope="${date}/dnspod/tc3_request"
    local string_to_sign="${algorithm}${newline}${timestamp}${newline}${credential_scope}${newline}${hashed_canonical_request}"
    
    local secret_key
    secret_key="$(get_signature_key "${SECRETKEY}" "${date}" "dnspod")"
    # 【修复】使用 printf 替代 echo -n，兼容所有 shell
    local signature
    signature="$(printf '%s' "${string_to_sign}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${secret_key}" -hex 2>/dev/null | awk '{print $NF}')"
    
    local authorization="${algorithm} Credential=${SECRETID}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"
    
    echo "Authorization:${authorization}"
    echo "Content-Type:${content_type}"
    echo "Host:dnspod.tencentcloudapi.com"
    echo "X-TC-Action:${action}"
    echo "X-TC-Version:2021-03-23"
    echo "X-TC-Timestamp:${timestamp}"
    echo "X-TC-Region:"
}

call_api() {
    local action="$1"
    local payload="$2"
    # 【修复】使用配置文件中的 MAX_RETRIES（默认 5），而非硬编码 3
    local max_retries="${MAX_RETRIES:-5}"
    local retry=0
    local result=""
    
    while [[ "${retry}" -lt "${max_retries}" ]]; do
        if [[ "${retry}" -gt 0 ]]; then
            log_warn "API 请求失败，正在重试第 ${retry}/${max_retries} 次..."
            sleep 2
        fi
        
        # 生成签名头
        local -a headers_array=()
        while IFS= read -r line; do
            if [[ -n "${line}" ]]; then
                headers_array+=("${line}")
            fi
        done <<< "$(generate_signature "${action}" "${payload}")"
        
        # 构建并执行 curl 命令 (使用数组避免 eval)
        local -a curl_args=("-s" "--connect-timeout" "10" "-X" "POST" "https://dnspod.tencentcloudapi.com")
        
        for header in "${headers_array[@]}"; do
            local key="${header%%:*}"
            local value="${header#*:}"
            if [[ -n "${key}" ]] && [[ -n "${value}" ]]; then
                curl_args+=("-H" "${key}:${value}")
            fi
        done
        
        # 【安全修复】使用 --data @- 通过 stdin 传递 payload，避免敏感信息泄露到进程列表
        curl_args+=("--data" "@-")
        
        # 执行请求（通过管道传递 payload）
        result=$(printf '%s' "${payload}" | curl "${curl_args[@]}") || true
        
        # 【修复】检查空响应，防止后续 jq 解析失败
        if [[ -z "${result}" ]]; then
            log_error "API 响应为空（网络错误或超时）"
            echo '{"status":{"code":"-1","message":"Empty response"}}'
            return 1
        fi
        
        # 【安全修复】严格验证 API 响应，区分成功和错误
        if echo "${result}" | grep -q "Response"; then
            # 检查是否包含错误字段
            local error_code
            error_code=$(echo "${result}" | jq -r '.Response.Error.Code // empty' 2>/dev/null)
            
            if [[ -n "$error_code" ]]; then
                # API 返回了错误
                local error_msg
                error_msg=$(echo "${result}" | jq -r '.Response.Error.Message // "未知错误"' 2>/dev/null)
                log_error "API 错误: ${error_code} - ${error_msg}"
                
                # 认证错误不重试，直接返回失败
                if [[ "$error_code" == "AuthFailure"* ]] || [[ "$error_code" == "Unauthorized"* ]]; then
                    echo "${result}"
                    return 1
                fi
                
                # 其他错误继续重试
                retry=$((retry + 1))
                continue
            else
                # 无错误，请求成功
                echo "${result}"
                return 0
            fi
        fi
        
        # 不包含 Response，可能是网络错误或无效响应
        retry=$((retry + 1))
    done
    
    log_error "API 调用最终失败: ${action}"
    echo "${result}"
    return 1
}

# 获取 DNS 记录
get_record() {
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$SUB_DOMAIN" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
    call_api "DescribeRecordList" "${payload}"
}

# 修改 DNS 记录
modify_record() {
    local record_id="$1"
    local value="$2"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$SUB_DOMAIN" --arg value "$value" --argjson ttl "$TTL" --argjson record_id "$record_id" '{"Domain":$domain,"SubDomain":$subdomain,"RecordType":"A","RecordLine":"默认","Value":$value,"TTL":$ttl,"RecordId":$record_id}')
    call_api "ModifyRecord" "${payload}"
}

# 创建 DNS 记录
create_record() {
    local value="$1"
    local line="${2:-默认}"
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$SUB_DOMAIN" --arg line "$line" --arg value "$value" --argjson ttl "$TTL" '{"Domain":$domain,"SubDomain":$subdomain,"RecordType":"A","RecordLine":$line,"Value":$value,"TTL":$ttl}')
    call_api "CreateRecord" "${payload}"
}

# 从文件读取优选 IP (单线路通用)
get_cf_ip_from_file() {
    if [[ ! -f "${IP_FILE}" ]]; then
        log_error "IP 文件不存在: ${IP_FILE}"
        log_warn "请创建文件或修改 dnspod.json 中的配置"
        return 1
    fi
    
    # 调用通用 IP 读取函数
    read_ips_from_file "$IP_FILE" "$MAX_IPS_PER_RECORD"
}

# 单线路模式主函数
main_single() {
    local current_time
    current_time="$(date +"%Y-%m-%d %H:%M:%S")"
    
    # 日志头部
    log_info ""
    log_info "================================================================"
    log_info "DNSPod DNS 更新器 - 单线路模式"
    log_info "================================================================"
    log_info "执行时间: ${current_time}"
    log_info "域名:     ${SUB_DOMAIN}.${DOMAIN}"
    log_info "IP限制:   ${MAX_IPS_PER_RECORD} 个/记录"
    log_info "================================================================"
    log_info ""
    
    # 获取 DNS 记录
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "步骤 1: 获取 DNS 记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local record_response
    # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
    record_response="$(get_record || true)"
    
    # 使用 jq 解析 JSON
    local -a all_record_ids=()
    local -a all_current_values=()
    local -a all_line_ids=()
    local -a record_ids=()
    local -a current_values=()
    local record_count=0
    
    # 检查是否有错误
    local error_code
    error_code="$(echo "${record_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
    
    # ResourceNotFound.NoDataOfRecord 表示记录不存在，这是正常情况
    if [[ -n "${error_code}" ]] && [[ "${error_code}" != "null" ]] && [[ "${error_code}" != "ResourceNotFound.NoDataOfRecord" ]]; then
        local error_msg
        error_msg="$(echo "${record_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
        log_error "[ERROR] API 错误: ${error_code} - ${error_msg}"
        exit 1
    fi
    
    # 获取记录数量
    local count
    count="$(echo "${record_response}" | jq '.Response.RecordList | length' 2>/dev/null)"
    
    if [[ -z "${count}" ]] || [[ "${count}" = "null" ]] || [[ "${count}" -eq 0 ]]; then
        log_info "状态: 未找到 DNS 记录,将自动创建"
    else
        # 提取所有记录信息
        for ((i=0; i<count; i++)); do
            local record_id
            record_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)"
            local value
            value="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)"
            local line_id
            line_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].LineId" 2>/dev/null)"
            
            all_record_ids+=("${record_id}")
            all_current_values+=("${value}")
            all_line_ids+=("${line_id}")
        done
        
        # 筛选"默认"线路的记录(LineId="0"表示默认线路)
        for i in "${!all_record_ids[@]}"; do
            if [[ "${all_line_ids[$i]}" = "0" ]]; then
                record_ids+=("${all_record_ids[$i]}")
                current_values+=("${all_current_values[$i]}")
            fi
        done
        
        record_count=${#record_ids[@]}
        
        if [[ "${record_count}" -eq 0 ]]; then
            log_info "状态: 未找到 DNS 记录,将自动创建"
        else
            log_info "状态: 找到 ${record_count} 条记录"
            for i in "${!record_ids[@]}"; do
                log_info "  [$((i+1))] RecordID=${record_ids[$i]}, IP=${current_values[$i]}"
            done
        fi
        log_info ""
    fi
    
    # 从文件获取优选 IP
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "步骤 2: 读取优选 IP"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "IP文件: ${IP_FILE}"
    local cf_ip
    if ! cf_ip="$(get_cf_ip_from_file)"; then
        log_error "无法从文件读取IP,请检查IP文件是否存在且格式正确"
        exit 1
    fi
    
    # 解析多个 IP 地址（公共库版本返回空格分隔）
    local -a ip_addresses=()
    local -a invalid_ips=()
    IFS=' ' read -ra raw_ips <<< "${cf_ip}"
    for ip in "${raw_ips[@]}"; do
        # 去除首尾空格和空白字符
        ip=$(echo "${ip}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "${ip}" ]]; then
            # 验证 IP 格式
            if validate_ip "${ip}"; then
                ip_addresses+=("${ip}")
            else
                invalid_ips+=("${ip}")
            fi
        fi
    done
    
    # 显示无效 IP 警告
    if [[ ${#invalid_ips[@]} -gt 0 ]]; then
        log_warn "[WARN] 发现 ${#invalid_ips[@]} 个无效 IP，已跳过:"
        for invalid_ip in "${invalid_ips[@]}"; do
            log_warn "    - ${invalid_ip}"
        done
    fi
    
    if [[ ${#ip_addresses[@]} -eq 0 ]]; then
        log_error "未解析到有效 IP"
        exit 1
    fi
    
    log_info "状态: 获取到 ${#ip_addresses[@]} 个 IP"
    for i in "${!ip_addresses[@]}"; do
        log_info "  [$((i+1))] ${ip_addresses[$i]}"
    done
    log_info ""
    
    # 更新或创建 DNS 记录
    local updated_count=0
    local skipped_count=0
    local created_count=0
    
    for ((i=0; i<${#ip_addresses[@]}; i++)); do
        local new_ip="${ip_addresses[$i]}"
        
        if [[ "${i}" -lt "${record_count}" ]]; then
            # 更新现有记录
            local record_id="${record_ids[$i]}"
            local current_value="${current_values[$i]}"
            
            # 【功能增强】显示进度
            printf "\r  [%d/%d] 正在处理 %s..." "$((i+1))" "${#ip_addresses[@]}" "$new_ip"
            
            # 检查 IP 是否变化 (去除空格后比较)
            local clean_current
            clean_current="$(echo "${current_value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            local clean_new
            clean_new="$(echo "${new_ip}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            
            if [[ "${clean_current}" = "${clean_new}" ]]; then
                skipped_count=$((skipped_count + 1))
            else
                # 需要更新
                local modify_response
                # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
                modify_response="$(modify_record "${record_id}" "${new_ip}" || true)"
                
                # 检查结果
                if echo "${modify_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                    local error_code
                    error_code="$(echo "${modify_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
                    local error_msg
                    error_msg="$(echo "${modify_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
                    echo ""  # 换行
                    log_error "  [ERROR] 更新失败: ${error_code} - ${error_msg}"
                else
                    updated_count=$((updated_count + 1))
                fi
            fi
        else
            # 自动新建记录
            # 【功能增强】显示进度
            printf "\r  [%d/%d] 正在创建 %s..." "$((i+1))" "${#ip_addresses[@]}" "$new_ip"
            
            local create_response
            # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
            create_response="$(create_record "${new_ip}" || true)"
            
            # 检查结果
            if echo "${create_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                local error_code
                error_code="$(echo "${create_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
                local error_msg
                error_msg="$(echo "${create_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
                echo ""  # 换行
                log_error "  [ERROR] 创建失败: ${error_code} - ${error_msg}"
            else
                created_count=$((created_count + 1))
            fi
        fi
    done
    echo ""  # 换行
    
    # 输出总结
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "更新结果汇总"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  [OK] 成功: ${updated_count}"
    log_info "  [SKIP] 跳过: ${skipped_count}"
    log_info "  ➕ 新建: ${created_count}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 【功能增强】记录 DNSPod 更新历史
    record_dnspod_update_history "$DOMAIN_NAME" "$updated_count" "$created_count" "$skipped_count"
    log_info "已记录 DNSPod 更新历史到 conf/history.jsonl"
}

# 多线路模式主函数
main_multi() {
    local current_time
    current_time="$(date +"%Y-%m-%d %H:%M:%S")"
    
    # 日志头部
    log_info ""
    log_info "================================================================"
    log_info "DNSPod DNS 更新器 - 多线路模式"
    log_info "================================================================"
    log_info "执行时间: ${current_time}"
    log_info "域名:     ${DOMAIN}"
    log_info "运营商线路: ${ISP_LINES[*]}"
    log_info "IP限制:   ${MAX_IPS_PER_RECORD} 个/记录"
    log_info "================================================================"
    log_info ""
    
    # 遍历每个运营商线路
    local total_updated=0
    local total_skipped=0
    local total_failed=0
    local total_created=0
    local processed_lines=0
    
    for line in "${ISP_LINES[@]}"; do
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "处理线路: ${line}"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 从文件获取该线路的优选 IP
        log_info "步骤 1: 读取优选 IP"
        local cf_ip
        if ! cf_ip="$(get_cf_ip_from_file_by_line "${line}")"; then
            log_error "无法从文件读取IP,请检查IP文件是否存在且格式正确"
            continue
        fi
        
        # 解析多个 IP 地址（公共库版本返回空格分隔）
        local -a ip_addresses=()
        local -a invalid_ips=()
        IFS=' ' read -ra raw_ips <<< "${cf_ip}"
        for ip in "${raw_ips[@]}"; do
            ip=$(echo "${ip}" | tr -d ' \r')
            if [[ -n "${ip}" ]]; then
                # 验证 IP 格式
                if validate_ip "${ip}"; then
                    ip_addresses+=("${ip}")
                else
                    invalid_ips+=("${ip}")
                fi
            fi
        done
        
        # 显示无效 IP 警告
        if [[ ${#invalid_ips[@]} -gt 0 ]]; then
            log_warn "[WARN] 发现 ${#invalid_ips[@]} 个无效 IP，已跳过:"
            for invalid_ip in "${invalid_ips[@]}"; do
                log_warn "    - ${invalid_ip}"
            done
        fi
        
        if [[ ${#ip_addresses[@]} -eq 0 ]]; then
            log_error "未解析到有效 IP"
            continue
        fi
        
        log_info "状态: 获取到 ${#ip_addresses[@]} 个 IP"
        for i in "${!ip_addresses[@]}"; do
            log_info "  [$((i+1))] ${ip_addresses[$i]}"
        done
        
        # 获取该线路的 DNS 记录
        log_info "步骤 2: 获取 DNS 记录"
        local record_response
        # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
        record_response="$(get_record_by_line "${line}" || true)"
        
        # 使用 jq 解析 JSON
        local -a record_ids=()
        local -a current_values=()
        local record_count=0
        
        # 检查是否有错误
        local error_code
        error_code="$(echo "${record_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
        
        # ResourceNotFound.NoDataOfRecord 表示记录不存在，这是正常情况
        if [[ -n "${error_code}" ]] && [[ "${error_code}" != "null" ]] && [[ "${error_code}" != "ResourceNotFound.NoDataOfRecord" ]]; then
            local error_msg
            error_msg="$(echo "${record_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
            log_error "[ERROR] API 错误: ${error_code} - ${error_msg}"
            continue
        fi
        
        # 获取记录数量
        local count
        count="$(echo "${record_response}" | jq '.Response.RecordList | length' 2>/dev/null)"
        
        if [[ -z "${count}" ]] || [[ "${count}" = "null" ]] || [[ "${count}" -eq 0 ]]; then
            log_info "状态: 该线路无记录,将自动创建"
        else
            # 提取所有记录信息
            for ((i=0; i<count; i++)); do
                local record_id
                record_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)"
                local value
                value="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)"
                
                record_ids+=("${record_id}")
                current_values+=("${value}")
            done
            
            record_count=${#record_ids[@]}
            
            log_info "状态: 找到 ${record_count} 条记录"
            for i in "${!record_ids[@]}"; do
                log_info "  [$((i+1))] RecordID=${record_ids[$i]}, IP=${current_values[$i]}"
            done
        fi
        log_info ""
        
        # 【安全修复】确定要处理的记录数（取 IP 数量和现有记录数的较小值）
        log_info "步骤 3: 更新/创建 DNS 记录"
        local updated=0
        local skipped=0
        local failed=0
        local created=0
        
        # 【安全修复】检查 IP 数量与记录数量的关系
        if [[ ${#ip_addresses[@]} -lt ${record_count} ]]; then
            log_warn "IP 数量(${#ip_addresses[@]})少于记录数量(${record_count})"
            log_warn "将更新前 ${#ip_addresses[@]} 条记录，并删除多余的 $((record_count - ${#ip_addresses[@]})) 条记录"
        elif [[ ${#ip_addresses[@]} -gt ${record_count} ]]; then
            log_info "IP 数量(${#ip_addresses[@]})多于记录数量(${record_count})"
            log_info "将更新所有现有记录，并新建 $(( ${#ip_addresses[@]} - record_count )) 条记录"
        fi
        
        # 【安全修复】计算需要处理的记录数（取最大值以确保所有 IP 都被处理）
        local process_count
        if [[ ${#ip_addresses[@]} -gt ${record_count} ]]; then
            process_count=${#ip_addresses[@]}
        else
            process_count=${record_count}
        fi
        
        for ((i=0; i<process_count; i++)); do
            # 【安全修复】获取当前要使用的 IP（循环使用）
            local ip_index=$((i % ${#ip_addresses[@]}))
            local new_ip="${ip_addresses[$ip_index]}"
            
            # 获取当前线路的子域名
            # shellcheck disable=SC2034
            local current_subdomain
            current_subdomain="$(get_subdomain_for_line "${line}")"
            
            if [[ "${i}" -lt "${record_count}" ]]; then
                # 更新现有记录
                local record_id="${record_ids[$i]}"
                local current_value="${current_values[$i]}"
                        
                # 【功能增强】显示进度
                printf "\r    [%d/%d] 正在处理 %s..." "$((i+1))" "${process_count}" "$new_ip"
                        
                # 检查 IP 是否变化 (去除空格后比较)
                local clean_current
                clean_current="$(echo "${current_value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                local clean_new
                clean_new="$(echo "${new_ip}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                        
                if [[ "${clean_current}" = "${clean_new}" ]]; then
                    skipped=$((skipped + 1))
                else
                    # 需要更新
                    local modify_response
                    # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
                    modify_response="$(modify_record_by_line "${record_id}" "${new_ip}" "${line}" || true)"
                            
                    # 检查结果
                    if echo "${modify_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                        local error_code
                        error_code="$(echo "${modify_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
                        local error_msg
                        error_msg="$(echo "${modify_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
                        echo ""  # 换行
                        log_error "  [ERROR] 更新失败: ${error_code} - ${error_msg}"
                        failed=$((failed + 1))
                    else
                        updated=$((updated + 1))
                    fi
                fi
            else
                # 【安全修复】当 IP 数量 >= 记录数时，才创建新记录
                # 如果 IP 数量 < 记录数，这里不应该执行（process_count = record_count）
                if [[ ${#ip_addresses[@]} -ge ${record_count} ]]; then
                    # 自动新建记录
                    # 【功能增强】显示进度
                    printf "\r    [%d/%d] 正在创建 %s..." "$((i+1))" "${process_count}" "$new_ip"
                            
                    local create_response
                    # 【安全修复】在 set -e 模式下，API 调用失败会导致脚本退出
                    create_response="$(create_record_by_line "${new_ip}" "${line}" || true)"
                            
                    # 检查结果
                    if echo "${create_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                        local error_code
                        error_code="$(echo "${create_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
                        local error_msg
                        error_msg="$(echo "${create_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
                        echo ""  # 换行
                        log_error "  [ERROR] 创建失败: ${error_code} - ${error_msg}"
                        failed=$((failed + 1))
                    else
                        created=$((created + 1))
                    fi
                fi
            fi
        done
        echo ""  # 换行
        
        # 【安全修复】如果 IP 数量少于记录数，删除多余的记录
        if [[ ${#ip_addresses[@]} -lt ${record_count} ]]; then
            log_info "步骤 4: 清理多余记录"
            local deleted=0
            for ((i=${#ip_addresses[@]}; i<record_count; i++)); do
                local record_id="${record_ids[$i]}"
                local current_value="${current_values[$i]}"
                log_info "  正在删除第 $((i+1)) 条记录 (RecordID=${record_id}, IP=${current_value})..."
                
                local delete_response
                # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
                if delete_response="$(delete_record_by_line "${record_id}" "${line}")"; then true; else delete_response=""; fi
                
                # 检查结果
                if echo "${delete_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                    local error_code
                    error_code="$(echo "${delete_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
                    local error_msg
                    error_msg="$(echo "${delete_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
                    log_error "  [ERROR] 删除失败: ${error_code} - ${error_msg}"
                    failed=$((failed + 1))
                else
                    deleted=$((deleted + 1))
                    log_info "  [OK] 已删除"
                fi
            done
            log_info "共删除 ${deleted} 条多余记录"
            log_info ""
        fi
        
        log_info ""
        log_info "线路完成统计:"
        log_info "  [OK] 成功: ${updated}"
        log_error "  [ERROR] 失败: ${failed}"
        log_info "  [SKIP] 跳过: ${skipped}"
        log_info "  ➕ 新建: ${created}"
        log_info ""
        
        total_updated=$((total_updated + updated))
        total_skipped=$((total_skipped + skipped))
        total_failed=$((total_failed + failed))
        total_created=$((total_created + created))
        processed_lines=$((processed_lines + 1))
    done
    
    # 总结
    log_info "================================================================"
    log_info "更新结果汇总"
    log_info "================================================================"
    log_info "处理线路: ${processed_lines}"
    log_info "更新成功: ${total_updated}"
    log_info "跳过:     ${total_skipped}"
    log_info "失败:     ${total_failed}"
    log_info "新建:     ${total_created}"
    log_info "================================================================"
    
    # 【功能增强】记录 DNSPod 多线路更新历史
    record_dnspod_update_history "$DOMAIN_NAME" "$total_updated" "$total_created" "$total_skipped"
    log_info "已记录 DNSPod 更新历史到 conf/history.jsonl"
}

# 删除模式主函数（单线路）
main_delete() {
    local lines_to_delete=("$@")
    
    # 如果没有指定线路，使用配置文件中的所有线路
    if [[ ${#lines_to_delete[@]} -eq 0 ]]; then
        if [[ "${MODE}" = "multi" ]] && [[ -n "${ISP_LINES[*]}" ]]; then
            lines_to_delete=("${ISP_LINES[@]}")
        elif [[ -n "${SUB_DOMAIN}" ]]; then
            lines_to_delete=("默认")
        else
            log_error "未指定要删除的线路"
            exit 1
        fi
    fi
    
    log_info ""
    log_info "================================================================"
    log_info "DNSPod DNS 记录删除器"
    log_info "================================================================"
    log_info "域名: ${DOMAIN}"
    log_info "线路: ${lines_to_delete[*]}"
    log_info "================================================================"
    log_info ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "预检：查询将要删除的记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a all_record_ids=()
    local -a all_subdomains=()
    local -a all_values=()
    local total_found=0
    
    for line in "${lines_to_delete[@]}"; do
        local subdomain=""
        if [[ "${MODE}" = "multi" ]]; then
            # 使用分离模式的子域名（忽略当前策略）
            subdomain="$(get_separate_subdomain_for_line "${line}")"
        else
            subdomain="${SUB_DOMAIN}"
        fi
        
        # 查询记录（只按子域名查询，不限制线路）
        # 【修复】使用 jq 安全构建 JSON
        local payload
        payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
        local record_response
        # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
        if record_response="$(call_api "DescribeRecordList" "${payload}")"; then true; else record_response=""; fi
        
        # 检查是否有错误
        local error_code
        error_code="$(echo "${record_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
        
        if [[ -n "${error_code}" ]] && [[ "${error_code}" != "null" ]] && [[ "${error_code}" != "ResourceNotFound.NoDataOfRecord" ]]; then
            local error_msg
            error_msg="$(echo "${record_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
            log_error "[ERROR] 查询失败: ${line} - ${error_code}"
            continue
        fi
        
        # 获取记录数量
        local count
        count="$(echo "${record_response}" | jq '.Response.RecordList | length' 2>/dev/null)"
        
        if [[ -z "${count}" ]] || [[ "${count}" = "null" ]] || [[ "${count}" -eq 0 ]]; then
            log_info "  [SKIP] ${subdomain}.${DOMAIN} - 无记录"
            continue
        fi
        
        # 收集所有记录信息
        for ((i=0; i<count; i++)); do
            local record_id
            record_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)"
            local value
            value="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)"
            
            all_record_ids+=("${record_id}")
            all_subdomains+=("${subdomain}.${DOMAIN}")
            all_values+=("${value}")
            total_found=$((total_found + 1))
            
            log_info "  [${total_found}] ${subdomain}.${DOMAIN} → ${value} (ID: ${record_id})"
        done
    done
    
    log_info ""
    
    if [[ "${total_found}" -eq 0 ]]; then
        log_warn "[INFO] 未找到任何记录，无需删除"
        return 0
    fi
    
    log_info "[OK] 共找到 ${total_found} 条记录"
    log_info ""
    
    # ===== 删除阶段 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始删除记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local subdomain="${all_subdomains[$i]}"
        local value="${all_values[$i]}"
        
        log_info ""
        log_info "  记录 $((i+1))/${total_found}:"
        log_info "    子域名:   ${subdomain}"
        log_info "    RecordID: ${record_id}"
        log_info "    IP:       ${value}"
        log_info "    ⟳ 正在删除..."
        
        local delete_response
        # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
        if delete_response="$(delete_record_by_line "${record_id}")"; then true; else delete_response=""; fi
        
        # 检查结果
        if echo "${delete_response}" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
            local error_code
            error_code="$(echo "${delete_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
            local error_msg
            error_msg="$(echo "${delete_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
            log_error "    [ERROR] 删除失败: ${error_code} - ${error_msg}"
            total_failed=$((total_failed + 1))
        else
            log_info "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        fi
    done
    
    # 总结
    log_info ""
    log_info "================================================================"
    log_info "删除结果汇总"
    log_info "================================================================"
    log_info " [OK] 成功: ${total_deleted}"
    log_error " [ERROR] 失败: ${total_failed}"
    log_info "================================================================"
}

# 删除统一模式记录的主函数
main_delete_unified() {
    local unified_subdomain="${1:-dns}"
    
    log_info ""
    log_info "================================================================"
    log_info "DNSPod DNS 记录删除器 - 统一模式"
    log_info "================================================================"
    log_info "域名: ${DOMAIN}"
    log_info "子域名: ${unified_subdomain}.${DOMAIN}"
    log_info "================================================================"
    log_info ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "预检：查询统一模式的记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a all_record_ids=()
    local -a all_lines=()
    local -a all_values=()
    local total_found=0
    local -A seen_records=()  # 用于去重
    
    # 只需要查询一次，因为统一模式下所有线路使用同一个子域名
    # 查询记录（按子域名查询，不限制线路）
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$unified_subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
    local record_response
    # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
    if record_response="$(call_api "DescribeRecordList" "${payload}")"; then true; else record_response=""; fi
    
    # 检查是否有错误
    local error_code
    error_code="$(echo "${record_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
    
    if [[ -n "${error_code}" ]] && [[ "${error_code}" != "null" ]] && [[ "${error_code}" != "ResourceNotFound.NoDataOfRecord" ]]; then
        local error_msg
        error_msg="$(echo "${record_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
        log_error "[ERROR] 查询失败: ${error_code}"
        return 1
    fi
    
    # 获取记录数量
    local count
    count="$(echo "${record_response}" | jq '.Response.RecordList | length' 2>/dev/null)"
    
    if [[ -z "${count}" ]] || [[ "${count}" = "null" ]] || [[ "${count}" -eq 0 ]]; then
        log_warn "[INFO] 未找到任何记录"
        return 0
    fi
    
    # 收集所有记录信息（自动去重）
    for ((i=0; i<count; i++)); do
        local record_id
        record_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)"
        local value
        value="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)"
        local record_line
        record_line="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Line" 2>/dev/null)"
        
        # 使用 RecordID 作为唯一标识进行去重
        if [[ -z "${seen_records[$record_id]+x}" ]]; then
            seen_records[$record_id]=1
            all_record_ids+=("${record_id}")
            all_lines+=("${record_line}")
            all_values+=("${value}")
            total_found=$((total_found + 1))
            
            log_info "  [${total_found}] ${unified_subdomain}.${DOMAIN} (${record_line}) → ${value} (ID: ${record_id})"
        fi
    done
    
    log_info ""
    
    if [[ "${total_found}" -eq 0 ]]; then
        log_warn "[INFO] 未找到任何记录，无需删除"
        return 0
    fi
    
    log_info "[OK] 共找到 ${total_found} 条记录"
    log_info ""
    
    # ===== 删除阶段 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始删除记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local line_name="${all_lines[$i]}"
        local value="${all_values[$i]}"
        
        log_info ""
        log_info "  记录 $((i+1))/${total_found}:"
        log_info "    子域名:   ${unified_subdomain}.${DOMAIN}"
        log_info "    线路:     ${line_name}"
        log_info "    RecordID: ${record_id}"
        log_info "    IP:       ${value}"
        log_info "    ⟳ 正在删除..."
        
        local delete_response
        # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
        if delete_response="$(delete_record_by_line "${record_id}")"; then true; else delete_response=""; fi
        local delete_error
        delete_error="$(echo "${delete_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
        
        if [[ -z "${delete_error}" ]] || [[ "${delete_error}" = "null" ]]; then
            log_info "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        else
            local delete_msg
            delete_msg="$(echo "${delete_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
            log_error "    [ERROR] 删除失败: ${delete_error} - ${delete_msg}"
            total_failed=$((total_failed + 1))
        fi
    done
    
    # 总结
    log_info ""
    log_info "================================================================"
    log_info "删除结果汇总"
    log_info "================================================================"
    log_info " [OK] 成功: ${total_deleted}"
    log_error " [ERROR] 失败: ${total_failed}"
    log_info "================================================================"
}

# 删除统一模式非默认线路记录的主函数（保留默认线路）
main_delete_unified_non_default() {
    local unified_subdomain="${1:-dns}"
    
    log_info ""
    log_info "================================================================"
    log_info "DNSPod DNS 记录删除器 - 统一模式（非默认线路）"
    log_info "================================================================"
    log_info "域名: ${DOMAIN}"
    log_info "子域名: ${unified_subdomain}.${DOMAIN}"
    log_info "说明: 删除联通、移动、电信线路，保留默认线路"
    log_info "================================================================"
    log_info ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "预检：查询统一模式的非默认线路记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
    local -a all_record_ids=()
    local -a all_lines=()
    local -a all_values=()
    local total_found=0
    local -A seen_records=()  # 用于去重
        
    # 只需要查询一次，因为统一模式下所有线路使用同一个子域名
    # 查询记录（按子域名查询，不限制线路）
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$DOMAIN" --arg subdomain "$unified_subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
    local record_response
    # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
    if record_response="$(call_api "DescribeRecordList" "${payload}")"; then true; else record_response=""; fi
        
    # 检查是否有错误
    local error_code
    error_code="$(echo "${record_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
        
    if [[ -n "${error_code}" ]] && [[ "${error_code}" != "null" ]] && [[ "${error_code}" != "ResourceNotFound.NoDataOfRecord" ]]; then
        local error_msg
        error_msg="$(echo "${record_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
        log_error "[ERROR] 查询失败: ${error_code}"
        return 1
    fi
        
    # 获取记录数量
    local count
    count="$(echo "${record_response}" | jq '.Response.RecordList | length' 2>/dev/null)"
        
    if [[ -z "${count}" ]] || [[ "${count}" = "null" ]] || [[ "${count}" -eq 0 ]]; then
        log_warn "[INFO] 未找到任何记录"
        return 0
    fi
        
    # 收集所有非默认线路的记录信息（自动去重）
    for ((i=0; i<count; i++)); do
        local record_id
        record_id="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)"
        local value
        value="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)"
        local record_line
        record_line="$(echo "${record_response}" | jq -r ".Response.RecordList[$i].Line" 2>/dev/null)"
            
        # 跳过默认线路
        if [[ "${record_line}" = "默认" ]]; then
            continue
        fi
            
        # 使用 RecordID 作为唯一标识进行去重
        if [[ -z "${seen_records[$record_id]+x}" ]]; then
            seen_records[$record_id]=1
            all_record_ids+=("${record_id}")
            all_lines+=("${record_line}")
            all_values+=("${value}")
            total_found=$((total_found + 1))
                
            log_info "  [${total_found}] ${unified_subdomain}.${DOMAIN} (${record_line}) → ${value} (ID: ${record_id})"
        fi
    done
        
    # 显示保留的默认线路提示
    log_info "  [OK] 默认线路 - 保留"
    
    log_info ""
    
    if [[ "${total_found}" -eq 0 ]]; then
        log_warn "[INFO] 未找到任何非默认线路记录，无需删除"
        return 0
    fi
    
    log_info "[OK] 共找到 ${total_found} 条非默认线路记录"
    log_info ""
    
    # ===== 删除阶段 =====
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始删除非默认线路记录"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local line_name="${all_lines[$i]}"
        local value="${all_values[$i]}"
        
        log_info ""
        log_info "  记录 $((i+1))/${total_found}:"
        log_info "    子域名:   ${unified_subdomain}.${DOMAIN}"
        log_info "    线路:     ${line_name}"
        log_info "    RecordID: ${record_id}"
        log_info "    IP:       ${value}"
        log_info "    ⟳ 正在删除..."
        
        local delete_response
        # 【修复】保护 API 调用赋值，防止 set -e 在 API 失败时终止脚本
        if delete_response="$(delete_record_by_line "${record_id}")"; then true; else delete_response=""; fi
        local delete_error
        delete_error="$(echo "${delete_response}" | jq -r '.Response.Error.Code' 2>/dev/null)"
        
        if [[ -z "${delete_error}" ]] || [[ "${delete_error}" = "null" ]]; then
            log_info "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        else
            local delete_msg
            delete_msg="$(echo "${delete_response}" | jq -r '.Response.Error.Message' 2>/dev/null)"
            log_error "    [ERROR] 删除失败: ${delete_error} - ${delete_msg}"
            total_failed=$((total_failed + 1))
        fi
    done
    
    # 总结
    log_info ""
    log_info "================================================================"
    log_info "删除结果汇总"
    log_info "================================================================"
    log_info " [OK] 成功: ${total_deleted}"
    log_error " [ERROR] 失败: ${total_failed}"
    log_info " 保留: 默认线路记录"
    log_info "================================================================"
}


# ==================== 记录管理辅助函数（供 setup.sh 调用） ====================

# 更新配置文件字段（通用函数）
update_config_field() {
    local field_path="$1"  # jq 路径，如 .dns.sub_domain
    local new_value="$2"
    
    if ! command -v jq &>/dev/null; then
        log_error "jq 未安装，无法更新配置"
        return 1
    fi
    
    local temp_file
    temp_file=$(mktemp /tmp/cfopt-dnspod.XXXXXX)
    chmod 600 "${temp_file}"
    
    # 【修复】自动判断值类型：纯数字用 --argjson，其他用 --arg
    local jq_arg="--arg"
    if [[ "$new_value" =~ ^[0-9]+$ ]]; then
        jq_arg="--argjson"
    fi
    
    if jq $jq_arg val "$new_value" "${field_path} = \$val" "$CONFIG_FILE" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        log_info "配置已更新: ${field_path} = ${new_value}"
        return 0
    else
        rm -f "$temp_file"
        log_error "更新配置失败: ${field_path}"
        return 1
    fi
}

# 通用的 IP 文件读取函数（支持单线路和多线路）
# 【已移除】read_ips_from_file() 函数
# 统一使用 lib/common.sh 中的公共版本，避免行为不一致

# 检查是否存在 DNS 记录
check_records_exist() {
    local subdomain="$1"
    local domain="$2"
    
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$domain" --arg subdomain "$subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":1}')
    local response
    response="$(call_api "DescribeRecordList" "$payload")"
    
    local count
    count="$(echo "$response" | jq '.Response.RecordList | length' 2>/dev/null)"
    
    if [[ -z "$count" ]] || [[ "$count" = "null" ]] || [[ "$count" -eq 0 ]]; then
        return 1  # 不存在
    else
        return 0  # 存在
    fi
}

# 获取记录数量
get_record_count() {
    local subdomain="$1"
    local domain="$2"
    
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$domain" --arg subdomain "$subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
    local response
    response="$(call_api "DescribeRecordList" "$payload")"
    
    local count
    count="$(echo "$response" | jq '.Response.RecordList | length' 2>/dev/null)"
    
    echo "${count:-0}"
}

# 获取记录详情（JSON 格式）
get_record_details() {
    local subdomain="$1"
    local domain="$2"
    
    # 【修复】使用 jq 安全构建 JSON
    local payload
    payload=$(jq -n --arg domain "$domain" --arg subdomain "$subdomain" '{"Domain":$domain,"Subdomain":$subdomain,"RecordType":"A","Limit":100}')
    call_api "DescribeRecordList" "$payload"
}

# 智能处理模式切换时的记录迁移
# 参数:
#   $1: from_mode (single/multi)
#   $2: to_mode (single/multi)
#   $3: strategy (unified/separate, 仅多线路时需要)
#   $4: new_subdomain (可选，新的子域名)
handle_mode_switch() {
    local from_mode="$1"
    local to_mode="$2"
    local strategy="${3:-separate}"
    local new_subdomain="$4"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始处理模式切换: ${from_mode} → ${to_mode}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ "$from_mode" == "single" ]] && [[ "$to_mode" == "multi" ]]; then
        # 单线路 → 多线路
        handle_single_to_multi "$strategy" "$new_subdomain"
    elif [[ "$from_mode" == "multi" ]] && [[ "$to_mode" == "single" ]]; then
        # 多线路 → 单线路
        handle_multi_to_single "$strategy" "$new_subdomain"
    else
        log_error "不支持的模式切换: ${from_mode} → ${to_mode}"
        return 1
    fi
}

# 单线路 → 多线路
handle_single_to_multi() {
    local strategy="$1"
    local new_subdomain="$2"
    
    local old_subdomain
    old_subdomain=$(jq -r '.dns.sub_domain // empty' "$CONFIG_FILE")
    local domain
    domain=$(jq -r '.dns.domain // empty' "$CONFIG_FILE")
    
    if [[ -z "$old_subdomain" ]] || [[ -z "$domain" ]]; then
        log_error "配置不完整，无法执行模式切换"
        return 1
    fi
    
    log_info "检测到单线路记录: ${old_subdomain}.${domain}"
    
    # 检查是否存在单线路记录
    if check_records_exist "$old_subdomain" "$domain"; then
        local record_count
        record_count=$(get_record_count "$old_subdomain" "$domain")
        log_info "找到 ${record_count} 条单线路记录"
        
        # 询问用户如何处理（交互式环境）
        if [[ -t 0 ]]; then
            echo ""
            echo -e "${YELLOW}请选择如何处理现有记录：${NC}"
            echo "  1) 删除单线路记录并创建多线路记录（推荐）"
            echo "  2) 保留单线路记录，仅创建多线路记录"
            echo "  3) 取消切换"
            echo ""
            read -r -p "请选择 (1/2/3, 默认 1): " choice
            choice=${choice:-1}
            
            case "$choice" in
                1)
                    # 删除单线路记录
                    log_info "正在删除单线路记录..."
                    main_delete
                    
                    # 创建多线路记录
                    log_info "正在创建多线路记录..."
                    main_multi
                    ;;
                2)
                    # 仅创建多线路记录
                    log_info "正在创建多线路记录（保留单线路记录）..."
                    main_multi
                    log_warn "注意: 单线路记录 ${old_subdomain}.${domain} 仍然保留"
                    ;;
                3)
                    log_info "已取消模式切换"
                    return 1
                    ;;
                *)
                    log_error "无效的选择"
                    return 1
                    ;;
            esac
        else
            # 非交互式环境，默认删除并创建
            log_info "非交互式环境，自动删除单线路记录并创建多线路记录"
            main_delete
            main_multi
        fi
    else
        log_info "未找到单线路记录，直接创建多线路记录"
        main_multi
    fi
}

# 多线路 → 单线路
handle_multi_to_single() {
    local strategy="$1"
    local new_subdomain="$2"
    
    local domain
    domain=$(jq -r '.dns.domain // empty' "$CONFIG_FILE")
    
    if [[ -z "$domain" ]]; then
        log_error "配置不完整，无法执行模式切换"
        return 1
    fi
    
    log_info "检测到多线路配置"
    
    # 根据策略处理
    if [[ "$strategy" == "unified" ]]; then
        local unified_subdomain
        unified_subdomain=$(jq -r '.dns.sub_domain_unified // "dns"' "$CONFIG_FILE")
        
        log_info "统一模式子域名: ${unified_subdomain}.${domain}"
        
        # 检查是否存在统一模式记录
        if check_records_exist "$unified_subdomain" "$domain"; then
            local record_count
            record_count=$(get_record_count "$unified_subdomain" "$domain")
            log_info "找到 ${record_count} 条统一模式记录"
            
            if [[ -t 0 ]]; then
                echo ""
                echo -e "${YELLOW}请选择如何处理默认线路记录：${NC}"
                echo "  1) 保留默认线路（推荐）"
                echo "  2) 使用新的子域名"
                echo ""
                read -r -p "请选择 (1/2, 默认 1): " choice
                choice=${choice:-1}
                
                if [[ "$choice" == "2" ]]; then
                    echo ""
                    read -r -p "请输入新的子域名 [${unified_subdomain}]: " new_sub
                    new_sub=${new_sub:-$unified_subdomain}
                    
                    # 删除所有统一模式记录
                    log_info "正在删除所有统一模式记录..."
                    main_delete_unified "$unified_subdomain"
                    
                    # 更新配置
                    # 更新配置
                    update_config_field ".dns.sub_domain" "$new_sub"
                    
                    # 创建单线路记录
                    log_info "正在创建单线路记录..."
                    main_single
                else
                    # 只删除非默认线路
                    log_info "正在删除非默认线路记录..."
                    main_delete_unified_non_default "$unified_subdomain"
                    
                    # 使用统一模式的子域名作为单线路子域名
                    # 更新配置
                    update_config_field ".dns.sub_domain" "$unified_subdomain"
                    
                    log_info "单线路将使用子域名: ${unified_subdomain}.${domain}"
                fi
            else
                # 非交互式环境，默认保留默认线路
                log_info "非交互式环境，保留默认线路记录"
                main_delete_unified_non_default "$unified_subdomain"
            fi
        else
            log_info "未找到统一模式记录，直接配置单线路"
        fi
    else
        # 分离模式
        local default_subdomain
        default_subdomain=$(jq -r '.dns.sub_domains.default // "default"' "$CONFIG_FILE")
        
        log_info "分离模式，默认线路子域名: ${default_subdomain}.${domain}"
        
        if [[ -t 0 ]]; then
            echo ""
            echo -e "${YELLOW}请选择如何处理 DNS 记录：${NC}"
            echo "  1) 使用默认线路的子域名（推荐）"
            echo "  2) 使用新的子域名"
            echo "  3) 取消切换"
            echo ""
            read -r -p "请选择 (1/2/3, 默认 1): " choice
            choice=${choice:-1}
            
            case "$choice" in
                1)
                    # 删除所有分离模式记录
                    log_info "正在删除分离模式记录..."
                    main_delete
                    
                    # 使用默认线路子域名
                    # 更新配置
                    update_config_field ".dns.sub_domain" "$default_subdomain"
                    
                    # 创建单线路记录
                    log_info "正在创建单线路记录..."
                    main_single
                    ;;
                2)
                    echo ""
                    read -r -p "请输入新的子域名 [${default_subdomain}]: " new_sub
                    new_sub=${new_sub:-$default_subdomain}
                    
                    # 删除所有分离模式记录
                    log_info "正在删除分离模式记录..."
                    main_delete
                    
                    # 更新配置
                    # 更新配置
                    update_config_field ".dns.sub_domain" "$new_sub"
                    
                    # 创建单线路记录
                    log_info "正在创建单线路记录..."
                    main_single
                    ;;
                3)
                    log_info "已取消模式切换"
                    return 1
                    ;;
                *)
                    log_error "无效的选择"
                    return 1
                    ;;
            esac
        else
            # 非交互式环境，默认使用默认线路子域名
            log_info "非交互式环境，使用默认线路子域名"
            main_delete
            
            # 更新配置
            update_config_field ".dns.sub_domain" "$default_subdomain"
            
            main_single
        fi
    fi
}

# ==================== 模式切换检测（供 setup.sh 调用） ====================
# 【修复】必须在所有函数定义之后执行，避免 "command not found" 错误
if [[ -n "${DNSPOD_MODE_SWITCH:-}" ]]; then
    # 检测到模式切换请求，执行智能处理
    # 【修复】使用 :- 默认值防止 set -u 报 unbound variable 错误
    log_info "检测到模式切换请求: ${DNSPOD_FROM_MODE:-unknown} → ${DNSPOD_TO_MODE:-unknown}"
    handle_mode_switch "${DNSPOD_FROM_MODE:-}" "${DNSPOD_TO_MODE:-}" "${DNSPOD_STRATEGY:-smart}"
    exit $?
fi

# 执行主函数
if [[ "${MODE_TYPE}" = "delete" ]]; then
    # 删除分线路记录
    main_delete "${DELETE_LINES[@]}"
elif [[ "${MODE_TYPE}" = "delete_unified" ]]; then
    # 删除统一模式记录
    main_delete_unified "${UNIFIED_SUBDOMAIN}"
elif [[ "${MODE_TYPE}" = "delete_unified_non_default" ]]; then
    # 删除统一模式的非默认线路记录
    main_delete_unified_non_default "${UNIFIED_SUBDOMAIN}"
else
    # 更新模式（默认）
    if [[ "${MODE}" = "multi" ]]; then
        main_multi
    else
        main_single
    fi
fi
