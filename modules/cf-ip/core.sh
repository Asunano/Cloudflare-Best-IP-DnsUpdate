#!/bin/bash
# ==============================================================================
# cfopt - CF-IP 优选测速核心 (Core)
# Version: 0.1
# Description: 负责调用 cfst 程序进行 Cloudflare IP 测速并生成 result.csv
# Usage: bash modules/cf-ip/core.sh
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${YELLOW}CF-IP 优选测速核心 v${SCRIPT_VERSION}${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ==================== 配置加载与参数校验 ====================
CONFIG_FILE="$ROOT_DIR/conf/config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR] 配置文件不存在: $CONFIG_FILE${NC}"
    echo -e "${YELLOW}提示: 请先运行 menu.sh 进行初始化配置。${NC}"
    exit 1
fi
source "$CONFIG_FILE"

# 优先使用配置文件中的 CFST_DIR，否则使用默认路径
if [ -z "${CFST_DIR:-}" ]; then
    CFST_DIR="$ROOT_DIR/assets/bin/cfst"
fi
CFST_BIN="$CFST_DIR/cfst"
OUTPUT_DIR="$ROOT_DIR/assets/data/cf-ip"
LOG_DIR="$ROOT_DIR/logs/cf-ip"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# 设置默认参数 (如果配置文件中未定义)
TAKE_IP_NUM=${TAKE_IP_NUM:-5}
CFST_THREADS=${CFST_THREADS:-200}

# 允许外部传入特定的 COLO 列表、输出文件名和线路标识
TARGET_COLO=${1:-${CFST_COLO:-"HKG,NRT"}}
OUTPUT_CSV=${2:-"$OUTPUT_DIR/result.csv"}
LINE_TAG=${3:-"default"} # 用于生成独立的进程锁

# ==================== 【进程锁管理】 ====================
LOCK_FILE="$OUTPUT_DIR/.lock_${LINE_TAG}"
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}[ERROR] ${LINE_TAG} 线路测速任务已在运行 (PID: $pid)。${NC}"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
}

# 获取锁以确保同一线路不会并发执行
acquire_lock

# ==================== 前置检查 ====================
if [ ! -f "$CFST_BIN" ]; then
    echo -e "${RED}[ERROR] 测速程序 cfst 不存在: $CFST_BIN${NC}"
    exit 1
fi

# 检查 IP 数据源 (ip.txt)
IP_DATA_FILE="${CFST_IP_FILE:-$ROOT_DIR/assets/data/cf-ip/ip.txt}"
if [ ! -f "$IP_DATA_FILE" ]; then
    echo -e "${YELLOW}[WARN] 未找到自定义 IP 列表，将使用 cfst 内置列表。${NC}"
fi

# ==================== 执行测速 ====================
echo -e "${GREEN}[INFO] 正在启动测速程序...${NC}"
echo -e "  线程数: ${CFST_THREADS}"
echo -e "  目标地区: ${TARGET_COLO}"
echo -e "  提取数量: ${TAKE_IP_NUM}"
echo -e "  输出文件: ${OUTPUT_CSV}"

# 构建 cfst 命令
CMD="$CFST_BIN -t $CFST_THREADS -n $TAKE_IP_NUM"
if [ -n "$TARGET_COLO" ]; then CMD+=" -c $TARGET_COLO"; fi
if [ -f "$IP_DATA_FILE" ]; then CMD+=" -f $IP_DATA_FILE"; fi
CMD+=" -o $OUTPUT_CSV"

# 执行并记录日志
if [ "$ENABLE_LOG" = "true" ]; then
    LOG_FILE="$LOG_DIR/cfst_$(date +%Y%m%d_%H%M%S).log"
    echo -e "${CYAN}[INFO] 日志已开启: $LOG_FILE${NC}"
    eval "$CMD" 2>&1 | tee "$LOG_FILE"
else
    eval "$CMD"
fi

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_CSV" ]; then
    echo ""
    echo -e "${GREEN}[OK] 测速完成！结果已保存至: $OUTPUT_CSV${NC}"
    
    # 简单展示前 3 个结果
    echo -e "\n${CYAN}--- 最优 IP 预览 ---${NC}"
    head -n 4 "$OUTPUT_CSV" | tail -n 3
    echo -e "${CYAN}--------------------${NC}"
else
    echo -e "${RED}[ERROR] 测速程序执行失败 (Exit Code: $EXIT_CODE)${NC}"
    exit 1
fi
