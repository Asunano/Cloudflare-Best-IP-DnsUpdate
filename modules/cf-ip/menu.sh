#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - CF-IP 优选配置向导 (Menu)
# Version: 0.1
# Description: 提供交互式界面用于配置测速参数、管理定时任务及查看运行状态
# Usage: bash modules/cf-ip/menu.sh
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 颜色定义（必须最先定义） ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

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
trap cleanup INT TERM HUP

# ==================== 路径初始化 ====================
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ====================== 【进程锁管理】 ======================
LOCK_FILE="${ROOT_DIR}/modules/cf-ip/.menu.lock"
acquire_lock() {
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
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
download_with_retry() {
    local url="$1"
    local output="$2"
    local expected_hash="${3:-}" # 可选参数，默认为空
    local max_retries=3
    local retry_count=0
    
    while [[ "${retry_count}" -lt "${max_retries}" ]]; do
        if curl -sL --connect-timeout 15 -o "${output}" "${url}" 2>/dev/null; then
            if [[ -s "${output}" ]]; then
                if [[ -n "${expected_hash}" ]]; then
                    local actual_hash
                    actual_hash="$(sha256sum "${output}" | awk '{print $1}')"
                    if [[ "${actual_hash}" = "${expected_hash}" ]]; then return 0; fi
                else
                    return 0
                fi
            fi
        fi
        retry_count=$((retry_count + 1))
        echo -e "${YELLOW}[WARN] 下载失败 (尝试 ${retry_count}/${max_retries})，正在重试...${NC}"
        sleep 2
    done
    return 1
}


# ====================== 【函数：检查配置文件】 ======================
check_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return 1
    fi
    
    # 检查是否为有效的 JSON 格式
    if ! jq empty "${CONFIG_FILE}" 2>/dev/null; then
        return 2
    fi
    
    # 检查是否包含关键配置字段（验证是否真正完成了用户配置）
    local has_colo
    has_colo=$(jq -r '.cfst.colo // empty' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -z "${has_colo}" ]]; then
        # 配置文件存在但缺少关键配置，视为未配置
        return 3
    fi
    
    return 0
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
    check_config || config_status=$?
    
    if [[ "${config_status}" -eq 0 ]]; then
        echo -e " ${GREEN}[OK] 配置文件: 已就绪"
    elif [[ "${config_status}" -eq 3 ]]; then
        echo -e " ${YELLOW}[WARN] 配置文件: 存在但未完成配置"
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
    # 调试：检查环境变量
    # 【修复】删除未使用的 run_sh 分支，仅保留 main_menu
    if [[ "${CF_OPT_ENTRY:-}" != "main_menu" ]]; then
        echo -e "${RED}[ERROR] 环境变量 CF_OPT_ENTRY 未设置或值不正确: '${CF_OPT_ENTRY:-空}'${NC}"
        echo -e "${RED}[ERROR] 请通过 'cfopt' 命令启动程序${NC}"
        return 1
    fi
    
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
    read -r -p "HTML输出文件路径（默认: /opt/1panel/www/sites/sw/index/index.html）: " OUTPUT_HTML
    OUTPUT_HTML=${OUTPUT_HTML:-"/opt/1panel/www/sites/sw/index/index.html"}
    
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
    
    read -r -p "延迟测速次数（默认: 8）: " CFST_PING_TIMES
    CFST_PING_TIMES=${CFST_PING_TIMES:-8}
    
    read -r -p "下载测速数量（默认: 10）: " CFST_DOWNLOAD_COUNT
    CFST_DOWNLOAD_COUNT=${CFST_DOWNLOAD_COUNT:-10}
    
    read -r -p "下载测速时间/秒（默认: 10）: " CFST_DOWNLOAD_TIME
    CFST_DOWNLOAD_TIME=${CFST_DOWNLOAD_TIME:-10}
    
    read -r -p "测速端口（留空=默认443）: " CFST_PORT
    
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
    
    read -r -p "IP段数据文件名（留空=使用默认ip.txt）: " CFST_IP_FILE
    
    read -r -p "禁用下载测速？(true/false，默认留空): " CFST_DISABLE_DOWNLOAD
    
    read -r -p "测速全部IP？(true/false，默认留空): " CFST_ALL_IP
    
    if ! generate_config_advanced; then
        echo -e "${RED}[ERROR] 配置生成失败，请重试${NC}"
        return 1
    fi
    
    return 0
}

# ====================== 【函数：生成简单配置】 ======================
generate_config_simple() {
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
                "take_ip_num": $take_ip_num,
                "max_retry": 3,
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
        log_error "配置文件生成失败"
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

# ====================== 【函数：生成高级配置】 ======================
generate_config_advanced() {
    # 使用 jq 创建完整的 JSON 配置文件
    local temp_file
    temp_file=$(mktemp)
    
    jq -n \
        --arg cfst_dir "${CFST_DIR}" \
        --arg output_html "${OUTPUT_HTML}" \
        --argjson take_ip_num "${TAKE_IP_NUM}" \
        --argjson max_retry "${MAX_RETRY}" \
        --argjson enable_log "${ENABLE_LOG}" \
        --argjson threads "${CFST_THREADS}" \
        --argjson ping_times "${CFST_PING_TIMES}" \
        --argjson download_count "${CFST_DOWNLOAD_COUNT}" \
        --argjson download_time "${CFST_DOWNLOAD_TIME}" \
        --arg port "${CFST_PORT:-443}" \
        --arg url "${CFST_URL:-https://cf-ns.com/cdn-cgi/trace}" \
        --argjson httping "${CFST_HTTPING}" \
        --arg colo "${CFST_COLO}" \
        --argjson latency_max "${CFST_LATENCY_MAX}" \
        --arg packet_loss_max "${CFST_PACKET_LOSS_MAX}" \
        --arg speed_min "${CFST_SPEED_MIN}" \
        --argjson show_count "${CFST_SHOW_COUNT}" \
        --arg ip_file "${CFST_IP_FILE}" \
        --arg disable_download "${CFST_DISABLE_DOWNLOAD:-false}" \
        --arg all_ip "${CFST_ALL_IP:-false}" \
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
                "output_html": ($output_html == "true"),
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
        }' > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    
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
    
    # 提取关键配置项
    local enabled threads colo ping_times download_count
    local latency_max packet_loss_max speed_min show_count
    local take_ip_num max_retry output_html enable_log
    
    enabled="$(jq -r '.enabled // false' "${CONFIG_FILE}")"
    threads="$(jq -r '.cfst.threads // 200' "${CONFIG_FILE}")"
    colo="$(jq -r '.cfst.colo // "HKG,NRT"' "${CONFIG_FILE}")"
    ping_times="$(jq -r '.cfst.ping_times // 4' "${CONFIG_FILE}")"
    download_count="$(jq -r '.cfst.download_count // 10' "${CONFIG_FILE}")"
    latency_max="$(jq -r '.cfst.latency_max // 9999' "${CONFIG_FILE}")"
    packet_loss_max="$(jq -r '.cfst.packet_loss_max // 100' "${CONFIG_FILE}")"
    speed_min="$(jq -r '.cfst.speed_min // 0' "${CONFIG_FILE}")"
    show_count="$(jq -r '.cfst.show_count // 20' "${CONFIG_FILE}")"
    take_ip_num="$(jq -r '.speed_test.take_ip_num // 5' "${CONFIG_FILE}")"
    max_retry="$(jq -r '.speed_test.max_retry // 3' "${CONFIG_FILE}")"
    output_html="$(jq -r '.speed_test.output_html // true' "${CONFIG_FILE}")"
    enable_log="$(jq -r '.speed_test.enable_log // true' "${CONFIG_FILE}")"
    
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
    
    # 双栏布局显示
    echo ""
    echo -e " ${GREEN}$(printf '%-24s' '[模块状态]')${NC}${GREEN}$(printf '%-24s' '[测速参数]')${NC}"
    echo -e "   $(printf '%-22s' "启用状态: ${status_enabled}")$(printf '%-22s' "并发线程: ${YELLOW}${threads}${NC}")"
    echo -e "   $(printf '%-22s' '')$(printf '%-22s' "测速节点: ${YELLOW}${colo}${NC}")"
    echo -e "   $(printf '%-22s' '')$(printf '%-22s' "Ping 次数: ${YELLOW}${ping_times}${NC}")"
    echo -e "   $(printf '%-22s' '')$(printf '%-22s' "下载测试: ${YELLOW}${download_count} 次${NC}")"
    
    echo ""
    echo -e " ${GREEN}$(printf '%-24s' '[筛选条件]')${NC}${GREEN}$(printf '%-24s' '[结果处理]')${NC}"
    echo -e "   $(printf '%-22s' "最大延迟: ${YELLOW}${latency_max} ms${NC}")$(printf '%-22s' "选取 IP 数: ${YELLOW}${take_ip_num} 个${NC}")"
    echo -e "   $(printf '%-22s' "最大丢包: ${YELLOW}${packet_loss_max}%${NC}")$(printf '%-22s' "最大重试: ${YELLOW}${max_retry} 次${NC}")"
    echo -e "   $(printf '%-22s' "最低速度: ${YELLOW}${speed_min} MB/s${NC}")$(printf '%-22s' "HTML 报告: ${status_html}")"
    echo -e "   $(printf '%-22s' "显示数量: ${YELLOW}${show_count} 个${NC}")$(printf '%-22s' "运行日志: ${status_log}")"
    
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
            CRON_DESC="每周日${CRON_HOUR}点${CRON_MIN}分"
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
    read -r -p "确认删除所有 CF-IP 相关的定时任务？(y/n): " CONFIRM_REMOVE
    
    if [[ "${CONFIRM_REMOVE}" = "y" ]] || [[ "${CONFIRM_REMOVE}" = "Y" ]]; then
        crontab -l 2>/dev/null | grep -v "cf-ip/core.sh" | crontab -
        echo -e "${GREEN}[OK] 定时任务已删除${NC}"
    fi
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
    CF_OPT_ENTRY=1 bash "${IP_AUTO_SCRIPT}" || true
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
    LOG_FILE="${LOG_DIR}/cfst_auto.log"
    CRON_LOG="${LOG_DIR}/cron.log"
    
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${YELLOW}请选择要查看的日志"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo -e " ${GREEN}➤${NC} 1. 运行日志 (cfst_auto.log)"
    echo -e " ${GREEN}➤${NC} 2. 定时任务日志 (cron.log)"
    echo -e " ${RED}➤${NC} 3. 返回"
    echo -e "${CYAN}+------------------------------------------------------------+"
    echo ""
    read -r -p "请选择 [1-3]: " LOG_CHOICE
    
    case ${LOG_CHOICE} in
        1)
            if [[ -f "${LOG_FILE}" ]]; then
                echo ""
                tail -50 "${LOG_FILE}"
            else
                echo -e "${YELLOW}[WARN] 日志文件不存在${NC}"
            fi
            ;;
        2)
            if [[ -f "${CRON_LOG}" ]]; then
                echo ""
                tail -50 "${CRON_LOG}"
            else
                echo -e "${YELLOW}[WARN] 日志文件不存在${NC}"
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
check_config
config_status=$?

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



