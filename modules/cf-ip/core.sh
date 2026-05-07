#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - CF-IP 优选测速核心 (Core)
# Version: 0.1
# Description: 负责调用 cfst 程序进行 Cloudflare IP 测速并生成 result.csv
# Usage: bash modules/cf-ip/core.sh [COLO] [OUTPUT_CSV] [LINE_TAG]
# ==============================================================================
# 【安全修复】启用严格模式，防止错误传播
set -euo pipefail

SCRIPT_VERSION="0.1"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
GRAY='\033[0;90m'
NC='\033[0m'

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

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}[ERROR] 配置文件不存在: ${CONFIG_FILE}${NC}"
    echo ""
    
    # 检测是否为交互式环境（有终端输入）
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}[WARN] 请先通过 cfopt 主菜单进入 CF-IP 模块进行配置${NC}"
        echo -e "${CYAN}提示: 运行 'cfopt' 命令，然后选择 '2. CF IP 优选管理'${NC}"
        exit 1
    else
        # 非交互式环境（定时任务等），直接退出
        echo -e "${YELLOW}[WARN] 请先运行配置向导创建配置文件${NC}"
        echo -e "${YELLOW}[WARN] 命令: cfopt -> 2. CF IP 优选管理 -> 1. 管理配置${NC}"
        exit 1
    fi
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
            "cfst_dir=" + (.cfst.directory // ""),
            "take_ip_num=" + (.speed_test.take_ip_num // 5 | tostring),
            "cfst_threads=" + (.cfst.threads // 200 | tostring),
            "cfst_colo=" + (.cfst.colo // "HKG,NRT"),
            "cfst_ping_times=" + (.cfst.ping_times // 4 | tostring),
            "cfst_download_count=" + (.cfst.download_count // 10 | tostring),
            "cfst_download_time=" + (.cfst.download_time // 10 | tostring),
            "cfst_port=" + (.cfst.port // 443 | tostring),
            "cfst_url=" + (.cfst.url // "https://mirror.drxian.qzz.io/index.html"),
            "cfst_httping=" + (.cfst.httping // false | tostring),
            "cfst_latency_max=" + (.cfst.latency_max // 9999 | tostring),
            "cfst_packet_loss_max=" + (.cfst.packet_loss_max // 100 | tostring),
            "cfst_speed_min=" + (.cfst.speed_min // 0 | tostring),
            "cfst_show_count=" + (.cfst.show_count // 20 | tostring),
            "cfst_ip_file=" + (.cfst.ip_file // ""),
            "cfst_disable_download=" + (.cfst.disable_download // false | tostring),
            "cfst_all_ip=" + (.cfst.all_ip // false | tostring),
            "output_html=" + (.speed_test.output_html // true | tostring),
            "max_retry=" + (.speed_test.max_retry // 3 | tostring),
            "enable_log=" + (.speed_test.enable_log // true | tostring)
        ] | .[]
    ' "$CONFIG_FILE")
else
    # 【修复】从环境变量恢复配置（scheduler 传递）
    # 多线路模式只需要这 4 个变量，其他配置使用默认值
    declare -A CFG
    CFG["multi_line_enabled"]="${CFG_MULTI_LINE_ENABLED:-false}"
    CFG["colo_mobile"]="${CFG_COLO_MOBILE:-HKG,SIN,TYO,LON}"
    CFG["colo_unicom"]="${CFG_COLO_UNICOM:-SJC,LAX,SIN,TYO}"
    CFG["colo_telecom"]="${CFG_COLO_TELECOM:-SJC,LAX,TYO,SIN}"
    # 其他配置使用默认值
    CFG["cfst_dir"]=""
    CFG["take_ip_num"]="5"
    CFG["cfst_threads"]="200"
    CFG["cfst_colo"]="HKG,NRT"
    CFG["cfst_ping_times"]="4"
    CFG["cfst_download_count"]="10"
    CFG["cfst_download_time"]="10"
    CFG["cfst_port"]="443"
    CFG["cfst_url"]="https://mirror.drxian.qzz.io/index.html"
    CFG["cfst_httping"]="false"
    CFG["cfst_latency_max"]="9999"
    CFG["cfst_packet_loss_max"]="100"
    CFG["cfst_speed_min"]="0"
    CFG["cfst_show_count"]="20"
    CFG["cfst_ip_file"]=""
    CFG["cfst_disable_download"]="false"
    CFG["cfst_all_ip"]="false"
    CFG["output_html"]="true"
    CFG["max_retry"]="3"
    CFG["enable_log"]="true"
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
TARGET_COLO="${1:-${CFST_COLO:-HKG,NRT}}"
# 【修复】如果没有指定输出文件，根据线路标识生成唯一文件名，避免覆盖
if [[ -n "${2:-}" ]]; then
    OUTPUT_CSV="$2"
else
    # 使用时间戳和线路标识生成唯一文件名
    timestamp=$(date '+%Y%m%d_%H%M%S')
    OUTPUT_CSV="${OUTPUT_DIR}/result_${LINE_TAG}_${timestamp}.csv"
fi

# ==================== 【进程锁管理】 ====================
LOCK_FILE="${OUTPUT_DIR}/.lock_${LINE_TAG}"

# ==================== 文件大小获取函数 ====================
# 兼容 Linux、macOS、BSD 系统，返回字节数
get_file_size() {
    local file="$1"
    local size
    
    if [[ ! -f "${file}" ]]; then
        echo "0"
        return
    fi
    
    # 【修复】优先尝试 macOS/BSD stat（无 --version 参数）
    if stat -f %z "${file}" >/dev/null 2>&1; then
        # macOS/BSD stat
        size=$(stat -f %z "${file}" 2>/dev/null)
    elif stat -c %s "${file}" >/dev/null 2>&1; then
        # Linux stat
        size=$(stat -c %s "${file}" 2>/dev/null)
    else
        # 降级方案：wc -c（去除空格）
        size=$(wc -c < "${file}" 2>/dev/null | tr -d '[:space:]')
    fi
    
    # 最终校验
    if [[ -z "${size}" ]] || [[ ! "${size}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${size}"
    fi
}

# ==================== 文件修改时间获取函数 ====================
# 兼容 Linux、macOS、BSD 系统，返回 Unix 时间戳
stat_file_mtime() {
    local file="$1"
    local mtime
    
    if [[ ! -f "${file}" ]]; then
        echo "0"
        return
    fi
    
    # 【修复】优先尝试 macOS/BSD stat
    if stat -f %m "${file}" >/dev/null 2>&1; then
        # macOS/BSD stat: %m = 修改时间（Unix 时间戳）
        mtime=$(stat -f %m "${file}" 2>/dev/null)
    elif stat -c %Y "${file}" >/dev/null 2>&1; then
        # Linux stat: %Y = 修改时间（Unix 时间戳）
        mtime=$(stat -c %Y "${file}" 2>/dev/null)
    else
        # 降级方案：使用 date -r（macOS）或 stat 输出解析
        if date -r "${file}" +%s >/dev/null 2>&1; then
            mtime=$(date -r "${file}" +%s 2>/dev/null)
        else
            echo "0"
            return
        fi
    fi
    
    # 最终校验
    if [[ -z "${mtime}" ]] || [[ ! "${mtime}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${mtime}"
    fi
}

# ==================== 跨平台反向读取文件函数 ====================
# 兼容 Linux（tac）和 macOS（tail -r）
reverse_read() {
    local file="$1"
    if command -v tac &>/dev/null; then
        tac "$file"
    else
        # macOS 使用 tail -r
        tail -r "$file" 2>/dev/null || cat "$file"
    fi
}

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
        rm -f "${LOCK_FILE}" 2>/dev/null || true
        # 【新增】清理临时日志文件（当 ENABLE_LOG=false 时）
        if [[ "${ENABLE_LOG:-true}" != "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
            rm -f "${LOG_FILE}" 2>/dev/null || true
        fi
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
build_cfst_cmd() {
    local target_colo="$1"
    local output_csv="$2"
    local ip_data_file="${3:-}"
    
    # Bash 4.3+ 支持 nameref，通过引用返回数组
    local -n __cmd_ref="$4"
    
    # 构建基础命令
    __cmd_ref=("${CFST_BIN}" "-n" "${CFST_THREADS}" "-t" "${CFST_PING_TIMES}")
    [[ -n "${target_colo}" ]] && __cmd_ref+=("-cfcolo" "${target_colo}")
    [[ -n "${ip_data_file}" ]] && __cmd_ref+=("-f" "${ip_data_file}")
    __cmd_ref+=("-dn" "${CFST_DOWNLOAD_COUNT}" "-dt" "${CFST_DOWNLOAD_TIME}")
    __cmd_ref+=("-tp" "${CFST_PORT}")
    [[ -n "${CFST_URL}" ]] && __cmd_ref+=("-url" "${CFST_URL}")
    [[ "${CFST_HTTPING}" = "true" ]] && __cmd_ref+=("-httping")
    __cmd_ref+=("-tl" "${CFST_LATENCY_MAX}" "-tlr" "${CFST_PACKET_LOSS_MAX}" "-sl" "${CFST_SPEED_MIN}")
    __cmd_ref+=("-p" "${CFST_SHOW_COUNT}")
    [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]] && __cmd_ref+=("-dd")
    [[ "${CFST_ALL_IP}" = "true" ]] && __cmd_ref+=("-allip")
    __cmd_ref+=("-o" "${output_csv}")
}

# ==================== 执行测速 ====================
# 简化启动信息显示
echo -e "${GREEN}✓${NC} 测速程序: ${CFST_BIN}"
echo -e "${GREEN}✓${NC} 配置参数:"
echo -e "   • 线程数: ${CFST_THREADS}"
echo -e "   • 目标地区: ${TARGET_COLO}"
echo -e "   • 提取数量: ${TAKE_IP_NUM}"
echo -e "   • 输出文件: ${OUTPUT_CSV}"

# 【重构】使用函数构建 cfst 命令，消除代码重复
declare -a CMD
build_cfst_cmd "${TARGET_COLO}" "${OUTPUT_CSV}" "${IP_DATA_FILE}" CMD

# 执行并记录日志（带实时进度提示）
# 【修复】关闭日志时仍需要临时日志文件用于进度监控，测速完成后删除
if [[ "${ENABLE_LOG}" = "true" ]]; then
    LOG_FILE="${LOG_DIR}/cfst_$(date +%Y%m%d_%H%M%S).log"
else
    # 即使关闭日志，也需要临时文件用于进度监控
    LOG_FILE="${LOG_DIR}/.tmp_cfst_$(date +%Y%m%d_%H%M%S).log"
fi

# 【安全配置】日志轮转：防止日志无限增长
rotate_log() {
    local log_file="$1"
    local max_size=${2:-$((10 * 1024 * 1024))}  # 默认 10MB
    
    if [[ -f "$log_file" ]]; then
        # 【跨平台】使用 get_file_size 替代 stat -c %s
        local file_size
        file_size=$(get_file_size "$log_file")
        
        if [[ "$file_size" -gt "$max_size" ]]; then
            mv "$log_file" "${log_file}.old"
            rm -f "${log_file}.old.old"
            touch "$log_file"
        fi
    fi
}

# 【修复】在测速开始前轮转当前日志文件（而非 .old 文件）
if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE}" ]]; then
    rotate_log "${LOG_FILE}" $((10 * 1024 * 1024))  # 10MB
fi

# ====================== 【统一结构化日志系统】 ======================
# 格式: [2026-05-06 09:30:00] [INFO ] [cf-ip] message
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    
    # 【修复】防御性检查：确保 LOG_FILE 已定义，避免写入未定义路径
    if [[ -z "${LOG_FILE:-}" ]]; then
        # 如果 LOG_FILE 未定义，只输出到终端
        printf "[%s] [%-5s] [cf-ip] %s\n" "$timestamp" "$level" "$*"
    else
        # 正常情况：同时输出到终端和文件
        printf "[%s] [%-5s] [cf-ip] %s\n" "$timestamp" "$level" "$*" | tee -a "${LOG_FILE}"
    fi
}

# 便捷函数
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "OK" "$@"; }

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
    # 【安全修复】添加 || true 防止 set -e 导致脚本退出
    (
        flock -n 200 || { log_warn "无法获取历史记录写入锁"; exit 0; }
        printf '{"time":"%s","action":"speed_test","domain":"%s","ips_found":%d,"best_ip":"%s","latency":%.2f,"speed":%.2f}\n' \
            "$timestamp" "$domain" "$ips_found" "$best_ip" "$latency" "$speed" >> "$history_file"
    ) 200>"${history_file}.lock" || true
}

# 清屏，开始显示进度
clear 2>/dev/null || true

echo -e "${CYAN}+------------------------------------------------------------+"
echo -e " ${YELLOW}测速进行中...${NC}"
echo -e "${CYAN}+------------------------------------------------------------+"
echo ""
echo -e "${GRAY}  第一阶段: 延迟测速 (TCP Ping)${NC}"

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
        # 延迟阶段：提取 "可用: XXXX / YYYY" 格式
        # 【修复】使用 tac + grep -m 1 从后向前匹配，减少读写竞态窗口（使用 || true 防止无匹配时退出）
        local ping_line
        ping_line=$(reverse_read "${log_file}" 2>/dev/null | grep -m 1 '可用:' || true)
        
        if [[ -n "${ping_line}" ]]; then
            # 【修复】使用更精确的正则提取 "可用: X / Y" 中的数字
            local available_count
            local total_count
            # 【跨平台】使用 sed 替代 grep -oP（macOS 不支持 -P）
            available_count=$(echo "${ping_line}" | sed -n 's/.*可用:[[:space:]]*\([0-9]*\).*/\1/p')
            total_count=$(echo "${ping_line}" | sed -n 's/.*可用:[[:space:]]*[0-9]*[[:space:]]*\/[[:space:]]*\([0-9]*\).*/\1/p')
            
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
        # 下载阶段：提取 "X / 10" 格式的进度
        # 【修复】使用 tac + grep -m 1 从后向前匹配，减少读写竞态窗口（使用 || true 防止无匹配时退出）
        local download_line
        download_line=$(reverse_read "${log_file}" 2>/dev/null | grep -m 1 -E '[0-9]+\s*/\s*[0-9]+' || true)
        
        if [[ -n "${download_line}" ]]; then
            # 【修复】使用更精确的正则提取 "X / Y" 中的数字（使用 || true 防止 grep 无匹配时退出）
            local download_current
            local download_total
            # 【跨平台】使用 sed 替代 grep -oP（macOS 不支持 -P）
            download_current=$(echo "${download_line}" | sed -n 's/^[[:space:]]*\([0-9]*\)[[:space:]]*\/.*/\1/p')
            download_total=$(echo "${download_line}" | sed -n 's/.*[0-9][[:space:]]*\/[[:space:]]*\([0-9]*\).*/\1/p')
            
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
    local last_displayed_size=0  # 【修复】移除未使用的 last_log_size，只保留 last_displayed_size
    local max_empty_loops=20
    local empty_loop_count=0
    
    while kill -0 "${pid}" 2>/dev/null; do
        # 检查日志文件是否存在
        if [[ ! -f "${log_file}" ]]; then
            empty_loop_count=$((empty_loop_count + 1))
            
            if [[ ${empty_loop_count} -ge ${max_empty_loops} ]]; then
                printf "\r%-80s" "${YELLOW}[WARN] 日志文件不存在或进程已退出，跳过进度监控${NC}"
                echo ""
                break
            fi
            
            sleep 0.5
            continue
        fi
        
        empty_loop_count=0
        
        # 检查日志文件是否有新内容
        # 优化：使用 get_file_size 函数，兼容所有系统
        local current_log_size
        current_log_size=$(get_file_size "${log_file}")
        
        # 【修复】仅当日志大小真正变化时才刷新进度，避免闪烁
        if [[ "${current_log_size}" -gt "${last_displayed_size}" ]]; then
            
            # 【修复】更新已显示大小，避免重复打印
            last_displayed_size=${current_log_size}
            
            # 检测是否进入第二阶段（下载测速）
            # 【修复】使用 tac + grep -m 1 从后向前匹配，减少读写竞态窗口（使用 || true 防止无匹配时退出）
            if [[ "${stage}" = "ping" ]] && { tac "${log_file}" 2>/dev/null | grep -q -m 1 "开始下载测速" || true; }; then
                stage="download"
                # 【修复】阶段切换时先清空当前行，避免进度条残留
                printf "\r%-80s\n" ""
                echo -e "${CYAN}  [进度] 延迟测速完成，正在进行下载测速...${NC}"
                echo -e "${GRAY}  第二阶段: 下载速度测试${NC}"
            fi
            
            # 调用通用解析函数
            parse_and_display_progress "${log_file}" "${stage}" "${bar_width}"
        fi
        
        sleep 0.5
    done
}

# 实时显示进度（通过监控日志文件）
progress_bar_width=40

# 【增强】测速结果验证与自动重试
# 【修复】将首次测速也纳入循环，确保 MAX_RETRY 含义符合用户预期
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
    declare -a RETRY_CMD
    build_cfst_cmd "${TARGET_COLO}" "${OUTPUT_CSV}" "${IP_DATA_FILE}" RETRY_CMD
    
    # 2. 【修复】使用 subshell 隔离目录切换
    (
        cd "$(dirname "${CFST_BIN}")" || exit 1
        
        # 3. 启动测速程序（后台运行）
        "${RETRY_CMD[@]}" > "${LOG_FILE}" 2>&1 &
        CFST_PID=$!
        
        # 4. 实时显示进度（使用通用监控函数）
        echo -e "\n${CYAN}+------------------------------------------------------------+"
        if [[ ${retry} -eq 0 ]]; then
            echo -e " ${YELLOW}首次测速中...${NC}"
        else
            echo -e " ${YELLOW}第 ${retry} 次重试测速中...${NC}"
        fi
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        echo -e "${GRAY}  第一阶段: 延迟测速 (TCP Ping)${NC}"
        
        monitor_progress "${CFST_PID}" "${LOG_FILE}" "${progress_bar_width}" || true
        
        # 5. 等待进程结束（屏蔽错误输出）
        wait "${CFST_PID}" 2>/dev/null
        EXIT_CODE=$?
        
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
