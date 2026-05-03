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
NC='\033[0m'

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

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${YELLOW}CF-IP 优选测速核心 v${SCRIPT_VERSION}${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo -e " ${YELLOW}CF-IP 测速模块首次配置向导"
        echo -e "${CYAN}+------------------------------------------------------------+"
        echo ""
        echo -e "${YELLOW}[INFO] 检测到您尚未配置 CF-IP 模块${NC}"
        echo ""
        echo -e "${GREEN}我们将帮助您完成以下配置：${NC}"
        echo "  ✓ cfst 程序路径和参数"
        echo "  ✓ 测速并发数和超时时间"
        echo "  ✓ Cloudflare Colo 节点选择"
        echo "  ✓ 多线路分流策略（可选）"
        echo ""
        read -r -p "是否立即启动配置向导？[Y/n] (默认: Y): " choice
        choice=${choice:-Y}
        
        if [[ "$choice" =~ ^[Yy]$ ]] || [[ -z "$choice" ]]; then
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}正在启动快速配置向导...${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            exec bash "$ROOT_DIR/modules/cf-ip/menu.sh"
        else
            echo -e "${YELLOW}已取消操作${NC}"
            exit 1
        fi
    else
        # 非交互式环境（定时任务等），直接退出
        echo -e "${YELLOW}[WARN] 请先运行配置向导创建配置文件${NC}"
        echo -e "${YELLOW}[WARN] 命令: bash $ROOT_DIR/modules/cf-ip/menu.sh${NC}"
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
echo -e "${GREEN}[INFO] 正在启动测速程序...${NC}"
echo -e "  线程数: ${CFST_THREADS}"
echo -e "  目标地区: ${TARGET_COLO}"
echo -e "  提取数量: ${TAKE_IP_NUM}"
echo -e "  输出文件: ${OUTPUT_CSV}"

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

# 执行并记录日志
if [[ "${ENABLE_LOG}" = "true" ]]; then
    LOG_FILE="${LOG_DIR}/cfst_$(date +%Y%m%d_%H%M%S).log"
    echo -e "${CYAN}[INFO] 日志已开启: ${LOG_FILE}${NC}"
    # 切换到 cfst 所在目录执行，避免 cfst 寻找当前目录下的 ip.txt
    cd "$(dirname "$CFST_BIN")" && "${CMD[@]}" 2>&1 | tee "${LOG_FILE}"
else
    cd "$(dirname "$CFST_BIN")" && "${CMD[@]}"
fi

EXIT_CODE=$?

if [[ "${EXIT_CODE}" -eq 0 ]] && [[ -f "${OUTPUT_CSV}" ]]; then
    echo ""
    echo -e "${GREEN}[OK] 测速完成！结果已保存至: ${OUTPUT_CSV}${NC}"
    
    # 简单展示前 3 个结果
    echo -e "\n${CYAN}--- 最优 IP 预览 ---${NC}"
    head -n 4 "${OUTPUT_CSV}" | tail -n 3
    echo -e "${CYAN}--------------------${NC}"
else
    echo -e "${RED}[ERROR] 测速程序执行失败 (Exit Code: ${EXIT_CODE})${NC}"
    exit 1
fi
