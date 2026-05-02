#!/bin/bash
# ==============================================================================
# cfopt - DNSPod DNS 更新核心 (Core)
# Version: 0.1
# Description: 负责将优选 IP 同步至 DNSPod 记录，支持单线路及多运营商分流策略
# Usage: bash modules/dnspod-dns/core.sh
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 路径初始化与进程锁管理 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOCK_FILE="$ROOT_DIR/modules/dnspod-dns/.core.lock"
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "[ERROR] 检测到另一个 DNSPod 更新进程正在运行 (PID: $pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
}

acquire_lock

# ==================== 加载配置文件 ====================
CONFIG_FILE="$ROOT_DIR/conf/dnspod.conf"
LOG_DIR="$ROOT_DIR/logs/dnspod-dns"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/dnspod_$(date +%Y%m%d_%H%M%S).log"

# DNSPod IP 数据默认路径
DEFAULT_IP_DIR="$ROOT_DIR/assets/data/dnspod-dns"

# 日志函数
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误${NC}: 找不到配置文件 ${CONFIG_FILE}"
    echo ""
    echo "请先创建配置文件,参考示例: dnspod.conf"
    exit 1
fi

# 加载配置
source "$CONFIG_FILE"

# 检查启用状态
if [ "${ENABLED:-false}" != "true" ]; then
    log_msg "INFO" "DNSPod 模块当前处于禁用状态 (ENABLED=false)。"
    exit 0
fi

# ==================== IP 数据文件检测 (启动前校验) ====================
# 根据模式确定要检查的 IP 文件
IP_FILES_TO_CHECK=()
if [ "$MODE" = "single" ]; then
    IP_FILES_TO_CHECK+=("${IP_FILE:-$DEFAULT_IP_DIR/ip_list.txt}")
else
    # 多线路模式下，至少检查默认线路的文件
    IP_FILES_TO_CHECK+=("${IP_FILE_DEFAULT:-$DEFAULT_IP_DIR/ip_list_default.txt}")
fi

for ip_file in "${IP_FILES_TO_CHECK[@]}"; do
    if [ ! -f "$ip_file" ]; then
        log_msg "ERROR" "IP 文件不存在: $ip_file"
        exit 1
    fi
    
    # 有效性检测
    FIRST_LINE=$(head -n 1 "$ip_file")
    if [ -z "$FIRST_LINE" ] || [[ ! "$FIRST_LINE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_msg "ERROR" "IP 文件格式错误或包含无效数据 ($ip_file): ${FIRST_LINE:-空}"
        log_msg "WARN" "这可能是测速程序的临时 Bug，请重新运行测速。"
        exit 1
    fi
done
log_msg "INFO" "IP 数据检查通过"

log_msg "INFO" "配置文件已加载 ${CONFIG_FILE}"
echo ""

# 检查 jq 是否可用
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误${NC}: jq 未安装 (必需工具)"
    echo "请安装 jq: apt install jq 或 yum install jq"
    exit 1
fi

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
            if [ -n "$1" ] && [[ "$1" != --* ]]; then
                UNIFIED_SUBDOMAIN="$1"
                shift
            fi
            ;;
        --delete-unified-non-default)
            MODE_TYPE="delete_unified_non_default"
            shift
            if [ -n "$1" ] && [[ "$1" != --* ]]; then
                UNIFIED_SUBDOMAIN="$1"
                shift
            fi
            ;;
        *)
            echo -e "${RED}错误${NC}: 未知参数: $1"
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
if [ -n "$ISP_LINES" ]; then
    IFS=' ' read -ra ISP_LINES <<< "$ISP_LINES"
else
    echo -e "${RED}错误${NC}: 配置文件中缺少 ISP_LINES"
    exit 1
fi

# 检查工作模式
MODE=${MODE:-"single"}

# 检查必要配置
if [ -z "$DOMAIN" ] || [ -z "$SECRETID" ] || [ -z "$SECRETKEY" ]; then
    log_msg "ERROR" "配置文件中缺少必要的配置项 (DOMAIN, SECRETID, SECRETKEY)"
    exit 1
fi

# 设置默认值
TTL=${TTL:-600}
MAX_RETRIES=${MAX_RETRIES:-5}
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-10}
MAX_IPS_PER_RECORD=${MAX_IPS_PER_RECORD:-2}
SUBDOMAIN_STRATEGY=${SUBDOMAIN_STRATEGY:-"separate"} # separate 或 unified

# 确认工作模式为 multi
if [ "$MODE" = "multi" ]; then
    if [ "$SUBDOMAIN_STRATEGY" = "unified" ]; then
        expected_lines="默认 联通 移动 电信"
        missing_lines=()
        
        for line in $expected_lines; do
            if [[ ! " ${ISP_LINES[*]} " =~ " ${line} " ]]; then
                missing_lines+=("$line")
            fi
        done
        
        if [ ${#missing_lines[@]} -gt 0 ]; then
            log_msg "WARN" "检测到统一模式配置不完整，正在自动补全..."
            ISP_LINES=("默认" "联通" "移动" "电信")
            
            # 更新配置文件
            if grep -q '^ISP_LINES=' "$CONFIG_FILE"; then
                sed -i 's/^ISP_LINES=.*/ISP_LINES="默认 联通 移动 电信"/' "$CONFIG_FILE"
            else
                echo 'ISP_LINES="默认 联通 移动 电信"' >> "$CONFIG_FILE"
            fi
            log_msg "INFO" "已更新配置文件: ISP_LINES=\"默认 联通 移动 电信\""
        fi
    fi
fi

# 获取线路对应的子域名
get_subdomain_for_line() {
    local line="$1"
    
    # 如果配置了 SUBDOMAIN_STRATEGY,根据策略选择子域名
    if [ "$SUBDOMAIN_STRATEGY" = "unified" ]; then
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
            if [ -n "${SUB_DOMAIN_UNICOM}" ]; then
                echo "${SUB_DOMAIN_UNICOM}"
            else
                echo "${SUB_DOMAIN_DEFAULT:-unicom}"
            fi
            ;;
        "移动")
            # 如果 SUB_DOMAIN_MOBILE 未配置，使用 SUB_DOMAIN_DEFAULT
            if [ -n "${SUB_DOMAIN_MOBILE}" ]; then
                echo "${SUB_DOMAIN_MOBILE}"
            else
                echo "${SUB_DOMAIN_DEFAULT:-mobile}"
            fi
            ;;
        "电信")
            # 如果 SUB_DOMAIN_TELECOM 未配置，使用 SUB_DOMAIN_DEFAULT
            if [ -n "${SUB_DOMAIN_TELECOM}" ]; then
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
    
    # 根据线路名选择对应的 IP 文件
    case "$line_name" in
        "默认")
            ip_file="${IP_FILE_DEFAULT:-$DEFAULT_IP_DIR/default.txt}"
            ;;
        "联通")
            ip_file="${IP_FILE_UNICOM:-$DEFAULT_IP_DIR/unicom.txt}"
            ;;
        "移动")
            ip_file="${IP_FILE_MOBILE:-$DEFAULT_IP_DIR/mobile.txt}"
            ;;
        "电信")
            ip_file="${IP_FILE_TELECOM:-$DEFAULT_IP_DIR/telecom.txt}"
            ;;
        *)
            echo -e "${RED}错误${NC}: 未知的线路名称: ${line_name}"
            return 1
            ;;
    esac
    
    if [ ! -f "$ip_file" ]; then
        echo -e "${RED}错误${NC}: IP 文件不存在: ${ip_file}" >&2
        echo "   请创建文件或修改 dnspod.conf 中的配置" >&2
        return 1
    fi
    
    # 读取文件内容,支持两种格式:
    # 1. 每行一个 IP
    # 2. 逗号分隔的 IP
    local content=$(grep -v '^#' "$ip_file" | sed 's/#.*//g' | tr '\n' ',' | sed 's/,$//' | sed 's/^,//')
    
    if [ -z "$content" ]; then
        echo -e "${YELLOW}警告${NC}: IP 文件为空: ${ip_file}" >&2
        return 1
    fi
    
    # 限制 IP 数量
    if [ "$MAX_IPS_PER_RECORD" -gt 0 ]; then
        # 将 IP 转换为数组
        IFS=',' read -ra ip_array <<< "$content"
        local total_ips=${#ip_array[@]}
        
        # 如果超出限制,只取前 N 个
        if [ "$total_ips" -gt "$MAX_IPS_PER_RECORD" ]; then
            echo -e "${YELLOW}${line_name}线路 IP 文件包含 ${total_ips} 个 IP,超出限制 ${MAX_IPS_PER_RECORD} 个" >&2
            echo "   已自动截取前 ${MAX_IPS_PER_RECORD} 个 IP (避免超出套餐限制)" >&2
            
            # 取前 N 个 IP
            local limited_ips=""
            for ((i=0; i<MAX_IPS_PER_RECORD && i<total_ips; i++)); do
                if [ -z "$limited_ips" ]; then
                    limited_ips="${ip_array[$i]}"
                else
                    limited_ips="${limited_ips},${ip_array[$i]}"
                fi
            done
            echo "$limited_ips"
        else
            echo "$content"
        fi
    else
        # 不限制
        echo "$content"
    fi
    
    return 0
}

# 获取指定线路的 DNS 记录
get_record_by_line() {
    local line="$1"
    local subdomain=$(get_subdomain_for_line "$line")
    local payload="{\"Domain\":\"${DOMAIN}\",\"Subdomain\":\"${subdomain}\",\"RecordType\":\"A\",\"RecordLine\":\"${line}\",\"Limit\":100}"
    call_api "DescribeRecordList" "$payload"
}

# 修改指定线路的 DNS 记录
modify_record_by_line() {
    local record_id="$1"
    local value="$2"
    local line="$3"
    local subdomain=$(get_subdomain_for_line "$line")
    local payload="{\"Domain\":\"${DOMAIN}\",\"SubDomain\":\"${subdomain}\",\"RecordType\":\"A\",\"RecordLine\":\"${line}\",\"Value\":\"${value}\",\"TTL\":${TTL},\"RecordId\":${record_id}}"
    call_api "ModifyRecord" "$payload"
}

# 创建指定线路的 DNS 记录
create_record_by_line() {
    local value="$1"
    local line="$2"
    local subdomain=$(get_subdomain_for_line "$line")
    local payload="{\"Domain\":\"${DOMAIN}\",\"SubDomain\":\"${subdomain}\",\"RecordType\":\"A\",\"RecordLine\":\"${line}\",\"Value\":\"${value}\",\"TTL\":${TTL}}"
    call_api "CreateRecord" "$payload"
}

# 清屏
clear

# 显示配置摘要
echo -e "${CYAN}+--------------------------------------------------+"
if [ "$MODE" = "multi" ]; then
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 多线路${NC}"
    if [ "$SUBDOMAIN_STRATEGY" = "unified" ]; then
        echo -e " 域名: ${SUB_DOMAIN_UNIFIED:-dns}.${DOMAIN} (统一模式)"
    else
        echo -e " 域名: 分离模式 (各线路独立子域名)"
    fi
    echo -e " 线路: ${ISP_LINES[*]}"
else
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 单线路${NC}"
    echo -e " 域名: ${SUB_DOMAIN:-dns}.${DOMAIN}"
    IP_FILE=${IP_FILE_SINGLE:-"$DEFAULT_IP_DIR/default.txt"}
fi
echo -e " IP限制: ${MAX_IPS_PER_RECORD} 个/记录"
echo -e "${CYAN}+--------------------------------------------------+${NC}"
echo ""

# ==================== 腾讯云 API 签名 ====================
sha256_hex() {
    if command -v sha256sum &> /dev/null; then
        echo -n "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum &> /dev/null; then
        echo -n "$1" | shasum -a 256 | awk '{print $1}'
    else
        echo "错误: 未找到 sha256sum 或 shasum 命令" >&2
        exit 1
    fi
}

get_signature_key() {
    local key="$1"
    local date_stamp="$2"
    local service_name="$3"
    
    local k_date=$(echo -n "$date_stamp" | openssl dgst -sha256 -hmac "TC3${key}" -hex 2>/dev/null | awk '{print $NF}')
    local k_service=$(echo -n "$service_name" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_date}" -hex 2>/dev/null | awk '{print $NF}')
    local k_signing=$(echo -n "tc3_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_service}" -hex 2>/dev/null | awk '{print $NF}')
    
    echo "$k_signing"
}

generate_signature() {
    local action="$1"
    local payload="$2"
    
    local timestamp=$(date +%s)
    local date=$(date -u +"%Y-%m-%d")
    
    local http_method="POST"
    local canonical_uri="/"
    local canonical_querystring=""
    local content_type="application/json"
    
    local hashed_payload=$(sha256_hex "$payload")
    
    local canonical_headers="content-type:${content_type}
host:dnspod.tencentcloudapi.com
x-tc-action:$(echo "$action" | tr '[:upper:]' '[:lower:]')
"
    local signed_headers="content-type;host;x-tc-action"
    
    local canonical_request="${http_method}
${canonical_uri}
${canonical_querystring}
${canonical_headers}
${signed_headers}
${hashed_payload}"
    
    local hashed_canonical_request=$(sha256_hex "$canonical_request")
    
    local algorithm="TC3-HMAC-SHA256"
    local credential_scope="${date}/dnspod/tc3_request"
    local string_to_sign="${algorithm}
${timestamp}
${credential_scope}
${hashed_canonical_request}"
    
    local secret_key=$(get_signature_key "$SECRETKEY" "$date" "dnspod")
    local signature=$(echo -n "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${secret_key}" -hex 2>/dev/null | awk '{print $NF}')
    
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
    local max_retries=3
    local retry=0
    local result=""
    
    while [ $retry -lt $max_retries ]; do
        if [ $retry -gt 0 ]; then
            log_msg "WARN" "API 请求失败，正在重试第 $retry/$max_retries 次..."
            sleep 2
        fi
        
        # 生成签名头
        local -a headers_array=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                headers_array+=("$line")
            fi
        done <<< "$(generate_signature "$action" "$payload")"
        
        # 构建并执行 curl 命令 (使用数组避免 eval)
        local -a curl_args=("-s" "--connect-timeout" "10" "-X" "POST" "https://dnspod.tencentcloudapi.com")
        
        for header in "${headers_array[@]}"; do
            local key="${header%%:*}"
            local value="${header#*:}"
            if [ -n "$key" ] && [ -n "$value" ]; then
                curl_args+=("-H" "${key}:${value}")
            fi
        done
        
        curl_args+=("-d" "$payload")
        
        # 执行请求
        result=$(curl "${curl_args[@]}")
        
        # 简单的成功校验：如果返回了 JSON 且包含 Response 字段，则认为请求已发出
        if echo "$result" | grep -q "Response"; then
            echo "$result"
            return 0
        fi
        
        retry=$((retry + 1))
    done
    
    log_msg "ERROR" "API 调用最终失败: $action"
    echo "$result"
    return 1
}

# 获取 DNS 记录
get_record() {
    local payload="{\"Domain\":\"${DOMAIN}\",\"Subdomain\":\"${SUB_DOMAIN}\",\"RecordType\":\"A\",\"Limit\":100}"
    call_api "DescribeRecordList" "$payload"
}

# 修改 DNS 记录
modify_record() {
    local record_id="$1"
    local value="$2"
    local payload="{\"Domain\":\"${DOMAIN}\",\"SubDomain\":\"${SUB_DOMAIN}\",\"RecordType\":\"A\",\"RecordLine\":\"默认\",\"Value\":\"${value}\",\"TTL\":${TTL},\"RecordId\":${record_id}}"
    call_api "ModifyRecord" "$payload"
}

# 创建 DNS 记录
create_record() {
    local value="$1"
    local line="${2:-默认}"
    local payload="{\"Domain\":\"${DOMAIN}\",\"SubDomain\":\"${SUB_DOMAIN}\",\"RecordType\":\"A\",\"RecordLine\":\"${line}\",\"Value\":\"${value}\",\"TTL\":${TTL}}"
    call_api "CreateRecord" "$payload"
}

# 验证 IP 地址格式
validate_ip() {
    local ip="$1"
    
    # 检查是否为有效的 IPv4 地址格式
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        # 检查每个段是否在 0-255 范围内
        local i
        for i in 1 2 3 4; do
            if [ "${BASH_REMATCH[$i]}" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 从文件读取优选 IP (单线路通用)
get_cf_ip_from_file() {
    if [ ! -f "$IP_FILE" ]; then
        echo -e "${RED}错误${NC}: IP 文件不存在: ${IP_FILE}" >&2
        echo "   请创建文件或修改 dnspod.conf 中的配置" >&2
        return 1
    fi
    
    # 读取文件内容,支持两种格式:
    # 1. 每行一个 IP
    # 2. 逗号分隔的 IP
    local content=$(grep -v '^#' "$IP_FILE" | sed 's/#.*//g' | tr '\n' ',' | sed 's/,$//' | sed 's/^,//')
    
    if [ -z "$content" ]; then
        echo -e "${YELLOW}警告${NC}: IP 文件为空: ${IP_FILE}" >&2
        return 1
    fi
    
    # 限制 IP 数量
    if [ "$MAX_IPS_PER_RECORD" -gt 0 ]; then
        # 将 IP 转换为数组
        IFS=',' read -ra ip_array <<< "$content"
        local total_ips=${#ip_array[@]}
        
        # 如果超出限制,只取前 N 个
        if [ "$total_ips" -gt "$MAX_IPS_PER_RECORD" ]; then
            echo -e "${YELLOW}警告${NC}: IP 文件包含 ${total_ips} 个 IP,超出限制 ${MAX_IPS_PER_RECORD} 个" >&2
            echo "   已自动截取前 ${MAX_IPS_PER_RECORD} 个 IP (避免超出套餐限制)" >&2
            
            # 取前 N 个 IP
            local limited_ips=""
            for ((i=0; i<MAX_IPS_PER_RECORD && i<total_ips; i++)); do
                if [ -z "$limited_ips" ]; then
                    limited_ips="${ip_array[$i]}"
                else
                    limited_ips="${limited_ips},${ip_array[$i]}"
                fi
            done
            echo "$limited_ips"
        else
            echo "$content"
        fi
    else
        # 不限制
        echo "$content"
    fi
    
    return 0
}

# 单线路模式主函数
main_single() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 日志头部
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "DNSPod DNS 更新器 - 单线路模式"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "执行时间: ${current_time}"
    log_msg "INFO" "域名:     ${SUB_DOMAIN}.${DOMAIN}"
    log_msg "INFO" "IP限制:   ${MAX_IPS_PER_RECORD} 个/记录"
    log_msg "INFO" "================================================================"
    log_msg "INFO" ""
    
    # 获取 DNS 记录
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "步骤 1: 获取 DNS 记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local record_response=$(get_record)
    
    # 使用 jq 解析 JSON
    local -a all_record_ids=()
    local -a all_current_values=()
    local -a all_line_ids=()
    local -a record_ids=()
    local -a current_values=()
    local record_count=0
    
    # 检查是否有错误
    local error_code=$(echo "$record_response" | jq -r '.Response.Error.Code' 2>/dev/null)
    
    # ResourceNotFound.NoDataOfRecord 表示记录不存在，这是正常情况
    if [ -n "$error_code" ] && [ "$error_code" != "null" ] && [ "$error_code" != "ResourceNotFound.NoDataOfRecord" ]; then
        local error_msg=$(echo "$record_response" | jq -r '.Response.Error.Message' 2>/dev/null)
        log_msg "ERROR" "[ERROR] API 错误: ${error_code} - ${error_msg}"
        exit 1
    fi
    
    # 获取记录数量
    local count=$(echo "$record_response" | jq '.Response.RecordList | length' 2>/dev/null)
    
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        log_msg "INFO" "状态: 未找到 DNS 记录,将自动创建"
    else
        # 提取所有记录信息
        for ((i=0; i<count; i++)); do
            local record_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)
            local value=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)
            local line_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].LineId" 2>/dev/null)
            
            all_record_ids+=("$record_id")
            all_current_values+=("$value")
            all_line_ids+=("$line_id")
        done
        
        # 筛选"默认"线路的记录(LineId="0"表示默认线路)
        for i in "${!all_record_ids[@]}"; do
            if [ "${all_line_ids[$i]}" = "0" ]; then
                record_ids+=("${all_record_ids[$i]}")
                current_values+=("${all_current_values[$i]}")
            fi
        done
        
        record_count=${#record_ids[@]}
        
        if [ $record_count -eq 0 ]; then
            log_msg "INFO" "状态: 未找到 DNS 记录,将自动创建"
        else
            log_msg "INFO" "状态: 找到 ${record_count} 条记录"
            for i in "${!record_ids[@]}"; do
                log_msg "INFO" "  [$((i+1))] RecordID=${record_ids[$i]}, IP=${current_values[$i]}"
            done
        fi
        log_msg "INFO" ""
    fi
    
    # 从文件获取优选 IP
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "步骤 2: 读取优选 IP"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "IP文件: ${IP_FILE}"
    local cf_ip=$(get_cf_ip_from_file)
    
    if [ $? -ne 0 ] || [ -z "$cf_ip" ]; then
        log_msg "ERROR" "无法从文件读取IP,请检查IP文件是否存在且格式正确"
        exit 1
    fi
    
    # 解析多个 IP 地址
    local -a ip_addresses=()
    local -a invalid_ips=()
    IFS=',' read -ra raw_ips <<< "$cf_ip"
    for ip in "${raw_ips[@]}"; do
        # 去除首尾空格和空白字符
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$ip" ]; then
            # 验证 IP 格式
            if validate_ip "$ip"; then
                ip_addresses+=("$ip")
            else
                invalid_ips+=("$ip")
            fi
        fi
    done
    
    # 显示无效 IP 警告
    if [ ${#invalid_ips[@]} -gt 0 ]; then
        log_msg "WARN" "[WARN] 发现 ${#invalid_ips[@]} 个无效 IP，已跳过:"
        for invalid_ip in "${invalid_ips[@]}"; do
            log_msg "WARN" "    - ${invalid_ip}"
        done
    fi
    
    if [ ${#ip_addresses[@]} -eq 0 ]; then
        log_msg "ERROR" "[ERROR] 未解析到有效 IP"
        exit 1
    fi
    
    log_msg "INFO" "状态: 获取到 ${#ip_addresses[@]} 个 IP"
    for i in "${!ip_addresses[@]}"; do
        log_msg "INFO" "  [$((i+1))] ${ip_addresses[$i]}"
    done
    log_msg "INFO" ""
    
    # 更新或创建 DNS 记录
    local updated_count=0
    local skipped_count=0
    local created_count=0
    
    for ((i=0; i<${#ip_addresses[@]}; i++)); do
        local new_ip="${ip_addresses[$i]}"
        
        if [ $i -lt $record_count ]; then
            # 更新现有记录
            local record_id="${record_ids[$i]}"
            local current_value="${current_values[$i]}"
            
            log_msg "INFO" "处理记录 $((i+1))/${#ip_addresses[@]}"
            log_msg "INFO" "  Record ID: ${record_id}"
            log_msg "INFO" "  当前IP:    ${current_value}"
            log_msg "INFO" "  目标IP:    ${new_ip}"
            
            # 检查 IP 是否变化 (去除空格后比较)
            local clean_current=$(echo "$current_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local clean_new=$(echo "$new_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ "$clean_current" = "$clean_new" ]; then
                log_msg "INFO" "  [OK] IP未变化,跳过"
                skipped_count=$((skipped_count + 1))
            else
                # 需要更新
                log_msg "INFO" "  ⟳ 正在更新..."
                
                local modify_response=$(modify_record "$record_id" "$new_ip")
                
                # 检查结果
                if echo "$modify_response" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                    local error_code=$(echo "$modify_response" | jq -r '.Response.Error.Code' 2>/dev/null)
                    local error_msg=$(echo "$modify_response" | jq -r '.Response.Error.Message' 2>/dev/null)
                    log_msg "ERROR" "  [ERROR] 更新失败: ${error_code} - ${error_msg}"
                else
                    log_msg "INFO" "  [OK] 更新成功"
                    updated_count=$((updated_count + 1))
                fi
            fi
        else
            # 自动新建记录
            log_msg "INFO" "处理记录 $((i+1))/${#ip_addresses[@]}"
            log_msg "INFO" "  ➕ 自动新建记录"
            log_msg "INFO" "  目标IP:    ${new_ip}"
            log_msg "INFO" "  ⟳ 正在创建..."
            
            local create_response=$(create_record "$new_ip")
            
            # 检查结果
            if echo "$create_response" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                local error_code=$(echo "$create_response" | jq -r '.Response.Error.Code' 2>/dev/null)
                local error_msg=$(echo "$create_response" | jq -r '.Response.Error.Message' 2>/dev/null)
                log_msg "ERROR" "  [ERROR] 创建失败: ${error_code} - ${error_msg}"
            else
                log_msg "INFO" "  [OK] 创建成功"
                created_count=$((created_count + 1))
            fi
        fi
    done
    
    # 输出总结
    log_msg "INFO" ""
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "更新结果汇总"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "  [OK] 成功: ${updated_count}"
    log_msg "INFO" "  [SKIP] 跳过: ${skipped_count}"
    log_msg "INFO" "  ➕ 新建: ${created_count}"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 多线路模式主函数
main_multi() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 日志头部
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "DNSPod DNS 更新器 - 多线路模式"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "执行时间: ${current_time}"
    log_msg "INFO" "域名:     ${DOMAIN}"
    log_msg "INFO" "运营商线路: ${ISP_LINES[*]}"
    log_msg "INFO" "IP限制:   ${MAX_IPS_PER_RECORD} 个/记录"
    log_msg "INFO" "================================================================"
    log_msg "INFO" ""
    
    # 遍历每个运营商线路
    local total_updated=0
    local total_skipped=0
    local total_failed=0
    local total_created=0
    local processed_lines=0
    
    for line in "${ISP_LINES[@]}"; do
        log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_msg "INFO" "处理线路: ${line}"
        log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 从文件获取该线路的优选 IP
        log_msg "INFO" "步骤 1: 读取优选 IP"
        local cf_ip=$(get_cf_ip_from_file_by_line "$line")
        
        if [ $? -ne 0 ] || [ -z "$cf_ip" ]; then
            log_msg "ERROR" "无法从文件读取IP,请检查IP文件是否存在且格式正确"
            continue
        fi
        
        # 解析多个 IP 地址
        local -a ip_addresses=()
        local -a invalid_ips=()
        IFS=',' read -ra raw_ips <<< "$cf_ip"
        for ip in "${raw_ips[@]}"; do
            ip=$(echo "$ip" | tr -d ' \r')
            if [ -n "$ip" ]; then
                # 验证 IP 格式
                if validate_ip "$ip"; then
                    ip_addresses+=("$ip")
                else
                    invalid_ips+=("$ip")
                fi
            fi
        done
        
        # 显示无效 IP 警告
        if [ ${#invalid_ips[@]} -gt 0 ]; then
            log_msg "WARN" "[WARN] 发现 ${#invalid_ips[@]} 个无效 IP，已跳过:"
            for invalid_ip in "${invalid_ips[@]}"; do
                log_msg "WARN" "    - ${invalid_ip}"
            done
        fi
        
        if [ ${#ip_addresses[@]} -eq 0 ]; then
            log_msg "ERROR" "[ERROR] 未解析到有效 IP"
            continue
        fi
        
        log_msg "INFO" "状态: 获取到 ${#ip_addresses[@]} 个 IP"
        for i in "${!ip_addresses[@]}"; do
            log_msg "INFO" "  [$((i+1))] ${ip_addresses[$i]}"
        done
        
        # 获取该线路的 DNS 记录
        log_msg "INFO" "步骤 2: 获取 DNS 记录"
        local record_response=$(get_record_by_line "$line")
        
        # 使用 jq 解析 JSON
        local -a record_ids=()
        local -a current_values=()
        local record_count=0
        
        # 检查是否有错误
        local error_code=$(echo "$record_response" | jq -r '.Response.Error.Code' 2>/dev/null)
        
        # ResourceNotFound.NoDataOfRecord 表示记录不存在，这是正常情况
        if [ -n "$error_code" ] && [ "$error_code" != "null" ] && [ "$error_code" != "ResourceNotFound.NoDataOfRecord" ]; then
            local error_msg=$(echo "$record_response" | jq -r '.Response.Error.Message' 2>/dev/null)
            log_msg "ERROR" "[ERROR] API 错误: ${error_code} - ${error_msg}"
            continue
        fi
        
        # 获取记录数量
        local count=$(echo "$record_response" | jq '.Response.RecordList | length' 2>/dev/null)
        
        if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
            log_msg "INFO" "状态: 该线路无记录,将自动创建"
        else
            # 提取所有记录信息
            for ((i=0; i<count; i++)); do
                local record_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)
                local value=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)
                
                record_ids+=("$record_id")
                current_values+=("$value")
            done
            
            record_count=${#record_ids[@]}
            
            log_msg "INFO" "状态: 找到 ${record_count} 条记录"
            for i in "${!record_ids[@]}"; do
                log_msg "INFO" "  [$((i+1))] RecordID=${record_ids[$i]}, IP=${current_values[$i]}"
            done
        fi
        log_msg "INFO" ""
        
        # 确定要使用的 IP (循环使用可用的 IP)
        log_msg "INFO" "步骤 3: 更新/创建 DNS 记录"
        local updated=0
        local skipped=0
        local failed=0
        local created=0
        
        for ((i=0; i<${#ip_addresses[@]}; i++)); do
            # 循环使用 IP 地址
            local ip_index=$((i % ${#ip_addresses[@]}))
            local new_ip="${ip_addresses[$ip_index]}"
            
            # 获取当前线路的子域名
            local current_subdomain=$(get_subdomain_for_line "$line")
            local full_domain="${current_subdomain}.${DOMAIN}"
            
            if [ $i -lt $record_count ]; then
                # 更新现有记录
                local record_id="${record_ids[$i]}"
                local current_value="${current_values[$i]}"
                
                log_msg "INFO" "处理记录 $((i+1))/${#ip_addresses[@]}"
                log_msg "INFO" "  RecordID: ${record_id}"
                log_msg "INFO" "  当前IP:   ${current_value}"
                log_msg "INFO" "  目标IP:   ${new_ip}"
                
                # 检查 IP 是否变化 (去除空格后比较)
                local clean_current=$(echo "$current_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                local clean_new=$(echo "$new_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                if [ "$clean_current" = "$clean_new" ]; then
                    log_msg "INFO" "  [OK] IP未变化,跳过"
                    skipped=$((skipped + 1))
                else
                    # 需要更新
                    log_msg "INFO" "  ⟳ 正在更新..."
                    local modify_response=$(modify_record_by_line "$record_id" "$new_ip" "$line")
                    
                    # 检查结果
                    if echo "$modify_response" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                        local error_code=$(echo "$modify_response" | jq -r '.Response.Error.Code' 2>/dev/null)
                        local error_msg=$(echo "$modify_response" | jq -r '.Response.Error.Message' 2>/dev/null)
                        log_msg "ERROR" "  [ERROR] 更新失败: ${error_code} - ${error_msg}"
                        failed=$((failed + 1))
                    else
                        log_msg "INFO" "  [OK] 更新成功"
                        updated=$((updated + 1))
                    fi
                fi
            else
                # 自动新建记录
                log_msg "INFO" "处理记录 $((i+1))/${#ip_addresses[@]}"
                log_msg "INFO" "  ➕ 自动新建记录"
                log_msg "INFO" "  目标IP:   ${new_ip}"
                log_msg "INFO" "  ⟳ 正在创建..."
                
                local create_response=$(create_record_by_line "$new_ip" "$line")
                
                # 检查结果
                if echo "$create_response" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
                    local error_code=$(echo "$create_response" | jq -r '.Response.Error.Code' 2>/dev/null)
                    local error_msg=$(echo "$create_response" | jq -r '.Response.Error.Message' 2>/dev/null)
                    log_msg "ERROR" "  [ERROR] 创建失败: ${error_code} - ${error_msg}"
                    failed=$((failed + 1))
                else
                    log_msg "INFO" "  [OK] 创建成功"
                    created=$((created + 1))
                fi
            fi
        done
        
        log_msg "INFO" ""
        log_msg "INFO" "线路完成统计:"
        log_msg "INFO" "  [OK] 成功: ${updated}"
        log_msg "ERROR" "  [ERROR] 失败: ${failed}"
        log_msg "INFO" "  [SKIP] 跳过: ${skipped}"
        log_msg "INFO" "  ➕ 新建: ${created}"
        log_msg "INFO" ""
        
        total_updated=$((total_updated + updated))
        total_skipped=$((total_skipped + skipped))
        total_failed=$((total_failed + failed))
        total_created=$((total_created + created))
        processed_lines=$((processed_lines + 1))
    done
    
    # 总结
    log_msg "INFO" "================================================================"
    log_msg "INFO" "更新结果汇总"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "处理线路: ${processed_lines}"
    log_msg "INFO" "更新成功: ${total_updated}"
    log_msg "INFO" "跳过:     ${total_skipped}"
    log_msg "INFO" "失败:     ${total_failed}"
    log_msg "INFO" "新建:     ${total_created}"
    log_msg "INFO" "================================================================"
}

# 删除模式主函数（单线路）
main_delete() {
    local lines_to_delete=("$@")
    
    # 如果没有指定线路，使用配置文件中的所有线路
    if [ ${#lines_to_delete[@]} -eq 0 ]; then
        if [ "$MODE" = "multi" ] && [ -n "${ISP_LINES[*]}" ]; then
            lines_to_delete=("${ISP_LINES[@]}")
        elif [ -n "$SUB_DOMAIN" ]; then
            lines_to_delete=("默认")
        else
            log_msg "ERROR" "未指定要删除的线路"
            exit 1
        fi
    fi
    
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "DNSPod DNS 记录删除器"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "域名: ${DOMAIN}"
    log_msg "INFO" "线路: ${lines_to_delete[*]}"
    log_msg "INFO" "================================================================"
    log_msg "INFO" ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "预检：查询将要删除的记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a all_record_ids=()
    local -a all_subdomains=()
    local -a all_values=()
    local total_found=0
    
    for line in "${lines_to_delete[@]}"; do
        local subdomain=""
        if [ "$MODE" = "multi" ]; then
            # 使用分离模式的子域名（忽略当前策略）
            subdomain=$(get_separate_subdomain_for_line "$line")
        else
            subdomain="${SUB_DOMAIN:-dns}"
        fi
        
        # 查询记录（只按子域名查询，不限制线路）
        local payload="{\"Domain\":\"${DOMAIN}\",\"Subdomain\":\"${subdomain}\",\"RecordType\":\"A\",\"Limit\":100}"
        local record_response=$(call_api "DescribeRecordList" "$payload")
        
        # 检查是否有错误
        local error_code=$(echo "$record_response" | jq -r '.Response.Error.Code' 2>/dev/null)
        
        if [ -n "$error_code" ] && [ "$error_code" != "null" ] && [ "$error_code" != "ResourceNotFound.NoDataOfRecord" ]; then
            local error_msg=$(echo "$record_response" | jq -r '.Response.Error.Message' 2>/dev/null)
            log_msg "ERROR" "[ERROR] 查询失败: ${line} - ${error_code}"
            continue
        fi
        
        # 获取记录数量
        local count=$(echo "$record_response" | jq '.Response.RecordList | length' 2>/dev/null)
        
        if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
            log_msg "INFO" "  [SKIP] ${subdomain}.${DOMAIN} - 无记录"
            continue
        fi
        
        # 收集所有记录信息
        for ((i=0; i<count; i++)); do
            local record_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)
            local value=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)
            
            all_record_ids+=("$record_id")
            all_subdomains+=("${subdomain}.${DOMAIN}")
            all_values+=("$value")
            total_found=$((total_found + 1))
            
            log_msg "INFO" "  [${total_found}] ${subdomain}.${DOMAIN} → ${value} (ID: ${record_id})"
        done
    done
    
    log_msg "INFO" ""
    
    if [ $total_found -eq 0 ]; then
        log_msg "WARN" "[INFO] 未找到任何记录，无需删除"
        return 0
    fi
    
    log_msg "INFO" "[OK] 共找到 ${total_found} 条记录"
    log_msg "INFO" ""
    
    # ===== 删除阶段 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "开始删除记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local subdomain="${all_subdomains[$i]}"
        local value="${all_values[$i]}"
        
        log_msg "INFO" ""
        log_msg "INFO" "  记录 $((i+1))/${total_found}:"
        log_msg "INFO" "    子域名:   ${subdomain}"
        log_msg "INFO" "    RecordID: ${record_id}"
        log_msg "INFO" "    IP:       ${value}"
        log_msg "INFO" "    ⟳ 正在删除..."
        
        local delete_response=$(delete_record_by_line "$record_id")
        
        # 检查结果
        if echo "$delete_response" | jq -r '.Response.Error' 2>/dev/null | grep -q 'Code'; then
            local error_code=$(echo "$delete_response" | jq -r '.Response.Error.Code' 2>/dev/null)
            local error_msg=$(echo "$delete_response" | jq -r '.Response.Error.Message' 2>/dev/null)
            log_msg "ERROR" "    [ERROR] 删除失败: ${error_code} - ${error_msg}"
            total_failed=$((total_failed + 1))
        else
            log_msg "INFO" "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        fi
    done
    
    # 总结
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "删除结果汇总"
    log_msg "INFO" "================================================================"
    log_msg "INFO" " [OK] 成功: ${total_deleted}"
    log_msg "ERROR" " [ERROR] 失败: ${total_failed}"
    log_msg "INFO" "================================================================"
}

# 删除统一模式记录的主函数
main_delete_unified() {
    local unified_subdomain="${1:-dns}"
    
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "DNSPod DNS 记录删除器 - 统一模式"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "域名: ${DOMAIN}"
    log_msg "INFO" "子域名: ${unified_subdomain}.${DOMAIN}"
    log_msg "INFO" "================================================================"
    log_msg "INFO" ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "预检：查询统一模式的记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a all_record_ids=()
    local -a all_lines=()
    local -a all_values=()
    local total_found=0
    local -A seen_records=()  # 用于去重
    
    # 只需要查询一次，因为统一模式下所有线路使用同一个子域名
    # 查询记录（按子域名查询，不限制线路）
    local payload="{\"Domain\":\"${DOMAIN}\",\"Subdomain\":\"${unified_subdomain}\",\"RecordType\":\"A\",\"Limit\":100}"
    local record_response=$(call_api "DescribeRecordList" "$payload")
    
    # 检查是否有错误
    local error_code=$(echo "$record_response" | jq -r '.Response.Error.Code' 2>/dev/null)
    
    if [ -n "$error_code" ] && [ "$error_code" != "null" ] && [ "$error_code" != "ResourceNotFound.NoDataOfRecord" ]; then
        local error_msg=$(echo "$record_response" | jq -r '.Response.Error.Message' 2>/dev/null)
        log_msg "ERROR" "[ERROR] 查询失败: ${error_code}"
        return 1
    fi
    
    # 获取记录数量
    local count=$(echo "$record_response" | jq '.Response.RecordList | length' 2>/dev/null)
    
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        log_msg "WARN" "[INFO] 未找到任何记录"
        return 0
    fi
    
    # 收集所有记录信息（自动去重）
    for ((i=0; i<count; i++)); do
        local record_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)
        local value=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)
        local record_line=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Line" 2>/dev/null)
        
        # 使用 RecordID 作为唯一标识进行去重
        if [ -z "${seen_records[$record_id]+x}" ]; then
            seen_records[$record_id]=1
            all_record_ids+=("$record_id")
            all_lines+=("$record_line")
            all_values+=("$value")
            total_found=$((total_found + 1))
            
            log_msg "INFO" "  [${total_found}] ${unified_subdomain}.${DOMAIN} (${record_line}) → ${value} (ID: ${record_id})"
        fi
    done
    
    log_msg "INFO" ""
    
    if [ $total_found -eq 0 ]; then
        log_msg "WARN" "[INFO] 未找到任何记录，无需删除"
        return 0
    fi
    
    log_msg "INFO" "[OK] 共找到 ${total_found} 条记录"
    log_msg "INFO" ""
    
    # ===== 删除阶段 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "开始删除记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local line_name="${all_lines[$i]}"
        local value="${all_values[$i]}"
        
        log_msg "INFO" ""
        log_msg "INFO" "  记录 $((i+1))/${total_found}:"
        log_msg "INFO" "    子域名:   ${unified_subdomain}.${DOMAIN}"
        log_msg "INFO" "    线路:     ${line_name}"
        log_msg "INFO" "    RecordID: ${record_id}"
        log_msg "INFO" "    IP:       ${value}"
        log_msg "INFO" "    ⟳ 正在删除..."
        
        local delete_response=$(delete_record_by_line "$record_id")
        local delete_error=$(echo "$delete_response" | jq -r '.Response.Error.Code' 2>/dev/null)
        
        if [ -z "$delete_error" ] || [ "$delete_error" = "null" ]; then
            log_msg "INFO" "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        else
            local delete_msg=$(echo "$delete_response" | jq -r '.Response.Error.Message' 2>/dev/null)
            log_msg "ERROR" "    [ERROR] 删除失败: ${delete_error} - ${delete_msg}"
            total_failed=$((total_failed + 1))
        fi
    done
    
    # 总结
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "删除结果汇总"
    log_msg "INFO" "================================================================"
    log_msg "INFO" " [OK] 成功: ${total_deleted}"
    log_msg "ERROR" " [ERROR] 失败: ${total_failed}"
    log_msg "INFO" "================================================================"
}

# 删除统一模式非默认线路记录的主函数（保留默认线路）
main_delete_unified_non_default() {
    local unified_subdomain="${1:-dns}"
    
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "DNSPod DNS 记录删除器 - 统一模式（非默认线路）"
    log_msg "INFO" "================================================================"
    log_msg "INFO" "域名: ${DOMAIN}"
    log_msg "INFO" "子域名: ${unified_subdomain}.${DOMAIN}"
    log_msg "INFO" "说明: 删除联通、移动、电信线路，保留默认线路"
    log_msg "INFO" "================================================================"
    log_msg "INFO" ""
    
    # ===== 预检阶段：查询所有将要删除的记录 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "预检：查询统一模式的非默认线路记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
    local -a all_record_ids=()
    local -a all_lines=()
    local -a all_values=()
    local total_found=0
    local -A seen_records=()  # 用于去重
        
    # 只需要查询一次，因为统一模式下所有线路使用同一个子域名
    # 查询记录（按子域名查询，不限制线路）
    local payload="{\"Domain\":\"${DOMAIN}\",\"Subdomain\":\"${unified_subdomain}\",\"RecordType\":\"A\",\"Limit\":100}"
    local record_response=$(call_api "DescribeRecordList" "$payload")
        
    # 检查是否有错误
    local error_code=$(echo "$record_response" | jq -r '.Response.Error.Code' 2>/dev/null)
        
    if [ -n "$error_code" ] && [ "$error_code" != "null" ] && [ "$error_code" != "ResourceNotFound.NoDataOfRecord" ]; then
        local error_msg=$(echo "$record_response" | jq -r '.Response.Error.Message' 2>/dev/null)
        log_msg "ERROR" "[ERROR] 查询失败: ${error_code}"
        return 1
    fi
        
    # 获取记录数量
    local count=$(echo "$record_response" | jq '.Response.RecordList | length' 2>/dev/null)
        
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        log_msg "WARN" "[INFO] 未找到任何记录"
        return 0
    fi
        
    # 收集所有非默认线路的记录信息（自动去重）
    for ((i=0; i<count; i++)); do
        local record_id=$(echo "$record_response" | jq -r ".Response.RecordList[$i].RecordId" 2>/dev/null)
        local value=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Value" 2>/dev/null)
        local record_line=$(echo "$record_response" | jq -r ".Response.RecordList[$i].Line" 2>/dev/null)
            
        # 跳过默认线路
        if [ "$record_line" = "默认" ]; then
            continue
        fi
            
        # 使用 RecordID 作为唯一标识进行去重
        if [ -z "${seen_records[$record_id]+x}" ]; then
            seen_records[$record_id]=1
            all_record_ids+=("$record_id")
            all_lines+=("$record_line")
            all_values+=("$value")
            total_found=$((total_found + 1))
                
            log_msg "INFO" "  [${total_found}] ${unified_subdomain}.${DOMAIN} (${record_line}) → ${value} (ID: ${record_id})"
        fi
    done
        
    # 显示保留的默认线路提示
    log_msg "INFO" "  [OK] 默认线路 - 保留"
    
    log_msg "INFO" ""
    
    if [ $total_found -eq 0 ]; then
        log_msg "WARN" "[INFO] 未找到任何非默认线路记录，无需删除"
        return 0
    fi
    
    log_msg "INFO" "[OK] 共找到 ${total_found} 条非默认线路记录"
    log_msg "INFO" ""
    
    # ===== 删除阶段 =====
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "INFO" "开始删除非默认线路记录"
    log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_deleted=0
    local total_failed=0
    
    for ((i=0; i<total_found; i++)); do
        local record_id="${all_record_ids[$i]}"
        local line_name="${all_lines[$i]}"
        local value="${all_values[$i]}"
        
        log_msg "INFO" ""
        log_msg "INFO" "  记录 $((i+1))/${total_found}:"
        log_msg "INFO" "    子域名:   ${unified_subdomain}.${DOMAIN}"
        log_msg "INFO" "    线路:     ${line_name}"
        log_msg "INFO" "    RecordID: ${record_id}"
        log_msg "INFO" "    IP:       ${value}"
        log_msg "INFO" "    ⟳ 正在删除..."
        
        local delete_response=$(delete_record_by_line "$record_id")
        local delete_error=$(echo "$delete_response" | jq -r '.Response.Error.Code' 2>/dev/null)
        
        if [ -z "$delete_error" ] || [ "$delete_error" = "null" ]; then
            log_msg "INFO" "    [OK] 删除成功"
            total_deleted=$((total_deleted + 1))
        else
            local delete_msg=$(echo "$delete_response" | jq -r '.Response.Error.Message' 2>/dev/null)
            log_msg "ERROR" "    [ERROR] 删除失败: ${delete_error} - ${delete_msg}"
            total_failed=$((total_failed + 1))
        fi
    done
    
    # 总结
    log_msg "INFO" ""
    log_msg "INFO" "================================================================"
    log_msg "INFO" "删除结果汇总"
    log_msg "INFO" "================================================================"
    log_msg "INFO" " [OK] 成功: ${total_deleted}"
    log_msg "ERROR" " [ERROR] 失败: ${total_failed}"
    log_msg "INFO" " 保留: 默认线路记录"
    log_msg "INFO" "================================================================"
}


# 执行主函数
if [ "$MODE_TYPE" = "delete" ]; then
    # 删除分线路记录
    main_delete "${DELETE_LINES[@]}"
elif [ "$MODE_TYPE" = "delete_unified" ]; then
    # 删除统一模式记录
    main_delete_unified "$UNIFIED_SUBDOMAIN"
elif [ "$MODE_TYPE" = "delete_unified_non_default" ]; then
    # 删除统一模式的非默认线路记录
    main_delete_unified_non_default "$UNIFIED_SUBDOMAIN"
else
    # 更新模式（默认）
    if [ "$MODE" = "multi" ]; then
        main_multi
    else
        main_single
    fi
fi
