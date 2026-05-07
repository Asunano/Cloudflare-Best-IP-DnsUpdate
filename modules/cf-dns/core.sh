#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - Cloudflare DNS 更新核心 (Core)
# Version: 0.1
# Description: 负责将优选 IP 同步至 Cloudflare DNS 记录，支持有效性校验与日志记录
# Usage: bash modules/cf-dns/core.sh
# ==============================================================================
# 【安全修复】启用严格模式，防止错误传播
set -euo pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"
MODULE_NAME="cf-dns"  # 【修复】定义模块名称，用于日志输出

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
    
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "[ERROR] 无法获取锁，另一个 CF-DNS 更新进程正在运行 (Domain: ${DOMAIN_NAME:-default})"
        exit 1
    fi
    # 锁会在脚本退出时自动释放（fd 9 关闭）
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

# 【安全配置】日志轮转：防止日志无限增长
rotate_log() {
    local log_file="$1"
    local max_size=${2:-$((10 * 1024 * 1024))}  # 默认 10MB
    
    if [[ -f "$log_file" ]]; then
        local file_size
        # 【修复】跨平台获取文件大小（macOS 不支持 stat -c）
        if stat -f %z "$log_file" >/dev/null 2>&1; then
            # macOS/BSD
            file_size=$(stat -f %z "$log_file")
        elif stat -c %s "$log_file" >/dev/null 2>&1; then
            # Linux
            file_size=$(stat -c %s "$log_file")
        else
            # 备用方案：使用 wc -c
            file_size=$(wc -c < "$log_file" | tr -d ' ')
        fi
        
        if [[ "$file_size" -gt "$max_size" ]]; then
            mv "$log_file" "${log_file}.old"
            rm -f "${log_file}.old.old"
            touch "$log_file"
        fi
    fi
}

# 轮转旧的 cfdns 日志文件
for old_log in "${LOG_DIR}"/cfdns_*.log.old; do
    [[ -f "$old_log" ]] && rotate_log "$old_log" 5242880  # 5MB
done

# ====================== 【统一结构化日志系统】 ======================
# 格式: [2026-05-06 09:30:00] [INFO ] [cf-dns] message
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 【修复】写入文件时剥离 ANSI 颜色码，终端输出保留颜色
    local plain_message
    plain_message=$(echo "$*" | sed 's/\x1b\[[0-9;]*m//g')
    
    # 写入日志文件（纯文本）
    printf "[%s] [%-5s] [cf-dns] %s\n" "$timestamp" "$level" "$plain_message" >> "$LOG_FILE"
    
    # 终端输出（带颜色）
    printf "[%s] [%-5s] [cf-dns] %s\n" "$timestamp" "$level" "$*"
}

# 便捷函数
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "OK" "$@"; }

# ====================== 【执行历史记录】 ======================
# 记录 DNS 更新结果到 history.jsonl
record_dns_update_history() {
    local domain="$1"
    local records_updated="$2"
    local records_created="$3"
    local records_deleted="$4"
    
    local history_file="${ROOT_DIR}/conf/history.jsonl"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%S+08:00")"
    
    # 确保目录存在
    mkdir -p "${ROOT_DIR}/conf"
    
    # 【修复】使用 flock 保护并发写入，防止多进程同时写入导致数据损坏
    (
        flock -n 200 || { log_warn "无法获取历史记录写入锁"; return 1; }
        printf '{"time":"%s","action":"dns_update","domain":"%s","records_updated":%d,"records_created":%d,"records_deleted":%d}\n' \
            "$timestamp" "$domain" "$records_updated" "$records_created" "$records_deleted" >> "$history_file"
    ) 200>"${history_file}.lock"
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

# ==================== 【性能优化】一次性读取配置文件 ====================

# 【修复】先检查 jq 是否可用，再加载配置（避免 jq 不存在时配置加载失败）
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误${NC}: jq 未安装 (必需工具)"
    echo "请安装 jq: apt install jq 或 yum install jq"
    exit 1
fi

# 从 JSON 读取配置（【优化】只调用 1 次 jq，避免 10 次 fork + 文件 I/O）
declare -A CFG
while IFS='=' read -r key value; do
    [[ -n "$key" ]] && CFG["$key"]="$value"
done < <(jq -r '
    [
        "enabled=\(.enabled // false)",
        "api_token=\(.api.token // \"\")",
        "zone_id=\(.api.zone_id // \"\")",
        "dns_name=\(.dns.record_name // \"\")",
        "domain=\(.dns.domain // \"\")",
        "ip_file=\(.ip_source.file_path // \"\")",
        "max_ips_per_record=\(.dns.max_ips_per_record // 2)",
        "timeout=\(.api.timeout // 10)",
        "max_retries=\(.api.max_retries // 5)",
        "log_dir=\(.logging.log_dir // \"\")"
    ] | .[]
' "$CONFIG_FILE")

# 导出配置变量（【安全修复】不要 export，避免通过 /proc/<pid>/environ 泄露）
ENABLED="${CFG[enabled]}"
CF_API_TOKEN="${CFG[api_token]}"
CF_ZONE_ID="${CFG[zone_id]}"
CF_DNS_NAME="${CFG[dns_name]}"
CF_DOMAIN="${CFG[domain]}"
IP_FILE="${CFG[ip_file]}"
MAX_IPS_PER_RECORD="${CFG[max_ips_per_record]}"
REQUEST_TIMEOUT="${CFG[timeout]}"
MAX_RETRIES="${CFG[max_retries]}"
LOG_DIR="${CFG[log_dir]}"

# 【修复】如果 CF_DOMAIN 为空，fallback 到 DOMAIN_NAME（支持通过 CF_DNS_DOMAIN 环境变量指定域名）
if [[ -z "${CF_DOMAIN}" ]] && [[ -n "${DOMAIN_NAME:-}" ]]; then
    CF_DOMAIN="${DOMAIN_NAME}"
fi

# 检查启用状态
if [ "${ENABLED:-false}" != "true" ]; then
    echo -e "${YELLOW}[INFO] CF-DNS 模块当前处于禁用状态 (ENABLED=false)。${NC}"
    echo -e "${YELLOW}[INFO] 如需启用，请在配置文件或菜单中开启。${NC}"
    exit 0
fi

echo -e "${GREEN}成功${NC}: 配置文件已加载 ${CONFIG_FILE}"
echo ""

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
# 【标准化】统一使用 .iplist 标准格式
IP_FILE=${IP_FILE:-"$ROOT_DIR/assets/data/cf-dns/ip_list.iplist"}
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
    
    # 【修复】domain 不能为空（@ 模式下尤其需要）
    if [[ -z "$domain" ]]; then
        log_error "域名(domain)配置为空，请检查配置文件"
        return 1
    fi
    
    if [[ "$dns_name" == "@" ]]; then
        echo "$domain"
    else
        echo "${dns_name}.${domain}"
    fi
}

# 日志轮转（删除7天前的日志）
rotate_logs() {
    find "$LOG_DIR" -name "cfdns_*.log" -mtime +7 -delete 2>/dev/null
}

# ==================== 【通用 HTTP 请求函数】 ====================
# 【重构】合并 http_get/http_put/http_post 为一个通用函数，消除代码重复
_http_request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local max_retries=${MAX_RETRIES:-3}
    local retry=0
    
    while [ "$retry" -lt "$max_retries" ]; do
        if [ $retry -gt 0 ] && [ "$method" = "GET" ]; then
            log_msg "WARN" "正在重试第 $retry/$max_retries 次..."
            sleep 2
        fi
        
        # 构建 curl 参数数组
        local -a curl_args=(-s -X "$method" "$url"
            -H "Authorization: Bearer ${CF_API_TOKEN}"
            -H "Content-Type: application/json"
            --max-time "$REQUEST_TIMEOUT"
            -w "\n%{http_code}")
        
        # GET 请求添加连接超时
        if [ "$method" = "GET" ]; then
            curl_args=(--connect-timeout 10 "${curl_args[@]}")
        fi
        
        # PUT/POST 请求添加数据体
        if [[ -n "$data" ]] && [[ "$method" != "GET" ]] && [[ "$method" != "DELETE" ]]; then
            curl_args+=(-d "$data")
        fi
        
        local response
        response=$(curl "${curl_args[@]}")
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
            echo "$body"
            return 0
        elif [ "$http_code" = "429" ]; then
            # 【修复】速率限制，指数退避，并递增重试计数器
            retry=$((retry + 1))
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

# HTTP GET 请求（带重试）
http_get() {
    _http_request "GET" "$1" "${2:-}"
}

# HTTP PUT 请求（带重试）
http_put() {
    _http_request "PUT" "$1" "$2"
}

# HTTP POST 请求（带重试）
http_post() {
    _http_request "POST" "$1" "$2"
}

# 【新增】HTTP DELETE 请求（带重试）
http_delete() {
    _http_request "DELETE" "$1" "${2:-}"
}

# ==================== 【智能判断】是否需要更新 DNS 记录 ====================
# 参数：$1=现有 IP 数组名, $2=目标 IP 数组名
# 返回：0=需要更新，1=无需更新
needs_update() {
    local -n _existing="$1"  # 现有 IP 数组（nameref）
    local -n _target="$2"    # 目标 IP 数组（nameref）
    
    # 数量不同，肯定需要更新
    if [[ ${#_existing[@]} -ne ${#_target[@]} ]]; then
        return 0  # 需要更新
    fi
    
    # 构建现有 IP 的关联数组（集合）
    local -A _existing_set=()
    for ip in "${_existing[@]}"; do
        # 清理空白字符
        local clean_ip
        clean_ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        _existing_set["$clean_ip"]=1
    done
    
    # 检查目标 IP 是否都在现有集合中
    for ip in "${_target[@]}"; do
        local clean_ip
        clean_ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "${_existing_set[$clean_ip]+x}" ]]; then
            return 0  # 发现新 IP，需要更新
        fi
    done
    
    return 1  # 集合完全相同，无需更新
}

# ==================== API 调用函数 ====================

# 从文件读取优选 IP
get_cf_ip_from_file() {
    if [ ! -f "$IP_FILE" ]; then
        log "${RED}错误${NC}: IP 文件不存在: ${IP_FILE}"
        log "   请创建文件或修改 cf-dns.json 中的配置"
        return 1
    fi
    
    # 【修复】移除死代码缓存逻辑（原逻辑无论文件是否变化都继续执行，毫无意义）
    # 如果需要实现真正的缓存，应该返回缓存内容并 return，但当前设计不需要缓存
    
    # 读取文件内容,支持多种格式:
    # 1. 每行一个 IP
    # 2. 逗号分隔的 IP
    # 3. 空格分隔的 IP
    # 4. 混合分隔符
    local content
    # 【性能优化】使用单次 awk 替代 4 个管道 + 4 次 fork
    content=$(awk '!/^#/ && !/^$/ { gsub(/#.*/, ""); gsub(/,/, " "); printf "%s ", $0 }' "$IP_FILE" | sed 's/ $//')
    
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
    
    # 【优化】单次 jq 提取所有 A 类型记录的 id 和 content，避免 N+1 次 fork
    echo "$response" | jq -r '
        .result[] | select(.type == "A") | "\(.id)|\(.content)"
    ' 2>/dev/null
}

# 更新 DNS 记录
update_dns_record() {
    local record_id="$1"
    local name="$2"
    local cf_ip="$3"
    
    local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"
    # 【修复】显式指定 proxied=false，避免 Cloudflare API 重置为默认值
    local data="{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${cf_ip}\",\"proxied\":false}"
    
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
    
    # 【修复】使用 http_delete 替代直接调用 curl，支持重试和统一错误处理
    local response
    response=$(http_delete "$url")
    
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
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e " 域名: ${full_domain}"
    echo -e " IP限制: ${MAX_IPS_PER_RECORD} 个/记录"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
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
        # 【性能优化】使用关联数组去重，时间复杂度从 O(n²) 降低到 O(n)
        local -A seen_ips=()  # 关联数组用于快速查找
        local -a unique_ips=()
        local -a duplicate_ips=()
        
        for ip in "${ip_addresses[@]}"; do
            # 检查是否已存在（关联数组查找为 O(1)）
            if [[ -z "${seen_ips[$ip]+x}" ]]; then
                # 首次出现，添加到唯一列表
                seen_ips["$ip"]=1
                unique_ips+=("$ip")
            else
                # 重复出现，添加到重复列表
                duplicate_ips+=("$ip")
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
    
    # 3. 【重构】智能同步逻辑：删除、更新、创建
    local -a ips_to_update=()
    local -a update_record_ids=()
        
    # 【重构】清晰的分支结构，避免脆弱的嵌套依赖
    if needs_update current_values ip_addresses; then
        log "  ${CYAN}[INFO]${NC} 检测到 IP 变化，开始更新..."
            
        # 情况 1：有现有记录且有待同步的 IP → 执行智能匹配更新
        if [ "$record_count" -gt 0 ] && [ ${#ip_addresses[@]} -gt 0 ]; then
            # 【修复】使用集合差异算法，避免位置依赖导致的遗漏
            # 找出可以直接保留的记录（IP 相同）
            local -a matched_indices=()
            local -a used_target_indices=()  # 跟踪已使用的目标 IP 索引
                
            for ((i=0; i<record_count; i++)); do
                local existing_ip="${current_values[$i]}"
                local clean_existing
                clean_existing=$(echo "$existing_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    
                # 在目标列表中查找匹配的 IP
                for ((j=0; j<${#ip_addresses[@]}; j++)); do
                    # 跳过已使用的目标 IP
                    local is_used=false
                    for ui in "${used_target_indices[@]}"; do
                        if [ "$ui" -eq "$j" ]; then
                            is_used=true
                            break
                        fi
                    done
                    [ "$is_used" = true ] && continue
                        
                    local target_ip="${ip_addresses[$j]}"
                    local clean_target
                    clean_target=$(echo "$target_ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        
                    if [ "$clean_existing" = "$clean_target" ]; then
                        matched_indices+=("$i")
                        used_target_indices+=("$j")
                        skipped_count=$((skipped_count + 1))
                        break
                    fi
                done
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
                    
                # 找到一个未被使用的目标 IP 来更新这条记录
                for ((j=0; j<${#ip_addresses[@]}; j++)); do
                    # 跳过已使用的目标 IP
                    local is_used=false
                    for ui in "${used_target_indices[@]}"; do
                        if [ "$ui" -eq "$j" ]; then
                            is_used=true
                            break
                        fi
                    done
                    [ "$is_used" = true ] && continue
                        
                    # 将这个目标 IP 分配给当前记录
                    ips_to_update+=("${ip_addresses[$j]}")
                    update_record_ids+=("${record_ids[$i]}")
                    used_target_indices+=("$j")
                    break
                done
            done
        fi
            
        # 执行更新
        if [ ${#ips_to_update[@]} -gt 0 ]; then
            log "  ${CYAN}⟳${NC} 更新 ${#ips_to_update[@]} 条记录..."
                
            # 构建完整域名用于 API 调用
            local full_dns_name
            full_dns_name=$(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")
                
            local total=${#ips_to_update[@]}
            for ((i=0; i<total; i++)); do
                local target_ip="${ips_to_update[$i]}"
                local record_id="${update_record_ids[$i]}"
                    
                # 【功能增强】显示进度
                printf "\r  [%d/%d] 正在更新 %s..." "$((i+1))" "$total" "$target_ip"
                    
                local update_result
                update_result=$(update_dns_record "$record_id" "$full_dns_name" "$target_ip")
                    
                if [[ "$update_result" == success* ]]; then
                    updated_count=$((updated_count + 1))
                else
                    echo ""  # 换行
                    log "    ${RED}[ERROR]${NC} 更新失败: ${target_ip}"
                fi
            done
            echo ""  # 换行
            log "  [OK] 已更新 ${updated_count} 条记录"
        elif [ "$record_count" -gt 0 ] && [ ${#ip_addresses[@]} -gt 0 ]; then
            # 【修复】无需更新，所有 IP 已存在且相同
            log_success "所有 IP 已存在且相同，无需更新"
            skipped_count=${#ip_addresses[@]}
        fi
    else
        # 无需更新，所有 IP 已存在
        if [ "$record_count" -eq "${#ip_addresses[@]}" ]; then
            log "  ${GREEN}[OK]${NC} 所有 IP 已存在，无需更新"
            skipped_count=${#ip_addresses[@]}
        else
            log "  ${YELLOW}[WARN]${NC} 未执行任何操作，但记录数 (${record_count}) 与目标 IP 数 (${#ip_addresses[@]}) 不一致"
            log "  ${YELLOW}[WARN]${NC} 这可能是 API 查询失败导致，请检查配置和网络连接"
        fi
    fi
    
    # 4. 【重构】独立于 needs_update 的创建逻辑
    # 计算需要创建的 IP 数量：总 IP 数 - 已有记录数
    local remaining_ips=$((${#ip_addresses[@]} - record_count))
    if [ "$remaining_ips" -gt 0 ]; then
        log "  ${GREEN}⟳${NC} 创建 ${remaining_ips} 条新记录..."
            
        # 构建完整域名用于 API 调用
        local full_dns_name
        full_dns_name=$(build_full_domain "$CF_DNS_NAME" "$CF_DOMAIN")
            
        local total=${#ip_addresses[@]}
        for ((i=record_count; i<total; i++)); do
            local target_ip="${ip_addresses[$i]}"
                
            # 【功能增强】显示进度
            printf "\r  [%d/%d] 正在创建 %s..." "$((i+1-record_count))" "$remaining_ips" "$target_ip"
                
            local create_result
            create_result=$(create_dns_record "$full_dns_name" "$target_ip")
                
            if [[ "$create_result" == success* ]]; then
                created_count=$((created_count + 1))
            else
                echo ""  # 换行
                log "    ${RED}[ERROR]${NC} 创建失败: ${target_ip}"
                # 提取错误信息
                local error_msg
                error_msg=$(echo "$create_result" | sed 's/^failed://' | jq -r '.errors[0].message' 2>/dev/null)
                if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
                    log "    ${RED}[详情]${NC} ${error_msg}"
                fi
            fi
        done
        echo ""  # 换行
        if [ "$created_count" -gt 0 ]; then
            log "  [OK] 已创建 ${created_count} 条记录"
        else
            log "  ${RED}[ERROR]${NC} 所有记录创建失败，请检查 API 配置和网络连接"
            exit 1
        fi
    fi
    
    # 输出总结（简化）
    log ""
    log "${CYAN}结果汇总:${NC} 跳过 ${skipped_count} | 新建 ${created_count} | 删除 ${deleted_count}"
    log ""
    
    # 【功能增强】记录 DNS 更新历史
    record_dns_update_history "$DOMAIN_NAME" "$updated_count" "$created_count" "$deleted_count"
    log_info "已记录 DNS 更新历史到 conf/history.jsonl"
}

# 执行主函数
main
