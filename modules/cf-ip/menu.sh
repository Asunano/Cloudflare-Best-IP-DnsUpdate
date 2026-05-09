#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - CF-IP 优选配置向导 (Menu)
# Version: 0.1
# Description: 提供交互式界面用于配置测速参数、管理定时任务及查看运行状态
# Usage: bash modules/cf-ip/menu.sh
#
# ==================== 环境变量契约 ====================
# 本模块依赖以下环境变量（由调用者设置）：
#
# 1. CFOPT_ROOT (必需)
#    - 来源：cfopt.sh
#    - 用途：指定项目根目录，优先于自动检测
#    - 默认：$(cd "$SCRIPT_DIR/../.." && pwd)
#    - 示例：export CFOPT_ROOT="/opt/cfopt"
#
# 2. CF_OPT_ENTRY (必需)
#    - 来源：cfopt.sh
#    - 用途：标识调用来源，用于权限控制
#    - 值：必须为 "main_menu"，否则拒绝执行
#    - 默认：未设置或空字符串（会导致脚本退出）
#    - 示例：export CF_OPT_ENTRY="main_menu"
#
# ==================== 导出变量 ====================
# 本模块导出的变量（供子进程使用）：
#
# - ROOT_DIR: 项目根目录（绝对路径）
# - CONFIG_FILE: 配置文件路径
# - CFST_BIN: cfst 测速程序路径
#
# ==============================================================================
# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# 【关键修复】优先使用 CFOPT_ROOT 环境变量，防止路径计算错误
ROOT_DIR="${CFOPT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ==================== 加载公共函数库 ====================
if [[ -f "${ROOT_DIR}/lib/common.sh" ]]; then
    # shellcheck source=../../lib/common.sh
    source "${ROOT_DIR}/lib/common.sh"
fi

# 【关键修复】在 common.sh 加载后再启用严格模式
# 原因：common.sh 定义了所有颜色变量和工具函数
# 如果先启用 set -u，会导致未定义变量报错
set -euo pipefail

# 【关键修复】检查 common.sh 是否成功加载
if ! declare -f log_info >/dev/null 2>&1; then
    # common.sh 未加载，定义临时的颜色变量（完整定义，避免 set -u 错误）
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
    echo -e "${RED}[ERROR] 无法加载公共函数库: ${ROOT_DIR}/lib/common.sh${NC}" >&2
    echo -e "${YELLOW}[INFO] 请检查文件是否存在且可读${NC}" >&2
    exit 1
fi

# ==================== 信号捕获与资源清理 ====================
# shellcheck disable=SC2329
cleanup() {
    local exit_code=$?
    # 清理锁文件
    rm -f "${LOCK_FILE}" 2>/dev/null || true
    if [[ "${exit_code}" -ne 0 ]]; then
        echo "[ERROR] 脚本异常退出 (Code: ${exit_code})" >&2
    fi
}
trap cleanup EXIT INT TERM HUP

# 【已移除】SCRIPT_DIR/ROOT_DIR 已在文件开头定义，此处删除重复定义

# ====================== 【进程锁管理】 ======================
# 【修复】统一锁文件命名规范：.${module_name}_${type}.lock
LOCK_FILE="${ROOT_DIR}/modules/cf-ip/.cf-ip_menu.lock"
acquire_lock() {
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    
    # 检查残留锁文件（修改时间超过 30 分钟）
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_mtime
        lock_mtime=$(stat -c %Y "${LOCK_FILE}" 2>/dev/null || stat -f %m "${LOCK_FILE}" 2>/dev/null)
        if [[ -n "${lock_mtime}" ]]; then
            local current_time
            current_time=$(date +%s)
            local lock_age=$((current_time - lock_mtime))
            
            if [[ ${lock_age} -gt 1800 ]]; then
                echo -e "${YELLOW}[WARN] 发现残留锁文件（已存在 ${lock_age} 秒），自动清理...${NC}"
                rm -f "${LOCK_FILE}" 2>/dev/null || true
            fi
        fi
    fi
    
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo -e "${RED}[ERROR] 检测到另一个 CF-IP 管理进程正在运行。${NC}"
        echo -e "${CYAN}提示:${NC} 如果确认没有进程在运行，请手动删除: ${LOCK_FILE}"
        echo ""
        read -r -p "按回车键返回主菜单..."
        exit 1
    fi
    # 锁会在脚本退出时自动释放（fd 9 关闭）
}

# ====================== 【入口权限校验】 ======================

# 【安全修复】检测非 TTY 环境，防止在 cron 中阻塞
if [[ ! -t 0 ]]; then
    echo -e "${RED}[ERROR] 此脚本需要交互式终端，请通过 cfopt 菜单运行${NC}"
    echo -e "${YELLOW}[提示] 正确用法: cfopt -> 2. CF IP 优选管理${NC}"
    exit 1
fi

# 【修复】删除未使用的 run_sh 分支，仅保留 main_menu
if [[ "${CF_OPT_ENTRY:-}" != "main_menu" ]]; then
    echo -e "${RED}[ERROR] 请使用 'cfopt' 命令进入主菜单运行此模块。${NC}"
    echo -e "${YELLOW}[INFO] 当前 CF_OPT_ENTRY='${CF_OPT_ENTRY:-空}'${NC}"
    echo -e "${CYAN}提示:${NC} 请运行 'cfopt' 命令，然后选择 '2. CF IP 优选管理'"
    echo ""
    read -r -p "按回车键返回主菜单..."
    exit 1
fi

acquire_lock

CONFIG_FILE="${ROOT_DIR}/conf/cf-ip.json"
IP_AUTO_SCRIPT="${ROOT_DIR}/modules/cf-ip/core.sh"
CFST_DIR="${ROOT_DIR}/assets/cfst"
CFST_BIN="${CFST_DIR}/cfst"

# ====================== 【函数：显示欢迎信息】 ======================
# shellcheck disable=SC2329
show_welcome() {
    clear 2>/dev/null || true
    echo ""
    echo "        Cloudflare IP 优选工具 - 智能管理系统"
    echo ""
    echo "   自动测速 | 智能筛选 | 定时更新 | 可视化管理"
    echo ""
}

# ====================== 【函数：显示分隔线】 ======================
# shellcheck disable=SC2329
show_separator() {
    echo "------------------------------------------------------------------------"
}

# ====================== 【函数：显示成功提示】 ======================
# shellcheck disable=SC2329
show_success() {
    echo "[OK] $1"
}

# ====================== 【函数：显示错误提示】 ======================
# shellcheck disable=SC2329
show_error() {
    echo "[ERROR] $1"
}

# ====================== 【函数：显示警告提示】 ======================
# shellcheck disable=SC2329
show_warning() {
    echo "[WARN] $1"
}

# ====================== 【函数：显示信息提示】 ======================
# shellcheck disable=SC2329
show_info() {
    echo "[INFO] $1"
}

# ====================== 【函数：暂停等待用户】 ======================
pause_and_continue() {
    local msg="${1:-按回车键继续...}"
    echo ""
    read -r -p "${msg}" || true
}

# ====================== 【函数：安全读取输入】 ======================
# shellcheck disable=SC2329
safe_read() {
    local var_name="$1"
    shift
    # shellcheck disable=SC2229
    read -r "${var_name}" "$@" || true
}

# ====================== 【函数：带重试的下载与校验】 ======================
# ====================== 【函数：检查配置文件】 ======================
# 返回值说明：
#   0 = CONFIG_OK - 配置正常
#   1 = CONFIG_NOT_FOUND - 配置文件不存在
#   2 = CONFIG_INVALID_JSON - JSON 格式错误
#   3 = CONFIG_INCOMPLETE - 配置文件存在但未完成配置（缺少关键字段）
check_config() {
    # 定义返回值常量，提高可读性
    local CONFIG_OK=0
    local CONFIG_NOT_FOUND=1
    local CONFIG_INVALID_JSON=2
    local CONFIG_INCOMPLETE=3
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return ${CONFIG_NOT_FOUND}
    fi
    
    # 检查是否为有效的 JSON 格式
    if ! jq empty "${CONFIG_FILE}" 2>/dev/null; then
        return ${CONFIG_INVALID_JSON}
    fi
    
    # 检查是否包含关键配置字段（验证是否真正完成了用户配置）
    local has_colo
    has_colo=$(jq -r '.cfst.colo // empty' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -z "${has_colo}" ]]; then
        # 配置文件存在但缺少关键配置，视为未配置
        return ${CONFIG_INCOMPLETE}
    fi
    
    return ${CONFIG_OK}
}

# ====================== 【函数：显示帮助信息】 ======================
# shellcheck disable=SC2329
show_help() {
    clear 2>/dev/null || true
    show_welcome
    echo "=== 使用指南 ==="
    show_separator
    echo ""
    echo "【这是什么？】"
    echo "  Cloudflare IP 优选工具可以自动测试 Cloudflare CDN 的 IP 地址，"
    echo "  找出速度最快、延迟最低的优质 IP，并自动更新到您的网站配置中。"
    echo ""
    echo "【主要功能】"
    echo "  - 自动测速: 批量测试 Cloudflare IP 的延迟和下载速度"
    echo "  - 智能筛选: 自动选择质量最好的 IP 地址"
    echo "  - 定时更新: 可设置定时任务，定期自动更新 IP"
    echo "  - 可视化界面: 友好的菜单操作，无需记忆命令"
    echo ""
    echo "【快速开始】"
    echo "  1. 日常维护 -> 通过主菜单管理配置和定时任务"
    echo "  2. 手动测试 -> 选择 '3) 立即执行测速' 立即运行"
    echo ""
    echo "【配置文件说明】"
    echo "  cf-ip.json - 存储所有配置参数 (JSON 格式)"
    echo "     位置：${CONFIG_FILE}"
    echo "     说明：修改后下次执行自动生效，无需重启"
    echo ""
    echo "【常见问题】"
    echo "  Q: 如何修改测速地区？"
    echo "  A: 主菜单 -> 2) 修改配置 -> 重新配置地区参数"
    echo ""
    echo "  Q: 定时任务不执行怎么办？"
    echo "  A: 主菜单 -> 4) 管理定时任务 -> 检查状态或重新设置"
    echo ""
    echo "  Q: 如何查看执行日志？"
    echo "  A: 主菜单 -> 6) 查看日志 -> 选择要查看的日志类型"
    echo ""
    show_separator
    pause_and_continue "按回车键返回主菜单..."
}

# ====================== 【函数：显示主菜单】 ======================
show_main_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+"
    
    # 检查配置状态
    local config_status=0
    if ! check_config; then
        config_status=$?
    fi
    
    if [[ "${config_status}" -eq 0 ]]; then
        echo -e " ${GREEN}[OK] 配置文件: 已就绪"
    elif [[ "${config_status}" -eq 3 ]]; then
        echo -e " ${YELLOW}[WARN] 配置文件: 存在但未完成配置"
    elif [[ "${config_status}" -eq 2 ]]; then
        echo -e " ${RED}[ERROR] 配置文件: JSON 格式错误"
    else
        echo -e " ${RED}[NONE] 配置文件: 未找到 (请先运行 cfopt 安装)"
    fi
    
    # 检查测速程序状态
    if [[ -f "${CFST_BIN}" ]]; then
        echo -e " ${GREEN}[OK] 测速程序: cfst 已就绪"
    fi
    
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 修改测速配置     ${CYAN}- 调整地区、线程及筛选策略${NC}"
    echo -e " ${GREEN}➤${NC} 2. 查看当前配置     ${CYAN}- 浏览 cf-ip.json 内容${NC}"
    echo -e " ${GREEN}➤${NC} 3. 立即执行测速     ${CYAN}- 手动触发一次 IP 优选${NC}"
    echo -e " ${GREEN}➤${NC} 4. 管理定时任务     ${CYAN}- 设置自动测速 Cron 计划${NC}"
    echo -e " ${GREEN}➤${NC} 5. 查看运行日志     ${CYAN}- 追踪测速结果与错误信息${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 0. 返回主菜单"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
}

# ====================== 【函数：配置管理入口】 ======================
manage_config() {
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${CYAN}[INFO] 首次配置向导启动...${NC}"
        echo ""
    fi
    
    echo -e "\n${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}请选择配置模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 简单模式 ${CYAN}- 快速调整关键参数（地区、线程数）${NC}"
    echo -e " ${GREEN}➤${NC} 2. 高级模式 ${CYAN}- 精细控制所有测速选项${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    read -r -p "请选择 [1-2, 默认 1]: " CONFIG_MODE
    CONFIG_MODE=${CONFIG_MODE:-1}
    
    if [[ "${CONFIG_MODE}" = "1" ]]; then
        configure_simple
    else
        configure_advanced
    fi
    pause_and_continue
}

# ====================== 【函数：简单配置】 ======================
configure_simple() {
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}CF-IP 优选配置向导 - 简单模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "${CYAN}本向导将帮助您快速配置 IP 测速参数：${NC}"
    echo "  - 选择适合您网络的测速节点地区"
    echo "  - 设置测速线程数（影响速度和资源占用）"
    echo "  - 指定保留的优质 IP 数量"
    echo ""
    
    # 第一步：选择测速策略（最重要）
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}CF-IP 优选配置向导 - 简单模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "${GREEN}【步骤 1/3】选择测速节点地区${NC}"
    echo -e "${GRAY}系统将根据您的选择自动测试对应地区的 Cloudflare 节点${NC}"
    echo ""
    echo -e "  ${GREEN}1) 国内通用推荐${NC}     - 综合优化，适合大多数用户 (HKG, NRT)"
    echo -e "  ${GREEN}2) 移动线路专项${NC}     - 中国移动用户优选 (HKG, SIN, TYO, LON)"
    echo -e "  ${GREEN}3) 联通线路专项${NC}     - 中国联通用户优选 (SJC, LAX, SIN, TYO)"
    echo -e "  ${GREEN}4) 电信线路专项${NC}     - 中国电信用户优选 (SJC, LAX, TYO, SIN)"
    echo -e "  ${GREEN}5) 按地理区域筛选${NC}   - 亚太/北美/欧洲等地区"
    echo -e "  ${GREEN}6) 自定义节点代码${NC}   - 查看完整代码表并手动指定"
    echo ""
    read -r -p "请选择策略编号 [1-6，默认 1]: " STRATEGY_CHOICE
    STRATEGY_CHOICE=${STRATEGY_CHOICE:-1}
    
    case ${STRATEGY_CHOICE} in
        1) 
            CFST_COLO="HKG,NRT"
            echo -e "${GREEN}[OK] 已选择：国内通用推荐${NC}"
            ;;
        2) 
            CFST_COLO="HKG,SIN,TYO,LON"
            echo -e "${GREEN}[OK] 已选择：移动线路专项${NC}"
            ;;
        3) 
            CFST_COLO="SJC,LAX,SIN,TYO"
            echo -e "${GREEN}[OK] 已选择：联通线路专项${NC}"
            ;;
        4) 
            CFST_COLO="SJC,LAX,TYO,SIN"
            echo -e "${GREEN}[OK] 已选择：电信线路专项${NC}"
            ;;
        5)
            # 二级菜单：区域细分
            echo ""
            echo -e "${CYAN}请选择目标地理区域：${NC}"
            echo -e "  ${GREEN}1) 亚太地区${NC}     - 香港、东京、首尔、新加坡等"
            echo -e "  ${GREEN}2) 北美地区${NC}     - 洛杉矶、旧金山、西雅图等"
            echo -e "  ${GREEN}3) 欧洲地区${NC}     - 伦敦、法兰克福、阿姆斯特丹等"
            echo -e "  ${GREEN}4) 南美/大洋洲${NC}  - 圣保罗、悉尼、墨尔本等"
            echo ""
            read -r -p "请选择区域编号 [1-4，默认 1]: " REGION_CHOICE
            case ${REGION_CHOICE} in
                2) 
                    CFST_COLO="LAX,SJC,SEA,LAS,MIA,YVR,ORD"
                    echo -e "${GREEN}[OK] 已选择：北美地区${NC}"
                    ;;
                3) 
                    CFST_COLO="LHR,FRA,AMS,MAD,WAW,ARN"
                    echo -e "${GREEN}[OK] 已选择：欧洲地区${NC}"
                    ;;
                4) 
                    CFST_COLO="GRU,EZE,SYD,MEL"
                    echo -e "${GREEN}[OK] 已选择：南美/大洋洲${NC}"
                    ;;
                *) 
                    CFST_COLO="HKG,NRT,ICN,SIN,TPE,KUL,BKK"
                    echo -e "${GREEN}[OK] 已选择：亚太地区${NC}"
                    ;;
            esac
            ;;
        6)
            # 显示完整代码表
            echo ""
            echo -e "${CYAN}+------------------------------------------------------------+"
            echo -e " ${YELLOW}Cloudflare 数据中心代码参考表"
            echo -e "${CYAN}+------------------------------------------------------------+"
            echo -e "  ${GREEN}[亚太]${NC} HKG(香港) NRT(东京) ICN(首尔) SIN(新加坡)"
            echo -e "         TPE(台北) KUL(吉隆坡) BKK(曼谷) MNL(马尼拉)"
            echo -e "  ${GREEN}[北美]${NC} LAX(洛杉矶) SJC(圣何塞) SEA(西雅图) LAS(拉斯维加斯)"
            echo -e "         MIA(迈阿密) YVR(温哥华) ORD(芝加哥) DEN(丹佛)"
            echo -e "  ${GREEN}[欧洲]${NC} LHR(伦敦) FRA(法兰克福) AMS(阿姆斯特丹) MAD(马德里)"
            echo -e "         WAW(华沙) ARN(斯德哥尔摩) CDG(巴黎) ZRH(苏黎世)"
            echo -e "  ${GREEN}[其他]${NC} GRU(圣保罗) EZE(布宜诺斯艾利斯) SYD(悉尼) MEL(墨尔本)"
            echo -e "${CYAN}+------------------------------------------------------------+"
            echo -e "${YELLOW}提示:${NC} 多个代码用逗号分隔，例如: HKG,SJC,LHR"
            read -r -p "请输入节点代码: " CFST_COLO
            CFST_COLO=${CFST_COLO:-"HKG,NRT"}
            ;;
        *) 
            CFST_COLO="HKG,NRT"
            echo -e "${GREEN}[OK] 已选择：国内通用推荐${NC}"
            ;;
    esac
    
    # 第二步：测速线程数
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}CF-IP 优选配置向导 - 简单模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "${GREEN}【步骤 2/3】设置测速线程数${NC}"
    echo -e "${GRAY}线程数越高测速越快，但会占用更多系统资源${NC}"
    echo ""
    echo -e "  ${CYAN}推荐范围：${NC}100-200"
    echo -e "  ${CYAN}低配置服务器：${NC}建议使用 100"
    echo -e "  ${CYAN}高配置服务器：${NC}可使用 200 或更高"
    echo ""
    read -r -p "请输入线程数 [默认 200]: " CFST_THREADS
    CFST_THREADS=${CFST_THREADS:-200}
    
    # 验证输入
    if ! [[ "${CFST_THREADS}" =~ ^[0-9]+$ ]] || [[ "${CFST_THREADS}" -lt 1 ]]; then
        echo -e "${YELLOW}[WARN] 输入无效，使用默认值 200${NC}"
        CFST_THREADS=200
    fi
    
    # 第三步：提取 IP 数量
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}CF-IP 优选配置向导 - 简单模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "${GREEN}【步骤 3/3】设置保留的优质 IP 数量${NC}"
    echo -e "${GRAY}测速完成后，系统将保留速度最快的前 N 个 IP${NC}"
    echo ""
    echo -e "  ${CYAN}推荐：${NC}3-10 个"
    echo -e "  ${CYAN}说明：${NC}数量越多，DNS 轮询效果越好，但可能包含次优 IP"
    echo ""
    read -r -p "请输入 IP 数量 [默认 5]: " TAKE_IP_NUM
    TAKE_IP_NUM=${TAKE_IP_NUM:-5}
    
    # 验证输入
    if ! [[ "${TAKE_IP_NUM}" =~ ^[0-9]+$ ]] || [[ "${TAKE_IP_NUM}" -lt 1 ]]; then
        echo -e "${YELLOW}[WARN] 输入无效，使用默认值 5${NC}"
        TAKE_IP_NUM=5
    fi
    
    # 询问是否启用日志
    clear
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}CF-IP 优选配置向导 - 简单模式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "${GREEN}【可选配置】${NC}"
    read -r -p "是否启用详细日志记录？(y/n，默认 n): " ENABLE_LOG_INPUT
    if [[ "${ENABLE_LOG_INPUT}" = "y" ]] || [[ "${ENABLE_LOG_INPUT}" = "Y" ]]; then
        ENABLE_LOG="true"
        echo -e "${GREEN}[OK] 日志记录已启用${NC}"
    else
        ENABLE_LOG="false"
        echo -e "${GREEN}[OK] 日志记录已禁用${NC}"
    fi
    
    if ! generate_config_simple; then
        echo -e "${RED}[ERROR] 配置生成失败，请重试${NC}"
        return 1
    fi
    
    return 0
}

# ====================== 【函数：高级配置】 ======================
configure_advanced() {
    echo ""
    echo -e "${GREEN}━━━ 高级配置模式 ━━━${NC}"
    echo ""
    echo "提示：直接回车使用默认值，留空表示不启用该参数"
    echo ""
    
    echo -e "${YELLOW}【基础配置】${NC}"
    read -r -p "是否生成 HTML 报告？(true/false，默认: true): " ENABLE_HTML
    ENABLE_HTML=${ENABLE_HTML:-"true"}
    
    read -r -p "HTML输出文件路径（默认: /opt/1panel/www/sites/sw/index/index.html）: " OUTPUT_HTML_PATH
    OUTPUT_HTML_PATH=${OUTPUT_HTML_PATH:-"/opt/1panel/www/sites/sw/index/index.html"}
    
    read -r -p "需要提取的优质IP数量（默认: 5）: " TAKE_IP_NUM
    TAKE_IP_NUM=${TAKE_IP_NUM:-5}
    
    read -r -p "测速失败最大重试次数（默认: 5）: " MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}
    
    read -r -p "是否启用日志记录？(true/false，默认: false): " ENABLE_LOG
    ENABLE_LOG=${ENABLE_LOG:-"false"}
    
    echo ""
    echo -e "${YELLOW}【CFST 测速参数】${NC}"
    read -r -p "延迟测速线程数（默认: 200）: " CFST_THREADS
    CFST_THREADS=${CFST_THREADS:-200}
    if ! [[ "${CFST_THREADS}" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARN] 线程数输入无效，使用默认值 200${NC}"
        CFST_THREADS=200
    fi
    
    read -r -p "延迟测速次数（默认: 8）: " CFST_PING_TIMES
    CFST_PING_TIMES=${CFST_PING_TIMES:-8}
    if ! [[ "${CFST_PING_TIMES}" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARN] 测速次数输入无效，使用默认值 8${NC}"
        CFST_PING_TIMES=8
    fi
    
    read -r -p "下载测速数量（默认: 10）: " CFST_DOWNLOAD_COUNT
    CFST_DOWNLOAD_COUNT=${CFST_DOWNLOAD_COUNT:-10}
    if ! [[ "${CFST_DOWNLOAD_COUNT}" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARN] 下载数量输入无效，使用默认值 10${NC}"
        CFST_DOWNLOAD_COUNT=10
    fi
    
    read -r -p "下载测速时间/秒（默认: 10）: " CFST_DOWNLOAD_TIME
    CFST_DOWNLOAD_TIME=${CFST_DOWNLOAD_TIME:-10}
    if ! [[ "${CFST_DOWNLOAD_TIME}" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARN] 下载时间输入无效，使用默认值 10${NC}"
        CFST_DOWNLOAD_TIME=10
    fi
    
    read -r -p "测速端口（留空=默认443）: " CFST_PORT
    if [[ -n "${CFST_PORT}" ]] && ! [[ "${CFST_PORT}" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}[WARN] 端口输入无效，使用默认值 443${NC}"
        CFST_PORT=""
    fi
    
    read -r -p "测速地址URL（留空=使用默认）: " CFST_URL
    
    read -r -p "使用HTTPing模式？(true/false，默认: true): " CFST_HTTPING
    CFST_HTTPING=${CFST_HTTPING:-"true"}
    
    echo ""
    echo "常用地区代码：HKG=香港 NRT=东京 LAX=洛杉矶 SJC=旧金山 SEA=西雅图"
    echo -e "${YELLOW}[INFO] 测速策略参考:${NC}"
    echo "  - 移动优化: HKG,SIN,TYO,LON"
    echo "  - 亚太专属: HKG,NRT,ICN,SIN,TPE,KUL,BKK"
    echo "  - 美洲专属: LAX,SJC,SEA,LAS,MIA,YVR"
    read -r -p "匹配指定地区 (直接回车使用默认 HKG,NRT): " CFST_COLO
    CFST_COLO=${CFST_COLO:-"HKG,NRT"}
    
    read -r -p "平均延迟上限/ms（默认: 400）: " CFST_LATENCY_MAX
    CFST_LATENCY_MAX=${CFST_LATENCY_MAX:-400}
    
    read -r -p "丢包几率上限（默认: 0.3）: " CFST_PACKET_LOSS_MAX
    CFST_PACKET_LOSS_MAX=${CFST_PACKET_LOSS_MAX:-0.3}
    
    read -r -p "下载速度下限/MB/s（默认: 0.2）: " CFST_SPEED_MIN
    CFST_SPEED_MIN=${CFST_SPEED_MIN:-0.2}
    
    read -r -p "显示结果数量（0=不显示，默认: 0）: " CFST_SHOW_COUNT
    CFST_SHOW_COUNT=${CFST_SHOW_COUNT:-0}
    
    read -r -p "IP段数据文件名（留空=使用默认ip.iplist）: " CFST_IP_FILE
    
    read -r -p "禁用下载测速？(true/false，默认 false): " CFST_DISABLE_DOWNLOAD
    CFST_DISABLE_DOWNLOAD=${CFST_DISABLE_DOWNLOAD:-"false"}
    
    read -r -p "测速全部IP？(true/false，默认 false): " CFST_ALL_IP
    CFST_ALL_IP=${CFST_ALL_IP:-"false"}
    
    if ! generate_config_advanced; then
        echo -e "${RED}[ERROR] 配置生成失败，请重试${NC}"
        return 1
    fi
    
    return 0
}

# ====================== 【函数：生成简单配置】 ======================
generate_config_simple() {
    # 【修复】规范化布尔值，防止 jq --argjson 类型转换失败
    ENABLE_LOG=$(normalize_boolean "${ENABLE_LOG:-false}")
    
    # 使用 jq 创建 JSON 配置文件
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq -n \
        --arg cfst_dir "${CFST_DIR}" \
        --argjson take_ip_num "${TAKE_IP_NUM}" \
        --argjson threads "${CFST_THREADS}" \
        --arg colo "${CFST_COLO}" \
        --argjson enable_log "${ENABLE_LOG}" \
        --arg output_dir "./assets/data/cf-ip" \
        --arg log_dir "./logs/cf-ip" \
        '{
            "_comment": "Cloudflare IP 优选模块配置",
            "_version": "0.1",
            "enabled": true,
            "cfst": {
                "directory": $cfst_dir,
                "binary": "cfst",
                "threads": $threads,
                "colo": $colo,
                "ping_times": 4,
                "download_count": 10,
                "download_time": 10,
                "port": 443,
                "url": "https://mirror.drxian.qzz.io/index.html",
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
                "take_ip_num": $take_ip_num,
                "max_retry": 3,
                "output_html": true,
                "enable_log": $enable_log
            },
            "multi_line": {
                "enabled": false,
                "colo_mobile": "HKG,SIN,TYO,LON",
                "colo_unicom": "SJC,LAX,SIN,TYO",
                "colo_telecom": "SJC,LAX,TYO,SIN"
            },
            "paths": {
                "output_dir": $output_dir,
                "log_dir": $log_dir
            }
        }' > "$temp_file"; then
        rm -f "$temp_file" 2>/dev/null
        show_error "配置文件生成失败"
        return 1
    fi
    
    if ! mv "$temp_file" "$CONFIG_FILE" 2>/dev/null; then
        rm -f "$temp_file" 2>/dev/null
        echo -e "${RED}[ERROR] 配置文件保存失败！${NC}"
        return 1
    fi
    
    chmod 600 "$CONFIG_FILE"
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}[OK] 配置已完成！"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    echo -e "  ${CYAN}测速节点:${NC} ${CFST_COLO}"
    echo -e "  ${CYAN}线程数量:${NC} ${CFST_THREADS}"
    echo -e "  ${CYAN}保留 IP 数:${NC} ${TAKE_IP_NUM}"
    echo -e "  ${CYAN}日志记录:${NC} ${ENABLE_LOG}"
    echo ""
    echo -e "${GRAY}配置文件已保存到：${CONFIG_FILE}${NC}"
    echo -e "${GRAY}下次执行测速时将自动使用这些配置${NC}"
    return 0
}

# ====================== 【函数：布尔值规范化】 ======================
# 将用户输入转换为标准的 JSON 布尔值（true/false）
normalize_boolean() {
    local val="${1,,}"  # 转小写
    case "$val" in
        true|yes|1|on)  echo "true" ;;
        false|no|0|off) echo "false" ;;
        *)              echo "false" ;;  # 默认 false
    esac
}

# ====================== 【函数：生成高级配置】 ======================
generate_config_advanced() {
    # 【修复】规范化布尔值，防止 jq --argjson 类型转换失败
    ENABLE_LOG=$(normalize_boolean "${ENABLE_LOG:-false}")
    ENABLE_HTML=$(normalize_boolean "${ENABLE_HTML:-true}")
    CFST_HTTPING=$(normalize_boolean "${CFST_HTTPING:-true}")
    CFST_DISABLE_DOWNLOAD=$(normalize_boolean "${CFST_DISABLE_DOWNLOAD:-false}")
    CFST_ALL_IP=$(normalize_boolean "${CFST_ALL_IP:-false}")
    
    # 使用 jq 创建完整的 JSON 配置文件
    local temp_file
    temp_file=$(mktemp)
    
    if ! jq -n \
        --arg cfst_dir "${CFST_DIR}" \
        --argjson output_html "${ENABLE_HTML}" \
        --arg output_html_path "${OUTPUT_HTML_PATH}" \
        --argjson take_ip_num "${TAKE_IP_NUM}" \
        --argjson max_retry "${MAX_RETRY}" \
        --argjson enable_log "${ENABLE_LOG}" \
        --argjson threads "${CFST_THREADS}" \
        --argjson ping_times "${CFST_PING_TIMES}" \
        --argjson download_count "${CFST_DOWNLOAD_COUNT}" \
        --argjson download_time "${CFST_DOWNLOAD_TIME}" \
        --arg port "${CFST_PORT:-443}" \
        --arg url "${CFST_URL:-https://mirror.drxian.qzz.io/index.html}" \
        --argjson httping "${CFST_HTTPING}" \
        --arg colo "${CFST_COLO}" \
        --argjson latency_max "${CFST_LATENCY_MAX}" \
        --arg packet_loss_max "${CFST_PACKET_LOSS_MAX}" \
        --arg speed_min "${CFST_SPEED_MIN}" \
        --argjson show_count "${CFST_SHOW_COUNT}" \
        --arg ip_file "${CFST_IP_FILE}" \
        --arg disable_download "${CFST_DISABLE_DOWNLOAD}" \
        --arg all_ip "${CFST_ALL_IP}" \
        --arg output_dir "./assets/data/cf-ip" \
        --arg log_dir "./logs/cf-ip" \
        '{
            "_comment": "Cloudflare IP 优选模块配置",
            "_version": "0.1",
            "enabled": true,
            "cfst": {
                "directory": $cfst_dir,
                "binary": "cfst",
                "threads": $threads,
                "colo": $colo,
                "ping_times": $ping_times,
                "download_count": $download_count,
                "download_time": $download_time,
                "port": ($port | tonumber),
                "url": $url,
                "httping": $httping,
                "latency_max": ($latency_max | tonumber),
                "packet_loss_max": ($packet_loss_max | tonumber),
                "speed_min": ($speed_min | tonumber),
                "show_count": $show_count,
                "ip_file": $ip_file,
                "disable_download": ($disable_download == "true"),
                "all_ip": ($all_ip == "true")
            },
            "speed_test": {
                "take_ip_num": $take_ip_num,
                "max_retry": $max_retry,
                "output_html": $output_html,
                "output_html_path": $output_html_path,
                "enable_log": $enable_log
            },
            "multi_line": {
                "enabled": false,
                "colo_mobile": "HKG,SIN,TYO,LON",
                "colo_unicom": "SJC,LAX,SIN,TYO",
                "colo_telecom": "SJC,LAX,TYO,SIN"
            },
            "paths": {
                "output_dir": $output_dir,
                "log_dir": $log_dir
            }
        }' > "$temp_file"; then
        rm -f "$temp_file" 2>/dev/null
        show_error "配置文件生成失败"
        return 1
    fi
    
    if ! mv "$temp_file" "$CONFIG_FILE" 2>/dev/null; then
        rm -f "$temp_file" 2>/dev/null
        show_error "配置文件保存失败"
        return 1
    fi
    
    chmod 600 "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}[OK] 高级配置完成！${NC}"
    echo "配置文件已保存到：${CONFIG_FILE}"
    return 0
}

# ====================== 【函数：修改配置】 ======================
# shellcheck disable=SC2329
modify_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}[ERROR] 配置文件不存在，请先运行安装向导${NC}"
        read -r -p "按回车键返回..."
        return
    fi
    
    echo ""
    echo -e "${YELLOW}当前配置：${NC}"
    jq '.' "${CONFIG_FILE}"
    echo ""
    
    read -r -p "是否重新配置？(y/n，默认n): " RECONFIG
    RECONFIG=${RECONFIG:-n}
    
    if [[ "${RECONFIG}" = "y" ]] || [[ "${RECONFIG}" = "Y" ]]; then
        manage_config
    fi
    
    read -r -p "按回车键返回..."
}

# ====================== 【函数：查看配置】 ======================
view_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}[ERROR] 配置文件不存在${NC}"
        read -r -p "按回车键返回..."
        return
    fi
    
    # 【修复】使用单次 jq 调用读取所有配置项，避免多次 fork
    local config_data
    config_data=$(jq -r '
        [
            (.enabled // false | tostring),
            (.cfst.threads // 200 | tostring),
            (.cfst.colo // "HKG,NRT"),
            (.cfst.ping_times // 4 | tostring),
            (.cfst.download_count // 10 | tostring),
            (.cfst.latency_max // 9999 | tostring),
            (.cfst.packet_loss_max // 100 | tostring),
            (.cfst.speed_min // 0 | tostring),
            (.cfst.show_count // 20 | tostring),
            (.speed_test.take_ip_num // 5 | tostring),
            (.speed_test.max_retry // 3 | tostring),
            (.speed_test.output_html // true | tostring),
            (.speed_test.enable_log // true | tostring)
        ] | join("\n")
    ' "${CONFIG_FILE}")
    
    # 解析配置数据
    local enabled threads colo ping_times download_count
    local latency_max packet_loss_max speed_min show_count
    local take_ip_num max_retry output_html enable_log
    
    IFS=$'\n' read -r -d '' \
        enabled \
        threads \
        colo \
        ping_times \
        download_count \
        latency_max \
        packet_loss_max \
        speed_min \
        show_count \
        take_ip_num \
        max_retry \
        output_html \
        enable_log \
        <<< "$config_data"
    
    # 格式化状态显示
    local status_enabled
    if [[ "${enabled}" = "true" ]]; then
        status_enabled="${GREEN}[已启用]${NC}"
    else
        status_enabled="${RED}[已禁用]${NC}"
    fi
    
    local status_html status_log
    if [[ "${output_html}" = "true" ]]; then
        status_html="${GREEN}[开启]${NC}"
    else
        status_html="${GRAY}[关闭]${NC}"
    fi
    if [[ "${enable_log}" = "true" ]]; then
        status_log="${GREEN}[开启]${NC}"
    else
        status_log="${GRAY}[关闭]${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}CF-IP 优选配置概览${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 【修复】使用固定宽度的 key-value 分行显示，避免中文字符对齐错乱
    echo ""
    echo -e " ${GREEN}[模块状态]${NC}"
    printf "   %-12s %b\n" "启用状态:" "${status_enabled}"
    
    echo ""
    echo -e " ${GREEN}[测速参数]${NC}"
    printf "   %-12s %b\n" "并发线程:" "${YELLOW}${threads}${NC}"
    printf "   %-12s %b\n" "测速节点:" "${YELLOW}${colo}${NC}"
    printf "   %-12s %b\n" "Ping 次数:" "${YELLOW}${ping_times}${NC}"
    printf "   %-12s %b\n" "下载测试:" "${YELLOW}${download_count} 次${NC}"
    
    echo ""
    echo -e " ${GREEN}[筛选条件]${NC}"
    printf "   %-12s %b\n" "最大延迟:" "${YELLOW}${latency_max} ms${NC}"
    printf "   %-12s %b\n" "最大丢包:" "${YELLOW}${packet_loss_max}%${NC}"
    printf "   %-12s %b\n" "最低速度:" "${YELLOW}${speed_min} MB/s${NC}"
    printf "   %-12s %b\n" "显示数量:" "${YELLOW}${show_count} 个${NC}"
    
    echo ""
    echo -e " ${GREEN}[结果处理]${NC}"
    printf "   %-12s %b\n" "选取 IP 数:" "${YELLOW}${take_ip_num} 个${NC}"
    printf "   %-12s %b\n" "最大重试:" "${YELLOW}${max_retry} 次${NC}"
    printf "   %-12s %b\n" "HTML 报告:" "${status_html}"
    printf "   %-12s %b\n" "运行日志:" "${status_log}"
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${GRAY}提示: 选择选项 1 可修改以上配置${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    read -r -p "按回车键返回..."
}

# ====================== 【函数：管理定时任务】 ======================
manage_cron() {
    echo ""
    echo -e "${BLUE}【定时任务管理】${NC}"
    echo "--------------------------------------------------------"
    
    if ! command -v crontab >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 系统未安装 crontab${NC}"
        echo "请先安装：yum install -y cronie 或 apt-get install -y cron"
        read -r -p "按回车键返回..."
        return
    fi
    
    # 显示当前定时任务
    echo ""
    echo "当前定时任务："
    CRON_LIST=$(crontab -l 2>/dev/null | grep "cf-ip/core.sh")
    if [[ -n "${CRON_LIST}" ]]; then
        echo -e "${GREEN}${CRON_LIST}${NC}"
    else
        echo -e "${YELLOW}未配置定时任务${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}请选择操作"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 添加/修改定时任务"
    echo -e " ${GREEN}➤${NC} 2. 删除定时任务"
    echo -e " ${RED}➤${NC} 3. 返回"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    read -r -p "请选择 [1-3]: " CRON_ACTION
    
    case ${CRON_ACTION} in
        1)
            setup_cron
            ;;
        2)
            remove_cron
            ;;
        *)
            return
            ;;
    esac
    
    read -r -p "按回车键返回..."
}

# ====================== 【函数：设置定时任务】 ======================
setup_cron() {
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}请选择执行频率"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 每小时执行一次"
    echo -e " ${GREEN}➤${NC} 2. 每6小时执行一次"
    echo -e " ${GREEN}➤${NC} 3. 每天执行一次 ${GRAY}(推荐)${NC}"
    echo -e " ${GREEN}➤${NC} 4. 每周执行一次"
    echo -e " ${GREEN}➤${NC} 5. 自定义cron表达式"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    read -r -p "请选择 [1-5, 默认 3]: " CRON_OPTION
    CRON_OPTION=${CRON_OPTION:-3}
    
    case ${CRON_OPTION} in
        1)
            CRON_EXPR="0 * * * *"
            CRON_DESC="每小时"
            ;;
        2)
            CRON_EXPR="0 */6 * * *"
            CRON_DESC="每6小时"
            ;;
        3)
            read -r -p "请输入执行时间（格式：小时 分钟，默认 3 0 表示凌晨3点）: " CRON_TIME
            CRON_TIME=${CRON_TIME:-"3 0"}
            CRON_HOUR=$(echo "${CRON_TIME}" | awk '{print $1}')
            CRON_MIN=$(echo "${CRON_TIME}" | awk '{print $2}')
            CRON_EXPR="${CRON_MIN} ${CRON_HOUR} * * *"
            CRON_DESC="每天${CRON_HOUR}点${CRON_MIN}分"
            ;;
        4)
            read -r -p "请输入星期几（0-7，0和7都表示周日，默认0）: " CRON_WEEKDAY
            CRON_WEEKDAY=${CRON_WEEKDAY:-0}
            read -r -p "请输入执行时间（格式：小时 分钟，默认 3 0）: " CRON_TIME
            CRON_TIME=${CRON_TIME:-"3 0"}
            CRON_HOUR=$(echo "${CRON_TIME}" | awk '{print $1}')
            CRON_MIN=$(echo "${CRON_TIME}" | awk '{print $2}')
            CRON_EXPR="${CRON_MIN} ${CRON_HOUR} * * ${CRON_WEEKDAY}"
            # 【修复】根据用户选择的星期几动态生成描述
            declare -a DAY_NAMES=([0]="周日" [1]="周一" [2]="周二" [3]="周三" [4]="周四" [5]="周五" [6]="周六" [7]="周日")
            CRON_DESC="每${DAY_NAMES[${CRON_WEEKDAY}]:-周日}${CRON_HOUR}点${CRON_MIN}分"
            ;;
        5)
            echo "请输入cron表达式（格式：分 时 日 月 周）"
            echo "例如：0 3 * * * 表示每天凌晨3点"
            read -r -p "cron表达式: " CRON_EXPR
            CRON_DESC="自定义"
            ;;
        *)
            CRON_EXPR="0 3 * * *"
            CRON_DESC="每天凌晨3点"
            ;;
    esac
    
    SCRIPT_PATH="${IP_AUTO_SCRIPT}"
    LOG_DIR="${ROOT_DIR}/logs/cf-ip"
    mkdir -p "${LOG_DIR}"
    LOG_PATH="${LOG_DIR}/cron.log"
    # 设置 CF_OPT_ENTRY=scheduler 以允许定时任务调用
    CRON_CMD="${CRON_EXPR} CF_OPT_ENTRY=scheduler /bin/bash ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"
    
    echo ""
    echo -e "${YELLOW}即将添加以下定时任务：${NC}"
    echo "  执行频率：${CRON_DESC}"
    echo "  Cron表达式：${CRON_EXPR}"
    echo "  执行脚本：${SCRIPT_PATH}"
    echo "  日志文件：${LOG_PATH}"
    echo ""
    read -r -p "确认添加？(y/n，默认y): " CONFIRM_CRON
    CONFIRM_CRON=${CONFIRM_CRON:-y}
    
    if [[ "${CONFIRM_CRON}" = "y" ]] || [[ "${CONFIRM_CRON}" = "Y" ]]; then
        # 先删除旧的，再添加新的
        if (crontab -l 2>/dev/null | grep -v "cf-ip/core.sh"; echo "${CRON_CMD}") | crontab -; then
            echo -e "${GREEN}[OK] 定时任务添加成功！${NC}"
        else
            echo -e "${RED}[ERROR] 定时任务添加失败${NC}"
        fi
    fi
}

# ====================== 【函数：删除定时任务】 ======================
remove_cron() {
    echo ""
    
    # 获取所有 CF-IP 相关的定时任务
    CRON_LIST=$(crontab -l 2>/dev/null | grep "cf-ip/core.sh")
    
    if [[ -z "${CRON_LIST}" ]]; then
        echo -e "${YELLOW}[WARN] 未找到 CF-IP 相关的定时任务${NC}"
        return
    fi
    
    # 将任务存入数组并显示编号
    declare -a TASKS
    local idx=1
    echo -e "${CYAN}当前 CF-IP 定时任务列表：${NC}"
    echo "--------------------------------------------------------"
    while IFS= read -r line; do
        TASKS[$idx]="$line"
        echo -e " ${GREEN}[${idx}]${NC} $line"
        idx=$((idx + 1))
    done <<< "${CRON_LIST}"
    echo "--------------------------------------------------------"
    echo ""
    
    # 提供删除选项
    echo -e "${YELLOW}请选择要删除的任务：${NC}"
    echo -e " ${GRAY}• 输入单个编号：删除指定任务（如：1）${NC}"
    echo -e " ${GRAY}• 输入多个编号：删除多个任务（如：1 2 3）${NC}"
    echo -e " ${GRAY}• 输入 'all'：删除所有任务${NC}"
    echo -e " ${GRAY}• 直接回车：取消操作${NC}"
    echo ""
    read -r -p "请输入选择: " DELETE_CHOICE
    
    if [[ -z "${DELETE_CHOICE}" ]]; then
        echo -e "${GRAY}[INFO] 已取消删除操作${NC}"
        return
    fi
    
    # 处理 'all' 选项
    if [[ "${DELETE_CHOICE}" == "all" ]] || [[ "${DELETE_CHOICE}" == "ALL" ]]; then
        read -r -p "确认删除所有 ${#TASKS[@]} 个 CF-IP 定时任务？(y/n): " CONFIRM_ALL
        if [[ "${CONFIRM_ALL}" == "y" ]] || [[ "${CONFIRM_ALL}" == "Y" ]]; then
            crontab -l 2>/dev/null | grep -v "cf-ip/core.sh" | crontab -
            echo -e "${GREEN}[OK] 已删除所有 CF-IP 定时任务${NC}"
        else
            echo -e "${GRAY}[INFO] 已取消删除操作${NC}"
        fi
        return
    fi
    
    # 解析用户输入的编号（支持空格分隔的多个编号）
    declare -a SELECTED_INDICES
    for num in ${DELETE_CHOICE}; do
        # 验证是否为有效数字
        if [[ "${num}" =~ ^[0-9]+$ ]] && [[ ${num} -ge 1 ]] && [[ ${num} -lt ${idx} ]]; then
            SELECTED_INDICES+=("${num}")
        else
            echo -e "${RED}[ERROR] 无效的任务编号: ${num}${NC}"
        fi
    done
    
    if [[ ${#SELECTED_INDICES[@]} -eq 0 ]]; then
        echo -e "${RED}[ERROR] 未选择任何有效任务${NC}"
        return
    fi
    
    # 显示将要删除的任务
    echo ""
    echo -e "${YELLOW}即将删除以下任务：${NC}"
    for i in "${SELECTED_INDICES[@]}"; do
        echo -e " ${RED}[${i}]${NC} ${TASKS[$i]}"
    done
    echo ""
    
    # 确认删除
    read -r -p "确认删除以上 ${#SELECTED_INDICES[@]} 个任务？(y/n): " CONFIRM_DELETE
    if [[ "${CONFIRM_DELETE}" != "y" ]] && [[ "${CONFIRM_DELETE}" != "Y" ]]; then
        echo -e "${GRAY}[INFO] 已取消删除操作${NC}"
        return
    fi
    
    # 执行删除：保留未被选中的任务
    CURRENT_CRON=$(crontab -l 2>/dev/null)
    NEW_CRON="${CURRENT_CRON}"
    
    for i in "${SELECTED_INDICES[@]}"; do
        # 【修复】使用 -Fx 进行整行精确匹配，避免子串误删
        NEW_CRON=$(echo "${NEW_CRON}" | grep -v -Fx "${TASKS[$i]}")
    done
    
    # 更新 crontab
    echo "${NEW_CRON}" | crontab -
    
    echo -e "${GREEN}[OK] 已成功删除 ${#SELECTED_INDICES[@]} 个定时任务${NC}"
}

# ====================== 【函数：手动执行测速】 ======================
run_test() {
    
    if [[ ! -f "${IP_AUTO_SCRIPT}" ]]; then
        echo -e "${RED}[ERROR] 核心脚本 core.sh 不存在${NC}"
        read -r -p "按回车键返回..."
        return
    fi
    
    echo ""
    echo -e "${YELLOW}开始执行测速...${NC}"
    echo "--------------------------------------------------------"
    # 切换到 ROOT_DIR 以确保相对路径正确
    cd "${ROOT_DIR}" || return 1
    if ! CF_OPT_ENTRY=1 bash "${IP_AUTO_SCRIPT}"; then
        echo -e "${RED}[ERROR] 测速执行失败，请检查日志${NC}"
        read -r -p "按回车键返回..."
        return 1
    fi
    echo ""
    read -r -p "按回车键返回..."
}

# ====================== 【函数：查看日志】 ======================
view_logs() {
    echo ""
    echo -e "${BLUE}【日志查看】${NC}"
    echo "--------------------------------------------------------"
    
    LOG_DIR="${ROOT_DIR}/logs/cf-ip"
    mkdir -p "${LOG_DIR}"
    # 【修复】跨平台查找最新的 cfst 日志文件（支持时间戳命名）
    # 优先查找正式日志，如果不存在则查找临时日志
    LOG_FILE=$(find_latest_file "${LOG_DIR}" "cfst_*.log")
    if [[ -z "${LOG_FILE}" ]]; then
        # fallback：查找临时日志文件（ENABLE_LOG=false 时生成）
        LOG_FILE=$(find_latest_file "${LOG_DIR}" ".tmp_cfst_*.log")
    fi
    CRON_LOG="${LOG_DIR}/cron.log"
    
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}请选择要查看的日志"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 运行日志 (最新 cfst 日志)"
    echo -e " ${GREEN}➤${NC} 2. 定时任务日志 (cron.log)"
    echo -e " ${RED}➤${NC} 3. 返回"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    read -r -p "请选择 [1-3]: " LOG_CHOICE
    
    case ${LOG_CHOICE} in
        1)
            if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
                echo ""
                echo -e "${CYAN}日志文件: ${LOG_FILE}${NC}"
                echo "--------------------------------------------------------"
                tail -50 "${LOG_FILE}"
            else
                echo -e "${YELLOW}[WARN] 未找到 cfst 日志文件${NC}"
                echo -e "${GRAY}提示: 请先执行一次测速以生成日志${NC}"
                echo -e "${GRAY}日志目录: ${LOG_DIR}${NC}"
                # 显示目录内容以便调试
                if [[ -d "${LOG_DIR}" ]]; then
                    echo -e "${GRAY}目录内容:$(ls -la "${LOG_DIR}" 2>/dev/null | head -10)${NC}"
                fi
            fi
            ;;
        2)
            if [[ -f "${CRON_LOG}" ]]; then
                echo ""
                echo -e "${CYAN}日志文件: ${CRON_LOG}${NC}"
                echo "--------------------------------------------------------"
                tail -50 "${CRON_LOG}"
            else
                echo -e "${YELLOW}[WARN] 定时任务日志不存在${NC}"
                echo -e "${GRAY}提示: 请先设置定时任务并等待执行${NC}"
                echo -e "${GRAY}日志路径: ${CRON_LOG}${NC}"
            fi
            ;;
        *)
            return
            ;;
    esac
    
    read -r -p "按回车键返回..."
}

# ====================== 【主程序入口】 ======================
# 检查配置文件状态
config_status=0
if ! check_config; then
    config_status=$?
fi

if [[ "${config_status}" -ne 0 ]]; then
    echo -e "${YELLOW}[INFO] 检测到尚未配置 CF 优选参数。${NC}"
    echo ""
    read -r -p "是否现在运行配置向导？[Y/n] (默认 Y): " confirm
    confirm=${confirm:-Y}
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        manage_config || {
            echo -e "${RED}[ERROR] 配置向导执行失败${NC}"
            exit 1
        }
    else
        echo -e "${CYAN}[INFO] 已取消配置${NC}"
        echo -e "${YELLOW}[WARN] 未配置无法使用 CF-IP 功能，请重新进入菜单进行配置${NC}"
        # 不退出，继续显示主菜单，让用户可以稍后配置
    fi
fi

# 主循环
while true; do
    show_main_menu
    read -r -p "请选择功能 [0-5]: " CHOICE
    
    case ${CHOICE} in
        1) manage_config ;;
        2) view_config ;;
        3) run_test ;;
        4) manage_cron ;;
        5) view_logs ;;
        0) 
            # 退出子菜单，返回 cfopt 主菜单
            echo -e "${CYAN}[INFO] 正在返回主菜单...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择，请输入 0-5 之间的数字${NC}"
            read -r -p "按回车键继续..." || true
            ;;
    esac
done

# 正常情况下不会到达这里，但为了安全起见
exit 0



