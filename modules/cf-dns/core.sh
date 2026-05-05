#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - Cloudflare DNS 更新核心 (Core)
# Version: 0.1
# Description: 负责将优选 IP 同步至 Cloudflare DNS 记录，支持有效性校验与日志记录
# Usage: bash modules/cf-dns/core.sh
# ==============================================================================
# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 路径初始化与进程锁管理 ====================
# 动态获取项目根目录，确保在不同调用环境下路径正确
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 配置加载逻辑（支持多域名） ====================
# 优先级：
# 1. 命令行参数指定配置文件: bash core.sh /path/to/config.json
# 2. 环境变量指定域名: CF_DNS_DOMAIN=example.com bash core.sh
# 3. 默认：需要传递配置文件路径

if [[ $# -gt 0 ]] && [[ -f "$1" ]]; then
    # 方式 1: 命令行参数指定配置文件
    CONFIG_FILE="$1"
    DOMAIN_NAME=$(basename "$CONFIG_FILE" .json)
elif [[ -n "${CF_DNS_DOMAIN:-}" ]]; then
    # 方式 2: 环境变量指定域名
    DOMAIN_NAME="${CF_DNS_DOMAIN}"
    CONFIG_FILE="$ROOT_DIR/conf/cf-dns/${DOMAIN_NAME}.json"
else
    # 方式 3: 错误，必须指定配置文件
    echo -e "${RED}错误${NC}: 未指定配置文件"
    echo "用法:"
    echo "  1. bash core.sh /path/to/config.json"
    echo "  2. CF_DNS_DOMAIN=example.com bash core.sh"
    exit 1
fi

# 根据域名生成独立的锁文件
LOCK_FILE="$ROOT_DIR/modules/cf-dns/.core.lock"
acquire_lock() {
    local domain_safe
    domain_safe=$(echo "${DOMAIN_NAME:-default}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    LOCK_FILE="$ROOT_DIR/modules/cf-dns/.core_${domain_safe}.lock"
    
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "[ERROR] 检测到另一个 CF-DNS 更新进程正在运行 (PID: $pid, Domain: ${DOMAIN_NAME:-default})"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
}

acquire_lock

# DNS 记录名称说明:
#   record_name 配置说明:
#   - 如果最终域名是 dns.example.com，填 dns
#   - 如果最终域名是 cf.example.com，填 cf
#   - 如果最终域名是 example.com（根域名），填 @

# 设置日志目录
LOG_DIR_DEFAULT="$ROOT_DIR/logs/cf-dns"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cfdns_$(date +%Y%m%d_%H%M%S).log"

# 日志函数
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] ${message}" | tee -a "$LOG_FILE"
}

# ==================== 加载 JSON 配置 ====================
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误${NC}: 找不到配置文件 ${CONFIG_FILE}"
    echo ""
    
    # 检测是否为交互式环境（有终端输入）
    if [ -t 0 ]; then
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo -e " ${YELLOW}CF-DNS 模块首次配置向导"
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        echo -e "${YELLOW}[INFO] 检测到您尚未配置 CF-DNS 模块${NC}"
        echo ""
        echo -e "${GREEN}我们将帮助您完成以下配置：${NC}"
        echo "  ✓ Cloudflare API Token（用于管理 DNS 记录）"
        echo "  ✓ Zone ID（您的域名区域 ID）"
        echo "  ✓ DNS 记录名称和域名"
        echo "  ✓ IP 数据源路径"
        echo ""
        read -r -p "是否立即启动配置向导？[Y/n] (默认: Y): " choice
        choice=${choice:-Y}
        
        if [[ "$choice" =~ ^[Yy]$ ]] || [[ -z "$choice" ]]; then
            echo ""
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            echo -e "${GREEN}正在启动快速配置向导...${NC}"
            echo -e "${CYAN}+------------------------------------------------------------+${NC}"
            echo ""
            exec bash "$ROOT_DIR/modules/cf-dns/setup.sh"
        else
            echo -e "${YELLOW}已取消操作${NC}"
            exit 1
        fi
    else
        # 非交互式环境（定时任务等），直接退出
        echo -e "${YELLOW}[WARN] 请先运行配置向导创建配置文件${NC}"
        echo -e "${YELLOW}[WARN] 命令: bash $ROOT_DIR/modules/cf-dns/setup.sh${NC}"
        exit 1
    fi
fi

# 从 JSON 读取配置并导出为环境变量
export ENABLED=$(jq -r '.enabled // false' "$CONFIG_FILE")
export CF_API_TOKEN=$(jq -r '.api.token // empty' "$CONFIG_FILE")
export CF_ZONE_ID=$(jq -r '.api.zone_id // empty' "$CONFIG_FILE")
export CF_DNS_NAME=$(jq -r '.dns.record_name // empty' "$CONFIG_FILE")
export CF_DOMAIN=$(jq -r '.dns.domain // empty' "$CONFIG_FILE")
export IP_FILE=$(jq -r '.ip_source.file_path // empty' "$CONFIG_FILE")
export MAX_IPS_PER_RECORD=$(jq -r '.dns.max_ips_per_record // 2' "$CONFIG_FILE")
export REQUEST_TIMEOUT=$(jq -r '.api.timeout // 10' "$CONFIG_FILE")
export MAX_RETRIES=$(jq -r '.api.max_retries // 5' "$CONFIG_FILE")
export LOG_DIR=$(jq -r '.logging.log_dir // empty' "$CONFIG_FILE")

# 检查启用状态
if [ "${ENABLED:-false}" != "true" ]; then
    echo -e "${YELLOW}[INFO] CF-DNS 模块当前处于禁用状态 (ENABLED=false)。${NC}"
    echo -e "${YELLOW}[INFO] 如需启用，请在配置文件或菜单中开启。${NC}"
    exit 0
fi

echo -e "${GREEN}成功${NC}: 配置文件已加载 ${CONFIG_FILE}"
echo ""

# 检查 jq 是否可用
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误${NC}: jq 未安装 (必需工具)"
    echo "请安装 jq: apt install jq 或 yum install jq"
    exit 1
fi

# 检查必要配置
if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_DNS_NAME" ]; then
    echo -e "${RED}错误${NC}: 配置文件中缺少必要的配置项"
    echo "请编辑 ${CONFIG_FILE} 并填写完整"
    exit 1
fi

# 验证 API Token 格式（非空且至少 20 字符）
if [ -z "$CF_API_TOKEN" ]; then
    echo -e "${RED}错误${NC}: API Token 不能为空"
    echo "请检查 CF_API_TOKEN 配置"
    exit 1
fi

if [ ${#CF_API_TOKEN} -lt 20 ]; then
    echo -e "${RED}错误${NC}: API Token 格式不正确 (长度: ${#CF_API_TOKEN}, 太短)"
    echo "请检查 CF_API_TOKEN 配置"
    exit 1
fi

# 验证 DNS 名称格式（只允许字母、数字、@、.、-、_）
if [[ ! "$CF_DNS_NAME" =~ ^[a-zA-Z0-9@._-]+$ ]]; then
    echo -e "${RED}错误${NC}: DNS 名称包含非法字符: $CF_DNS_NAME"
    echo "只允许使用: 字母、数字、@、.、-、_"
    exit 1
fi

# 设置默认值
MAX_RETRIES=${MAX_RETRIES:-3}
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-10}
MAX_IPS_PER_RECORD=${MAX_IPS_PER_RECORD:-2}
IP_FILE=${IP_FILE:-"$ROOT_DIR/assets/data/cf-dns/ip_list.txt"}
CF_DEBUG=${CF_DEBUG:-false}  # 调试模式

# ==================== IP 数据文件检测 (启动前校验) ====================
if [ ! -f "$IP_FILE" ]; then
    log "${RED}[ERROR] IP 文件不存在: $IP_FILE${NC}"
    log "${YELLOW}[INFO] 请先运行 CF-IP 优选程序或手动创建 IP 列表。${NC}"
    exit 1
fi

# 1. 时效性检测 (防止使用旧 IP)
CURRENT_TIME=$(date +%s)
FILE_MOD_TIME=$(stat -c %Y "$IP_FILE" 2>/dev/null || stat -f %m "$IP_FILE" 2>/dev/null)
if [ -n "$FILE_MOD_TIME" ]; then
    AGE_HOURS=$(( (CURRENT_TIME - FILE_MOD_TIME) / 3600 ))
    if [ $AGE_HOURS -ge 48 ]; then # 超过 48 小时视为过期
        log "${YELLOW}[WARN] IP 数据已过期 (${AGE_HOURS} 小时前更新)。${NC}"
        log "${YELLOW}[WARN] 建议重新测速以获取最优节点，当前将尝试继续执行...${NC}"
    fi
fi

# 2. 有效性检测 (防止全 0 或空数据 Bug)
FIRST_LINE=$(head -n 1 "$IP_FILE")
if [ -z "$FIRST_LINE" ] || [[ ! "$FIRST_LINE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "${RED}[ERROR] IP 文件格式错误或包含无效数据 (首行: ${FIRST_LINE:-空})。${NC}"
    log "${YELLOW}[INFO] 这可能是测速程序的临时 Bug，请重新运行测速。${NC}"
    exit 1
fi

log "${GREEN}[OK] IP 数据检查通过 (首个 IP: ${FIRST_LINE})${NC}"

# ==================== 工具函数 ====================

# 构建完整域名
build_full_domain() {
    local dns_name="$1"
    local domain="$2"
    
    if [ "$dns_name" != "@" ] && [ -n "$domain" ]; then
        echo "${dns_name}.${domain}"
    elif [ "$dns_name" = "@" ] && [ -n "$domain" ]; then
        echo "${domain}"
    else
        echo "$dns_name"
    fi
}

# 日志轮转（删除7天前的日志）
rotate_logs() {
    find "$LOG_DIR" -name "cfdns_*.log" -mtime +7 -delete 2>/dev/null
}

# HTTP GET 请求（带重试、校验与详细提示）
http_get() {
    local url="$1"
    # shellcheck disable=SC2034
    local expected_hash="$2" # 可选参数
    local max_retries=${MAX_RETRIES:-3}
    local retry=0
    
    while [ "$retry" -lt "$max_retries" ]; do
        if [ $retry -gt 0 ]; then
            log_msg "WARN" "正在重试第 $retry/$max_retries 次..."
            sleep 2
        fi
        
        local response
        response=$(curl -s --connect-timeout 10 -X GET "$url" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --max-time "$REQUEST_TIMEOUT" \
            -w "\n%{http_code}")
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        elif [ "$http_code" = "429" ]; then
            # 速率限制，指数退避
            local wait_time=$((2 ** retry * 3))
            if [ "${CF_DEBUG}" = "true" ]; then
                log "  [WARN] API 速率限制，等待 ${wait_time}秒后重试..."
            fi
            sleep $wait_time
        elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            # 认证错误，不重试
            log "  ${RED}[ERROR]${NC} API 认证失败 (HTTP $http_code)"
            echo '{"success":false,"errors":[{"message":"Authentication failed"}]}'
            return 1
        else
            retry=$((retry + 1))
            if [ "$retry" -lt "$max_retries" ]; then
                local wait_time=$((retry * 2))
                if [ "${CF_DEBUG}" = "true" ]; then
                    log "  [WARN] API 请求失败 (HTTP $http_code), ${wait_time}秒后重试 $retry/$max_retries"
                fi
                sleep $wait_time
            fi
        fi
    done
    
    if [ "${CF_DEBUG}" = "true" ]; then
        log "  ${RED}[ERROR]${NC} API 请求失败，已达到最大重试次数"
    fi
    echo '{"success":false,"errors":[{"message":"Max retries exceeded"}]}'
    return 1
}

# HTTP PUT 请求（带重试）
http_put() {
    local url="$1"
    local data="$2"
    local max_retries=${MAX_RETRIES:-3}
    local retry=0
    
    while [ "$retry" -lt "$max_retries" ]; do
        local response
        response=$(curl -s -X PUT "$url" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data" \
            --max-time "$REQUEST_TIMEOUT" \
            -w "\n%{http_code}")
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        elif [ "$http_code" = "429" ]; then
            local wait_time=$((2 ** retry * 3))
            if [ "${CF_DEBUG}" = "true" ]; then
                log "  [WARN] API 速率限制，等待 ${wait_time}秒后重试..."
            fi
            sleep $wait_time
        elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            log "  ${RED}[ERROR]${NC} API 认证失败 (HTTP $http_code)"
            echo '{"success":false,"errors":[{"message":"Authentication failed"}]}'
            return 1
        else
            retry=$((retry + 1))
            if [ "$retry" -lt "$max_retries" ]; then
                local wait_time=$((retry * 2))
                if [ "${CF_DEBUG}" = "true" ]; then
                    log "  [WARN] API 请求失败 (HTTP $http_code), ${wait_time}秒后重试 $retry/$max_retries"
                fi
                sleep $wait_time
            fi
        fi
    done
    
    if [ "${CF_DEBUG}" = "true" ]; then
        log "  ${RED}[ERROR]${NC} API 请求失败，已达到最大重试次数"
    fi
    echo '{"success":false,"errors":[{"message":"Max retries exceeded"}]}'
    return 1
}

# HTTP POST 请求（带重试）
http_post() {
    local url="$1"
    local data="$2"
    local max_retries=${MAX_RETRIES:-3}
    local retry=0
    
    while [ "$retry" -lt "$max_retries" ]; do
        local response
        response=$(curl -s -X POST "$url" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data" \
            --max-time "$REQUEST_TIMEOUT" \
            -w "\n%{http_code}")
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        elif [ "$http_code" = "429" ]; then
            local wait_time=$((2 ** retry * 3))
            if [ "${CF_DEBUG}" = "true" ]; then
                log "  [WARN] API 速率限制，等待 ${wait_time}秒后重试..."
            fi
            sleep $wait_time
        elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            log "  ${RED}[ERROR]${NC} API 认证失败 (HTTP $http_code)"
            echo '{"success":false,"errors":[{"message":"Authentication failed"}]}'
            return 1
        else
            retry=$((retry + 1))
            if [ "$retry" -lt "$max_retries" ]; then
                local wait_time=$((retry * 2))
                if [ "${CF_DEBUG}" = "true" ]; then
                    log "  [WARN] API 请求失败 (HTTP $http_code), ${wait_time}秒后重试 $retry/$max_retries"
                fi
                sleep $wait_time
            fi
        fi
    done
    
    if [ "${CF_DEBUG}" = "true" ]; then
        log "  ${RED}[ERROR]${NC} API 请求失败，已达到最大重试次数"
    fi
    echo '{"success":false,"errors":[{"message":"Max retries exceeded"}]}'
    return 1
}

# ==================== API 调用函数 ====================

# 从文件读取优选 IP
get_cf_ip_from_file() {
    if [ ! -f "$IP_FILE" ]; then
        log "${RED}错误${NC}: IP 文件不存在: ${IP_FILE}"
        log "   请创建文件或修改 cf-dns.json 中的配置"
        return 1
    fi
    
    # 检查文件修改时间，如果文件没有变化则返回空（由主函数处理）
    local current_mtime
    current_mtime=$(stat -c %Y "$IP_FILE" 2>/dev/null || stat -f %m "$IP_FILE" 2>/dev/null)
    local cache_file="${IP_FILE}.mtime"
    
    if [ -f "$cache_file" ]; then
        local cached_mtime
        cached_mtime=$(cat "$cache_file")
        if [ "$current_mtime" = "$cached_mtime" ]; then
            # 文件未变化，但我们需要读取内容让主函数处理
            # 这里不返回空，而是继续执行，由主函数判断是否需要更新
            :
        fi
    fi
    
    # 读取文件内容,支持多种格式:
    # 1. 每行一个 IP
    # 2. 逗号分隔的 IP
    # 3. 空格分隔的 IP
    # 4. 混合分隔符
    local content
    content=$(grep -v '^#' "$IP_FILE" | sed 's/#.*//g' | tr '\n,' '  ' | tr -s ' ' | sed 's/^ //;s/ $//')
    
    if [ -z "$content" ]; then
        log "${RED}错误${NC}: IP 文件为空: ${IP_FILE}"
        return 1
    fi
    
    # 限制 IP 数量
    if [ "$MAX_IPS_PER_RECORD" -gt 0 ]; then
        # 将 IP 转换为数组
        IFS=' ' read -ra ip_array <<< "$content"
        local total_ips=${#ip_array[@]}
        
        # 如果超出限制,只取前 N 个
        if [ "$total_ips" -gt "$MAX_IPS_PER_RECORD" ]; then
            echo -e "${YELLOW}警告${NC}: IP 文件包含 ${total_ips} 个 IP,超出限制 ${MAX_IPS_PER_RECORD} 个" >&2
            echo -e "   已自动截取前 ${MAX_IPS_PER_RECORD} 个 IP (避免超出套餐限制)" >&2
            
            # 取前 N 个 IP
            local limited_ips=""
            for ((i=0; i<MAX_IPS_PER_RECORD && i<total_ips; i++)); do
                if [ -z "$limited_ips" ]; then
                    limited_ips="${ip_array[$i]}"
                else
                    limited_ips="${limited_ips} ${ip_array[$i]}"
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

# 获取 DNS 记录
# 返回值格式：
#   成功: 第一行是记录数量，后续每行是 "record_id|content"
#   失败: 第一行是 "ERROR"，第二行是错误信息
get_dns_records() {
    local name="$1"
    
    # 构建完整的域名
    local full_name="${name}"
    if [ "$name" != "@" ]; then
        # 如果不是根域名，需要加上 Zone 的域名
        if [ -n "$CF_DOMAIN" ]; then
            full_name="${name}.${CF_DOMAIN}"
        fi
    else
        # 根域名直接使用 CF_DOMAIN
        if [ -n "$CF_DOMAIN" ]; then
            full_name="${CF_DOMAIN}"
        fi
    fi
    
    # 调试输出（输出到 stderr，不影响返回值）
    if [ "${CF_DEBUG}" = "true" ]; then
        echo "  [DEBUG] 查询域名: ${full_name}" >&2
    fi
    
    # 使用 name 参数过滤，只获取指定名称的记录
    local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${full_name}"
    
    local response
    response=$(http_get "$url")
    
    # 解析 JSON 获取 A 类型记录
    # 使用 grep -o 提取所有匹配项，处理单行 JSON
    local -a record_ids=()
    # shellcheck disable=SC2034
    local -a record_contents=()
    
    # 检查是否成功
    if ! echo "$response" | jq -r '.success' 2>/dev/null | grep -q 'true'; then
        # API 请求失败，返回 ERROR 标记和错误信息
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null)
        if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
            echo "ERROR"
            echo "API 请求失败: ${error_msg}"
        else
            echo "ERROR"
            echo "API 请求失败，响应: ${response:0:200}"
        fi
        return 1
    fi
    
    # 使用 jq 提取记录数量
    local count
    count=$(echo "$response" | jq '.result | length' 2>/dev/null)
    
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        echo "0"
        return 0
    fi
    
    # 输出结果
    echo "$count"
    
    # 使用 jq 提取每个记录的 id、type、content
    for ((i=0; i<count; i++)); do
        local obj_id
        obj_id=$(echo "$response" | jq -r ".result[$i].id" 2>/dev/null)
        local obj_type
        obj_type=$(echo "$response" | jq -r ".result[$i].type" 2>/dev/null)
        local obj_content
        obj_content=$(echo "$response" | jq -r ".result[$i].content" 2>/dev/null)
        
        # 只添加 A 类型的记录
        if [ "$obj_type" = "A" ] && [ -n "$obj_id" ] && [ "$obj_id" != "null" ] && [ -n "$obj_content" ] && [ "$obj_content" != "null" ]; then
            echo "${obj_id}|${obj_content}"
        fi
    done
}

# 更新 DNS 记录
update_dns_record() {
    local record_id="$1"
    local name="$2"
    local cf_ip="$3"
    
    local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"
    local data="{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${cf_ip}\"}"
    
    local response
    response=$(http_put "$url" "$data")
    
    if echo "$response" | jq -r '.success' 2>/dev/null | grep -q 'true'; then
        echo "success"
    else
        echo "failed:$response"
    fi
}

# 创建 DNS 记录
create_dns_record() {
    local name="$1"
    local cf_ip="$2"
    
    local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
    local data="{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${cf_ip}\",\"ttl\":1,\"proxied\":false}"
    
    local response
    response=$(http_post "$url" "$data")
    
    if echo "$response" | jq -r '.success' 2>/dev/null | grep -q 'true'; then
        echo "success"
    else
        echo "failed:$response"
    fi
}

# 删除 DNS 记录
delete_dns_record() {
    local record_id="$1"
    
    local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"
    
    local response
    response=$(curl -s -X DELETE "$url" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --max-time "$REQUEST_TIMEOUT")
    
    if echo "$response" | jq -r '.success' 2>/dev/null | grep -q 'true'; then
        echo "success"
    else
        echo "failed:$response"
    fi
}

# ==================== 主逻辑 ====================

main() {
    local current_time
    current_time=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 清屏
    clear
    
    # 构建完整域名用于显示
    local full_domain
    full_domain=$(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")
    
    # 显示配置摘要
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${VERSION}${NC}"
    echo -e " ${CYAN}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e " 域名: ${full_domain}"
    echo -e " IP限制: ${MAX_IPS_PER_RECORD} 个/记录"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    # 日志轮转
    rotate_logs
    
    # 日志头部（简化）
    log ""
    log "${CYAN}Cloudflare DNS 更新器${NC} | ${full_domain} | ${current_time}"
    log ""
    
    # 从文件读取优选 IP
    log "${BLUE}[1/3]${NC} 读取 IP 文件: ${IP_FILE}"
    
    local cf_ip
    cf_ip=$(get_cf_ip_from_file)
    
    if [ -z "$cf_ip" ]; then
        log "错误: 无法从文件读取IP,请检查IP文件是否存在且格式正确"
        exit 1
    fi
    
    # 解析多个 IP 地址并验证格式
    local -a ip_addresses=()
    local -a invalid_ips=()
    IFS=' ' read -ra raw_ips <<< "$cf_ip"
    for ip in "${raw_ips[@]}"; do
        # 去除首尾空格和空白字符
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$ip" ]; then
            # 验证 IPv4 格式
            if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                # 进一步验证每个段是否 <= 255
                local valid=true
                IFS='.' read -ra octets <<< "$ip"
                for octet in "${octets[@]}"; do
                    if [ "$octet" -gt 255 ]; then
                        valid=false
                        break
                    fi
                done
                
                if [ "$valid" = true ]; then
                    ip_addresses+=("$ip")
                else
                    invalid_ips+=("$ip")
                fi
            else
                invalid_ips+=("$ip")
            fi
        fi
    done
    
    # 如果有无效 IP，发出警告
    if [ ${#invalid_ips[@]} -gt 0 ]; then
        log "${YELLOW}[WARN]: 发现 ${#invalid_ips[@]} 个无效的 IP 地址，已自动忽略"
        log ""
        log "无效的 IP:"
        for inv_ip in "${invalid_ips[@]}"; do
            log "  - ${inv_ip}"
        done
        log ""
    fi
    
    # 检测并去重 IP 文件中的重复 IP
    local original_count=${#ip_addresses[@]}
    if [ "$original_count" -gt 0 ]; then
        local -a unique_ips=()
        local -a duplicate_ips=()
        
        for ip in "${ip_addresses[@]}"; do
            # 检查是否已存在
            local is_duplicate=false
            for existing_ip in "${unique_ips[@]}"; do
                if [ "$ip" = "$existing_ip" ]; then
                    is_duplicate=true
                    break
                fi
            done
            
            if [ "$is_duplicate" = true ]; then
                duplicate_ips+=("$ip")
            else
                unique_ips+=("$ip")
            fi
        done
        
        # 如果有重复，提示用户
        if [ ${#duplicate_ips[@]} -gt 0 ]; then
            log "[WARN]: IP 文件中存在 ${#duplicate_ips[@]} 个重复的 IP，已自动忽略"
            log ""
            log "重复的 IP:"
            for dup_ip in "${duplicate_ips[@]}"; do
                log "  - ${dup_ip}"
            done
            log ""
            log "有效 IP 数量: ${#unique_ips[@]} (原始数量: ${original_count})"
            log ""
        fi
        
        # 使用去重后的 IP 列表
        ip_addresses=("${unique_ips[@]}")
    fi
    
    if [ ${#ip_addresses[@]} -eq 0 ]; then
        log "${RED}[ERROR]: 未解析到有效 IP，请检查文件: ${IP_FILE}"
        exit 1
    fi
    
    log "  [OK] 获取到 ${#ip_addresses[@]} 个 IP"
    
    # 检测 IP 数量变化（与上次执行对比）
    local count_file="${IP_FILE}.count"
    if [ -f "$count_file" ]; then
        local last_count
        last_count=$(cat "$count_file")
        local count_diff=$((${#ip_addresses[@]} - last_count))
        
        if [ $count_diff -ne 0 ]; then
            if [ $count_diff -gt 0 ]; then
                log "  ${CYAN}[INFO]${NC} IP 数量增加 ${count_diff} 个 (${last_count} → ${#ip_addresses[@]})"
            else
                log "  ${YELLOW}[WARN]${NC} IP 数量减少 $((0 - count_diff)) 个 (${last_count} → ${#ip_addresses[@]})"
            fi
            
            # 如果变化超过 50%，发出严重警告
            if [ "$last_count" -gt 0 ]; then
                local change_percent=$(( (count_diff < 0 ? -count_diff : count_diff) * 100 / last_count ))
                if [ $change_percent -gt 50 ]; then
                    log "  ${RED}[WARN] 严重警告${NC}: IP 数量变化超过 50%，请检查测速软件"
                fi
            fi
        fi
    fi
    
    # 保存本次 IP 数量
    echo "${#ip_addresses[@]}" > "$count_file"
    
    # 获取 DNS 记录
    log "${BLUE}[2/3]${NC} 查询 DNS 记录: $(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")"
    
    local records_output
    records_output=$(get_dns_records "$CF_DNS_NAME")
    local first_line
    first_line=$(echo "$records_output" | head -n 1)
    
    # 检查是否 API 请求失败
    if [ "$first_line" = "ERROR" ]; then
        local error_detail
        error_detail=$(echo "$records_output" | sed -n '2p')
        log "  ${RED}[ERROR]${NC} DNS 记录查询失败"
        log "  ${RED}[详情]${NC} $error_detail"
        exit 1
    fi
    
    # 验证 record_count 是有效数字
    if ! [[ "$first_line" =~ ^[0-9]+$ ]]; then
        log "${RED}[ERROR]: 获取 DNS 记录失败 (无效响应: ${first_line})"
        exit 1
    fi
    
    local record_count="$first_line"
    
    local -a record_ids=()
    local -a current_values=()
    
    if [ "$record_count" -gt 0 ]; then
        local idx=0
        while IFS= read -r line; do
            if [ $idx -gt 0 ]; then
                local rid
                rid=$(echo "$line" | cut -d'|' -f1)
                local rval
                rval=$(echo "$line" | cut -d'|' -f2)
                record_ids+=("$rid")
                current_values+=("$rval")
            fi
            idx=$((idx + 1))
        done <<< "$records_output"
        
        log "  [OK] 找到 ${record_count} 条记录"
    else
        log "  [SKIP] 未找到记录，将自动创建"
    fi
    
    # 同步 DNS 记录
    log "${BLUE}[3/3]${NC} 同步 DNS 记录"
    
    local updated_count=0
    local skipped_count=0
    local created_count=0
    local deleted_count=0
    
    # 显示 IP 变化对比（基于集合对比，不关心顺序）
    if [ "$record_count" -gt 0 ]; then
        local same_count=0
        local to_add=0
        local to_remove=0
        
        # 计算相同 IP 的数量（集合交集）
        for new_ip in "${ip_addresses[@]}"; do
            local clean_new
            clean_new=$(echo "$new_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            for existing_ip in "${current_values[@]}"; do
                local clean_existing
                clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ "$clean_new" = "$clean_existing" ]; then
                    same_count=$((same_count + 1))
                    break
                fi
            done
        done
        
        # 需要新增的 IP（目标中有但现有中没有）
        to_add=$((${#ip_addresses[@]} - same_count))
        # 需要删除的记录（现有中有但目标中没有）
        to_remove=$((record_count - same_count))
        
        if [ $same_count -gt 0 ] || [ $to_add -gt 0 ] || [ $to_remove -gt 0 ]; then
            log "  ${CYAN}变化分析:${NC} 相同 ${same_count} | 需新建 ${to_add} | 需删除 ${to_remove}"
        fi
    fi
    
    # 策略：智能同步（优先更新，减少 API 调用）
    # 1. 找出现有记录中需要删除的 IP（不在目标列表中）
    local -a records_to_delete_ids=()
    local -a records_to_delete_values=()
    
    if [ "$record_count" -gt 0 ]; then
        for ((i=0; i<record_count; i++)); do
            local existing_ip="${current_values[$i]}"
            local clean_existing
            clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # 检查这个 IP 是否在目标列表中
            local found=false
            for target_ip in "${ip_addresses[@]}"; do
                local clean_target
                clean_target=$(echo "$target_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ "$clean_existing" = "$clean_target" ]; then
                    found=true
                    break
                fi
            done
            
            # 如果不在目标列表中，标记为删除
            if [ "$found" = false ]; then
                records_to_delete_ids+=("${record_ids[$i]}")
                records_to_delete_values+=("$existing_ip")
            fi
        done
    fi
    
    # 2. 先删除多余的记录
    if [ ${#records_to_delete_ids[@]} -gt 0 ]; then
        log "  ${YELLOW}⟳${NC} 删除 ${#records_to_delete_ids[@]} 条多余记录..."
        
        for ((i=0; i<${#records_to_delete_ids[@]}; i++)); do
            local record_id="${records_to_delete_ids[$i]}"
            local current_value="${records_to_delete_values[$i]}"
            
            local delete_result
            delete_result=$(delete_dns_record "$record_id")
            
            if [[ "$delete_result" == success* ]]; then
                deleted_count=$((deleted_count + 1))
            else
                log "    ${RED}[ERROR]${NC} 删除失败: ${current_value}"
            fi
        done
        log "  [OK] 已删除 ${deleted_count} 条记录"
        
        # 重新获取记录列表（删除后）
        local new_records_output
        new_records_output=$(get_dns_records "$CF_DNS_NAME")
        local new_record_count
        new_record_count=$(echo "$new_records_output" | head -n 1)
        
        record_ids=()
        current_values=()
        
        if [ "$new_record_count" -gt 0 ]; then
            local idx=0
            while IFS= read -r line; do
                if [ $idx -gt 0 ]; then
                    local rid
                    rid=$(echo "$line" | cut -d'|' -f1)
                    local rval
                    rval=$(echo "$line" | cut -d'|' -f2)
                    record_ids+=("$rid")
                    current_values+=("$rval")
                fi
                idx=$((idx + 1))
            done <<< "$new_records_output"
        fi
        
        record_count=$new_record_count
    fi
    
    # 3. 检查是否需要更新（只有当记录数和 IP 数相同且位置不同时）
    local -a ips_to_update=()
    local -a update_record_ids=()
    
    # 只有当记录数和 IP 数相同，且有 IP 不在目标列表中时，才进行更新
    if [ "$record_count" -eq ${#ip_addresses[@]} ] && [ ${#records_to_delete_ids[@]} -eq 0 ]; then
        # 检查是否有位置不同的 IP
        local has_position_diff=false
        for ((i=0; i<record_count; i++)); do
            local existing_ip="${current_values[$i]}"
            local target_ip="${ip_addresses[$i]}"
            local clean_existing
            clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local clean_target
            clean_target=$(echo "$target_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ "$clean_existing" != "$clean_target" ]; then
                has_position_diff=true
                break
            fi
        done
        
        # 如果所有 IP 都存在但位置不同，不需要更新（集合相同即可）
        if [ "$has_position_diff" = true ]; then
            log "  ${CYAN}[INFO]${NC} IP 集合相同但顺序不同，无需更新"
            skipped_count=${#ip_addresses[@]}
        else
            # 完全相同，跳过
            skipped_count=${#ip_addresses[@]}
        fi
    elif [ "$record_count" -gt 0 ] && [ ${#ip_addresses[@]} -gt 0 ]; then
        # 记录数和 IP 数不同，或者有需要删除的记录，进行智能匹配更新
        # 找出可以直接保留的记录（IP 和位置都相同）
        local -a matched_indices=()
        
        for ((i=0; i<record_count && i<${#ip_addresses[@]}; i++)); do
            local existing_ip="${current_values[$i]}"
            local target_ip="${ip_addresses[$i]}"
            local clean_existing
            clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local clean_target
            clean_target=$(echo "$target_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ "$clean_existing" = "$clean_target" ]; then
                matched_indices+=("$i")
                skipped_count=$((skipped_count + 1))
            fi
        done
        
        # 对于未匹配的记录，尝试找到可以更新的
        for ((i=0; i<record_count; i++)); do
            # 跳过已匹配的
            local is_matched=false
            for mi in "${matched_indices[@]}"; do
                if [ "$mi" -eq "$i" ]; then
                    is_matched=true
                    break
                fi
            done
            [ "$is_matched" = true ] && continue
            
            # 检查这个位置的 IP 是否在目标列表中
            local existing_ip="${current_values[$i]}"
            local clean_existing
            clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            local found_in_target=false
            for target_ip in "${ip_addresses[@]}"; do
                local clean_target
                clean_target=$(echo "$target_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ "$clean_existing" = "$clean_target" ]; then
                    found_in_target=true
                    break
                fi
            done
            
            # 如果这个 IP 不在目标列表中，它应该已经被删除了
            # 如果还在，说明需要更新为目标 IP
            if [ "$found_in_target" = false ] && [ $i -lt ${#ip_addresses[@]} ]; then
                ips_to_update+=("${ip_addresses[$i]}")
                update_record_ids+=("${record_ids[$i]}")
            fi
        done
    fi
    
    # 执行更新
    if [ ${#ips_to_update[@]} -gt 0 ]; then
        log "  ${CYAN}⟳${NC} 更新 ${#ips_to_update[@]} 条记录..."
        
        # 构建完整域名用于 API 调用
        local full_dns_name
        full_dns_name=$(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")
        
        for ((i=0; i<${#ips_to_update[@]}; i++)); do
            local target_ip="${ips_to_update[$i]}"
            local record_id="${update_record_ids[$i]}"
            
            local update_result
            update_result=$(update_dns_record "$record_id" "$full_dns_name" "$target_ip")
            
            if [[ "$update_result" == success* ]]; then
                updated_count=$((updated_count + 1))
            else
                log "    ${RED}[ERROR]${NC} 更新失败: ${target_ip}"
            fi
        done
        log "  [OK] 已更新 ${updated_count} 条记录"
    fi
    
    # 4. 如果还有剩余的 IP，创建新记录
    local remaining_ips=$((${#ip_addresses[@]} - record_count))
    if [ "$remaining_ips" -gt 0 ]; then
        log "  ${GREEN}⟳${NC} 创建 ${remaining_ips} 条新记录..."
        
        # 构建完整域名用于 API 调用
        local full_dns_name
        full_dns_name=$(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")
        
        for ((i=record_count; i<${#ip_addresses[@]}; i++)); do
            local target_ip="${ip_addresses[$i]}"
            
            local create_result
            create_result=$(create_dns_record "$full_dns_name" "$target_ip")
            
            if [[ "$create_result" == success* ]]; then
                created_count=$((created_count + 1))
            else
                log "    ${RED}[ERROR]${NC} 创建失败: ${target_ip}"
                # 提取错误信息
                local error_msg
                error_msg=$(echo "$create_result" | sed 's/^failed://' | jq -r '.errors[0].message' 2>/dev/null)
                if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
                    log "    ${RED}[详情]${NC} ${error_msg}"
                fi
            fi
        done
        
        if [ "$created_count" -gt 0 ]; then
            log "  [OK] 已创建 ${created_count} 条记录"
        else
            log "  ${RED}[ERROR]${NC} 所有记录创建失败，请检查 API 配置和网络连接"
            exit 1
        fi
    fi
    
    # 5. 如果没有需要操作的，说明所有 IP 都已存在
    if [ "$deleted_count" -eq 0 ] && [ "$updated_count" -eq 0 ] && [ "$created_count" -eq 0 ]; then
        # 只有当查询到的记录数与目标 IP 数一致时，才能判断为"已存在"
        if [ "$record_count" -eq "${#ip_addresses[@]}" ]; then
            log "  ${GREEN}[OK]${NC} 所有 IP 已存在，无需更新"
            skipped_count=${#ip_addresses[@]}
        else
            log "  ${YELLOW}[WARN]${NC} 未执行任何操作，但记录数 (${record_count}) 与目标 IP 数 (${#ip_addresses[@]}) 不一致"
            log "  ${YELLOW}[WARN]${NC} 这可能是 API 查询失败导致，请检查配置和网络连接"
        fi
    fi
    
    # 输出总结（简化）
    log ""
    log "${CYAN}结果汇总:${NC} 跳过 ${skipped_count} | 新建 ${created_count} | 删除 ${deleted_count}"
    log ""
}

# 执行主函数
main
