#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - CF-IP 优选测速核心 (Core)
# Version: 0.1
# Description: 负责调用 cfst 程序进行 Cloudflare IP 测速并生成 result.csv
# Usage: bash modules/cf-ip/core.sh [COLO] [OUTPUT_CSV] [LINE_TAG]
#
# ==================== 环境变量契约 ====================
# 本模块依赖以下环境变量（由调用者设置）：
#
# 1. CFOPT_ROOT (可选)
#    - 来源：cfopt.sh 或 scheduler/run.sh
#    - 用途：指定项目根目录，优先于自动检测
#    - 默认：$(cd "$SCRIPT_DIR/../.." && pwd)
#    - 示例：export CFOPT_ROOT="/opt/cfopt"
#
# 2. CF_IP_CFG_LOADED (可选)
#    - 来源：scheduler/run.sh
#    - 用途：标识配置是否已由 scheduler 加载到环境变量
#    - 值："true" = 已加载，跳过配置文件读取；其他 = 未加载，从文件读取
#    - 默认：未设置或空字符串（从配置文件读取）
#    - 性能优化：避免多线路模式下重复读取 JSON 配置文件
#    - 示例：export CF_IP_CFG_LOADED="true"
#
# 3. CF_OPT_ENTRY (可选)
#    - 来源：cfopt.sh 或 scheduler/run.sh
#    - 用途：标识调用来源，用于日志记录和权限控制
#    - 值："main_menu" | "scheduler" | "run_sh" | 其他
#    - 默认：未设置或空字符串
#    - 示例：export CF_OPT_ENTRY="main_menu"
#
# ==================== 导出变量 ====================
# 本模块导出的变量（供子进程使用）：
#
# - ROOT_DIR: 项目根目录（绝对路径）
# - OUTPUT_DIR: 输出目录（绝对路径）
# - LOG_DIR: 日志目录（绝对路径）
# - _LOG_MODULE: 日志模块名 ("cf-ip")
# - _LOG_FILE: 日志文件路径
#
# ==============================================================================
# 【安全修复】启用严格模式，防止错误传播
set -euo pipefail

SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 【修复】加载公共函数库
# shellcheck source=../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

# 设置日志模块名
_LOG_MODULE="cf-ip"
# 【修复】设置临时日志路径（acquire_lock 等早期调用需要）
# 实际路径在后面 ENABLE_LOG 判断后更新
mkdir -p "${ROOT_DIR}/logs/cf-ip" 2>/dev/null || true
_LOG_FILE="${ROOT_DIR}/logs/cf-ip/cfst_$(date +%Y%m%d_%H%M%S).log"

# ==================== 地区码转换函数 ====================
# 将 Cloudflare Colo 代码转换为中文名称
convert_colo_to_name() {
    local colo_code="$1"
    # 【修复】统一转换为大写，支持小写输入
    colo_code=$(echo "${colo_code}" | tr '[:lower:]' '[:upper:]')
    
    case "${colo_code}" in
        # 亚太地区
        HKG) echo "香港" ;;
        NRT|TYO) echo "东京" ;;
        ICN) echo "首尔" ;;
        SIN) echo "新加坡" ;;
        TPE) echo "台北" ;;
        KUL) echo "吉隆坡" ;;
        BKK) echo "曼谷" ;;
        MNL) echo "马尼拉" ;;
        
        # 北美地区
        LAX) echo "洛杉矶" ;;
        SJC) echo "圣何塞" ;;
        SEA) echo "西雅图" ;;
        LAS) echo "拉斯维加斯" ;;
        DEN) echo "丹佛" ;;
        MIA) echo "迈阿密" ;;
        YVR) echo "温哥华" ;;
        YYZ) echo "多伦多" ;;
        YUL) echo "蒙特利尔" ;;
        IAD) echo "华盛顿" ;;
        ORD) echo "芝加哥" ;;
        DFW) echo "达拉斯" ;;
        ATL) echo "亚特兰大" ;;
        
        # 欧洲地区
        LON|LHR) echo "伦敦" ;;
        FRA) echo "法兰克福" ;;
        AMS) echo "阿姆斯特丹" ;;
        CDG) echo "巴黎" ;;
        MAD) echo "马德里" ;;
        MXP) echo "米兰" ;;
        ZRH) echo "苏黎世" ;;
        VIE) echo "维也纳" ;;
        WAW) echo "华沙" ;;
        PRG) echo "布拉格" ;;
        BUD) echo "布达佩斯" ;;
        ARN) echo "斯德哥尔摩" ;;
        IST) echo "伊斯坦布尔" ;;
        
        # 中东和南亚
        DXB) echo "迪拜" ;;
        BOM) echo "孟买" ;;
        DEL) echo "德里" ;;
        
        # 大洋洲
        SYD) echo "悉尼" ;;
        MEL) echo "墨尔本" ;;
        AKL) echo "奥克兰" ;;
        
        # 南美
        GRU) echo "圣保罗" ;;
        GIG) echo "里约热内卢" ;;
        EZE) echo "布宜诺斯艾利斯" ;;
        SCL) echo "圣地亚哥" ;;
        BOG) echo "波哥大" ;;
        LIM) echo "利马" ;;
        
        # 北美（墨西哥）
        QRO) echo "克雷塔罗" ;;
        MEX) echo "墨西哥城" ;;
        
        *   ) echo "${colo_code}" ;;  # 未知代码，返回原值
    esac
}

# ==================== 入口权限校验 ====================
# 允许以下场景调用：
# 1. CF_OPT_ENTRY=1 - 从 menu.sh 手动触发
# 2. CF_OPT_ENTRY=scheduler - 从定时任务/scheduler 调用
# 3. 未设置 - 直接运行（用于调试）
if [[ -n "${CF_OPT_ENTRY:-}" ]] && [[ "${CF_OPT_ENTRY}" != "1" ]] && [[ "${CF_OPT_ENTRY}" != "scheduler" ]]; then
    echo -e "${RED}[ERROR] 请使用 'cfopt' 菜单或定时任务运行此模块。${NC}"
    exit 1
fi

# 【已移除】SCRIPT_DIR/ROOT_DIR 已在文件开头定义，此处删除重复定义

# 清屏，准备显示测速信息
clear 2>/dev/null || true

echo -e "${CYAN}+------------------------------------------------------------+"
echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
echo -e " ${GRAY}启动时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${CYAN}+------------------------------------------------------------+"

# ==================== 配置加载与参数校验 ====================
CONFIG_FILE="${ROOT_DIR}/conf/cf-ip.json"

# 检查 jq 是否可用
if ! command -v jq &>/dev/null; then
    echo -e "${RED}[ERROR] jq 未安装 (必需工具)${NC}"
    echo "请安装 jq: apt install jq 或 yum install jq"
    exit 1
fi

# ==================== 【新增】自动创建默认配置 ====================
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${CYAN}[INFO] 检测到配置文件不存在，正在创建默认配置...${NC}"
    
    # 创建 conf 目录
    mkdir -p "$(dirname "${CONFIG_FILE}")" 2>/dev/null || true
    
    # 使用 jq 创建最小化配置（cfst 对象留空，让 cfst 使用内置默认值）
    if command -v jq &>/dev/null; then
        jq -n '{
            "enabled": true,
            "speed_test": {
                "take_ip_num": 5,
                "output_html": true,
                "max_retry": 3,
                "enable_log": true
            },
            "cfst": {}
        }' > "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}"
        echo -e "${GREEN}[OK] 已创建默认配置文件: ${CONFIG_FILE}${NC}"
        echo -e "${YELLOW}[WARN] 建议通过 cfopt -> 2. CF IP 优选管理 -> 1. 修改测速配置 调整参数${NC}"
        echo ""
    else
        echo -e "${RED}[ERROR] jq 未安装，无法创建配置文件${NC}"
        echo -e "${YELLOW}[WARN] 请安装 jq (apt install jq 或 yum install jq)${NC}"
        exit 1
    fi
fi

# ==================== 【新增】配置文件 Schema 验证 ====================
# 验证 JSON 格式和必需字段，提前发现配置错误
validate_config_schema() {
    local config_file="$1"
    local errors=()
    
    # 1. 验证 JSON 格式
    if ! jq empty "${config_file}" 2>/dev/null; then
        echo -e "${RED}[ERROR] 配置文件 JSON 格式错误: ${config_file}${NC}"
        echo -e "${YELLOW}[提示] 请使用 jq . ${config_file} 检查语法${NC}"
        exit 1
    fi
    
    # 2. 验证必需字段存在性
    local required_fields=(
        ".cfst"
        ".speed_test"
        # .paths 不是必需字段，因为有默认值
    )
    
    for field in "${required_fields[@]}"; do
        if ! jq -e "${field}" "${config_file}" &>/dev/null; then
            errors+=("缺少必需字段: ${field}")
        fi
    done
    
    # 3. 验证字段类型
    local type_checks=(
        ".cfst.threads:number"
        ".cfst.ping_times:number"
        ".cfst.download_count:number"
        ".cfst.download_time:number"
        ".cfst.port:number"
        ".cfst.latency_max:number"
        ".cfst.packet_loss_max:number"
        ".cfst.speed_min:number"
        ".cfst.show_count:number"
        ".speed_test.take_ip_num:number"
        ".speed_test.max_retry:number"
        ".cfst.httping:boolean"
        ".cfst.disable_download:boolean"
        ".cfst.all_ip:boolean"
        ".speed_test.output_html:boolean"
        ".speed_test.enable_log:boolean"
    )
    
    for check in "${type_checks[@]}"; do
        local field="${check%%:*}"
        local expected_type="${check##*:}"
        
        # 检查字段是否存在
        if ! jq -e "${field}" "${config_file}" &>/dev/null; then
            continue  # 字段不存在，使用默认值
        fi
        
        # 检查类型
        local actual_type
        actual_type=$(jq -r "${field} | type" "${config_file}" 2>/dev/null)
        
        if [[ "${actual_type}" != "${expected_type}" ]]; then
            errors+=("字段类型错误: ${field} 应为 ${expected_type}，实际为 ${actual_type}")
        fi
    done
    
    # 4. 验证数值范围
    local range_checks=(
        ".cfst.threads:1:1000"
        ".cfst.ping_times:1:100"
        ".cfst.download_count:1:100"
        ".cfst.download_time:1:60"
        ".cfst.port:1:65535"
        ".speed_test.take_ip_num:1:100"
        ".speed_test.max_retry:1:10"
    )
    
    for check in "${range_checks[@]}"; do
        local field="${check%%:*}"
        local range_part="${check#*:}"
        local min_val="${range_part%%:*}"
        local max_val="${range_part##*:}"
        
        # 检查字段是否存在
        if ! jq -e "${field}" "${config_file}" &>/dev/null; then
            continue  # 字段不存在，使用默认值
        fi
        
        # 检查范围
        local value
        value=$(jq -r "${field}" "${config_file}" 2>/dev/null)
        
        if [[ "${value}" -lt "${min_val}" ]] || [[ "${value}" -gt "${max_val}" ]]; then
            errors+=("字段值超出范围: ${field}=${value} (应在 ${min_val}-${max_val} 之间)")
        fi
    done
    
    # 5. 报告错误
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR] 配置文件验证失败:${NC}"
        for error in "${errors[@]}"; do
            echo -e "  ${RED}• ${error}${NC}"
        done
        echo ""
        echo -e "${YELLOW}[提示] 请参考配置文件模板: ${ROOT_DIR}/conf/templates/cf-ip.json.example${NC}"
        exit 1
    fi
}

# 执行配置验证（仅在从文件读取时执行）
if [[ "${CF_IP_CFG_LOADED:-}" != "true" ]]; then
    validate_config_schema "${CONFIG_FILE}"
fi

# ==================== 【性能优化】一次性读取配置文件 ====================
# 从 JSON 读取配置（【优化】只调用 1 次 jq，避免 20 次 fork + 文件 I/O）
# 【优化】如果 scheduler 已通过环境变量传递配置，则跳过文件读取
if [[ "${CF_IP_CFG_LOADED:-}" != "true" ]]; then
    declare -A CFG
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && CFG["$key"]="$value"
    done < <(jq -r '
        [
            "cfst_dir=" + (if .cfst.directory == null then "" else .cfst.directory end),
            "take_ip_num=" + (.speed_test.take_ip_num // 5 | tostring),
            "cfst_threads=" + (if .cfst.threads == null then "" else (.cfst.threads | tostring) end),
            "cfst_colo=" + (if .cfst.colo == null then "" else .cfst.colo end),
            "cfst_ping_times=" + (if .cfst.ping_times == null then "" else (.cfst.ping_times | tostring) end),
            "cfst_download_count=" + (if .cfst.download_count == null then "" else (.cfst.download_count | tostring) end),
            "cfst_download_time=" + (if .cfst.download_time == null then "" else (.cfst.download_time | tostring) end),
            "cfst_port=" + (if .cfst.port == null then "" else (.cfst.port | tostring) end),
            "cfst_url=" + (if .cfst.url == null then "" else .cfst.url end),
            "cfst_httping=" + (if .cfst.httping == null then "" else (.cfst.httping | tostring) end),
            "cfst_latency_max=" + (if .cfst.latency_max == null then "" else (.cfst.latency_max | tostring) end),
            "cfst_packet_loss_max=" + (if .cfst.packet_loss_max == null then "" else (.cfst.packet_loss_max | tostring) end),
            "cfst_speed_min=" + (if .cfst.speed_min == null then "" else (.cfst.speed_min | tostring) end),
            "cfst_show_count=" + (if .cfst.show_count == null then "" else (.cfst.show_count | tostring) end),
            "cfst_ip_file=" + (if .cfst.ip_file == null then "" else .cfst.ip_file end),
            "cfst_disable_download=" + (if .cfst.disable_download == null then "" else (.cfst.disable_download | tostring) end),
            "cfst_all_ip=" + (if .cfst.all_ip == null then "" else (.cfst.all_ip | tostring) end),
            "output_html=" + (.speed_test.output_html // true | tostring),
            "max_retry=" + (.speed_test.max_retry // 3 | tostring),
            "enable_log=" + (.speed_test.enable_log // true | tostring)
        ] | .[]
    ' "$CONFIG_FILE")
else
    # 【修复】从环境变量恢复配置（scheduler 传递）
    # 多线路模式只需要这 4 个变量，其他配置仍然从配置文件读取
    declare -A CFG
    CFG["multi_line_enabled"]="${CFG_MULTI_LINE_ENABLED:-false}"
    CFG["colo_mobile"]="${CFG_COLO_MOBILE:-HKG,SIN,TYO,LON}"
    CFG["colo_unicom"]="${CFG_COLO_UNICOM:-SJC,LAX,SIN,TYO}"
    CFG["colo_telecom"]="${CFG_COLO_TELECOM:-SJC,LAX,TYO,SIN}"
    
    # 【修复】其他配置项仍然从配置文件读取，避免覆盖用户自定义配置
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && CFG["$key"]="$value"
    done < <(jq -r '
        [
            "cfst_dir=" + (if .cfst.directory == null then "" else .cfst.directory end),
            "take_ip_num=" + (.speed_test.take_ip_num // 5 | tostring),
            "cfst_threads=" + (if .cfst.threads == null then "" else (.cfst.threads | tostring) end),
            "cfst_colo=" + (if .cfst.colo == null then "" else .cfst.colo end),
            "cfst_ping_times=" + (if .cfst.ping_times == null then "" else (.cfst.ping_times | tostring) end),
            "cfst_download_count=" + (if .cfst.download_count == null then "" else (.cfst.download_count | tostring) end),
            "cfst_download_time=" + (if .cfst.download_time == null then "" else (.cfst.download_time | tostring) end),
            "cfst_port=" + (if .cfst.port == null then "" else (.cfst.port | tostring) end),
            "cfst_url=" + (if .cfst.url == null then "" else .cfst.url end),
            "cfst_httping=" + (if .cfst.httping == null then "" else (.cfst.httping | tostring) end),
            "cfst_latency_max=" + (if .cfst.latency_max == null then "" else (.cfst.latency_max | tostring) end),
            "cfst_packet_loss_max=" + (if .cfst.packet_loss_max == null then "" else (.cfst.packet_loss_max | tostring) end),
            "cfst_speed_min=" + (if .cfst.speed_min == null then "" else (.cfst.speed_min | tostring) end),
            "cfst_show_count=" + (if .cfst.show_count == null then "" else (.cfst.show_count | tostring) end),
            "cfst_ip_file=" + (if .cfst.ip_file == null then "" else .cfst.ip_file end),
            "cfst_disable_download=" + (if .cfst.disable_download == null then "" else (.cfst.disable_download | tostring) end),
            "cfst_all_ip=" + (if .cfst.all_ip == null then "" else (.cfst.all_ip | tostring) end),
            "output_html=" + (.speed_test.output_html // true | tostring),
            "max_retry=" + (.speed_test.max_retry // 3 | tostring),
            "enable_log=" + (.speed_test.enable_log // true | tostring)
        ] | .[]
    ' "$CONFIG_FILE")
fi

# 导出配置变量（保持向后兼容）
export CFST_DIR="${CFG[cfst_dir]}"
export TAKE_IP_NUM="${CFG[take_ip_num]}"
export CFST_THREADS="${CFG[cfst_threads]}"
export CFST_COLO="${CFG[cfst_colo]}"
export CFST_PING_TIMES="${CFG[cfst_ping_times]}"
export CFST_DOWNLOAD_COUNT="${CFG[cfst_download_count]}"
export CFST_DOWNLOAD_TIME="${CFG[cfst_download_time]}"
export CFST_PORT="${CFG[cfst_port]}"
export CFST_URL="${CFG[cfst_url]}"
export CFST_HTTPING="${CFG[cfst_httping]}"
export CFST_LATENCY_MAX="${CFG[cfst_latency_max]}"
export CFST_PACKET_LOSS_MAX="${CFG[cfst_packet_loss_max]}"
export CFST_SPEED_MIN="${CFG[cfst_speed_min]}"
export CFST_SHOW_COUNT="${CFG[cfst_show_count]}"
export CFST_IP_FILE="${CFG[cfst_ip_file]}"
export CFST_DISABLE_DOWNLOAD="${CFG[cfst_disable_download]}"
export CFST_ALL_IP="${CFG[cfst_all_ip]}"
export OUTPUT_HTML="${CFG[output_html]}"
export MAX_RETRY="${CFG[max_retry]}"
export ENABLE_LOG="${CFG[enable_log]}"

# 优先使用配置文件中的路径，否则使用默认路径
if [[ -z "${CFST_DIR:-}" ]]; then
    CFST_DIR="${ROOT_DIR}/assets/cfst"
fi
CFST_BIN="${CFST_DIR}/cfst"

# 【修复】输出和日志目录（如果 scheduler 已加载配置，使用默认值）
if [[ "${CF_IP_CFG_LOADED:-}" != "true" ]]; then
    OUTPUT_DIR=$(jq -r '.paths.output_dir // "./assets/data/cf-ip"' "$CONFIG_FILE")
    LOG_DIR=$(jq -r '.paths.log_dir // "./logs/cf-ip"' "$CONFIG_FILE")
else
    # 多线路模式下使用默认路径
    OUTPUT_DIR="./assets/data/cf-ip"
    LOG_DIR="./logs/cf-ip"
fi

# 如果是相对路径，转换为绝对路径
if [[ "${OUTPUT_DIR:0:1}" != "/" ]]; then
    OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR#./}"
fi
if [[ "${LOG_DIR:0:1}" != "/" ]]; then
    LOG_DIR="${ROOT_DIR}/${LOG_DIR#./}"
fi

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

# 允许外部传入特定的 COLO 列表、输出文件名和线路标识
LINE_TAG="${3:-default}" # 【修复】先赋值 LINE_TAG，再使用它生成文件名
# 【修复】正确处理空字符串：如果 CFST_COLO 为空字符串，保持为空，不使用默认值
if [[ -n "${1:-}" ]]; then
    # 外部传入了参数，优先使用
    TARGET_COLO="$1"
elif [[ -n "${CFST_COLO+x}" ]]; then
    # CFST_COLO 已定义（即使是空字符串），使用它的值
    TARGET_COLO="${CFST_COLO}"
else
    # CFST_COLO 未定义，使用默认值
    TARGET_COLO="HKG,NRT"
fi
# 【修复】如果没有指定输出文件，根据线路标识生成唯一文件名，避免覆盖
if [[ -n "${2:-}" ]]; then
    OUTPUT_CSV="$2"
else
    # 使用时间戳和线路标识生成唯一文件名
    timestamp=$(date '+%Y%m%d_%H%M%S')
    OUTPUT_CSV="${OUTPUT_DIR}/result_${LINE_TAG}_${timestamp}.csv"
fi

# ==================== 【进程锁管理】 ====================
# 【修复】统一锁文件命名规范：.${module_name}_${type}_${identifier}.lock
LOCK_FILE="${OUTPUT_DIR}/.cf-ip_core_${LINE_TAG}.lock"

# ==================== 跨平台反向读取文件函数 ====================
# 【已移除】reverse_read() 已在 lib/common.sh 中统一定义，此处删除重复实现
# common.sh 提供跨平台兼容：Linux (tac) / macOS (tail -r)

acquire_lock() {
    # 【修复】检查残留的锁文件是否过期（超过 30 分钟视为残留）
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_mtime
        lock_mtime=$(stat_file_mtime "${LOCK_FILE}")
        local now
        now=$(date +%s)
        local age=$(( now - lock_mtime ))
        if [[ $age -gt 1800 ]]; then
            log_warn "发现残留锁文件（${age}秒前），自动清理"
            rm -f "${LOCK_FILE}"
        fi
    fi

    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log_error "无法获取锁，另一个测速进程正在运行"
        log_info  "如果确认没有进程在运行，请删除: ${LOCK_FILE}"
        exit 1
    fi

    # 【修复】注册清理函数，确保退出时删除锁文件和临时日志
    cleanup_lock() {
        local exit_code=$?
        rm -f "${LOCK_FILE}" 2>/dev/null || true
        # 【新增】清理临时日志文件（当 ENABLE_LOG=false 时）
        if [[ "${ENABLE_LOG:-true}" != "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
            rm -f "${LOG_FILE}" 2>/dev/null || true
        fi
        # 【修复】关闭文件描述符 fd 9，防止泄漏
        exec 9>&- 2>/dev/null || true
        exit ${exit_code}
    }
    trap cleanup_lock EXIT
}

# 获取锁以确保同一线路不会并发执行
acquire_lock

# ==================== 前置检查 ====================
if [[ ! -f "${CFST_BIN}" ]]; then
    echo -e "${RED}[ERROR] 测速程序 cfst 不存在: ${CFST_BIN}${NC}"
    echo -e "${YELLOW}[提示] 请先通过 cfopt 菜单运行一次测速以自动安装 cfst${NC}"
    exit 1
fi

# 检查 IP 数据源 (ip.txt)
IP_DATA_FILE=""
if [[ -n "${CFST_IP_FILE}" ]] && [[ "${CFST_IP_FILE}" != "null" ]]; then
    # 使用配置文件中指定的 IP 文件路径
    IP_DATA_FILE="${CFST_IP_FILE}"
elif [[ -f "${ROOT_DIR}/assets/data/cf-ip/ip.txt" ]]; then
    # 使用默认 IP 文件路径
    IP_DATA_FILE="${ROOT_DIR}/assets/data/cf-ip/ip.txt"
fi

if [[ -n "${IP_DATA_FILE}" ]] && [[ ! -f "${IP_DATA_FILE}" ]]; then
    echo -e "${YELLOW}[WARN] 指定的 IP 列表文件不存在: ${IP_DATA_FILE}${NC}"
    echo -e "${YELLOW}[WARN] 将使用 cfst 内置列表。${NC}"
    IP_DATA_FILE=""  # 清空，不传递给 cfst
elif [[ -z "${IP_DATA_FILE}" ]]; then
    echo -e "${YELLOW}[WARN] 未找到自定义 IP 列表，将使用 cfst 内置列表。${NC}"
fi

# ==================== 【重构】cfst 命令构建函数 ====================
# 参数：$1=目标地区, $2=输出文件, $3=IP数据文件(可选), $4=命令数组引用(nameref)
# ==================== 【重构】构建 cfst 命令函数 ====================
# 【修复】不再使用 nameref (bash 4.3+)，改用全局变量 CFST_CMD_ARRAY 返回结果
# 参数: $1=target_colo, $2=output_csv, $3=ip_data_file (可选)
# 返回: 全局数组 CFST_CMD_ARRAY
build_cfst_cmd() {
    local target_colo="$1"
    local output_csv="$2"
    local ip_data_file="${3:-}"
    
    # 【重构】只有当配置项非空时才添加参数，让 cfst 使用内置默认值
    CFST_CMD_ARRAY=("${CFST_BIN}")
    
    # 线程数（可选，HTTPing 模式自动降并发防止 CDN 限速）
    if [[ -n "${CFST_THREADS}" ]]; then
        local actual_threads="${CFST_THREADS}"
        if [[ "${CFST_HTTPING}" = "true" ]] && [[ "${actual_threads}" -gt 100 ]]; then
            actual_threads=100
            log_warn "HTTPing 模式自动降线程: ${CFST_THREADS} → 100（避免 CDN 限速致下载测速全 0）"
        fi
        CFST_CMD_ARRAY+=("-n" "${actual_threads}")
    fi
    
    # Ping 次数（可选）
    [[ -n "${CFST_PING_TIMES}" ]] && CFST_CMD_ARRAY+=("-t" "${CFST_PING_TIMES}")
    
    # 目标地区（可选）
    [[ -n "${target_colo}" ]] && CFST_CMD_ARRAY+=("-cfcolo" "${target_colo}")
    
    # IP 数据文件（可选）
    [[ -n "${ip_data_file}" ]] && CFST_CMD_ARRAY+=("-f" "${ip_data_file}")
    
    # 下载测速参数（可选）
    [[ -n "${CFST_DOWNLOAD_COUNT}" ]] && CFST_CMD_ARRAY+=("-dn" "${CFST_DOWNLOAD_COUNT}")
    [[ -n "${CFST_DOWNLOAD_TIME}" ]] && CFST_CMD_ARRAY+=("-dt" "${CFST_DOWNLOAD_TIME}")
    
    # 端口（可选）
    [[ -n "${CFST_PORT}" ]] && CFST_CMD_ARRAY+=("-tp" "${CFST_PORT}")
    
    # 下载 URL（可选）
    [[ -n "${CFST_URL}" ]] && CFST_CMD_ARRAY+=("-url" "${CFST_URL}")
    
    # HTTP Ping 模式（可选）
    [[ "${CFST_HTTPING}" = "true" ]] && CFST_CMD_ARRAY+=("-httping")
    
    # 延迟和速度阈值（可选）
    [[ -n "${CFST_LATENCY_MAX}" ]] && CFST_CMD_ARRAY+=("-tl" "${CFST_LATENCY_MAX}")
    [[ -n "${CFST_PACKET_LOSS_MAX}" ]] && CFST_CMD_ARRAY+=("-tlr" "${CFST_PACKET_LOSS_MAX}")
    [[ -n "${CFST_SPEED_MIN}" ]] && CFST_CMD_ARRAY+=("-sl" "${CFST_SPEED_MIN}")
    
    # 显示数量（可选）
    [[ -n "${CFST_SHOW_COUNT}" ]] && CFST_CMD_ARRAY+=("-p" "${CFST_SHOW_COUNT}")
    
    # 禁用下载测速（可选）
    [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]] && CFST_CMD_ARRAY+=("-dd")
    
    # 测试所有 IP（可选）
    [[ "${CFST_ALL_IP}" = "true" ]] && CFST_CMD_ARRAY+=("-allip")
    
    # 输出文件（必需）
    CFST_CMD_ARRAY+=("-o" "${output_csv}")
}

# ==================== 执行测速 ====================
# 简化启动信息显示
echo -e "${GREEN}✓${NC} 测速程序: ${CFST_BIN}"
echo -e "${GREEN}✓${NC} 配置参数:"
echo -e "   • 线程数: ${CFST_THREADS}"
echo -e "   • 目标地区: ${TARGET_COLO}"
echo -e "   • 提取数量: ${TAKE_IP_NUM}"
echo -e "   • 输出文件: ${OUTPUT_CSV}"

# 【新增】下载测速前 URL 连通性检查
if [[ "${CFST_DISABLE_DOWNLOAD}" != "true" ]] && [[ -n "${CFST_URL}" ]]; then
    echo -e "${CYAN}[INFO] 正在检查下载 URL 连通性...${NC}"
    
    # 第一步：检查 HTTP 状态码
    url_check_result=$(curl -sLf --max-time 10 -o /dev/null -w "%{http_code}" "${CFST_URL}" 2>/dev/null || true)
    
    # 【修复】在脚本体中不能使用 local（仅函数内可用），直接赋值即可
    temp_test_file="/tmp/cfst_url_test_$$"
    
    if [[ ! "${url_check_result}" =~ ^[23] ]]; then
        echo -e "${YELLOW}[WARN] 下载 URL 不可达 (HTTP ${url_check_result:-000})，跳过下载测速${NC}"
        echo -e "${YELLOW}[WARN] 建议检查网络或修改配置文件中的 cfst.url 字段${NC}"
        echo -e "${CYAN}[INFO] 将仅执行延迟测速，不进行下载速度测试${NC}"
        export CFST_DISABLE_DOWNLOAD="true"
    else
        # 第二步：实际测试下载（只下载前 1KB，验证是否真的能下载）
        echo -e "${CYAN}[INFO] 正在测试实际下载能力...${NC}"
        test_download_result=$(curl -sLf --max-time 15 --range 0-1023 -o "${temp_test_file}" "${CFST_URL}" 2>&1 || true)
        download_exit_code=$?
        
        if [[ ${download_exit_code} -eq 0 ]] && [[ -s "${temp_test_file}" ]]; then
            file_size=$(wc -c < "${temp_test_file}")
            echo -e "${GREEN}[OK] 下载 URL 连通性正常 (HTTP ${url_check_result}, 测试下载 ${file_size} 字节)${NC}"
            rm -f "${temp_test_file}"
        else
            echo -e "${YELLOW}[WARN] 下载 URL 虽然可达，但实际下载失败 (Exit: ${download_exit_code})${NC}"
            if [[ -n "${test_download_result}" ]]; then
                echo -e "${YELLOW}[WARN] 错误信息: ${test_download_result}${NC}"
            fi
            echo -e "${YELLOW}[WARN] 跳过下载测速，仅执行延迟测速${NC}"
            export CFST_DISABLE_DOWNLOAD="true"
            rm -f "${temp_test_file}" 2>/dev/null || true
        fi
    fi
    echo ""
fi

# 【重构】使用函数构建 cfst 命令，消除代码重复
build_cfst_cmd "${TARGET_COLO}" "${OUTPUT_CSV}" "${IP_DATA_FILE}"

# 执行并记录日志（带实时进度提示）
# 【修复】关闭日志时仍需要临时日志文件用于进度监控，测速完成后删除
if [[ "${ENABLE_LOG}" = "true" ]]; then
    LOG_FILE="${LOG_DIR}/cfst_$(date +%Y%m%d_%H%M%S).log"
else
    # 即使关闭日志，也需要临时文件用于进度监控
    LOG_FILE="${LOG_DIR}/.tmp_cfst_$(date +%Y%m%d_%H%M%S).log"
fi

# 【修复】在测速开始前轮转当前日志文件（而非 .old 文件）
if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE}" ]]; then
    rotate_log "${LOG_FILE}" $((10 * 1024 * 1024))  # 10MB
fi

# ====================== 【统一结构化日志系统】 ======================
# 【修复】日志函数已移至 lib/common.sh，通过 _LOG_FILE 变量指定日志文件
# log, log_info, log_warn, log_error, log_success 均由公共库提供

# ====================== 【执行历史记录】 ======================
# 记录测速结果到 history.jsonl
record_speed_test_history() {
    local domain="$1"
    local ips_found="$2"
    local best_ip="$3"
    local latency="$4"
    local speed="$5"
    
    # 【修复】将 N/A 或其他非数字值转换为 0，避免 printf %.2f 静默失败
    if [[ "${latency}" = "N/A" ]] || [[ -z "${latency}" ]] || ! [[ "${latency}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "延迟值异常 (${latency})，记录为 0"
        latency=0
    fi
    
    if [[ "${speed}" = "N/A" ]] || [[ -z "${speed}" ]] || ! [[ "${speed}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "速度值异常 (${speed})，记录为 0"
        speed=0
    fi
    
    local history_file="${ROOT_DIR}/conf/history.jsonl"
    local timestamp
    # 【修复】使用本地时间并标注正确的时区，或 UTC 时间标注 +00:00
    timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    
    # 确保目录存在
    mkdir -p "${ROOT_DIR}/conf"
    
    # 【修复】使用 flock 保护并发写入，防止多进程同时写入导致数据损坏
    # 【安全修复】捕获错误并记录警告日志，而非静默忽略
    (
        flock -n 200 || { log_warn "无法获取历史记录写入锁，跳过记录"; exit 0; }
        if ! printf '{"time":"%s","action":"speed_test","domain":"%s","ips_found":%d,"best_ip":"%s","latency":%.2f,"speed":%.2f}\n' \
            "$timestamp" "$domain" "$ips_found" "$best_ip" "$latency" "$speed" >> "$history_file" 2>/dev/null; then
            log_warn "写入历史记录失败，可能磁盘空间不足或权限问题"
        fi
    ) 200>"${history_file}.lock" || {
        log_warn "历史记录写入异常（可能是 flock 超时或文件系统错误）"
    }
}

# 清屏，开始显示进度
clear 2>/dev/null || true

echo -e "${CYAN}+------------------------------------------------------------+"
echo -e " ${YELLOW}测速进行中...${NC}"
echo -e "${CYAN}+------------------------------------------------------------+"
echo ""
# 【修复】根据配置动态显示测速模式
if [[ "${CFST_HTTPING}" = "true" ]]; then
    echo -e "${GRAY}  第一阶段: 延迟测速 (HTTP Ping)${NC}"
else
    echo -e "${GRAY}  第一阶段: 延迟测速 (TCP Ping)${NC}"
fi

# ==================== 日志内容清理函数 ====================
# 从日志文件读取内容，将 \r 转换为 \n
read_log_clean() {
    local log_file="$1"
    cat "${log_file}" 2>/dev/null | tr '\r' '\n' || true
}

# ==================== 进度条显示函数 ====================
# 参数：$1=当前值, $2=总值
display_progress() {
    local current="$1"
    local total="$2"
    local bar_width="${3:-40}"  # 【修复】添加进度条宽度参数，默认 40
    
    # 强制限制当前值 ≤ 总值，防止进度溢出
    if [[ ${current} -gt ${total} ]]; then
        current=${total}
    fi
    
    # 计算进度百分比
    local progress=$((current * 100 / total))
    local filled=$((progress * bar_width / 100))
    local empty=$((bar_width - filled))
    
    # 优化：使用 printf + tr 生成进度条，比 for 循环快得多
    # 【修复】使用 ASCII 字符替代 Unicode，避免终端编码问题
    local bar
    bar=$(printf '%*s' "${filled}" '' | tr ' ' '=')
    bar+=$(printf '%*s' "${empty}" '' | tr ' ' '-')
    
    # 修复：固定输出长度，结尾加空格补齐，防止字符残留
    # 格式：[========================================] 100% (5955/5955)   
    # 最大长度：2 + 40 + 2 + 4 + 2 + 12 + 4 = 66 字符
    local output
    # 【修复】使用 echo -e 正确解释转义码
    output=$(echo -e "${CYAN}  [${bar}] $(printf '%3d' ${progress})% (${current}/${total})${NC}   ")
    # 补齐到 80 字符，确保覆盖干净
    printf "\r%-80s" "${output}"
}

# ==================== 日志解析与进度显示函数 ====================
# 参数：$1=日志文件路径, $2=当前阶段(ping/download), $3=进度条宽度
parse_and_display_progress() {
    local log_file="$1"
    local current_stage="$2"
    local bar_width="${3:-40}"  # 【修复】接收进度条宽度参数
    
    if [[ "${current_stage}" = "ping" ]]; then
        # 延迟阶段：提取 "X / Y [...] 可用: X" 格式
        # cfst 实际格式: "26 / 5955 [____________] 可用: 26"
        # 【修复】cfst 使用 \r 覆盖同一行，所有进度更新挤在同一行
        # 使用 read_log_clean 清理 ANSI 转义码和回车符
        local latest_progress_line
        latest_progress_line=$(read_log_clean "${log_file}" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | tail -1 || true)
        
        if [[ -n "${latest_progress_line}" ]]; then
            # 提取行首的 "X / Y" 格式
            local available_count
            local total_count
            # cfst 格式: "26 / 5955 [↖____________] 可用: 26"
            # 提取行首的 X 和 Y
            available_count=$(echo "${latest_progress_line}" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\/.*/\1/p')
            total_count=$(echo "${latest_progress_line}" | sed -n 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*\/[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            
            # 【修复】严格校验：非空 + 纯数字 + 总数大于 0
            if [[ -n "${available_count}" ]] && [[ -n "${total_count}" ]] && \
               [[ "${available_count}" =~ ^[0-9]+$ ]] && [[ "${total_count}" =~ ^[0-9]+$ ]] && \
               [[ "${total_count}" -gt 0 ]]; then
                display_progress "${available_count}" "${total_count}" "${bar_width}"
                return 0
            fi
        fi
        # 修复：默认提示也固定长度，防止字符残留
        printf "\r%-80b" "${CYAN}  [进度] 正在测速中...${NC}   "
    else
        # 下载阶段：提取 "X / Y" 格式的进度
        # cfst 下载格式: "2 / 10 [====] 100%" 或类似
        # 【修复】cfst 使用 \r 覆盖同一行，所有进度更新挤在同一行
        # 使用 read_log_clean 清理 ANSI 转义码和回车符
        local latest_progress_line
        latest_progress_line=$(read_log_clean "${log_file}" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | tail -1 || true)
        
        if [[ -n "${latest_progress_line}" ]]; then
            # 提取 "X / Y" 格式
            local download_current
            local download_total
            # cfst 下载格式: "2 / 10 [====] 100%"
            # 提取行首的 X 和 Y
            download_current=$(echo "${latest_progress_line}" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\/.*/\1/p')
            download_total=$(echo "${latest_progress_line}" | sed -n 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*\/[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            
            # 【修复】严格校验：非空 + 纯数字 + 总数大于 0
            if [[ -n "${download_current}" ]] && [[ -n "${download_total}" ]] && \
               [[ "${download_current}" =~ ^[0-9]+$ ]] && [[ "${download_total}" =~ ^[0-9]+$ ]] && \
               [[ "${download_total}" -gt 0 ]]; then
                display_progress "${download_current}" "${download_total}" "${bar_width}"
                return 0
            fi
        fi
        # 修复：默认提示也固定长度，防止字符残留
        printf "\r%-80b" "${CYAN}  [进度] 正在测试下载速度...${NC}   "
    fi
    
    return 1
}

# ==================== 实时进度监控函数 ====================
# 参数：$1=PID, $2=日志文件路径, $3=进度条宽度
monitor_progress() {
    local pid="$1"
    local log_file="$2"
    local bar_width="${3:-40}"
    
    local stage="ping"
    # shellcheck disable=SC2034
    local last_displayed_size=0
    local max_empty_loops=20
    local empty_loop_count=0
    
    # 【修复】cfst 使用 \r 覆盖进度条，不会输出 \n
    # 日志文件只有一行，文件大小可能不增长
    # 改为固定时间间隔刷新，确保进度实时更新
    local refresh_interval=0.5  # 每 0.5 秒刷新一次
    
    while kill -0 "${pid}" 2>/dev/null; do
        # 检查日志文件是否存在
        if [[ ! -f "${log_file}" ]]; then
            empty_loop_count=$((empty_loop_count + 1))
            
            if [[ ${empty_loop_count} -ge ${max_empty_loops} ]]; then
                printf "\r%-80s" "${YELLOW}[WARN] 日志文件不存在或进程已退出，跳过进度监控${NC}"
                echo ""
                break
            fi
            
            sleep "${refresh_interval}"
            continue
        fi
        
        empty_loop_count=0
        
        # 【修复】cfst 使用 \r 覆盖同一行，日志文件只有一行
        # "开始下载测速" 可能被进度条覆盖，无法用于阶段切换检测
        # 改为根据日志内容格式自动判断阶段：
        # - ping 阶段：包含 "可用:" 字样，或格式为 "大数字 / 大数字"
        # - download 阶段：格式为 "小数字 / 小数字" 或包含 "下载速度" 或 "MB/s"
        if [[ "${stage}" = "ping" ]]; then
            # 尝试检测是否进入下载阶段
            # 【修复】cfst 使用 \r 覆盖同一行，tail -n 20 对单行文件无效
            # 使用 read_log_clean 清理 ANSI 转义码和回车符后再分析
            local log_content
            log_content=$(read_log_clean "${log_file}")
            
            # 方法 1：检测 "下载测速" 或 "下载速度" 或 "MB/s" 字样
            if echo "${log_content}" | grep -q "下载测速\|下载速度\|MB/s"; then
                stage="download"
                # 【修复】阶段切换时先清空当前行，避免进度条残留
                printf "\r%-80s\n" ""
                echo -e "${CYAN}  [进度] 延迟测速完成，正在进行下载测速...${NC}"
                echo -e "${GRAY}  第二阶段: 下载速度测试${NC}"
                # 重置大小记录，强制重新解析
                last_displayed_size=0
            # 方法 2：检测格式是否为 "X / Y" 且 Y 较小（下载阶段通常是 10）
            # ping 阶段通常是 "X / 5955" 这样的大数字
            # 【修复】cfst 下载阶段输出格式是 "2 / 10 [====] 3.24 MB/s"
            # 原 regex 要求行尾 $ 结束于小数字，但实际行在数字后还有 [====] 3.24 MB/s
            # 改为匹配数字后跟空格即可正确识别下载阶段
            elif echo "${log_content}" | grep -qE '^[[:space:]]*[0-9]+[[:space:]]*/[[:space:]]*([0-9]{1,2})[[:space:]]'; then
                stage="download"
                printf "\r%-80s\n" ""
                echo -e "${CYAN}  [进度] 延迟测速完成，正在进行下载测速...${NC}"
                echo -e "${GRAY}  第二阶段: 下载速度测试${NC}"
                last_displayed_size=0
            fi
        fi
        
        # 【修复】始终尝试解析最新内容，确保进度实时更新
        parse_and_display_progress "${log_file}" "${stage}" "${bar_width}"
        
        sleep "${refresh_interval}"
    done
}

# 实时显示进度（通过监控日志文件）
progress_bar_width=40

# 【增强】测速结果验证与自动重试
# 【修复】将首次测速也纳入循环，确保 MAX_RETRY 含义符合用户预期
# 【安全修复】将变量声明移到循环外部，避免重复声明问题
# 【修复】MAX_RETRY 表示最大重试次数，不包括首次尝试，所以循环应该是 retry=0 到 retry<MAX_RETRY
cfst_timeout=300
if [[ -n "${CFST_TIMEOUT:-}" ]] && [[ "${CFST_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    cfst_timeout="${CFST_TIMEOUT}"
fi

for ((retry=0; retry<=MAX_RETRY; retry++)); do
    if [[ ${retry} -gt 0 ]]; then
        echo -e "\n${CYAN}[INFO] 第 ${retry} 次自动重试测速...${NC}"
        # 递增等待时间：10s, 20s, 30s, 40s
        wait_time=$(( retry * 10 ))
        echo -e "${YELLOW}[等待] ${wait_time} 秒后重试...${NC}"
        sleep ${wait_time}
    else
        echo -e "\n${CYAN}[INFO] 正在执行首次测速...${NC}"
    fi
    
    # 重新执行测速（使用与首次测速相同的后台运行 + 实时进度监控方式）
    # 【重构】使用函数构建命令，消除代码重复
    build_cfst_cmd "${TARGET_COLO}" "${OUTPUT_CSV}" "${IP_DATA_FILE}"
    
    # 2. 【修复】使用 subshell 隔离目录切换
    (
        # 【修复】禁用严格模式，防止 cfst 非零退出时子 shell 立即终止
        # set -e 会跳过 wait 和 exit ${EXIT_CODE}，导致重试逻辑失效和脚本闪退
        set +euo pipefail
        cd "$(dirname "${CFST_BIN}")" || exit 1
        
        # 3. 【修复】启动测速程序（后台运行），添加超时保护
        if command -v timeout >/dev/null 2>&1; then
            # 使用 stdbuf 强制行缓冲，解决 Go 程序 \r 输出不 flush 的问题
            if command -v stdbuf >/dev/null 2>&1; then
                stdbuf -oL -eL timeout "${cfst_timeout}" "${CFST_CMD_ARRAY[@]}" > "${LOG_FILE}" 2>&1 &
            else
                timeout "${cfst_timeout}" "${CFST_CMD_ARRAY[@]}" > "${LOG_FILE}" 2>&1 &
            fi
            CFST_PID=$!
        else
            # 【安全增强】fallback：使用 Bash 内置功能实现超时保护
            # 避免在没有 timeout 命令的系统上进程无限挂起
            if command -v stdbuf >/dev/null 2>&1; then
                stdbuf -oL -eL "${CFST_CMD_ARRAY[@]}" > "${LOG_FILE}" 2>&1 &
            else
                "${CFST_CMD_ARRAY[@]}" > "${LOG_FILE}" 2>&1 &
            fi
            CFST_PID=$!
            
            # 启动超时监控子进程
            (
                sleep "${cfst_timeout}"
                # 检查主进程是否仍在运行
                if kill -0 "${CFST_PID}" 2>/dev/null; then
                    echo -e "\n${YELLOW}[WARN] 测速超时 (${cfst_timeout}秒)，强制终止进程${NC}" >&2
                    kill -TERM "${CFST_PID}" 2>/dev/null
                    sleep 2
                    # 如果仍未退出，强制杀死
                    if kill -0 "${CFST_PID}" 2>/dev/null; then
                        kill -KILL "${CFST_PID}" 2>/dev/null
                    fi
                fi
            ) &
            TIMEOUT_MONITOR_PID=$!
            
            # 确保超时监控进程在主进程退出后被清理
            # shellcheck disable=SC2064
            trap 'kill ${TIMEOUT_MONITOR_PID} 2>/dev/null' EXIT
        fi
        
        # 4. 实时显示进度（使用通用监控函数）
        echo -e "\n${CYAN}+------------------------------------------------------------+"
        if [[ ${retry} -eq 0 ]]; then
            echo -e " ${YELLOW}首次测速中...${NC}"
        else
            echo -e " ${YELLOW}第 ${retry} 次重试测速中...${NC}"
        fi
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        # 【修复】根据配置动态显示测速模式
        if [[ "${CFST_HTTPING}" = "true" ]]; then
            echo -e "${GRAY}  第一阶段: 延迟测速 (HTTP Ping)${NC}"
        else
            echo -e "${GRAY}  第一阶段: 延迟测速 (TCP Ping)${NC}"
        fi
        
        monitor_progress "${CFST_PID}" "${LOG_FILE}" "${progress_bar_width}" || true
        
        # 5. 【安全修复】等待进程结束，正确处理退出码
        # 使用 wait 捕获真实退出码，避免被信号干扰
        wait "${CFST_PID}" 2>/dev/null
        EXIT_CODE=$?
        
        # 【安全修复】处理特殊退出码
        # 124 = timeout 命令超时
        # 137 = SIGKILL (128 + 9)
        # 143 = SIGTERM (128 + 15)
        # 127 = 命令未找到或进程已不存在
        if [[ "${EXIT_CODE}" -eq 124 ]]; then
            echo -e "${YELLOW}[WARN] 测速超时 (${cfst_timeout}秒)${NC}"
        elif [[ "${EXIT_CODE}" -ge 128 ]]; then
            signal=$((EXIT_CODE - 128))
            echo -e "${YELLOW}[WARN] 测速进程被信号终止 (Signal: ${signal})${NC}"
        fi
        
        # 修复：固定长度输出，确保覆盖干净
        echo ""
        # 【修复】使用 echo -e 正确解释转义码
        echo -e "${CYAN}  [========================================] 100% 测速完成！${NC}"
        echo ""
        
        # 将退出码传递给父 shell
        exit ${EXIT_CODE}
    )
    EXIT_CODE=$?
    
    if [[ "${EXIT_CODE}" -eq 0 ]] && [[ -f "${OUTPUT_CSV}" ]]; then
        # 【修复】根据是否禁用下载测速，使用不同的验证条件
        if [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]]; then
            # 禁用下载测速时，只验证是否有数据行（IP 字段非空）
            valid_ip_count=$(awk -F',' 'NR>1 && $1 != "" {count++} END {print count+0}' "${OUTPUT_CSV}")
        else
            # 启用下载测速时，验证下载速度大于 0
            valid_ip_count=$(awk -F',' 'NR>1 && $6>0 {count++} END {print count+0}' "${OUTPUT_CSV}")
        fi
        
        if [[ "${valid_ip_count}" -gt 0 ]]; then
            # 测速成功且有有效数据
            if [[ ${retry} -gt 1 ]]; then
                echo -e "${GREEN}[OK] 第 ${retry} 次重试成功！找到 ${valid_ip_count} 个有效 IP${NC}"
            fi
            break  # 退出重试循环
        else
            # 数据无效，继续重试
            if [[ ${retry} -lt ${MAX_RETRY} ]]; then
                if [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]]; then
                    echo -e "${YELLOW}[WARN] 第 ${retry} 次测速完成，但未找到有效 IP 数据，数据无效${NC}"
                else
                    echo -e "${YELLOW}[WARN] 第 ${retry} 次测速完成，但所有 IP 下载速度均为 0，数据无效${NC}"
                fi
            else
                echo -e "${RED}[ERROR] 已重试 ${MAX_RETRY} 次，所有测速结果均无效${NC}"
                echo -e "${YELLOW}[提示] 可能的原因：${NC}"
                if [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]]; then
                    echo -e "  • 无法获取 IP 列表或网络问题"
                    echo -e "  • Cloudflare CDN 暂时异常"
                else
                    echo -e "  • 测速地址不可达或网络问题"
                    echo -e "  • 防火墙阻止了下载测试"
                    echo -e "  • Cloudflare CDN 暂时异常"
                fi
                echo ""
                echo -e "${CYAN}[建议] 请检查网络连接后重新运行测速${NC}"
                exit 1
            fi
        fi
    else
        # 测速程序执行失败
        if [[ ${retry} -lt ${MAX_RETRY} ]]; then
            echo -e "${YELLOW}[WARN] 第 ${retry} 次测速失败 (Exit Code: ${EXIT_CODE})${NC}"
        else
            echo -e "${RED}[ERROR] 测速程序执行失败 (Exit Code: ${EXIT_CODE})${NC}"
            if [[ "${ENABLE_LOG}" = "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
                echo -e "${YELLOW}[提示] 详细错误信息请查看: ${LOG_FILE}${NC}"
            fi
            exit 1
        fi
    fi
done

# 清屏，显示结果
clear 2>/dev/null || true

# 【修复】使用 subshell 后无需手动恢复目录，subshell 退出时自动恢复

echo ""
echo -e "${GREEN}[OK] 测速完成！${NC}"
echo ""

# 展示测速结果摘要（从配置文件读取）
# 【修复】检查 CSV 文件是否存在且非空
if [[ ! -f "${OUTPUT_CSV}" ]]; then
    echo -e "${RED}[ERROR] 测速结果文件不存在: ${OUTPUT_CSV}${NC}"
    exit 1
fi

# 【修复】检查是否有有效数据（至少有一行数据，不含表头）
data_lines=$(wc -l < "${OUTPUT_CSV}")
data_lines=$((data_lines - 1))  # 减去表头

if [[ ${data_lines} -le 0 ]]; then
    echo -e "${YELLOW}[WARN] 测速完成，但未找到有效 IP 数据${NC}"
    echo -e "${CYAN}[提示] 可能的原因：${NC}"
    echo -e "  • 所有 IP 均不可达"
    echo -e "  • 网络环境异常"
    echo -e "  • 测速配置过于严格"
    echo ""
    echo -e "${GRAY}结果文件: ${OUTPUT_CSV}${NC}"
    exit 0
fi

total_ips=${data_lines}
available_ips=$((total_ips > TAKE_IP_NUM ? TAKE_IP_NUM : total_ips))

# 转换 Colo 代码为中文
colo_names=""
IFS=',' read -ra COLO_ARRAY <<< "${TARGET_COLO}"
for colo in "${COLO_ARRAY[@]}"; do
    colo_name=$(convert_colo_to_name "${colo}")
    if [[ -n "${colo_names}" ]]; then
        colo_names="${colo_names}, ${colo_name}"
    else
        colo_names="${colo_name}"
    fi
done

# 获取最优 IP 的详细信息
best_ip_line=$(head -n 2 "${OUTPUT_CSV}" | tail -n 1)

# 【修复】使用 awk 解析 CSV，并处理 Windows 换行符 \r
# cfst CSV 格式: IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
best_ip=$(echo "$best_ip_line" | awk -F',' '{gsub(/\r/, "", $1); print $1}' | xargs)
delay=$(echo "$best_ip_line" | awk -F',' '{gsub(/\r/, "", $5); print $5}' | xargs)  # 第5列是平均延迟
speed=$(echo "$best_ip_line" | awk -F',' '{gsub(/\r/, "", $6); print $6}' | xargs)  # 第6列是下载速度
region=$(echo "$best_ip_line" | awk -F',' '{gsub(/\r/, "", $7); print $7}' | xargs)  # 第7列是地区码

# 【修复】数字变量空值校验，支持小数（如 12.54）
if [[ -z "${delay}" ]] || [[ ! "${delay}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    delay="N/A"
fi
if [[ -z "${speed}" ]] || [[ ! "${speed}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    speed="N/A"
fi

best_region_name=$(convert_colo_to_name "${region}")

echo -e "${CYAN}+------------------------------------------------------------+"
echo -e " ${YELLOW}测速结果摘要${NC}"
echo -e "${CYAN}+------------------------------------------------------------+"
echo -e "  ${CYAN}测试节点:${NC}   ${colo_names} (${TARGET_COLO})"
echo -e "  ${CYAN}线程数量:${NC}   ${CFST_THREADS}"
echo -e "  ${CYAN}测试结果:${NC}"
echo -e "    • 测试总数: ${total_ips} 个 IP"
echo -e "    • 可用数量: ${available_ips} 个 IP"
echo -e "    • 选取策略: 保留前 ${TAKE_IP_NUM} 个最优"
echo ""
echo -e " ${GREEN}[最佳] 最优 IP:${NC}"
echo -e "  ${GREEN}➤${NC} ${best_ip}"
echo -e "    延迟: ${delay}ms | 下载: ${speed}MB/s | 地区: ${best_region_name}"
echo ""
echo -e " ${GREEN}Top 3 推荐 IP:${NC}"
head -n 4 "${OUTPUT_CSV}" | tail -n 3 | while IFS= read -r line; do
    # 【修复】处理 Windows 换行符 \r
    ip=$(echo "$line" | awk -F',' '{gsub(/\r/, "", $1); print $1}' | xargs)
    delay=$(echo "$line" | awk -F',' '{gsub(/\r/, "", $5); print $5}' | xargs)  # 第5列是平均延迟
    speed=$(echo "$line" | awk -F',' '{gsub(/\r/, "", $6); print $6}' | xargs)  # 第6列是下载速度
    region=$(echo "$line" | awk -F',' '{gsub(/\r/, "", $7); print $7}' | xargs)  # 第7列是地区码
    
    # 【修复】数字变量空值校验，支持小数
    if [[ -z "${delay}" ]] || [[ ! "${delay}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        delay="N/A"
    fi
    if [[ -z "${speed}" ]] || [[ ! "${speed}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        speed="N/A"
    fi
    
    region_name=$(convert_colo_to_name "${region}")
    echo -e "  ${GREEN}➤${NC} ${ip}  (延迟: ${delay}ms, 下载: ${speed}MB/s, 地区: ${region_name})"
done
echo -e "${CYAN}+------------------------------------------------------------+"
echo ""
echo -e "${GRAY}文件位置:${NC}"
echo -e "  • 完整结果: ${OUTPUT_CSV}"

# 【新增】自动生成 .iplist 标准格式文件（程序专属格式）
# 从 CSV 中提取有效 IP，按速度降序+延迟升序排序，
# 取前 TAKE_IP_NUM 个，输出为 IP|延迟|速度|地区码 格式
# 【修复】移除函数体外的 local 关键字，改用普通变量声明
# 【修复】当禁用下载测速时，使用 IP 字段非空作为过滤条件（而非 $6>0）
iplist_file="${OUTPUT_CSV%.csv}.iplist"
{
    echo "# Cloudflare 优选 IP 列表"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 测速节点: ${TARGET_COLO}"
    echo "#"
    echo "# IP地址|延迟(ms)|下载速度(MB/s)|地区码"
    if [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]]; then
        # 禁用下载测速时，只要 IP 字段非空即为有效
        awk -F',' 'NR>1 && $1 != "" {print $0}' "${OUTPUT_CSV}" | \
            sort -t',' -k5,5 -n | \
            head -n "${TAKE_IP_NUM:-5}" | \
            awk -F',' '{gsub(/\r/,"",$5); gsub(/\r/,"",$6); gsub(/\r/,"",$7); print $1"|"$5"|"$6"|"$7}'
    else
        # 启用下载测速时，要求下载速度 > 0
        awk -F',' 'NR>1 && $6>0 {print $0}' "${OUTPUT_CSV}" | \
            sort -t',' -k6,6 -rn -k5,5 -n | \
            head -n "${TAKE_IP_NUM:-5}" | \
            awk -F',' '{gsub(/\r/,"",$5); gsub(/\r/,"",$6); gsub(/\r/,"",$7); print $1"|"$5"|"$6"|"$7}'
    fi
} > "${iplist_file}"

# 【修复】移除函数体外的 local 关键字
iplist_count=$(grep -c '|' "${iplist_file}" 2>/dev/null || echo 0)
echo -e "  • IP 列表:   ${iplist_file} (${iplist_count} 个有效 IP)"

if [[ "${ENABLE_LOG}" = "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
    echo -e "  • 运行日志: ${LOG_FILE}"
fi

# 【功能增强】记录测速历史
domain_name="${LINE_TAG:-default}"
record_speed_test_history "$domain_name" "$available_ips" "$best_ip" "$delay" "$speed"
log_info "已记录测速历史到 conf/history.jsonl"

# 【修复】如果关闭了日志，清理临时日志文件
if [[ "${ENABLE_LOG}" != "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
    rm -f "${LOG_FILE}"
fi
