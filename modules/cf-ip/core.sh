#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - CF-IP 优选测速核心 (Core)
# Version: 0.1
# Description: 负责调用 cfst 程序进行 Cloudflare IP 测速并生成 result.csv
# Usage: bash modules/cf-ip/core.sh [COLO] [OUTPUT_CSV] [LINE_TAG]
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ==================== 地区码转换函数 ====================
# 将 Cloudflare Colo 代码转换为中文名称
convert_colo_to_name() {
    local colo_code="$1"
    case "${colo_code}" in
        HKG) echo "香港" ;;
        NRT|TYO) echo "东京" ;;
        SIN) echo "新加坡" ;;
        LAX) echo "洛杉矶" ;;
        SJC) echo "圣何塞" ;;
        SEA) echo "西雅图" ;;
        LON) echo "伦敦" ;;
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
        IST) echo "伊斯坦布尔" ;;
        DXB) echo "迪拜" ;;
        BOM) echo "孟买" ;;
        DEL) echo "德里" ;;
        SYD) echo "悉尼" ;;
        MEL) echo "墨尔本" ;;
        AKL) echo "奥克兰" ;;
        GRU) echo "圣保罗" ;;
        GIG) echo "里约热内卢" ;;
        EZE) echo "布宜诺斯艾利斯" ;;
        SCL) echo "圣地亚哥" ;;
        BOG) echo "波哥大" ;;
        LIM) echo "利马" ;;
        QRO) echo "克雷塔罗" ;;
        MEX) echo "墨西哥城" ;;
        YYZ) echo "多伦多" ;;
        YUL) echo "蒙特利尔" ;;
        YVR) echo "温哥华" ;;
        IAD) echo "华盛顿" ;;
        ORD) echo "芝加哥" ;;
        DFW) echo "达拉斯" ;;
        ATL) echo "亚特兰大" ;;
        MIA) echo "迈阿密" ;;
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
echo -e " ${YELLOW}CF-IP 优选测速 v${SCRIPT_VERSION}${NC}"
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

# 从 JSON 读取配置
export CFST_DIR=$(jq -r '.cfst.directory // empty' "$CONFIG_FILE")
export TAKE_IP_NUM=$(jq -r '.speed_test.take_ip_num // 5' "$CONFIG_FILE")
export CFST_THREADS=$(jq -r '.cfst.threads // 200' "$CONFIG_FILE")
export CFST_COLO=$(jq -r '.cfst.colo // "HKG,NRT"' "$CONFIG_FILE")
export CFST_PING_TIMES=$(jq -r '.cfst.ping_times // 4' "$CONFIG_FILE")
export CFST_DOWNLOAD_COUNT=$(jq -r '.cfst.download_count // 10' "$CONFIG_FILE")
export CFST_DOWNLOAD_TIME=$(jq -r '.cfst.download_time // 10' "$CONFIG_FILE")
export CFST_PORT=$(jq -r '.cfst.port // 443' "$CONFIG_FILE")
export CFST_URL=$(jq -r '.cfst.url // "https://cf-ns.com/cdn-cgi/trace"' "$CONFIG_FILE")
export CFST_HTTPING=$(jq -r '.cfst.httping // false' "$CONFIG_FILE")
export CFST_LATENCY_MAX=$(jq -r '.cfst.latency_max // 9999' "$CONFIG_FILE")
export CFST_PACKET_LOSS_MAX=$(jq -r '.cfst.packet_loss_max // 100' "$CONFIG_FILE")
export CFST_SPEED_MIN=$(jq -r '.cfst.speed_min // 0' "$CONFIG_FILE")
export CFST_SHOW_COUNT=$(jq -r '.cfst.show_count // 20' "$CONFIG_FILE")
export CFST_IP_FILE=$(jq -r '.cfst.ip_file // empty' "$CONFIG_FILE")
export CFST_DISABLE_DOWNLOAD=$(jq -r '.cfst.disable_download // false' "$CONFIG_FILE")
export CFST_ALL_IP=$(jq -r '.cfst.all_ip // false' "$CONFIG_FILE")
export OUTPUT_HTML=$(jq -r '.speed_test.output_html // true' "$CONFIG_FILE")
export MAX_RETRY=$(jq -r '.speed_test.max_retry // 3' "$CONFIG_FILE")
export ENABLE_LOG=$(jq -r '.speed_test.enable_log // true' "$CONFIG_FILE")

# 优先使用配置文件中的路径，否则使用默认路径
if [[ -z "${CFST_DIR:-}" ]]; then
    CFST_DIR="${ROOT_DIR}/assets/cfst"
fi
CFST_BIN="${CFST_DIR}/cfst"

# 输出和日志目录
OUTPUT_DIR=$(jq -r '.paths.output_dir // "./assets/data/cf-ip"' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.paths.log_dir // "./logs/cf-ip"' "$CONFIG_FILE")

# 如果是相对路径，转换为绝对路径
if [[ "${OUTPUT_DIR:0:1}" != "/" ]]; then
    OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR#./}"
fi
if [[ "${LOG_DIR:0:1}" != "/" ]]; then
    LOG_DIR="${ROOT_DIR}/${LOG_DIR#./}"
fi

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

# 允许外部传入特定的 COLO 列表、输出文件名和线路标识
TARGET_COLO="${1:-${CFST_COLO:-HKG,NRT}}"
OUTPUT_CSV="${2:-${OUTPUT_DIR}/result.csv}"
LINE_TAG="${3:-default}" # 用于生成独立的进程锁

# ==================== 【进程锁管理】 ====================
LOCK_FILE="${OUTPUT_DIR}/.lock_${LINE_TAG}"
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid="$(cat "${LOCK_FILE}" 2>/dev/null)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo -e "${RED}[ERROR] ${LINE_TAG} 线路测速任务已在运行 (PID: ${pid})。${NC}"
            exit 1
        else
            rm -f "${LOCK_FILE}"
        fi
    fi
    echo $$ > "${LOCK_FILE}"
    trap 'rm -f "${LOCK_FILE}"' EXIT INT TERM HUP
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

# ==================== 执行测速 ====================
# 简化启动信息显示
echo -e "${GREEN}✓${NC} 测速程序: ${CFST_BIN}"
echo -e "${GREEN}✓${NC} 配置参数:"
echo -e "   • 线程数: ${CFST_THREADS}"
echo -e "   • 目标地区: ${TARGET_COLO}"
echo -e "   • 提取数量: ${TAKE_IP_NUM}"
echo -e "   • 输出文件: ${OUTPUT_CSV}"

# 构建 cfst 命令 - 使用绝对路径
CMD=(./cfst "-n" "${CFST_THREADS}" "-t" "${CFST_PING_TIMES}")
if [[ -n "${TARGET_COLO}" ]]; then CMD+=("-cfcolo" "${TARGET_COLO}"); fi
if [[ -n "${IP_DATA_FILE}" ]]; then CMD+=("-f" "${IP_DATA_FILE}"); fi
CMD+=("-dn" "${CFST_DOWNLOAD_COUNT}" "-dt" "${CFST_DOWNLOAD_TIME}")
CMD+=("-tp" "${CFST_PORT}" "-url" "${CFST_URL}")
if [[ "${CFST_HTTPING}" = "true" ]]; then CMD+=("-httping"); fi
CMD+=("-tl" "${CFST_LATENCY_MAX}" "-tlr" "${CFST_PACKET_LOSS_MAX}" "-sl" "${CFST_SPEED_MIN}")
CMD+=("-p" "${CFST_SHOW_COUNT}")
if [[ "${CFST_DISABLE_DOWNLOAD}" = "true" ]]; then CMD+=("-dd"); fi
if [[ "${CFST_ALL_IP}" = "true" ]]; then CMD+=("-allip"); fi
CMD+=("-o" "${OUTPUT_CSV}")

# 执行并记录日志（带实时进度提示）
if [[ "${ENABLE_LOG}" = "true" ]]; then
    LOG_FILE="${LOG_DIR}/cfst_$(date +%Y%m%d_%H%M%S).log"
else
    LOG_FILE="/dev/null"
fi

# 清屏，开始显示进度
clear 2>/dev/null || true

echo -e "${CYAN}+------------------------------------------------------------+"
echo -e " ${YELLOW}测速进行中...${NC}"
echo -e "${CYAN}+------------------------------------------------------------+"
echo ""
echo -e "${GRAY}  第一阶段: 延迟测速 (TCP Ping)${NC}"

# 切换到 cfst 所在目录执行
cd "$(dirname "$CFST_BIN")" || exit 1

# 启动测速程序（后台运行）
"${CMD[@]}" > "${LOG_FILE}" 2>&1 &
CFST_PID=$!

# 实时显示进度（通过监控日志文件）
stage="ping"
last_log_size=0
progress_bar_width=40

while kill -0 "${CFST_PID}" 2>/dev/null; do
    # 检查日志文件是否有新内容
    if [[ -f "${LOG_FILE}" ]]; then
        current_log_size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo "0")
        
        if [[ "${current_log_size}" -gt "${last_log_size}" ]]; then
            last_log_size=${current_log_size}
            
            # 检测是否进入第二阶段（下载测速）
            if [[ "${stage}" = "ping" ]] && grep -q "开始下载测速" "${LOG_FILE}" 2>/dev/null; then
                stage="download"
                echo -e "\r${CYAN}  [进度] 延迟测速完成，正在进行下载测速...          ${NC}"
                echo -e "${GRAY}  第二阶段: 下载速度测试${NC}"
            fi
            
            # 从日志中提取当前进度
            if [[ "${stage}" = "ping" ]]; then
                # 延迟阶段：提取 "可用: XXXX / YYYY" 格式
                # 只提取最后一行的进度信息
                ping_line=$(grep '可用:' "${LOG_FILE}" 2>/dev/null | tail -1)
                if [[ -n "${ping_line}" ]]; then
                    # 使用 sed 提取数字，兼容所有系统
                    # 匹配格式：可用: 123 / 456 或 可用:123/456
                    available_count=$(echo "${ping_line}" | sed -n 's/.*可用:\s*\([0-9]*\).*/\1/p' | tr -d '[:space:]')
                    total_count=$(echo "${ping_line}" | sed -n 's/.*[0-9]\s*\/\s*\([0-9]*\).*/\1/p' | tr -d '[:space:]')
                                    
                    # 验证是否为纯数字
                    if [[ -n "${available_count}" ]] && [[ -n "${total_count}" ]] && [[ "${available_count}" =~ ^[0-9]+$ ]] && [[ "${total_count}" =~ ^[0-9]+$ ]] && [[ "${total_count}" -gt 0 ]]; then
                        # 计算进度百分比
                        progress=$((available_count * 100 / total_count))
                        filled=$((progress * progress_bar_width / 100))
                        empty=$((progress_bar_width - filled))
                        
                        # 构建进度条
                        bar=""
                        for ((i=0; i<filled; i++)); do bar+="█"; done
                        for ((i=0; i<empty; i++)); do bar+="░"; done
                        
                        echo -ne "\r${CYAN}  [${bar}] ${progress}% (${available_count}/${total_count})${NC}   "
                    else
                        echo -ne "\r${CYAN}  [进度] 正在测速中...${NC}   "
                    fi
                else
                    echo -ne "\r${CYAN}  [进度] 正在测速中...${NC}   "
                fi
            else
                # 下载阶段：提取 "X / 10" 格式的进度
                # 只提取“开始下载测速”之后的行
                download_line=$(grep -A 100 "开始下载测速" "${LOG_FILE}" 2>/dev/null | grep -E '^[0-9]+ / [0-9]+' | tail -1)
                if [[ -n "${download_line}" ]]; then
                    download_current=$(echo "${download_line}" | awk '{print $1}' | tr -d '[:space:]')
                    download_total=$(echo "${download_line}" | awk '{print $3}' | tr -d '[:space:]')
                    
                    # 验证是否为纯数字
                    if [[ -n "${download_current}" ]] && [[ -n "${download_total}" ]] && [[ "${download_current}" =~ ^[0-9]+$ ]] && [[ "${download_total}" =~ ^[0-9]+$ ]] && [[ "${download_total}" -gt 0 ]]; then
                        progress=$((download_current * 100 / download_total))
                        filled=$((progress * progress_bar_width / 100))
                        empty=$((progress_bar_width - filled))
                        
                        # 构建进度条
                        bar=""
                        for ((i=0; i<filled; i++)); do bar+="█"; done
                        for ((i=0; i<empty; i++)); do bar+="░"; done
                        
                        echo -ne "\r${CYAN}  [${bar}] ${progress}% (${download_current}/${download_total})${NC}   "
                    else
                        echo -ne "\r${CYAN}  [进度] 正在测试下载速度...${NC}   "
                    fi
                else
                    echo -ne "\r${CYAN}  [进度] 正在测试下载速度...${NC}   "
                fi
            fi
        fi
    fi
    sleep 0.5
done

# 等待进程结束
wait "${CFST_PID}"
EXIT_CODE=$?

echo -e "\r${CYAN}  [████████████████████████████████████████] 100% 测速完成！${NC}"
echo ""

if [[ "${EXIT_CODE}" -eq 0 ]] && [[ -f "${OUTPUT_CSV}" ]]; then
    # 清屏，显示结果
    clear 2>/dev/null || true
    
    echo ""
    echo -e "${GREEN}[OK] 测速完成！${NC}"
    echo ""
    
    # 展示测速结果摘要（从配置文件读取）
    total_ips=$(wc -l < "${OUTPUT_CSV}")
    total_ips=$((total_ips - 1))  # 减去表头
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
    IFS=',' read -r best_ip sent recv loss delay speed region <<< "${best_ip_line}"
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
    head -n 4 "${OUTPUT_CSV}" | tail -n 3 | while IFS=',' read -r ip sent recv loss delay speed region; do
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
else
    echo -e "${RED}[ERROR] 测速程序执行失败 (Exit Code: ${EXIT_CODE})${NC}"
    if [[ "${ENABLE_LOG}" = "true" ]] && [[ -f "${LOG_FILE:-}" ]]; then
        echo -e "${YELLOW}[提示] 详细错误信息请查看: ${LOG_FILE}${NC}"
    fi
    exit 1
fi
