#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - Cloudflare DNS 配置向导 (Setup Wizard)
# Version: 0.1
# Description: 引导用户完成 API 令牌、Zone ID 及域名记录的交互式配置
# Usage: bash modules/cf-dns/setup.sh
# ==============================================================================
# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 入口校验与路径初始化 ====================

# 【安全修复】检测非 TTY 环境，防止在 cron 中阻塞
if [[ ! -t 0 ]] && [[ -z "${CF_OPT_ENTRY:-}" ]]; then
    echo -e "${RED}[ERROR] 此脚本需要交互式终端，请通过 cfopt 菜单运行${NC}"
    echo -e "${YELLOW}[提示] 正确用法: cfopt -> 3. CF-DNS 管理 -> 1. 配置向导${NC}"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==================== 菜单框线样式 ====================
MENU_BORDER="+------------------------------------------------------------+"
MENU_BORDER_MID="+------------------------------------------------------------+"
MENU_BORDER_BOTTOM="+------------------------------------------------------------+"

# ==================== 进程锁管理 ====================

# 检查并获取锁
acquire_lock() {
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}[ERROR] 另一个实例正在运行，无法获取锁${NC}"
        echo -e "${YELLOW}提示: 如果确定没有运行，请删除 ${LOCK_FILE}${NC}"
        exit 1
    fi
    # 锁会在脚本退出时自动释放（fd 9 关闭）
}

# 释放锁（flock 会自动释放，此函数保留用于兼容性）
release_lock() {
    rm -f "$LOCK_FILE"
}

# ==================== 路径初始化 ====================

# 获取根目录 (如果之前没定义)
if [ -z "$ROOT_DIR" ]; then
    SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# 配置文件路径（必须在 ROOT_DIR 定义之后）
# 支持多域名配置：优先使用 conf/cf-dns/{domain}.json，否则使用 conf/cf-dns.json
# 注意：此变量仅在菜单显示时使用，实际运行时由 core.sh 动态加载
CONFIG_FILE="$ROOT_DIR/conf/cf-dns.json"
LOCK_FILE="$ROOT_DIR/modules/cf-dns/.setup_cfdns.lock"

# 自动检测配置文件（支持多域名）
auto_detect_config_file() {
    local cf_dns_dir="${ROOT_DIR}/conf/cf-dns"
    
    # 如果存在多域名配置目录
    if [[ -d "${cf_dns_dir}" ]]; then
        # 查找所有 .json 文件
        local json_files
        json_files=$(find "${cf_dns_dir}" -maxdepth 1 -name "*.json" -type f 2>/dev/null)
        
        if [[ -n "${json_files}" ]]; then
            # 如果有多个文件，使用第一个
            local first_file
            first_file=$(echo "${json_files}" | head -n 1)
            CONFIG_FILE="${first_file}"
            return 0
        fi
    fi
    
    # 如果没有多域名配置，检查单文件配置
    if [[ -f "${ROOT_DIR}/conf/cf-dns.json" ]]; then
        CONFIG_FILE="${ROOT_DIR}/conf/cf-dns.json"
        return 0
    fi
    
    # 没有找到任何配置文件
    return 1
}

# 启动时自动检测配置文件
auto_detect_config_file || true

# 显示主菜单
show_menu() {
    clear
    
    # 获取当前时间和状态
    local NOW
    NOW=$(date "+%Y-%m-%d %H:%M:%S")
    local status_text=""
    local dns_info=""
    
    if [ -f "$CONFIG_FILE" ]; then
        # 从 JSON 读取配置
        local cf_dns_name
        local cf_domain
        cf_dns_name=$(jq -r '.dns.record_name // empty' "$CONFIG_FILE" 2>/dev/null)
        cf_domain=$(jq -r '.dns.domain // empty' "$CONFIG_FILE" 2>/dev/null)
        
        # 构建完整域名显示
        local full_domain=""
        if [ -z "$cf_dns_name" ] || [ "$cf_dns_name" = "your_dns_name_here" ]; then
            full_domain="${RED}未设置${NC}"
        elif echo "$cf_dns_name" | grep -q '\.'; then
            # 检测到格式错误
            full_domain="${RED}${cf_dns_name}${NC} ${YELLOW}(格式错误)${NC}"
        elif [ "$cf_dns_name" = "@" ]; then
            # 根域名 - 使用配置文件中的域名
            if [ -n "$cf_domain" ]; then
                full_domain="${CYAN}${cf_domain}${NC} (根域名)"
            else
                full_domain="${CYAN}根域名${NC}"
            fi
        else
            # 子域名 - 使用配置文件中的域名
            if [ -n "$cf_domain" ]; then
                full_domain="${GREEN}${cf_dns_name}.${cf_domain}${NC}"
            else
                full_domain="${GREEN}${cf_dns_name}${NC}.${CYAN}您的域名${NC}"
            fi
        fi
        
        dns_info=" ${CYAN}DNS记录: ${full_domain}${NC}"
        status_text="${GREEN}[OK] 已配置${NC}"
    else
        status_text="${RED}[ERROR] 未配置${NC} | 请先运行完整配置向导"
    fi
    
    echo -e "${CYAN}${MENU_BORDER}${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e " 当前时间: ${NOW}"
    if [ -n "$dns_info" ]; then
        echo -e "$dns_info"
    fi
    echo -e " ${GREEN}状态: ${status_text}${NC}"
    echo -e "${CYAN}${MENU_BORDER_MID}${NC}"
    echo -e " ${GREEN}➤${NC} 1. 完整配置向导     ${CYAN}- 新手推荐，一步步引导你完成设置${NC}"
    echo -e " ${GREEN}➤${NC} 2. 快速运行         ${CYAN}- 立即执行一次 DNS 更新任务${NC}"
    echo -e " ${GREEN}➤${NC} 3. 查看当前配置     ${CYAN}- 检查已填写的 API 和域名信息${NC}"
    echo -e " ${GREEN}➤${NC} 4. 启用/禁用模块    ${CYAN}- 控制是否自动同步 IP 及更新 DNS${NC}"
    echo -e " ${GREEN}➤${NC} 5. 手动同步优选 IP   ${CYAN}- 从测速结果中提取最优 IP 到数据文件${NC}"
    echo -e " ${GREEN}➤${NC} 6. 修改 IP 数量限制 ${CYAN}- 调整每条记录包含的 IP 个数${NC}"
    echo -e " ${GREEN}➤${NC} 7. 修改配置         ${CYAN}- 针对性修改某一项（如 Token）${NC}"
    echo -e " ${GREEN}➤${NC} 8. 日志管理         ${CYAN}- 查看运行结果或清理旧日志${NC}"
    echo -e " ${RED}➤${NC} 9. 删除配置         ${CYAN}- 彻底删除当前域名的所有配置${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 0. 退出程序"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}${NC}"
    echo ""
}

# 显示二级菜单 (修改配置)
show_modify_menu() {
    clear
    
    echo -e "${CYAN}${MENU_BORDER}${NC}"
    echo -e " ${YELLOW}修改配置 - 二级菜单${NC}"
    echo -e "${CYAN}${MENU_BORDER_MID}${NC}"
    echo -e " ${GREEN}➤${NC} 1. 全部重新配置   ${CYAN}- 像第一次安装那样重新走一遍流程${NC}"
    echo -e " ${GREEN}➤${NC} 2. API 配置       ${CYAN}- 更换令牌 (Token) 或区域 ID (Zone ID)${NC}"
    echo -e " ${GREEN}➤${NC} 3. DNS 记录名称   ${CYAN}- 修改子域名 (例如把 dns 改成 cf)${NC}"
    echo -e " ${GREEN}➤${NC} 4. IP 文件路径    ${CYAN}- 更改存放优选 IP 的文件位置${NC}"
    echo -e " ${GREEN}➤${NC} 5. 管理 IP 内容   ${CYAN}- 手动添加或删除具体的 IP 地址${NC}"
    echo -e " ${GREEN}➤${NC} 6. 超时和重试     ${CYAN}- 网络不好时可以调大这些数值${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 0. 返回主菜单"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}${NC}"
    echo ""
}

# ==================== 配置更新函数 ====================

# 通用 HTTP 请求函数 (带重试)
http_request() {
    local method="$1"
    local url="$2"
    local api_token="$3"
    local data="${4:-}"
    local max_retries="${5:-3}"
    local retry_count=0
    local response=""
    
    while [ "$retry_count" -lt "$max_retries" ]; do
        if [ "$method" = "GET" ]; then
            response=$(curl -s -w "\n%{http_code}" -X GET "$url" \
                -H "Authorization: Bearer ${api_token}" \
                -H "Content-Type: application/json" \
                --max-time 10)
        elif [ "$method" = "DELETE" ]; then
            response=$(curl -s -w "\n%{http_code}" -X DELETE "$url" \
                -H "Authorization: Bearer ${api_token}" \
                -H "Content-Type: application/json" \
                --max-time 10)
        elif [ "$method" = "PUT" ] || [ "$method" = "POST" ]; then
            response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
                -H "Authorization: Bearer ${api_token}" \
                -H "Content-Type: application/json" \
                -d "$data" \
                --max-time 10)
        fi
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')
        
        # 成功或客户端错误不需要重试
        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ] || [[ "$http_code" =~ ^4 ]]; then
            echo "$response"
            return 0
        fi
        
        # 服务器错误需要重试
        retry_count=$((retry_count + 1))
        if [ "$retry_count" -lt "$max_retries" ]; then
            echo -e "${YELLOW}[WARN] API 请求失败 (HTTP ${http_code}), 第 ${retry_count}/${max_retries} 次重试...${NC}" >&2
            sleep 2
        fi
    done
    
    # 所有重试都失败
    echo "$response"
    return 1
}

# JSON 字段提取函数 (使用 jq)
json_get() {
    local json="$1"
    local field="$2"
    
    # 使用 jq 解析
    echo "$json" | jq -r ".${field}" 2>/dev/null
}

# 日志脱敏函数
sanitize_log() {
    local message="$1"
    # 脱敏 API Token (保留前8位和后4位)
    echo "$message" | sed -E 's/([A-Za-z0-9]{8})[A-Za-z0-9]+([A-Za-z0-9]{4})/\1...\2/g'
}

# 结构化日志输出函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 脱敏消息
    local sanitized_msg
    sanitized_msg=$(sanitize_log "$message")
    
    case "$level" in
        "INFO")
            echo -e "${GREEN}[${timestamp}] [INFO] ${sanitized_msg}${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}[${timestamp}] [WARN] ${sanitized_msg}${NC}"
            ;;
        "ERROR")
            echo -e "${RED}[${timestamp}] [ERROR] ${sanitized_msg}${NC}"
            ;;
        "DEBUG")
            if [ "${DEBUG_MODE:-0}" = "1" ]; then
                echo -e "${CYAN}[${timestamp}] [DEBUG] ${sanitized_msg}${NC}"
            fi
            ;;
    esac
}

# 通过 API 获取 Zone 的域名名称
get_zone_name() {
    local zone_id="$1"
    local api_token="$2"
    
    # 使用通用 HTTP 请求函数
    local response
    response=$(http_request "GET" "https://api.cloudflare.com/client/v4/zones/${zone_id}" "$api_token")
    
    # 分离响应体和状态码
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    # 如果返回 400 且错误是 Invalid format for Authorization header，可能是 Global API Key
    if [ "$http_code" = "400" ] && echo "$body" | grep -q '"code":6111'; then
        echo "" >&2
        echo "检测到可能是 Global API Key，请重新生成 API Token" >&2
        echo "访问: https://dash.cloudflare.com/profile/api-tokens" >&2
        echo "选择 '编辑区域 DNS' 模板创建新的 API Token" >&2
        echo ""
        return 1
    fi
    
    # 检查 HTTP 状态码
    if [ "$http_code" != "200" ]; then
        echo "" >&2
        echo "错误: API 返回 HTTP $http_code" >&2
        if echo "$body" | grep -q '"message"'; then
            local error_msg
            error_msg=$(json_get "$body" "message")
            echo "详情: $error_msg" >&2
        fi
        echo ""
        return 1
    fi
    
    # 解析 JSON 获取 name 字段
    if echo "$body" | grep -q '"success":true'; then
        local zone_name
        zone_name=$(json_get "$body" "name")
        echo "$zone_name"
    else
        echo "" >&2
        echo "错误: API 返回失败" >&2
        if echo "$body" | grep -q '"message"'; then
            local error_msg
            error_msg=$(json_get "$body" "message")
            echo "详情: $error_msg" >&2
        fi
        echo ""
        return 1
    fi
}

# ==================== 配置向导函数 ====================

# 完整配置向导
full_config_wizard() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}Cloudflare DNS 完整配置向导${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    # 1. API Token
    echo -e "${BLUE}步骤 1/6: 配置 API 令牌 (API Token)${NC}"
    echo ""
    echo -e "${YELLOW}[WARN] 重要提示：${NC}"
    echo -e "  ${RED}请务必使用 API 令牌，不要使用 Global API Key！${NC}"
    echo -e "  ${RED}两者长度相同但格式不同，混用会导致鉴权失败！${NC}"
    echo ""
    echo -e "${CYAN}如何获取 API 令牌（3步搞定）：${NC}"
    echo "  1. 访问: https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. 点击 '创建令牌' -> 选择 '编辑区域 DNS' 模板"
    echo "  3. 在 '区域资源' 选中你的域名 -> 复制生成的令牌"
    echo ""
    echo -e "${YELLOW}API 令牌示例：${NC} cfut_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx ${GREEN}[正确]${NC}"
    echo -e "${YELLOW}Global API Key 示例：${NC} xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx ${RED}[错误]${NC}"
    echo ""
    echo -e "${CYAN}[提示]${NC} 令牌需要包含以下权限："
    echo -e "  • Zone - DNS - Edit（编辑 DNS 记录）"
    echo -e "  • Zone - Zone - Read（读取域名列表）"
    echo ""
    # 【安全修复】使用 -s 静默模式，不回显 API Token
    echo -e "${CYAN}请输入 CF_API_TOKEN（输入不会显示在屏幕上）:${NC}"
    read -rs cf_api_token
    echo ""  # read -s 不会换行，手动换行
    
    # 【功能增强】支持返回上一步
    if [[ "$cf_api_token" == "b" ]] || [[ "$cf_api_token" == "B" ]]; then
        echo -e "${YELLOW}[INFO] 返回主菜单${NC}"
        return 2  # 特殊返回值表示用户主动返回
    fi
    
    if [ -z "$cf_api_token" ]; then
        echo -e "${RED}错误: API Token 不能为空${NC}"
        echo -e "${YELLOW}[提示] 输入 'b' 可返回上一步${NC}"
        read -r -p "按回车键重新输入，或输入 'b' 返回..." retry_choice
        if [[ "$retry_choice" == "b" ]] || [[ "$retry_choice" == "B" ]]; then
            return 2
        fi
        return 1
    fi
    
    # 简单验证令牌格式
    if [[ ${#cf_api_token} -lt 20 ]]; then
        echo -e "${RED}错误: API Token 长度异常${NC}"
        echo -e "${YELLOW}请检查是否正确复制了完整的令牌${NC}"
        read -r -p "按回车键继续..."
        return 1
    fi
    
    # 验证 API Token 并获取域名列表
    echo -e "${CYAN}正在验证 API Token...${NC}"
    local zones_response
    zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
        -H "Authorization: Bearer ${cf_api_token}" \
        -H "Content-Type: application/json")
    
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    local zones_count
    zones_count=$(echo "$zones_response" | jq -r '.result_info.total_count // 0')
    
    if [[ "$zones_count" == "0" ]]; then
        echo -e "${RED}[ERROR] API Token 无效或没有可用的域名${NC}"
        echo -e "${YELLOW}请检查：${NC}"
        echo -e "  1. API Token 是否正确"
        echo -e "  2. Token 是否有 'Zone - DNS - Edit' 权限"
        read -r -p "按回车键重新输入..."
        return 1
    fi
    
    echo -e "${GREEN}[OK] 找到 ${zones_count} 个域名${NC}"
    echo ""
    
    # 【新增】API Token 权限说明
    echo -e "${YELLOW}[重要说明]${NC}"
    echo -e "  ${YELLOW}⚠ 此处显示的域名是基于您当前 API Token 的权限范围${NC}"
    echo -e "  ${YELLOW} Cloudflare 支持精细化令牌权限，一个令牌可能只能操作部分域名${NC}"
    echo -e "  ${YELLOW} 如果此处未显示您的全部域名，请检查 API Token 权限设置${NC}"
    echo ""
    echo -e "${GRAY}如需操作其他域名，请重新创建包含该域名权限的 API Token${NC}"
    echo ""
    
    # 显示域名列表（带编号）
    echo -e "${CYAN}可用域名列表：${NC}"
    local domain_array=()
    local index=1
    while IFS= read -r line; do
        local domain_name
        domain_name=$(echo "$line" | awk '{print $1}')
        echo -e " ${GREEN}${index})${NC} ${line}"
        domain_array+=("$domain_name")
        ((index++))
    done <<< "$(echo "$zones_response" | jq -r '.result[] | "\(.name) (Zone ID: \(.id))"' | head -n 10)"
    if [[ "$zones_count" -gt 10 ]]; then
        echo -e "  ... 还有 $((zones_count - 10)) 个域名"
    fi
    echo ""
    
    # 2. 选择域名（自动获取 Zone ID）
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${BLUE}步骤 2/6: 选择要配置的域名${NC}"
    echo ""
    echo -e "${YELLOW}[说明]${NC}"
    echo -e "  系统已自动获取您的所有域名，请选择要配置的域名。"
    echo -e "  选择后，系统将自动匹配对应的 Zone ID。"
    echo ""
    read -r -p "请选择域名 [1-$((index-1))] 或直接输入域名: " cf_domain_input
    
    # 【功能增强】支持返回上一步
    if [[ "$cf_domain_input" == "b" ]] || [[ "$cf_domain_input" == "B" ]]; then
        echo -e "${YELLOW}[INFO] 返回上一步（重新输入 API Token）${NC}"
        return 2
    fi
    
    local cf_domain
    if [[ "$cf_domain_input" =~ ^[0-9]+$ ]] && [[ "$cf_domain_input" -ge 1 ]] && [[ "$cf_domain_input" -lt "$index" ]]; then
        # 用户选择了编号
        cf_domain="${domain_array[$((cf_domain_input-1))]}"
        echo -e "${GREEN}[OK] 已选择: ${cf_domain}${NC}"
    else
        # 用户手动输入域名
        cf_domain="$cf_domain_input"
    fi
    
    if [ -z "$cf_domain" ]; then
        echo -e "${RED}错误: 域名不能为空${NC}"
        echo -e "${YELLOW}[提示] 输入 'b' 可返回上一步${NC}"
        read -r -p "按回车键重新输入，或输入 'b' 返回..." retry_choice
        if [[ "$retry_choice" == "b" ]] || [[ "$retry_choice" == "B" ]]; then
            return 2
        fi
        return 1
    fi
    
    # 从 API 响应中获取 Zone ID
    local cf_zone_id
    cf_zone_id=$(echo "$zones_response" | jq -r --arg domain "$cf_domain" '.result[] | select(.name == $domain) | .id')
    
    if [[ -z "$cf_zone_id" ]]; then
        echo -e "${RED}[ERROR] 未找到域名: ${cf_domain}${NC}"
        echo -e "${YELLOW}请确认域名拼写是否正确${NC}"
        read -r -p "按回车键重新输入..."
        return 1
    fi
    
    echo -e "${GREEN}[OK] 域名验证成功: ${cf_domain}${NC}"
    echo -e "${CYAN}Zone ID: ${cf_zone_id:0:8}...${cf_zone_id: -4}${NC}"
    echo ""
    
    # 3. DNS 名称
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${BLUE}步骤 3/6: 配置 DNS 记录名称 (主机记录)${NC}"
    echo ""
    echo -e "${YELLOW}[WARN] 新手必读:${NC}"
    echo -e "  ${RED}这里只填子域名部分，不要填完整域名！${NC}"
    echo ""
    echo -e "${CYAN}填写示例:${NC}"
    echo -e "  - 想解析到 ${BOLD}dns.example.com${NC} -> 请输入: ${GREEN}dns${NC}"
    echo -e "  - 想解析到 ${BOLD}cf.example.com${NC} -> 请输入: ${GREEN}cf${NC}"
    echo -e "  - 想解析到根域名 ${BOLD}example.com${NC} -> 请输入: ${GREEN}@${NC}"
    echo ""
    read -r -p "请输入 DNS 记录名称 (例如 dns、cf 或 @): " cf_dns_name
    
    # 【功能增强】支持返回上一步
    if [[ "$cf_dns_name" == "b" ]] || [[ "$cf_dns_name" == "B" ]]; then
        echo -e "${YELLOW}[INFO] 返回上一步（重新选择域名）${NC}"
        return 2
    fi
    
    if [ -z "$cf_dns_name" ]; then
        echo -e "${RED}错误: DNS 记录名称不能为空${NC}"
        echo -e "${YELLOW}[提示] 输入 'b' 可返回上一步${NC}"
        read -r -p "按回车键重新输入，或输入 'b' 返回..." retry_choice
        if [[ "$retry_choice" == "b" ]] || [[ "$retry_choice" == "B" ]]; then
            return 2
        fi
        return 1
    fi
    
    # 验证 DNS 名称格式
    if echo "$cf_dns_name" | grep -q '\.'; then
        echo -e "${RED}错误: 检测到点号 (.)，请不要填写完整域名！${NC}"
        echo -e "${YELLOW}正确做法:${NC}"
        if echo "$cf_dns_name" | grep -q '^@'; then
            echo -e "  如果要解析根域名，请输入: ${GREEN}@${NC}"
        else
            # 提取第一个点号前的部分
            local subdomain
            subdomain=$(echo "$cf_dns_name" | cut -d'.' -f1)
            echo -e "  你的子域名是: ${GREEN}${subdomain}${NC}"
            echo -e "  请输入: ${GREEN}${subdomain}${NC}"
        fi
        read -r -p "按回车键重新输入..."
        return 1
    fi
    
    # 验证只能包含合法字符
    if [ "$cf_dns_name" != "@" ] && ! [[ "$cf_dns_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo -e "${RED}错误: DNS 记录名称格式无效${NC}"
        echo "只能使用字母、数字、连字符(-)和下划线(_)，或使用 @ 表示根域名"
        read -r -p "按回车键重新输入..."
        return 1
    fi
    
    # 4. 选择测速节点
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${BLUE}步骤 4/6: 选择测速节点（地区）${NC}"
    echo ""
    echo -e "${YELLOW}[说明]${NC}"
    echo -e "  选择距离您服务器较近的地区可获得更优的延迟"
    echo ""
    echo -e " ${GREEN}常用节点推荐：${NC}"
    echo -e "   1. 香港 + 东京 (HKG,NRT)          - 亚洲通用推荐"
    echo -e "   2. 新加坡 + 东京 (SIN,NRT)         - 东南亚优化"
    echo -e "   3. 洛杉矶 + 旧金山 (LAX,SJC)       - 北美优化"
    echo -e "   4. 法兰克福 + 伦敦 (FRA,LON)       - 欧洲优化"
    echo -e "   5. 悉尼 + 东京 (SYD,NRT)           - 大洋洲优化"
    echo ""
    echo -e " ${GRAY}其他选项：${NC}"
    echo -e "   6. 自动检测（默认 HKG,NRT）"
    echo -e "   7. 自定义节点（手动输入）"
    echo ""
    
    echo -ne "${CYAN}请选择 [1-7] (默认 1):${NC} "
    read -r colo_choice
    colo_choice=${colo_choice:-1}
    
    local recommended_colo
    case "$colo_choice" in
        1) recommended_colo="HKG,NRT" ;;
        2) recommended_colo="SIN,NRT" ;;
        3) recommended_colo="LAX,SJC" ;;
        4) recommended_colo="FRA,LON" ;;
        5) recommended_colo="SYD,NRT" ;;
        6) recommended_colo="HKG,NRT" ;;
        7)
            echo ""
            echo -e "${YELLOW}请输入 IATA 机场代码，多个用逗号分隔${NC}"
            echo -e "${GRAY}示例: HKG,NRT,LAX 或 SIN,TYO,FRA${NC}"
            echo -e "${GRAY}常见代码: HKG(香港) NRT/TYO(东京) SIN(新加坡) LAX(洛杉矶) SJC(旧金山) FRA(法兰克福) LON(伦敦) SYD(悉尼)${NC}"
            echo -ne "${CYAN}请输入节点代码:${NC} "
            read -r custom_colo
            if [[ -z "$custom_colo" ]]; then
                echo -e "${YELLOW}[WARN] 未输入，使用默认值 HKG,NRT${NC}"
                recommended_colo="HKG,NRT"
            else
                # 转换为大写并去除空格
                recommended_colo=$(echo "$custom_colo" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
            fi
            ;;
        *)
            echo -e "${YELLOW}[WARN] 无效选择，使用默认值 HKG,NRT${NC}"
            recommended_colo="HKG,NRT"
            ;;
    esac
    
    echo -e "${GREEN}[OK] 已选择测速节点: ${recommended_colo}${NC}"
    echo ""
    
    # 5. IP 数量限制
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${BLUE}步骤 5/6: 配置 IP 数量限制${NC}"
    echo ""
    echo -e "${YELLOW}说明:${NC}"
    echo "  - 这个数值决定了你的域名一次能解析到多少个 IP。"
    echo "  - 建议设置为 2-4 个。IP 并非越多越好，数量过多反而容易解析到质量较差的节点。"
    echo "  - 速度才是硬道理：保留少量经过测速的最优 IP，体验会更稳定。"
    echo ""
    echo "默认: 2"
    read -r -p "请输入限制数量 (直接回车使用默认): " max_ips
    
    # 【功能增强】支持返回上一步
    if [[ "$max_ips" == "b" ]] || [[ "$max_ips" == "B" ]]; then
        echo -e "${YELLOW}[INFO] 返回上一步（重新选择测速节点）${NC}"
        return 2
    fi
    
    max_ips=${max_ips:-"2"}
    
    # 创建配置文件（按域名独立存储）
    echo ""
    echo -e "${GREEN}正在创建配置文件...${NC}"
    
    # 创建多域名配置目录
    local config_dir="${ROOT_DIR}/conf/cf-dns"
    mkdir -p "$config_dir"
    
    # 构建完整域名（用于文件名）
    local full_domain
    if [[ "$cf_dns_name" == "@" ]]; then
        full_domain="$cf_domain"
    else
        full_domain="${cf_dns_name}.${cf_domain}"
    fi
    
    # 配置文件路径：conf/cf-dns/{full_domain}.json
    CONFIG_FILE="${config_dir}/${full_domain}.json"
    
    # 按域名独立存储 IP 列表和测速结果
    # 【功能增强】使用 .iplist 标准格式（推荐），同时兼容 .txt
    local ip_file="${ROOT_DIR}/assets/data/cf-dns/${full_domain}.iplist"
    local result_file="${ROOT_DIR}/assets/data/cf-ip/result_${full_domain}.csv"
    
    # 使用 jq 直接生成配置
    local temp_file
    temp_file=$(mktemp)
    
    jq -n \
        --arg domain "$cf_domain" \
        --arg token "$cf_api_token" \
        --arg zone_id "$cf_zone_id" \
        --arg record_name "$cf_dns_name" \
        --arg ip_file "${ip_file}" \
        --arg result_file "${result_file}" \
        --arg colo_nodes "$recommended_colo" \
        --argjson max_ips "$max_ips" \
        '{
            "_comment": "Cloudflare DNS 更新器配置",
            "_version": "0.1",
            "enabled": true,
            "api": {
                "token": $token,
                "zone_id": $zone_id
            },
            "dns": {
                "domain": $domain,
                "record_name": $record_name,
                "record_type": "A",
                "ttl": 600,
                "max_ips_per_record": $max_ips
            },
            "ip_source": {
                "file_path": $ip_file,
                "result_file": $result_file,
                "colo_nodes": $colo_nodes
            }
        }' > "$temp_file"
    
    mv "$temp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    
    echo -e "${GREEN}[OK] Cloudflare DNS 配置已生成: ${CONFIG_FILE}${NC}"
    
    # 6. 确认配置信息
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}Cloudflare DNS 完整配置向导 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${BLUE}步骤 6/6: 确认配置信息${NC}"
    echo ""
    
    echo -e "${CYAN}配置摘要：${NC}"
    echo -e "  • 完整域名: ${GREEN}${full_domain}${NC}"
    echo -e "  • 主机记录: ${GREEN}${cf_dns_name}${NC}"
    echo -e "  • 根域名: ${GREEN}${cf_domain}${NC}"
    echo -e "  • Zone ID: ${GREEN}${cf_zone_id:0:8}...${cf_zone_id: -4}${NC}"
    echo -e "  • 测速节点: ${GREEN}${recommended_colo}${NC}"
    echo -e "  • IP 文件: ${GREEN}${ip_file}${NC}"
    echo -e "  • IP 数量: ${GREEN}${max_ips}${NC}"
    echo ""
    
    # 【功能增强】提供返回上一步选项
    echo -e "${YELLOW}[提示]${NC} 如果配置有误，可以输入 'b' 返回上一步修改"
    read -r -p "按回车键保存配置，或输入 'b' 返回上一步: " confirm_choice
    
    if [[ "$confirm_choice" == "b" ]] || [[ "$confirm_choice" == "B" ]]; then
        echo -e "${YELLOW}[INFO] 返回上一步（重新配置 IP 数量）${NC}"
        return 2
    fi
    
    # 创建 IP 数据目录
    mkdir -p "$(dirname "$ip_file")"
    
    # 如果 IP 文件不存在,创建示例
    if [ ! -f "$ip_file" ]; then
        cat > "$ip_file" << 'EOF'
# Cloudflare 优选 IP 列表
# 
# 说明:
#   - 此文件由 CF-IP 优选程序自动生成 (modules/cf-ip/core.sh)
#   - 也可以手动添加已知的高速 IP
#   - 以 # 开头的行为注释，会被忽略
#
# 支持的格式:
#   1. 每行一个 IP
#   2. 逗号分隔: 1.2.3.4,5.6.7.8
#   3. 空格分隔: 1.2.3.4 5.6.7.8
#
# 示例 IP (请替换为实际测速结果):
104.16.132.229
104.16.133.229
EOF
        echo -e "${GREEN}[OK] 已创建示例 IP 文件: ${ip_file}${NC}"
        echo -e "${YELLOW}[提示]${NC} 建议运行 CF-IP 优选程序获取最优 IP" >&2
    fi
    
    # 自动验证配置格式
    echo ""
    echo -e "${CYAN}正在验证配置格式...${NC}"
    local config_valid=true
    local warnings=()
    
    # 检查 API Token 格式
    if [ ${#cf_api_token} -lt 20 ]; then
        warnings+=("API Token 长度异常 (${#cf_api_token} 字符)，建议检查是否正确复制")
        config_valid=false
    fi
    
    # 检查 Zone ID 格式（应该是 32 位十六进制字符串）
    if ! [[ "$cf_zone_id" =~ ^[a-f0-9]{32}$ ]]; then
        warnings+=("Zone ID 格式可能不正确，应该是 32 位十六进制字符串")
        config_valid=false
    fi
    
    # 检查 DNS 名称是否包含点号（常见错误）
    if echo "$cf_dns_name" | grep -q '\.'; then
        warnings+=("DNS 记录名称不应包含点号，请只填写子域名部分")
        config_valid=false
    fi
    
    # 检查 IP 文件路径
    if [[ "$ip_file" != /* ]] && [[ "$ip_file" != ./* ]]; then
        warnings+=("IP 文件路径建议使用绝对路径或以 ./ 开头的相对路径")
    fi
    
    # 输出验证结果
    if [ ${#warnings[@]} -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} 配置格式检查通过"
    else
        echo -e "  ${YELLOW}⚠${NC} 发现以下潜在问题:"
        for warning in "${warnings[@]}"; do
            echo -e "    ${YELLOW}- ${warning}${NC}"
        done
        echo ""
        echo -e "  ${YELLOW}提示:${NC} 如果确认配置无误，可以忽略以上警告"
    fi
    
    echo ""
    echo -e "${GREEN}[OK] 配置完成!${NC}"
    echo -e "配置文件已保存到: ${CONFIG_FILE}"
    echo ""
    
    # 询问是否执行首次测速
    echo -e "${CYAN}提示:${NC} 您已完成首次配置"
    echo -e "  - IP 文件: ${ip_file}"
    echo -e "  - 测速节点: ${recommended_colo}"
    echo ""
    
    read -r -p "是否立即执行首次测速？[Y/n] (默认 Y): " run_test
    run_test=${run_test:-Y}
    
    if [[ "$run_test" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}提示: 首次测速可能需要 2-5 分钟，请耐心等待...${NC}"
        echo ""
        cd "${ROOT_DIR}" || return 1
        
        # 【临时】创建 cf-ip.json 配置文件（如果不存在）
        local cf_ip_config="${ROOT_DIR}/conf/cf-ip.json"
        if [[ ! -f "$cf_ip_config" ]]; then
            echo -e "${CYAN}正在创建 CF-IP 基础配置...${NC}"
            mkdir -p "${ROOT_DIR}/conf"
            
            # 使用 jq 安全地生成 JSON 配置文件
            local temp_file
            temp_file=$(mktemp)
            
            jq -n '{
                "_comment": "CF-IP 优选程序配置",
                "_version": "0.1",
                "enabled": true,
                "cfst": {
                    "directory": "./assets/cfst",
                    "binary": "cfst",
                    "threads": 200,
                    "colo": "HKG,NRT",
                    "ping_times": 4,
                    "download_count": 10,
                    "download_time": 10,
                    "port": 443,
                    "url": "https://cf-ns.com/cdn-cgi/trace",
                    "httping": false,
                    "latency_max": 9999,
                    "packet_loss_max": 100,
                    "speed_min": 0,
                    "show_count": 20,
                    "ip_file": "",
                    "disable_download": false,
                    "all_ip": false
                },
                "speed_test": {
                    "take_ip_num": 5,
                    "output_html": true,
                    "max_retry": 3,
                    "enable_log": true
                },
                "paths": {
                    "output_dir": "./assets/data/cf-ip",
                    "log_dir": "./logs/cf-ip"
                }
            }' > "$temp_file"
            
            mv "$temp_file" "$cf_ip_config"
            chmod 600 "$cf_ip_config"
            echo -e "${GREEN}[OK] CF-IP 基础配置已创建${NC}"
            echo ""
        fi
        
        # 为当前域名生成独立的测速结果文件（使用静默模式，不显示标题栏）
        CF_OPT_ENTRY=scheduler bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${recommended_colo}" "${result_file}" "${full_domain}" 2>&1 | grep -v "^+" | grep -v "项目仓库" | grep -v "启动时间" | grep -v "^$" || true
        echo -e "${GREEN}[OK] 测速完成${NC}"
        echo ""
        
        # 执行 IP 同步，将测速结果同步到 DNS 模块的 IP 文件（静默模式）
        echo -e "${CYAN}正在同步 IP 数据...${NC}"
        bash "${ROOT_DIR}/modules/ip-sync/sync.sh" 2>&1 | grep -v "^+" | grep -v "项目仓库" | grep -v "^$" || true
        echo -e "${GREEN}[OK] IP 数据已同步到: ${ip_file}${NC}"
    fi
    
    echo ""
    read -r -p "按回车键继续..."
}

# 查看当前配置
view_config() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}当前配置${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    local cf_api_token cf_zone_id cf_dns_name cf_domain ip_file max_ips request_timeout max_retries
    
    cf_api_token=$(jq -r '.api.token // empty' "$CONFIG_FILE")
    cf_zone_id=$(jq -r '.api.zone_id // empty' "$CONFIG_FILE")
    cf_dns_name=$(jq -r '.dns.record_name // empty' "$CONFIG_FILE")
    cf_domain=$(jq -r '.dns.domain // empty' "$CONFIG_FILE")
    ip_file=$(jq -r '.ip_source.file_path // empty' "$CONFIG_FILE")
    max_ips=$(jq -r '.dns.max_ips_per_record // 2' "$CONFIG_FILE")
    request_timeout=$(jq -r '.api.timeout // 10' "$CONFIG_FILE")
    max_retries=$(jq -r '.api.max_retries // 5' "$CONFIG_FILE")
        
        # 显示核心配置
        echo -e "${BLUE}API 配置:${NC}"
        if [ -n "$cf_api_token" ]; then
            local token_display="${cf_api_token:0:8}...${cf_api_token: -4}"
            echo "  CF_API_TOKEN = ${token_display}"
        else
            echo "  CF_API_TOKEN = ${RED}未设置${NC}"
        fi
        echo "  CF_ZONE_ID   = ${cf_zone_id:-${RED}未设置${NC}}"
        echo ""
        
        # 显示 DNS 记录信息
        echo -e "${BLUE}DNS 记录配置:${NC}"
        
        if [ "$cf_dns_name" = "@" ]; then
            echo "  CF_DNS_NAME  = @ (根域名)"
            if [ -n "$cf_domain" ]; then
                echo "  完整域名   = ${cf_domain}"
            else
                echo "  完整域名   = 你的域名（如 example.com）"
            fi
        elif [ -n "$cf_dns_name" ]; then
            echo "  CF_DNS_NAME  = ${cf_dns_name}"
            if [ -n "$cf_domain" ]; then
                echo "  完整域名   = ${cf_dns_name}.${cf_domain}"
            else
                echo "  完整域名   = ${cf_dns_name}.你的域名 (如 ${cf_dns_name}.example.com)"
            fi
        else
            echo "  CF_DNS_NAME  = ${RED}未设置${NC}"
        fi
        
        if [ -n "$cf_domain" ]; then
            echo "  CF_DOMAIN    = ${cf_domain} (自动获取)"
        fi
        echo ""
        
        # 显示 IP 文件配置
        echo -e "${BLUE}IP 文件配置:${NC}"
        echo "  IP_FILE      = ${ip_file:-${RED}未设置${NC}}"
        if [ -n "$ip_file" ] && [ -f "$ip_file" ]; then
            local ip_count
            # 【修复】使用 grep -v 过滤后 wc -l 计数，避免管道逻辑错误
            ip_count=$(grep -v '^\s*#' "$ip_file" | grep -v '^\s*$' | wc -l)
            ip_count="${ip_count// /}"  # 去除 wc -l 可能的前导空格
            echo "  当前 IP 数量 = ${ip_count} 个"
        else
            echo "  当前 IP 数量 = 文件不存在"
        fi
        echo ""
        
        # 显示其他配置
        echo -e "${BLUE}其他配置:${NC}"
        echo "  IP 数量限制   = ${max_ips} 个/记录"
        echo "  请求超时时间  = ${request_timeout} 秒"
        echo "  最大重试次数  = ${max_retries} 次"
    echo -e "${CYAN}提示:${NC}"
    echo "  - 使用 '7) 修改配置' 可以修改任意配置项"
    echo "  - 使用 '2) 快速运行' 可以立即执行 DNS 更新"
    
    echo ""
    read -r -p "按回车键继续..."
}

# 修改 IP 数量限制
modify_ip_limit() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}修改 IP 数量限制${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    # 使用 jq 读取当前值
    local current_limit
    current_limit=$(jq -r '.dns.max_ips_per_record // 2' "$CONFIG_FILE")
    
    echo -e "${CYAN}当前限制: ${current_limit} 个IP/记录${NC}"
    echo ""
    echo -e "${YELLOW}说明:${NC}"
    echo "  - 设置每条 DNS 记录最多包含几个 IP 地址"
    echo "  - 例如: 设置为 2，则每个域名最多解析到 2 个 IP"
    echo "  - 设置为 0 表示不限制（需要套餐支持）"
    echo ""
    read -r -p "请输入新的限制 (0=不限制, 直接回车保持 ${current_limit}): " new_limit
    
    if [ -n "$new_limit" ] && [[ "$new_limit" =~ ^[0-9]+$ ]]; then
        local temp_file
        temp_file=$(mktemp)
        jq --argjson limit "$new_limit" '.dns.max_ips_per_record = $limit' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}[OK] IP 数量限制已更新为: ${new_limit}${NC}"
    else
        echo -e "${RED}错误: 请输入有效的数字${NC}"
    fi
    
    echo ""
    read -r -p "按回车键继续..."
}

# 启用/禁用模块
toggle_module_status() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}启用/禁用模块${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    # 使用 jq 读取当前状态
    local current_status
    current_status=$(jq -r '.enabled // false' "$CONFIG_FILE")
    
    if [ "$current_status" = "true" ]; then
        echo -e "${GREEN}当前状态: ${BOLD}已启用${NC}"
        echo ""
        echo -e "${YELLOW}功能说明:${NC}"
        echo "  - IP 同步组件会自动将测速结果写入此模块"
        echo "  - DNS 更新任务会正常执行"
        echo ""
        read -r -p "是否禁用此模块? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            local temp_file
            temp_file=$(mktemp)
            jq '.enabled = false' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            echo -e "${GREEN}[OK] 模块已禁用${NC}"
            echo -e "${CYAN}提示:${NC} IP 同步和 DNS 更新将跳过此模块"
        fi
    else
        echo -e "${RED}当前状态: ${BOLD}已禁用${NC}"
        echo ""
        echo -e "${YELLOW}功能说明:${NC}"
        echo "  - IP 同步组件不会为此模块写入 IP"
        echo "  - DNS 更新任务不会执行"
        echo ""
        read -r -p "是否启用此模块? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            local temp_file
            temp_file=$(mktemp)
            jq '.enabled = true' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            echo -e "${GREEN}[OK] 模块已启用${NC}"
            echo -e "${CYAN}提示:${NC} 下次测速后将自动同步 IP 并支持 DNS 更新"
        fi
    fi
    
    echo ""
    read -r -p "按回车键继续..."
}

# 管理 IP 内容
manage_ip_content() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}管理 IP 内容${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    # shellcheck disable=SC1090
    local ip_file
    ip_file=$(jq -r '.ip_source.file_path // empty' "$CONFIG_FILE")
    if [ -z "$ip_file" ]; then
        ip_file="$ROOT_DIR/assets/data/cf-dns/ip_list.iplist"
    fi
    
    echo "当前 IP 文件: ${ip_file}"
    echo ""
    
    if [ -f "$ip_file" ]; then
        # 读取并展平所有IP(支持逗号和换行分隔)
        local all_ips
        all_ips=$(cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local ip_count
        ip_count=$(echo "$all_ips" | wc -l)
        echo "当前 IP 数量: ${ip_count}"
        echo ""
        echo "IP 列表 (每行一个):"
        echo "$all_ips" | nl -ba
    else
        echo -e "${RED}[ERROR] IP 文件不存在${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}➤${NC} 1. 输入/编辑 IP "
    echo -e "  ${GREEN}➤${NC} 2. 清空所有 IP"
    echo -e "  ${GREEN}➤${NC} 3. 查看完整列表"
    echo -e "  ${GREEN}➤${NC} 4. 删除指定 IP"
    echo ""
    echo -e "  ${RED}➤${NC} 0. 返回主菜单"
    echo ""
    read -r -p "  请输入选项 [0-4]: " action
    
    case "$action" in
        1)
            # 输入/编辑 IP
            clear
            if [ -f "$ip_file" ]; then
                local old_count
                # 【修复】使用 grep -v 过滤后 wc -l 计数，避免管道逻辑错误
                old_count=$(grep -v '^\s*#' "$ip_file" | grep -v '^\s*$' | wc -l)
                old_count="${old_count// /}"  # 去除 wc -l 可能的前导空格
                echo ""
                echo -e "${CYAN}检测到现有文件 (${old_count} 个 IP)${NC}"
                echo ""
                echo -e "${CYAN}请选择操作:${NC}"
                echo ""
                echo -e "  ${GREEN}➤${NC} 1. 覆盖     ${YELLOW}[备份后清空]${NC}"
                echo -e "  ${GREEN}➤${NC} 2. 追加     ${YELLOW}[在现有基础上添加]${NC}"
                echo -e "  ${GREEN}➤${NC} 3. 清空     ${RED}[备份后删除所有]${NC}"
                echo -e "  ${GREEN}➤${NC} 4. 跳过     ${CYAN}[取消操作]${NC}"
                echo ""
                read -r -p "  请输入选项 [1-4, 默认 1]: " choice
                choice=${choice:-1}
                
                case "$choice" in
                    1)
                        cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                        echo -e "\n  ${GREEN}[OK]${NC} 已备份旧文件"
                        echo -e "  ${YELLOW}[WARN]${NC} 将清空现有内容，准备输入新 IP"
                        true > "$ip_file"
                        ;;
                    2)
                        echo -e "\n  ${GREEN}[INFO]${NC} 提示: 将在现有 ${old_count} 个 IP 后追加"
                        ;;
                    3)
                        cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                        true > "$ip_file"
                        echo -e "\n  ${GREEN}[OK]${NC} 已清空文件 (已备份)"
                        echo -e "  ${YELLOW}[WARN]${NC} 所有 IP 已删除，准备输入新 IP"
                        ;;
                    4)
                        echo -e "\n  ${CYAN}[INFO]${NC} 已取消操作"
                        read -r -p "  按回车键继续..."
                        return 0
                        ;;
                esac
            fi
            
            echo ""
            echo -e "${CYAN}请输入 IP 地址 (支持格式: 每行一个 或 逗号分隔):${NC}"
            echo "示例: 162.159.44.225,162.159.39.71"
            echo "      或每行一个 IP"
            echo "空行结束输入"
            echo ""
            
            local temp_file
            temp_file=$(mktemp)
            local valid_count=0
            
            while IFS= read -r line; do
                [ -z "$line" ] && break
                
                # 将逗号、分号分隔转换为换行，并逐个验证
                echo "$line" | tr ',;' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | while read -r ip; do
                    # 实时验证 IP 格式
                    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        # 进一步验证每个段是否 <= 255
                        local valid=true
                        IFS='.' read -ra octets <<< "$ip"
                        for octet in "${octets[@]}"; do
                            if [ "$octet" -gt 255 ] 2>/dev/null; then
                                valid=false
                                break
                            fi
                        done
                        
                        if [ "$valid" = true ]; then
                            echo "$ip" >> "$temp_file"
                            echo -e "  ${GREEN}[OK]${NC} $ip"
                        else
                            echo -e "  ${RED}[ERROR]${NC} $ip ${YELLOW}(无效的 IP 地址)${NC}"
                        fi
                    else
                        echo -e "  ${RED}[ERROR]${NC} $ip ${YELLOW}(格式错误)${NC}"
                    fi
                done
            done
            
            # 统计结果
            if [ -s "$temp_file" ]; then
                valid_count=$(wc -l < "$temp_file")
            fi
            
            # 追加到目标文件
            if [ -s "$temp_file" ]; then
                cat "$temp_file" >> "$ip_file"
                chmod 644 "$ip_file"
                
                local new_count
                # 【修复】使用 grep -v 过滤后 wc -l 计数，避免管道逻辑错误
                new_count=$(grep -v '^\s*#' "$ip_file" | grep -v '^\s*$' | wc -l)
                new_count="${new_count// /}"  # 去除 wc -l 可能的前导空格
                echo ""
                echo -e "${GREEN}[OK] 已保存 ${valid_count} 个有效 IP${NC}"
                echo -e "   当前总 IP 数: ${new_count}"
            else
                echo ""
                echo -e "${YELLOW}[INFO] 未输入任何有效 IP${NC}"
            fi
            
            rm -f "$temp_file"
            ;;
        2)
            # 清空
            clear
            if [ -f "$ip_file" ]; then
                cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                true > "$ip_file"
                echo -e "${GREEN}[OK] 已清空所有 IP (已备份)${NC}"
            else
                echo -e "${YELLOW}[INFO] 文件不存在,无需清空${NC}"
            fi
            ;;
        3)
            # 查看
            clear
            if [ -f "$ip_file" ]; then
                echo ""
                echo "完整 IP 列表:"
                cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | nl -ba
            else
                echo -e "${RED}[ERROR] 文件不存在${NC}"
            fi
            ;;
        4)
            # 删除指定 IP
            clear
            if [ ! -f "$ip_file" ]; then
                echo -e "${RED}[ERROR] 文件不存在${NC}"
                read -r -p "按回车键继续..."
                return 0
            fi
            
            local all_ips
            all_ips=$(cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local ip_count
            ip_count=$(echo "$all_ips" | wc -l)
            
            if [ "$ip_count" -eq 0 ]; then
                echo -e "${YELLOW}[INFO] 文件中没有 IP${NC}"
                read -r -p "按回车键继续..."
                return 0
            fi
            
            echo ""
            echo "当前 IP 列表:"
            echo "$all_ips" | nl -ba
            echo ""
            echo "请输入要删除的 IP 行号 (多个行号用空格分隔):"
            echo "例如: 2 或 1 3 5"
            echo ""
            read -r -p "请输入行号: " delete_lines
            
            if [ -z "$delete_lines" ]; then
                echo -e "${YELLOW}[INFO] 未输入,取消删除${NC}"
                read -r -p "按回车键继续..."
                return 0
            fi
            
            # 验证输入是否为数字(允许多个数字用空格分隔)
            if ! [[ "$delete_lines" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
                echo -e "${RED}[ERROR] 无效的行号格式,请输入数字(多个用空格分隔)${NC}"
                read -r -p "按回车键继续..."
                return 0
            fi
            
            # 验证行号是否在有效范围内
            local lines_to_delete_arr
            mapfile -t lines_to_delete_arr <<< "$delete_lines"
            for del_line in "${lines_to_delete_arr[@]}"; do
                if [ "$del_line" -lt 1 ] || [ "$del_line" -gt "$ip_count" ]; then
                    echo -e "${RED}[ERROR] 行号 ${del_line} 超出范围 (1-${ip_count})${NC}"
                    read -r -p "按回车键继续..."
                    return 0
                fi
            done
            
            # 备份原文件
            cp "$ip_file" "${ip_file}.bak.$(date +%s)"
            echo -e "${GREEN}[OK] 已备份原文件${NC}"
            
            # 将行号转换为数组
            local lines_to_delete
            mapfile -t lines_to_delete <<< "$delete_lines"
            
            # 构建新的IP列表(排除要删除的行)
            local new_ips=""
            local line_num=0
            while IFS= read -r ip; do
                line_num=$((line_num + 1))
                local should_delete=false
                for del_line in "${lines_to_delete[@]}"; do
                    if [ "$line_num" -eq "$del_line" ]; then
                        should_delete=true
                        break
                    fi
                done
                
                if [ "$should_delete" = false ]; then
                    if [ -n "$new_ips" ]; then
                        new_ips="${new_ips}
${ip}"
                    else
                        new_ips="$ip"
                    fi
                fi
            done <<< "$all_ips"
            
            # 写入新文件
            echo "$new_ips" > "$ip_file"
            chmod 644 "$ip_file"
            
            local deleted_count=${#lines_to_delete[@]}
            local remaining_count
            # 【修复】使用 grep -v 过滤后 wc -l 计数，避免管道逻辑错误
            remaining_count=$(grep -v '^\s*#' "$ip_file" | grep -v '^\s*$' | wc -l)
            remaining_count="${remaining_count// /}"  # 去除 wc -l 可能的前导空格
            echo -e "${GREEN}[OK] 已删除 ${deleted_count} 个 IP,剩余 ${remaining_count} 个${NC}"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    echo ""
    read -r -p "按回车键继续..."
}

# 日志管理
log_management() {
    clear
    echo -e "${CYAN}+--------------------------------------------------+"
    echo -e " ${YELLOW}日志管理${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
    
    local log_dir="$ROOT_DIR/logs/cf-dns"
    
    if [ ! -d "$log_dir" ]; then
        echo -e "${YELLOW}日志目录不存在${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    local log_count
    log_count=$(find "$log_dir" -name "cfdns_*.log" 2>/dev/null | wc -l)
    
    if [ "$log_count" -eq 0 ]; then
        echo -e "${YELLOW}暂无日志文件${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    echo "找到 ${log_count} 个日志文件"
    echo ""
    echo -e "${CYAN}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}➤${NC} 1. 查看最新日志"
    echo -e "  ${GREEN}➤${NC} 2. 查看所有日志列表"
    echo -e "  ${GREEN}➤${NC} 3. 清理旧日志     ${YELLOW}[保留最近7天]${NC}"
    echo -e "  ${GREEN}➤${NC} 4. 清空所有日志   ${RED}[危险操作]${NC}"
    echo ""
    echo -e "  ${RED}➤${NC} 0. 返回主菜单"
    echo ""
    read -r -p "  请输入选项 [0-4]: " choice
    
    case $choice in
        1)
            clear
            local latest_log
            latest_log=$(find "$log_dir" -name "cfdns_*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
            if [ -n "$latest_log" ]; then
                echo -e "${BLUE}最新日志: $(basename "$latest_log")${NC}"
                echo "----------------------------------------"
                tail -n 50 "$latest_log"
                echo "----------------------------------------"
            fi
            echo ""
            read -r -p "按回车键继续..."
            ;;
        2)
            clear
            echo -e "${BLUE}日志文件列表:${NC}"
            find "$log_dir" -name "cfdns_*.log" -type f -exec ls -lt {} + 2>/dev/null
            echo ""
            read -r -p "按回车键继续..."
            ;;
        3)
            clear
            echo -e "${YELLOW}将删除7天前的日志文件...${NC}"
            read -r -p "确认? (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                find "$log_dir" -name "cfdns_*.log" -mtime +7 -delete
                echo -e "${GREEN}[OK] 旧日志已清理${NC}"
            fi
            echo ""
            read -r -p "按回车键继续..."
            ;;
        4)
            clear
            echo -e "${RED}警告: 这将删除所有日志文件!${NC}"
            read -r -p "确认? (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                find "$log_dir" -name "cfdns_*.log" -type f -delete
                echo -e "${GREEN}[OK] 所有日志已清空${NC}"
            fi
            echo ""
            read -r -p "按回车键继续..."
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            echo ""
            read -r -p "按回车键继续..."
            ;;
    esac
}

# 删除配置
delete_config() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${BOLD}${RED}删除 Cloudflare DNS 配置${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}[INFO] 配置文件不存在，无需删除${NC}"
        echo ""
        read -r -p "按回车键继续..."
        return
    fi
    
    # 读取配置信息
    local domain_name record_name full_domain
    domain_name=$(jq -r '.dns.domain // "unknown"' "$CONFIG_FILE")
    record_name=$(jq -r '.dns.record_name // "@"' "$CONFIG_FILE")
    
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain_name"
    else
        full_domain="${record_name}.${domain_name}"
    fi
    
    echo -e "${RED}⚠ 警告：此操作将彻底删除以下配置：${NC}"
    echo ""
    echo -e "  • 完整域名: ${RED}${full_domain}${NC}"
    echo -e "  • 配置文件: ${RED}${CONFIG_FILE}${NC}"
    
    # 检查关联的 IP 文件
    local ip_file
    ip_file=$(jq -r '.ip_source.file_path // empty' "$CONFIG_FILE")
    if [[ -n "$ip_file" ]] && [[ -f "$ip_file" ]]; then
        echo -e "  • IP 数据文件: ${RED}${ip_file}${NC}"
    fi
    
    # 检查关联的测速结果文件
    local result_file
    result_file=$(jq -r '.ip_source.result_file // empty' "$CONFIG_FILE")
    if [[ -n "$result_file" ]] && [[ -f "$result_file" ]]; then
        echo -e "  • 测速结果文件: ${RED}${result_file}${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}注意：${NC}"
    echo -e "  - 此操作不可恢复！"
    echo -e "  - 不会删除系统级组件（如 crontab、wget 等）"
    echo -e "  - 建议先备份重要数据"
    echo ""
    
    # 【安全修复】重定向到 /dev/tty，确保从终端读取输入
    local input_device="/dev/tty"
    if [[ -e "${input_device}" ]]; then
        read -r -p "确认要删除吗？(输入 yes 确认): " CONFIRM_DELETE < "${input_device}"
    else
        # 非交互式环境，禁止自动删除（安全措施）
        CONFIRM_DELETE="no"
        echo -e "${RED}[ERROR] 非交互式环境，禁止自动删除。请手动执行删除。${NC}"
        read -r -p "按回车键返回主菜单..." < "${input_device}" 2>/dev/null || true
        return
    fi
    
    if [[ "$CONFIRM_DELETE" != "yes" ]]; then
        echo -e "${CYAN}[INFO] 已取消删除操作${NC}"
        echo ""
        read -r -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    echo -e "${CYAN}正在删除配置...${NC}"
    
    # 1. 删除配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo -e "  ${GREEN}[OK]${NC} 已删除配置文件: ${CONFIG_FILE}"
    fi
    
    # 2. 删除 IP 数据文件
    if [[ -n "$ip_file" ]] && [[ -f "$ip_file" ]]; then
        rm -f "$ip_file"
        echo -e "  ${GREEN}[OK]${NC} 已删除 IP 数据文件: ${ip_file}"
    fi
    
    # 3. 删除测速结果文件
    if [[ -n "$result_file" ]] && [[ -f "$result_file" ]]; then
        rm -f "$result_file"
        echo -e "  ${GREEN}[OK]${NC} 已删除测速结果文件: ${result_file}"
    fi
    
    # 4. 删除部署记录（如果存在）
    local deploy_record_file="${ROOT_DIR}/modules/quick-deploy/deploy_record.json"
    if [[ -f "$deploy_record_file" ]] && command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        if jq --arg d "$domain_name" '.domains = [.domains[] | select(.domain != $d)]' \
           "$deploy_record_file" > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$deploy_record_file"
            chmod 600 "$deploy_record_file"
            echo -e "  ${GREEN}[OK]${NC} 已从部署记录中移除: ${domain_name}"
        else
            rm -f "$temp_file"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}[OK] 配置已彻底删除！${NC}"
    echo ""
    
    # 重置 CONFIG_FILE，让 auto_detect_config_file 重新检测
    CONFIG_FILE="$ROOT_DIR/conf/cf-dns.json"
    auto_detect_config_file || true
    
    read -r -p "按回车键返回主菜单..."
}

# 修改配置二级菜单
modify_config_menu() {
    while true; do
        show_modify_menu
        
        read -r -p "请选择 (0-6): " choice
        
        case $choice in
            1)
                full_config_wizard
                ;;
            2)
                # 修改 API 配置
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
                    read -r -p "按回车键继续..."
                    continue
                fi
                
                echo ""
                echo -e "${CYAN}━━ 修改 API 配置 ━━${NC}"
                echo ""
                
                # 读取当前值
                local cf_api_token cf_zone_id
                cf_api_token=$(jq -r '.api.token // empty' "$CONFIG_FILE")
                cf_zone_id=$(jq -r '.api.zone_id // empty' "$CONFIG_FILE")
                
                echo "当前 CF_API_TOKEN: ${cf_api_token:0:8}...${cf_api_token: -4}"
                # 【安全修复】使用 -s 静默模式，不回显 API Token
                echo -e "${CYAN}请输入新的 CF_API_TOKEN (留空保持不变，输入不会显示):${NC}"
                read -rs new_token
                echo ""
                if [ -n "$new_token" ]; then
                    local temp_file
                    temp_file=$(mktemp)
                    jq --arg token "$new_token" '.api.token = $token' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    echo -e "${GREEN}[OK] CF_API_TOKEN 已更新${NC}"
                    cf_api_token="$new_token"
                fi
                
                echo "当前 CF_ZONE_ID: ${cf_zone_id}"
                read -r -p "请输入新的 CF_ZONE_ID (留空保持不变): " new_zone
                if [ -n "$new_zone" ]; then
                    local temp_file
                    temp_file=$(mktemp)
                    jq --arg zone_id "$new_zone" '.api.zone_id = $zone_id' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    echo -e "${GREEN}[OK] CF_ZONE_ID 已更新${NC}"
                    cf_zone_id="$new_zone"
                    
                    # 如果 API Token 或 Zone ID 有变化，重新获取域名
                    if [ -n "$new_token" ] || [ -n "$new_zone" ]; then
                        echo ""
                        echo -e "${YELLOW}正在重新获取域名信息...${NC}"
                        local api_token="$new_token"
                        [ -z "$api_token" ] && api_token="$cf_api_token"
                        local zone_id="$new_zone"
                        [ -z "$zone_id" ] && zone_id="$cf_zone_id"
                        
                        local zone_name
                        zone_name=$(get_zone_name "$zone_id" "$api_token")
                        if [ -n "$zone_name" ]; then
                            local temp_file
                            temp_file=$(mktemp)
                            jq --arg domain "$zone_name" '.dns.domain = $domain' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                            chmod 600 "$CONFIG_FILE"
                            echo -e "${GREEN}[OK] 已更新域名: ${zone_name}${NC}"
                        else
                            echo -e "${YELLOW}[WARN] 无法获取域名，请手动修改配置文件${NC}"
                        fi
                    fi
                fi
                
                echo ""
                read -r -p "按回车键继续..."
                ;;
            3)
                # 修改 DNS 记录名称
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
                    read -r -p "按回车键继续..."
                    continue
                fi
                
                echo ""
                echo -e "${CYAN}━━ 修改 DNS 记录名称 ━━${NC}"
                echo ""
                
                # 读取当前值
                local cf_dns_name
                cf_dns_name=$(jq -r '.dns.record_name // empty' "$CONFIG_FILE")
                
                echo "当前记录名称: ${cf_dns_name}"
                echo ""
                echo -e "${YELLOW}使用说明:${NC}"
                echo -e "  - 如果最终域名是 ${BOLD}dns.example.com${NC}，填 ${GREEN}dns${NC}"
                echo -e "  - 如果最终域名是 ${BOLD}cf.example.com${NC}，填 ${GREEN}cf${NC}"
                echo -e "  - 如果最终域名是 ${BOLD}example.com${NC}（根域名），填 ${GREEN}@${NC}"
                echo ""
                read -r -p "请输入新的 DNS 记录名称 (留空保持不变): " new_dns
                if [ -n "$new_dns" ]; then
                    # 验证输入
                    if [ "$new_dns" = "@" ] || [[ "$new_dns" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
                        local temp_file
                        temp_file=$(mktemp)
                        jq --arg dns_name "$new_dns" '.dns.record_name = $dns_name' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"
                        echo -e "${GREEN}[OK] CF_DNS_NAME 已更新为: ${new_dns}${NC}"
                        if [ "$new_dns" = "@" ]; then
                            echo -e "${YELLOW}提示: 这将更新根域名的 A 记录${NC}"
                        else
                            echo -e "${YELLOW}提示: 这将更新 ${new_dns}.你的域名 的 A 记录${NC}"
                        fi
                    else
                        echo -e "${RED}错误: 无效的记录名称格式${NC}"
                        echo "只能使用字母、数字、连字符和下划线，或使用 @ 表示根域名"
                    fi
                fi
                
                echo ""
                read -r -p "按回车键继续..."
                ;;
            4)
                # 修改 IP 文件路径
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
                    read -r -p "按回车键继续..."
                    continue
                fi
                
                # 读取当前值
                local ip_file
                ip_file=$(jq -r '.ip_source.file_path // empty' "$CONFIG_FILE")
                
                echo "当前 IP_FILE: ${ip_file}"
                read -r -p "请输入新的 IP_FILE (留空保持不变): " new_ip_file
                if [ -n "$new_ip_file" ]; then
                    local temp_file
                    temp_file=$(mktemp)
                    jq --arg ip_file "$new_ip_file" '.ip_source.file_path = $ip_file' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    mkdir -p "$(dirname "$new_ip_file")"
                    echo -e "${GREEN}[OK] IP_FILE 已更新${NC}"
                fi
                
                echo ""
                read -r -p "按回车键继续..."
                ;;
            5)
                manage_ip_content
                ;;
            6)
                # 修改超时和重试
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo -e "${RED}配置文件不存在,请先运行完整配置向导${NC}"
                    read -r -p "按回车键继续..."
                    continue
                fi
                
                # 读取当前值
                local request_timeout max_retries
                request_timeout=$(jq -r '.api.timeout // 10' "$CONFIG_FILE")
                max_retries=$(jq -r '.api.max_retries // 5' "$CONFIG_FILE")
                
                echo -e "${CYAN}━━ 修改超时和重试设置 ━━${NC}"
                echo ""
                echo -e "${YELLOW}REQUEST_TIMEOUT (请求超时时间):${NC}"
                echo "  - 每次 API 请求等待响应的最长时间（秒）"
                echo "  - 当前值: ${request_timeout} 秒"
                echo "  - 建议值: 5-15 秒"
                read -r -p "请输入新的超时时间 (留空保持 ${request_timeout}): " new_timeout
                if [ -n "$new_timeout" ] && [[ "$new_timeout" =~ ^[0-9]+$ ]]; then
                    local temp_file
                    temp_file=$(mktemp)
                    jq --argjson timeout "$new_timeout" '.api.timeout = $timeout' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    echo -e "${GREEN}[OK] 请求超时已更新为 ${new_timeout} 秒${NC}"
                fi
                
                echo ""
                echo -e "${YELLOW}MAX_RETRIES (最大重试次数):${NC}"
                echo "  - API 请求失败后自动重试的次数"
                echo "  - 当前值: ${max_retries} 次"
                echo "  - 建议值: 2-5 次"
                read -r -p "请输入新的重试次数 (留空保持 ${max_retries}): " new_retries
                if [ -n "$new_retries" ] && [[ "$new_retries" =~ ^[0-9]+$ ]]; then
                    local temp_file
                    temp_file=$(mktemp)
                    jq --argjson retries "$new_retries" '.api.max_retries = $retries' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
                    chmod 600 "$CONFIG_FILE"
                    echo -e "${GREEN}[OK] 重试次数已更新为 ${new_retries} 次${NC}"
                fi
                
                echo ""
                read -r -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 域名选择菜单（支持多域名配置）
select_domain_menu() {
    local action_name="$1"  # 操作名称，如 "快速运行"、"查看配置" 等
    
    # 检查多域名配置目录
    local config_dir="${ROOT_DIR}/conf/cf-dns"
    local config_files=()
    
    if [[ -d "$config_dir" ]]; then
        while IFS= read -r -d '' config_file; do
            config_files+=("$config_file")
        done < <(find "$config_dir" -name "*.json" -type f -print0 2>/dev/null)
    fi
    
    # 如果没有找到配置，提示用户
    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${RED}[ERROR] 未找到任何 Cloudflare DNS 配置文件${NC}"
        echo ""
        echo -e "${YELLOW}请先完成配置:${NC}"
        echo "  1. 选择 '1) 完整配置向导' 进行配置"
        echo "  2. 或通过快速部署向导配置域名"
        echo ""
        read -r -p "是否现在运行配置向导? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            full_config_wizard
        fi
        return 1
    fi
    
    # 如果只有一个配置，直接返回
    if [[ ${#config_files[@]} -eq 1 ]]; then
        echo "${config_files[0]}"
        return 0
    fi
    
    # 多个配置，显示选择菜单
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}选择要${action_name}的域名${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    
    echo -e "${CYAN}已配置的域名列表：${NC}"
    echo ""
    local index=1
    local domain_array=()
    for config_file in "${config_files[@]}"; do
        local domain_name
        domain_name=$(basename "$config_file" .json)
        
        # 读取配置信息
        local record_name enabled
        record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
        enabled=$(jq -r '.enabled // false' "$config_file" 2>/dev/null)
        
        # 构建完整域名显示
        local full_domain
        if [[ "$record_name" == "@" ]]; then
            full_domain="$domain_name"
        else
            full_domain="${record_name}.${domain_name}"
        fi
        
        # 显示启用状态
        local status_label
        if [[ "$enabled" == "true" ]]; then
            status_label="${GREEN}[启用]${NC}"
        else
            status_label="${RED}[禁用]${NC}"
        fi
        
        echo -e " ${GREEN}${index})${NC} ${full_domain} ${status_label}"
        domain_array+=("$config_file")
        ((index++))
    done
    
    echo ""
    echo -e " ${RED}0)${NC} 返回上一级"
    echo ""
    
    read -r -p "请选择要${action_name}的域名 [0-$((index-1))]: " choice
    
    if [[ "$choice" == "0" ]]; then
        return 1
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$index" ]]; then
        echo "${domain_array[$((choice-1))]}"
        return 0
    else
        echo -e "${RED}[ERROR] 无效的选择${NC}"
        read -r -p "按回车键返回..."
        return 1
    fi
}

# ==================== 主程序 ====================

# 配置文件有效性检测
check_config_valid() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    
    # 读取配置值
    local cf_api_token cf_zone_id cf_dns_name
    cf_api_token=$(jq -r '.api.token // empty' "$CONFIG_FILE")
    cf_zone_id=$(jq -r '.api.zone_id // empty' "$CONFIG_FILE")
    cf_dns_name=$(jq -r '.dns.record_name // empty' "$CONFIG_FILE")
    
    local config_valid=true
    local missing_items=()
    local format_errors=()
    
    # 检测必需的配置项
    if [ -z "$cf_api_token" ] || [ "$cf_api_token" = "your_api_token_here" ]; then
        missing_items+=("CF_API_TOKEN")
        config_valid=false
    fi
    
    if [ -z "$cf_zone_id" ] || [ "$cf_zone_id" = "your_zone_id_here" ]; then
        missing_items+=("CF_ZONE_ID")
        config_valid=false
    fi
    
    if [ -z "$cf_dns_name" ] || [ "$cf_dns_name" = "your_dns_name_here" ]; then
        missing_items+=("CF_DNS_NAME")
        config_valid=false
    elif echo "$cf_dns_name" | grep -q '\.'; then
        # 检测到完整域名格式错误
        format_errors+=("CF_DNS_NAME 格式错误: 你填的是完整域名，应该只填子域名部分")
        config_valid=false
    fi
    
    # 如果配置不完整，提示用户
    if [ "$config_valid" = false ]; then
        echo -e "${YELLOW}[WARN] 检测到配置问题${NC}"
        echo ""
        
        if [ ${#missing_items[@]} -gt 0 ]; then
            echo -e "${RED}以下配置项需要填写:${NC}"
            for item in "${missing_items[@]}"; do
                echo -e "  - ${RED}${item}${NC}"
            done
            echo ""
        fi
        
        if [ ${#format_errors[@]} -gt 0 ]; then
            echo -e "${RED}以下配置项格式错误:${NC}"
            for error in "${format_errors[@]}"; do
                echo -e "  - ${RED}${error}${NC}"
            done
            if echo "$cf_dns_name" | grep -q '\.'; then
                local correct_subdomain
                correct_subdomain=$(echo "$cf_dns_name" | cut -d'.' -f1)
                echo -e "${YELLOW}  提示: 应该填写 '${correct_subdomain}' 而不是 '${cf_dns_name}'${NC}"
            fi
            echo ""
        fi
        
        echo -e "${YELLOW}建议运行完整配置向导进行配置${NC}"
        echo ""
        read -r -p "是否现在运行配置向导? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            full_config_wizard
            # 配置完成后继续执行主菜单循环
        fi
        echo ""
        return 1
    fi
    
    return 0
}

main() {
    # 获取进程锁，防止并发执行
    acquire_lock
    
    # 首次使用检测 - 如果配置文件不存在，自动进入配置向导
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}[WARN] 检测到首次使用，配置文件不存在${NC}"
        echo ""
        echo -e "${CYAN}您可以选择：${NC}"
        echo -e "  ${GREEN}1)${NC} 立即运行配置向导（推荐）"
        echo -e "  ${RED}0)${NC} 退出程序"
        echo ""
        read -r -p "请选择 [0-1] (默认 1): " first_choice
        first_choice=${first_choice:-1}
        
        if [[ "$first_choice" == "0" ]]; then
            echo -e "${CYAN}[INFO] 已取消配置${NC}"
            exit 0
        fi
        
        echo -e "${YELLOW}将自动启动配置向导...${NC}"
        echo ""
        sleep 2
        full_config_wizard
        # 配置完成后继续执行主菜单循环，而不是退出
    fi
    
    # 配置文件有效性检测
    check_config_valid
    
    # 检查是否有多个域名配置，如果有则先让用户选择
    local config_dir="${ROOT_DIR}/conf/cf-dns"
    local config_files=()
    
    if [[ -d "$config_dir" ]]; then
        while IFS= read -r -d '' config_file; do
            config_files+=("$config_file")
        done < <(find "$config_dir" -name "*.json" -type f -print0 2>/dev/null)
    fi
    
    # 如果有多个域名配置，显示域名选择菜单
    if [[ ${#config_files[@]} -gt 1 ]]; then
        clear
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo -e " ${YELLOW}Cloudflare DNS 更新器 - 选择域名${NC}"
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        
        echo -e "${CYAN}已配置的域名列表：${NC}"
        echo ""
        local index=1
        local domain_array=()
        for config_file in "${config_files[@]}"; do
            local domain_name
            domain_name=$(basename "$config_file" .json)
            
            # 读取配置信息
            local record_name enabled
            record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
            enabled=$(jq -r '.enabled // false' "$config_file" 2>/dev/null)
            
            # 构建完整域名显示
            local full_domain
            if [[ "$record_name" == "@" ]]; then
                full_domain="$domain_name"
            else
                full_domain="${record_name}.${domain_name}"
            fi
            
            # 显示启用状态
            local status_label
            if [[ "$enabled" == "true" ]]; then
                status_label="${GREEN}[启用]${NC}"
            else
                status_label="${RED}[禁用]${NC}"
            fi
            
            echo -e " ${GREEN}${index})${NC} ${full_domain} ${status_label}"
            domain_array+=("$config_file")
            ((index++))
        done
        
        echo ""
        echo -e " ${RED}0)${NC} 退出程序"
        echo ""
        
        read -r -p "请选择要操作的域名 [0-$((index-1))]: " choice
        
        if [[ "$choice" == "0" ]]; then
            exit 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$index" ]]; then
            # 设置选中的配置文件
            CONFIG_FILE="${domain_array[$((choice-1))]}"
        else
            echo -e "${RED}[ERROR] 无效的选择${NC}"
            read -r -p "按回车键退出..."
            exit 1
        fi
    fi
    
    # 进入主菜单循环
    while true; do
        # 每次显示菜单前重新检测配置文件（支持 quick-deploy 生成的配置）
        auto_detect_config_file || true
        show_menu
        
        read -r -p "请选择 (0-9): " choice
        
        case $choice in
            1)
                full_config_wizard
                ;;
            2)
                # 快速运行 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "快速运行")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 检测配置是否完整
                local cf_api_token cf_zone_id cf_dns_name
                cf_api_token=$(jq -r '.api.token // empty' "$selected_config")
                cf_zone_id=$(jq -r '.api.zone_id // empty' "$selected_config")
                cf_dns_name=$(jq -r '.dns.record_name // empty' "$selected_config")
                
                local config_ok=true
                
                if [ -z "$cf_api_token" ] || [ "$cf_api_token" = "your_api_token_here" ]; then
                    echo -e "${RED}[ERROR] CF_API_TOKEN 未配置${NC}"
                    config_ok=false
                fi
                
                if [ -z "$cf_zone_id" ] || [ "$cf_zone_id" = "your_zone_id_here" ]; then
                    echo -e "${RED}[ERROR] CF_ZONE_ID 未配置${NC}"
                    config_ok=false
                fi
                
                if [ -z "$cf_dns_name" ] || [ "$cf_dns_name" = "your_dns_name_here" ]; then
                    echo -e "${RED}[ERROR] CF_DNS_NAME 未配置${NC}"
                    config_ok=false
                fi
                
                if [ "$config_ok" = false ]; then
                    echo ""
                    echo -e "${YELLOW}请先完成所有必需配置项${NC}"
                    echo ""
                    read -r -p "是否现在运行配置向导? (y/n): " confirm
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        full_config_wizard
                    fi
                    continue
                fi
                
                local domain_name
                domain_name=$(basename "$selected_config" .json)
                echo -e "${CYAN}正在运行 Cloudflare DNS 更新器 (${domain_name})...${NC}"
                sleep 1
                chmod +x "$ROOT_DIR/modules/cf-dns/core.sh"
                CF_DNS_DOMAIN="$domain_name" bash "$ROOT_DIR/modules/cf-dns/core.sh" "$selected_config"
                
                echo ""
                read -r -p "按回车键继续..."
                ;;
            3)
                # 查看配置 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "查看配置")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 临时设置 CONFIG_FILE 并调用 view_config
                local original_config_file="$CONFIG_FILE"
                CONFIG_FILE="$selected_config"
                view_config
                CONFIG_FILE="$original_config_file"
                ;;
            4)
                # 启用/禁用模块 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "启用/禁用")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 临时设置 CONFIG_FILE 并调用 toggle_module_status
                local original_config_file="$CONFIG_FILE"
                CONFIG_FILE="$selected_config"
                toggle_module_status
                CONFIG_FILE="$original_config_file"
                ;;
            5)
                echo -e "${GREEN}正在调用 IP 同步组件...${NC}"
                bash "$ROOT_DIR/modules/ip-sync/sync.sh"
                echo ""
                read -r -p "按回车键继续..."
                ;;
            6)
                # 修改 IP 数量限制 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "修改 IP 数量限制")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 临时设置 CONFIG_FILE 并调用 modify_ip_limit
                local original_config_file="$CONFIG_FILE"
                CONFIG_FILE="$selected_config"
                modify_ip_limit
                CONFIG_FILE="$original_config_file"
                ;;
            7)
                # 修改配置 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "修改配置")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 临时设置 CONFIG_FILE 并调用 modify_config_menu
                local original_config_file="$CONFIG_FILE"
                CONFIG_FILE="$selected_config"
                modify_config_menu
                CONFIG_FILE="$original_config_file"
                ;;
            8)
                # 日志管理（不需要选择域名，因为日志是共享的）
                log_management
                ;;
            9)
                # 删除配置 - 先选择域名
                local selected_config
                selected_config=$(select_domain_menu "删除")
                if [[ $? -ne 0 ]]; then
                    continue
                fi
                
                # 临时设置 CONFIG_FILE 并调用 delete_config
                local original_config_file="$CONFIG_FILE"
                CONFIG_FILE="$selected_config"
                delete_config
                CONFIG_FILE="$original_config_file"
                ;;
            0)
                # 退出子菜单，返回 cfopt 主菜单
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 执行主函数
main
