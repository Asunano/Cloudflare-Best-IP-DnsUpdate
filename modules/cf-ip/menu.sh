#!/bin/bash
# ==============================================================================
# cfopt - CF-IP 优选配置向导 (Menu)
# Version: 0.1
# Description: 提供交互式界面用于配置测速参数、管理定时任务及查看运行状态
# Usage: bash modules/cf-ip/menu.sh
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'
SCRIPT_VERSION="0.1"

# ==================== 信号捕获与资源清理 ====================
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "[ERROR] 安装脚本异常退出 (Code: $exit_code)"
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM HUP

# ==================== 路径初始化 ====================
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ====================== 【进程锁管理】 ======================
LOCK_FILE="$ROOT_DIR/modules/cf-ip/.menu.lock"
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # 校验 PID 是否有效且进程正在运行
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}[ERROR] 检测到另一个 CF-IP 管理进程正在运行 (PID: $pid)。${NC}"
            echo -e "${CYAN}提示:${NC} 如果确认没有进程在运行，请手动删除: $LOCK_FILE"
            exit 1
        else
            echo -e "${YELLOW}[WARN] 发现残留锁文件，正在清理...${NC}"
            rm -f "$LOCK_FILE"
        fi
    fi
    # 写入当前 PID 并设置退出时自动清理
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
}

# ====================== 【入口权限校验】 ======================
if [ "${CF_OPT_ENTRY:-}" != "main_menu" ] && [ "${CF_OPT_ENTRY:-}" != "run_sh" ]; then
    echo -e "${RED}[ERROR] 请使用 'cfopt' 命令进入主菜单运行此模块。${NC}"
    exit 1
fi

acquire_lock

CONFIG_FILE="$ROOT_DIR/conf/config.conf"
IP_AUTO_SCRIPT="$ROOT_DIR/modules/cf-ip/core.sh"
CFST_DIR="$ROOT_DIR/assets/bin/cfst"
CFST_BIN="$CFST_DIR/cfst"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ====================== 【函数：显示欢迎信息】 ======================
show_welcome() {
    clear 2>/dev/null || true
    echo ""
    echo "        Cloudflare IP 优选工具 - 智能管理系统"
    echo ""
    echo "   自动测速 | 智能筛选 | 定时更新 | 可视化管理"
    echo ""
}

# ====================== 【函数：显示分隔线】 ======================
show_separator() {
    echo "------------------------------------------------------------------------"
}

# ====================== 【函数：显示成功提示】 ======================
show_success() {
    echo "[OK] $1"
}

# ====================== 【函数：显示错误提示】 ======================
show_error() {
    echo "[ERROR] $1"
}

# ====================== 【函数：显示警告提示】 ======================
show_warning() {
    echo "[WARN] $1"
}

# ====================== 【函数：显示信息提示】 ======================
show_info() {
    echo "[INFO] $1"
}

# ====================== 【函数：暂停等待用户】 ======================
pause_and_continue() {
    local msg="${1:-按回车键继续...}"
    echo ""
    read -r -p "$msg" || true
}

# ====================== 【函数：安全读取输入】 ======================
safe_read() {
    local var_name="$1"
    shift
    read -r "$var_name" "$@" || true
}

# ====================== 【函数：带重试的下载与校验】 ======================
download_with_retry() {
    local url="$1"
    local output="$2"
    local expected_hash="$3" # 可选参数
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if wget -q --timeout=15 -O "$output" "$url" 2>/dev/null; then
            if [ -s "$output" ]; then
                if [ -n "$expected_hash" ]; then
                    local actual_hash=$(sha256sum "$output" | awk '{print $1}')
                    if [ "$actual_hash" = "$expected_hash" ]; then return 0; fi
                else
                    return 0
                fi
            fi
        fi
        retry_count=$((retry_count + 1))
        echo -e "${YELLOW}[WARN] 下载失败 (尝试 $retry_count/$max_retries)，正在重试...${NC}"
        sleep 2
    done
    return 1
}

# ====================== 【函数：检查配置文件】 ======================
check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    
    # 检查是否包含必要的配置项
    if ! grep -q "OUTPUT_HTML" "$CONFIG_FILE" || \
       ! grep -q "TAKE_IP_NUM" "$CONFIG_FILE"; then
        return 2
    fi
    
    return 0
}

# ====================== 【函数：显示帮助信息】 ======================
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
    echo "  1. 首次使用 -> 选择 '1) 首次安装向导'"
    echo "  2. 日常维护 -> 通过主菜单管理配置和定时任务"
    echo "  3. 手动测试 -> 选择 '5) 手动执行测速' 立即运行"
    echo ""
    echo "【配置文件说明】"
    echo "  config.conf - 存储所有配置参数"
    echo "     位置：$CONFIG_FILE"
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
    show_welcome
    
    # 检查配置状态
    local config_status=0
    check_config || config_status=$?
    
    echo "=== 系统状态 ==="
    show_separator
    
    if [ $config_status -eq 0 ]; then
        show_success "配置文件：已配置且有效"
    elif [ $config_status -eq 1 ]; then
        show_error "配置文件：未找到（需要首次安装）"
    else
        show_warning "配置文件：存在但不完整（建议重新配置）"
    fi
    
    # 检查定时任务
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "ip_auto.sh" || true; then
            CRON_INFO=$(crontab -l 2>/dev/null | grep "ip_auto.sh" || true)
            if [ -n "$CRON_INFO" ]; then
                show_success "定时任务：已配置"
                echo "   $CRON_INFO"
            else
                show_warning "定时任务：未配置（建议设置以自动更新）"
            fi
        else
            show_warning "定时任务：未配置（建议设置以自动更新）"
        fi
    else
        show_error "定时任务：crontab 未安装"
        show_info "请先安装：yum install -y cronie 或 apt-get install -y cron"
    fi
    
    # 检查核心文件
    echo ""
    if [ -f "$CFST_BIN" ]; then
        show_success "测速程序：cfst 已就绪"
    else
        show_warning "测速程序：cfst 未找到（需要安装）"
    fi
    
    if [ -f "$IP_AUTO_SCRIPT" ]; then
        show_success "核心脚本：ip_auto.sh 已就绪"
    else
        show_error "核心脚本：ip_auto.sh 未找到（需要安装）"
    fi
    
    echo ""
    show_separator
    echo "=== 主菜单 ==="
    show_separator
    echo ""
    echo "  1) 首次安装向导    - 下载程序 + 引导配置（新手推荐）"
    echo "  2) 修改配置        - 重新配置测速参数"
    echo "  3) 查看当前配置    - 浏览 config.conf 内容"
    echo "  4) 管理定时任务    - 添加/删除/查看定时任务"
    echo "  5) 手动执行测速    - 立即运行一次测速"
    echo "  6) 查看日志        - 查看运行日志和错误信息"
    echo "  7) 使用帮助        - 查看详细使用说明"
    echo "  0) 退出系统        - 返回主菜单"
    echo ""
    show_separator
}

# ====================== 【函数：首次安装向导】 ======================
install_wizard() {
    clear
    show_welcome
    echo "=== 首次安装向导 ==="
    show_separator
    echo ""
    echo "本向导将帮助您完成以下操作："
    echo "  1. 确认工作目录"
    echo "  2. 下载 CloudflareSpeedTest 测速程序"
    echo "  3. 检查/下载 ip_auto.sh 核心脚本"
    echo "  4. 配置测速参数"
    echo ""
    show_info "整个过程大约需要 2-5 分钟，请保持网络连接"
    pause_and_continue "按回车键开始安装..."
    
    # 第1步：确认安装目录
    echo ""
    echo "【步骤 1/4】 确认工作目录"
    show_separator
    echo ""
    echo "工作目录说明："
    echo "  所有程序文件、配置文件、日志文件都将存放在此目录中。"
    
    # 动态推荐路径：如果是 root 则推荐 /root/cfopt，否则推荐 ~/cfopt
    if [ "$EUID" -eq 0 ]; then
        DEFAULT_INSTALL_DIR="/root/cfopt"
    else
        DEFAULT_INSTALL_DIR="$HOME/cfopt"
    fi
    
    echo "  推荐路径：$DEFAULT_INSTALL_DIR"
    echo ""
    echo "当前脚本所在目录：$SCRIPT_DIR"
    read -p "是否使用当前脚本所在目录？(y/n，默认y): " USE_CURRENT
    USE_CURRENT=${USE_CURRENT:-y}
    
    if [ "$USE_CURRENT" != "y" ] && [ "$USE_CURRENT" != "Y" ]; then
        echo ""
        echo "请输入新的安装目录："
        read -p "目录路径: " INSTALL_DIR
        
        # 创建目录
        if [ ! -d "$INSTALL_DIR" ]; then
            mkdir -p "$INSTALL_DIR"
            if [ $? -eq 0 ]; then
                show_success "目录创建成功：$INSTALL_DIR"
            else
                show_error "无法创建目录：$INSTALL_DIR"
                pause_and_continue "按回车键返回主菜单..."
                return 1
            fi
        else
            show_warning "目录已存在：$INSTALL_DIR"
        fi
        
        cd "$INSTALL_DIR" || {
            show_error "无法进入目录：$INSTALL_DIR"
            pause_and_continue "按回车键返回主菜单..."
            return 1
        }
        SCRIPT_DIR="$INSTALL_DIR"
        CONFIG_FILE="$SCRIPT_DIR/config.conf"
        IP_AUTO_SCRIPT="$SCRIPT_DIR/ip_auto.sh"
        CFST_DIR="$SCRIPT_DIR/cfst"
        CFST_BIN="$CFST_DIR/cfst"
    fi
    
    show_success "工作目录确认：$SCRIPT_DIR"
    pause_and_continue "按回车键继续..."
    
    echo ""
    
    # 第2步：下载测速程序
    echo -e "${BLUE}【步骤 2/4】${NC} 下载 CloudflareSpeedTest 测速程序"
    echo "--------------------------------------------------------"
    
    CFST_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.4/cfst_linux_amd64.tar.gz"
    CFST_FILE="cfst_linux_amd64.tar.gz"
    
    # 确保 cfst 目录存在
    mkdir -p "$CFST_DIR"
    
    if [ ! -f "$CFST_BIN" ]; then
        echo -e "${YELLOW}[WARN] 检测到已存在的 cfst 文件${NC}"
        read -p "是否重新下载？(y/n，默认n): " REDOWNLOAD_CFST
        REDOWNLOAD_CFST=${REDOWNLOAD_CFST:-n}
        if [ "$REDOWNLOAD_CFST" = "y" ] || [ "$REDOWNLOAD_CFST" = "Y" ]; then
            echo "正在下载..."
            if download_with_retry "$CFST_URL" "$CFST_FILE"; then
                tar -zxf "$CFST_FILE" -C "$CFST_DIR"
                chmod +x "$CFST_BIN"
                echo -e "${GREEN}[OK] 测速程序更新成功${NC}"
            else
                echo -e "${RED}[ERROR] 下载失败，请检查网络或稍后重试${NC}"
                return 1
            fi
        else
            echo -e "${GREEN}[OK] 跳过下载，使用现有文件${NC}"
        fi
    else
        echo "正在下载测速程序..."
        if download_with_retry "$CFST_URL" "$CFST_FILE"; then
            tar -zxf "$CFST_FILE" -C "$CFST_DIR"
            chmod +x "$CFST_BIN"
            echo -e "${GREEN}[OK] 测速程序下载并安装成功${NC}"
        else
            echo -e "${RED}[ERROR] 下载失败，请检查网络连接${NC}"
            return 1
        fi
    fi
    
    echo ""
    
    # 第3步：下载 ip_auto.sh
    echo -e "${BLUE}【步骤 3/4】${NC} 检查核心脚本"
    echo "--------------------------------------------------------"
    
    if [ ! -f "$IP_AUTO_SCRIPT" ]; then
        echo -e "${YELLOW}[WARN] 未找到 ip_auto.sh${NC}"
        read -p "是否手动输入下载地址？(y/n，默认n): " DOWNLOAD_SCRIPT
        DOWNLOAD_SCRIPT=${DOWNLOAD_SCRIPT:-n}
        
        if [ "$DOWNLOAD_SCRIPT" = "y" ] || [ "$DOWNLOAD_SCRIPT" = "Y" ]; then
            read -p "请输入 ip_auto.sh 的下载地址: " SCRIPT_URL
            wget -N -O "$IP_AUTO_SCRIPT" "$SCRIPT_URL"
            if [ $? -eq 0 ]; then
                chmod +x "$IP_AUTO_SCRIPT"
                echo -e "${GREEN}[OK] 脚本下载成功${NC}"
            else
                echo -e "${RED}[ERROR] 下载失败${NC}"
                return 1
            fi
        else
            echo -e "${RED}[ERROR] 缺少 ip_auto.sh，无法继续${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}[OK] ip_auto.sh 已存在${NC}"
    fi
    
    echo ""
    
    # 第4步：配置向导
    echo -e "${BLUE}【步骤 4/4】${NC} 配置向导"
    echo "--------------------------------------------------------"
    configure_interactive
    
    echo ""
    echo -e "${GREEN}[OK] 安装完成！${NC}"
    read -p "按回车键返回主菜单..."
}

# ====================== 【函数：交互式配置】 ======================
configure_interactive() {
    echo ""
    echo "请选择配置模式："
    echo "  1) 简单模式 - 只需配置几个关键参数（推荐新手）"
    echo "  2) 高级模式 - 配置所有参数（适合有经验的用户）"
    echo ""
    read -p "请选择（1/2，默认1）: " CONFIG_MODE
    CONFIG_MODE=${CONFIG_MODE:-1}
    
    if [ "$CONFIG_MODE" = "1" ]; then
        configure_simple
    else
        configure_advanced
    fi
}

# ====================== 【函数：简单配置】 ======================
configure_simple() {
    echo ""
    echo -e "${GREEN}━━━ 简单配置模式 ━━━${NC}"
    echo ""
    
    read -p "1. HTML输出文件路径（默认: /opt/1panel/www/sites/sw/index/index.html）: " OUTPUT_HTML
    OUTPUT_HTML=${OUTPUT_HTML:-"/opt/1panel/www/sites/sw/index/index.html"}
    
    read -p "2. 需要提取的优质IP数量（默认: 5）: " TAKE_IP_NUM
    TAKE_IP_NUM=${TAKE_IP_NUM:-5}
    
    echo ""
    echo "常用地区代码："
    echo "  HKG=香港  NRT=东京  LAX=洛杉矶  SJC=旧金山"
    echo "  SEA=西雅图  SIN=新加坡  ICN=首尔  TPE=台北"
    read -p "3. 测速地区（多个用逗号分隔，默认: HKG,NRT）: " CFST_COLO
    CFST_COLO=${CFST_COLO:-"HKG,NRT"}
    
    read -p "4. 测速线程数（建议100-200，默认: 200）: " CFST_THREADS
    CFST_THREADS=${CFST_THREADS:-200}
    
    # 增加测速策略选择
    echo ""
    echo -e "${YELLOW}[INFO] 请选择 IP 优选策略 (第一层):${NC}"
    echo "  1) 国内通用推荐     - 综合筛选大陆访问最快的节点 (HKG, NRT)"
    echo "  2) 移动线路专项     - 针对中国移动优化 (HKG, SIN, TYO, LON)"
    echo "  3) 联通线路专项     - 针对中国联通优化 (SJC, LAX, SIN, TYO)"
    echo "  4) 电信线路专项     - 针对中国电信优化 (SJC, LAX, TYO, SIN)"
    echo "  5) 按大洲/区域筛选  - 进入二级菜单选择 (亚太/北美/欧洲等)"
    echo "  6) 手动指定地区代码 - 查看代码表并自由组合"
    echo "  7) 自定义 Colo 列表 - 直接输入已知的代码"
    echo ""
    read -p "请输入选项编号 (1-7，默认 1): " STRATEGY_CHOICE
    STRATEGY_CHOICE=${STRATEGY_CHOICE:-1}
    
    case $STRATEGY_CHOICE in
        2) CFST_COLO="HKG,SIN,TYO,LON" ;;
        3) CFST_COLO="SJC,LAX,SIN,TYO" ;;
        4) CFST_COLO="SJC,LAX,TYO,SIN" ;;
        5)
            # 二级菜单：区域细分
            echo ""
            echo -e "${CYAN}[INFO] 请选择目标地理区域 (第二层):${NC}"
            echo "  1) 亚太地区 (APAC)   - HKG, NRT, ICN, SIN, TPE, KUL, BKK"
            echo "  2) 北美地区 (NA)     - LAX, SJC, SEA, LAS, MIA, YVR, ORD"
            echo "  3) 欧洲地区 (EU)     - LHR, FRA, AMS, MAD, WAW, ARN"
            echo "  4) 南美/大洋洲 (SA/OC)- GRU, EZE, SYD, MEL"
            echo ""
            read -p "请输入区域编号 (1-4，默认 1): " REGION_CHOICE
            case $REGION_CHOICE in
                2) CFST_COLO="LAX,SJC,SEA,LAS,MIA,YVR,ORD" ;;
                3) CFST_COLO="LHR,FRA,AMS,MAD,WAW,ARN" ;;
                4) CFST_COLO="GRU,EZE,SYD,MEL" ;;
                *) CFST_COLO="HKG,NRT,ICN,SIN,TPE,KUL,BKK" ;; # 默认亚太
            esac
            ;;
        6)
            # 三级菜单：详细代码参考与手动输入
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e " ${YELLOW}Cloudflare 数据中心代码参考表${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo "  [亚太] HKG(香港) NRT(东京) ICN(首尔) SIN(新加坡)"
            echo "         TPE(台北) KUL(吉隆坡) BKK(曼谷) MNL(马尼拉)"
            echo "  [北美] LAX(洛杉矶) SJC(圣何塞) SEA(西雅图) LAS(拉斯维加斯)"
            echo "         MIA(迈阿密) YVR(温哥华) ORD(芝加哥) DEN(丹佛)"
            echo "  [欧洲] LHR(伦敦) FRA(法兰克福) AMS(阿姆斯特丹) MAD(马德里)"
            echo "         WAW(华沙) ARN(斯德哥尔摩) CDG(巴黎) ZRH(苏黎世)"
            echo "  [其他] GRU(圣保罗) EZE(布宜诺斯艾利斯) SYD(悉尼) MEL(墨尔本)"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}提示:${NC} 请输入代码并用逗号分隔 (例如: HKG,SJC,LHR)"
            read -p "请输入您想测试的地区代码: " CFST_COLO
            ;;
        7) 
            read -p "请直接输入 Colo 代码 (用逗号分隔): " CFST_COLO
            ;;
        *) CFST_COLO="HKG,NRT" ;; # 默认通用
    esac
    
    read -p "5. 是否启用日志记录？(y/n，默认n): " ENABLE_LOG_INPUT
    if [ "$ENABLE_LOG_INPUT" = "y" ] || [ "$ENABLE_LOG_INPUT" = "Y" ]; then
        ENABLE_LOG="true"
    else
        ENABLE_LOG="false"
    fi
    
    # 询问是否配置多线路分流
    echo ""
    echo -e "${YELLOW}[INFO] 是否配置运营商分流测速？${NC}"
    echo "  如果您使用 DNSPod 等多线路解析服务，建议开启此功能。"
    read -p "是否开启？(y/n，默认n): " MULTI_LINE_INPUT
    if [ "$MULTI_LINE_INPUT" = "y" ] || [ "$MULTI_LINE_INPUT" = "Y" ]; then
        configure_multi_line_params
    fi
    
    generate_config_simple
}

# ====================== 【函数：高级配置】 ======================
configure_advanced() {
    echo ""
    echo -e "${GREEN}━━━ 高级配置模式 ━━━${NC}"
    echo ""
    echo "提示：直接回车使用默认值，留空表示不启用该参数"
    echo ""
    
    echo -e "${YELLOW}【基础配置】${NC}"
    read -p "HTML输出文件路径（默认: /opt/1panel/www/sites/sw/index/index.html）: " OUTPUT_HTML
    OUTPUT_HTML=${OUTPUT_HTML:-"/opt/1panel/www/sites/sw/index/index.html"}
    
    read -p "需要提取的优质IP数量（默认: 5）: " TAKE_IP_NUM
    TAKE_IP_NUM=${TAKE_IP_NUM:-5}
    
    read -p "测速失败最大重试次数（默认: 5）: " MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}
    
    read -p "是否启用日志记录？(true/false，默认: false): " ENABLE_LOG
    ENABLE_LOG=${ENABLE_LOG:-"false"}
    
    # 询问是否配置多线路分流
    echo ""
    echo -e "${YELLOW}[INFO] 是否配置运营商分流测速？${NC}"
    echo "  如果您使用 DNSPod 等多线路解析服务，建议开启此功能。"
    read -p "是否开启？(y/n，默认n): " MULTI_LINE_INPUT
    if [ "$MULTI_LINE_INPUT" = "y" ] || [ "$MULTI_LINE_INPUT" = "Y" ]; then
        configure_multi_line_params
    fi
    
    echo ""
    echo -e "${YELLOW}【CFST 测速参数】${NC}"
    read -p "延迟测速线程数（默认: 200）: " CFST_THREADS
    CFST_THREADS=${CFST_THREADS:-200}
    
    read -p "延迟测速次数（默认: 8）: " CFST_PING_TIMES
    CFST_PING_TIMES=${CFST_PING_TIMES:-8}
    
    read -p "下载测速数量（默认: 10）: " CFST_DOWNLOAD_COUNT
    CFST_DOWNLOAD_COUNT=${CFST_DOWNLOAD_COUNT:-10}
    
    read -p "下载测速时间/秒（默认: 10）: " CFST_DOWNLOAD_TIME
    CFST_DOWNLOAD_TIME=${CFST_DOWNLOAD_TIME:-10}
    
    read -p "测速端口（留空=默认443）: " CFST_PORT
    
    read -p "测速地址URL（留空=使用默认）: " CFST_URL
    
    read -p "使用HTTPing模式？(true/false，默认: true): " CFST_HTTPING
    CFST_HTTPING=${CFST_HTTPING:-"true"}
    
    echo ""
    echo "常用地区代码：HKG=香港 NRT=东京 LAX=洛杉矶 SJC=旧金山 SEA=西雅图"
    echo -e "${YELLOW}[INFO] 测速策略参考:${NC}"
    echo "  - 移动优化: HKG,SIN,TYO,LON"
    echo "  - 亚太专属: HKG,NRT,ICN,SIN,TPE,KUL,BKK"
    echo "  - 美洲专属: LAX,SJC,SEA,LAS,MIA,YVR"
    read -p "匹配指定地区 (直接回车使用默认 HKG,NRT): " CFST_COLO
    CFST_COLO=${CFST_COLO:-"HKG,NRT"}
    
    read -p "平均延迟上限/ms（默认: 400）: " CFST_LATENCY_MAX
    CFST_LATENCY_MAX=${CFST_LATENCY_MAX:-400}
    
    read -p "丢包几率上限（默认: 0.3）: " CFST_PACKET_LOSS_MAX
    CFST_PACKET_LOSS_MAX=${CFST_PACKET_LOSS_MAX:-0.3}
    
    read -p "下载速度下限/MB/s（默认: 0.2）: " CFST_SPEED_MIN
    CFST_SPEED_MIN=${CFST_SPEED_MIN:-0.2}
    
    read -p "显示结果数量（0=不显示，默认: 0）: " CFST_SHOW_COUNT
    CFST_SHOW_COUNT=${CFST_SHOW_COUNT:-0}
    
    read -p "IP段数据文件名（留空=使用默认ip.txt）: " CFST_IP_FILE
    
    read -p "禁用下载测速？(true/false，默认留空): " CFST_DISABLE_DOWNLOAD
    
    read -p "测速全部IP？(true/false，默认留空): " CFST_ALL_IP
    
    generate_config_advanced
}

# ====================== 【函数：生成简单配置】 ======================
generate_config_simple() {
    cat > "$CONFIG_FILE" << 'EOF'
# ============================================================
# 自动生成的配置文件 - 由 install_setup.sh 创建
# 此文件的配置会优先于 ip_auto.sh 中的默认配置
# ============================================================
EOF
    
    cat >> "$CONFIG_FILE" << EOF
# --- 基础配置 ---
CFST_DIR="$CFST_DIR"
OUTPUT_HTML="$OUTPUT_HTML"
TAKE_IP_NUM=$TAKE_IP_NUM

# --- CFST 测速参数 ---
CFST_THREADS="$CFST_THREADS"
CFST_COLO="$CFST_COLO"
ENABLE_LOG="$ENABLE_LOG"
EOF
    
    chmod +x "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}[OK] 简单配置完成！${NC}"
    echo "配置文件已保存到：$CONFIG_FILE"
}

# ====================== 【函数：多线路参数配置】 ======================
configure_multi_line_params() {
    echo ""
    echo -e "${CYAN}━━━ 运营商分流测速配置 ━━━${NC}"
    echo "请为不同运营商选择最优的 Cloudflare 数据中心 (Colo)"
    echo -e "${YELLOW}提示:${NC} Cloudflare DNS 更新将统一使用【默认/移动】线路的结果。"
    echo ""
    
    # 定义常用节点选项
    local options=("HKG(香港)" "SIN(新加坡)" "TYO(东京)" "LAX(洛杉矶)" "SJC(圣何塞)" "LON(伦敦)" "SEA(西雅图)")
    
    # 辅助函数：显示选择菜单并处理自定义输入
    select_colo() {
        local line_name=$1
        local default_val=$2
        echo -e "\n${YELLOW}请选择 ${line_name} 的最佳节点:${NC}"
        for i in "${!options[@]}"; do
            echo "  $((i+1))) ${options[$i]}"
        done
        echo -e "  ${GREEN}0) 手动输入自定义节点代码 (如: HKG,SJC)${NC}"
        read -p "请输入编号或直接回车使用默认 ($default_val): " selection
        
        if [ -z "$selection" ]; then
            echo "$default_val"
        elif [ "$selection" = "0" ]; then
            read -p "请输入 Colo 代码 (用逗号分隔): " custom_input
            echo "${custom_input:-$default_val}"
        else
            local result=""
            for num in $selection; do
                local idx=$((num-1))
                if [ -n "${options[$idx]+x}" ]; then
                    local code=$(echo "${options[$idx]}" | cut -d'(' -f1)
                    result="$result$code,"
                fi
            done
            echo "${result%,}" # 去掉末尾逗号
        fi
    }

    COLO_MOBILE=$(select_colo "移动/默认线路" "HKG,SIN,TYO,LON")
    COLO_UNICOM=$(select_colo "联通线路" "SJC,LAX,SIN,TYO")
    COLO_TELECOM=$(select_colo "电信线路" "SJC,LAX,TYO,SIN")
    
    # 将配置直接写入 cf-ip 的主配置文件 config.conf
    # 这样 scheduler 只需要 source 一个文件即可
    cat >> "$CONFIG_FILE" << EOF

# --- 多线路测速配置 ---
ENABLE_MULTI_LINE="true"
COLO_MOBILE="$COLO_MOBILE"
COLO_UNICOM="$COLO_UNICOM"
COLO_TELECOM="$COLO_TELECOM"
EOF
    
    echo -e "\n${GREEN}[OK] 多线路配置已保存至主配置文件。${NC}"
}

# ====================== 【函数：生成高级配置】 ======================
generate_config_advanced() {
    cat > "$CONFIG_FILE" << 'EOF'
# ============================================================
# 自动生成的配置文件 - 由 install_setup.sh 创建
# 此文件的配置会优先于 ip_auto.sh 中的默认配置
# ============================================================
EOF
    
    cat >> "$CONFIG_FILE" << EOF
# --- 基础配置 ---
CFST_DIR="$CFST_DIR"
OUTPUT_HTML="$OUTPUT_HTML"
TAKE_IP_NUM=$TAKE_IP_NUM
MAX_RETRY=$MAX_RETRY
ENABLE_LOG="$ENABLE_LOG"

# --- CFST 测速参数 ---
CFST_THREADS="$CFST_THREADS"
CFST_PING_TIMES="$CFST_PING_TIMES"
CFST_DOWNLOAD_COUNT="$CFST_DOWNLOAD_COUNT"
CFST_DOWNLOAD_TIME="$CFST_DOWNLOAD_TIME"
CFST_PORT="$CFST_PORT"
CFST_URL="$CFST_URL"
CFST_HTTPING="$CFST_HTTPING"
CFST_COLO="$CFST_COLO"
CFST_LATENCY_MAX="$CFST_LATENCY_MAX"
CFST_PACKET_LOSS_MAX="$CFST_PACKET_LOSS_MAX"
CFST_SPEED_MIN="$CFST_SPEED_MIN"
CFST_SHOW_COUNT="$CFST_SHOW_COUNT"
CFST_IP_FILE="$CFST_IP_FILE"
CFST_DISABLE_DOWNLOAD="$CFST_DISABLE_DOWNLOAD"
CFST_ALL_IP="$CFST_ALL_IP"
EOF
    
    chmod +x "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}[OK] 高级配置完成！${NC}"
    echo "配置文件已保存到：$CONFIG_FILE"
}

# ====================== 【函数：修改配置】 ======================
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 配置文件不存在，请先运行安装向导${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    echo ""
    echo -e "${YELLOW}当前配置：${NC}"
    cat "$CONFIG_FILE"
    echo ""
    
    read -p "是否重新配置？(y/n，默认n): " RECONFIG
    RECONFIG=${RECONFIG:-n}
    
    if [ "$RECONFIG" = "y" ] || [ "$RECONFIG" = "Y" ]; then
        configure_interactive
    fi
    
    read -p "按回车键返回..."
}

# ====================== 【函数：查看配置】 ======================
view_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 配置文件不存在${NC}"
    else
        echo ""
        echo -e "${YELLOW}=== 当前配置 ===${NC}"
        cat "$CONFIG_FILE"
        echo -e "${YELLOW}==================${NC}"
    fi
    
    read -p "按回车键返回..."
}

# ====================== 【函数：管理定时任务】 ======================
manage_cron() {
    echo ""
    echo -e "${BLUE}【定时任务管理】${NC}"
    echo "--------------------------------------------------------"
    
    if ! command -v crontab >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 系统未安装 crontab${NC}"
        echo "请先安装：yum install -y cronie 或 apt-get install -y cron"
        read -p "按回车键返回..."
        return
    fi
    
    # 显示当前定时任务
    echo ""
    echo "当前定时任务："
    CRON_LIST=$(crontab -l 2>/dev/null | grep "ip_auto.sh")
    if [ -n "$CRON_LIST" ]; then
        echo -e "${GREEN}$CRON_LIST${NC}"
    else
        echo -e "${YELLOW}未配置定时任务${NC}"
    fi
    
    echo ""
    echo "请选择操作："
    echo "  1) 添加/修改定时任务"
    echo "  2) 删除定时任务"
    echo "  3) 返回"
    echo ""
    read -p "请选择（1-3）: " CRON_ACTION
    
    case $CRON_ACTION in
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
    
    read -p "按回车键返回..."
}

# ====================== 【函数：设置定时任务】 ======================
setup_cron() {
    echo ""
    echo "请选择执行频率："
    echo "  1) 每小时执行一次"
    echo "  2) 每6小时执行一次"
    echo "  3) 每天执行一次（推荐）"
    echo "  4) 每周执行一次"
    echo "  5) 自定义cron表达式"
    echo ""
    read -p "请选择（1-5，默认3）: " CRON_OPTION
    CRON_OPTION=${CRON_OPTION:-3}
    
    case $CRON_OPTION in
        1)
            CRON_EXPR="0 * * * *"
            CRON_DESC="每小时"
            ;;
        2)
            CRON_EXPR="0 */6 * * *"
            CRON_DESC="每6小时"
            ;;
        3)
            read -p "请输入执行时间（格式：小时 分钟，默认 3 0 表示凌晨3点）: " CRON_TIME
            CRON_TIME=${CRON_TIME:-"3 0"}
            CRON_HOUR=$(echo $CRON_TIME | awk '{print $1}')
            CRON_MIN=$(echo $CRON_TIME | awk '{print $2}')
            CRON_EXPR="$CRON_MIN $CRON_HOUR * * *"
            CRON_DESC="每天${CRON_HOUR}点${CRON_MIN}分"
            ;;
        4)
            read -p "请输入星期几（0-7，0和7都表示周日，默认0）: " CRON_WEEKDAY
            CRON_WEEKDAY=${CRON_WEEKDAY:-0}
            read -p "请输入执行时间（格式：小时 分钟，默认 3 0）: " CRON_TIME
            CRON_TIME=${CRON_TIME:-"3 0"}
            CRON_HOUR=$(echo $CRON_TIME | awk '{print $1}')
            CRON_MIN=$(echo $CRON_TIME | awk '{print $2}')
            CRON_EXPR="$CRON_MIN $CRON_HOUR * * $CRON_WEEKDAY"
            CRON_DESC="每周日${CRON_HOUR}点${CRON_MIN}分"
            ;;
        5)
            echo "请输入cron表达式（格式：分 时 日 月 周）"
            echo "例如：0 3 * * * 表示每天凌晨3点"
            read -p "cron表达式: " CRON_EXPR
            CRON_DESC="自定义"
            ;;
        *)
            CRON_EXPR="0 3 * * *"
            CRON_DESC="每天凌晨3点"
            ;;
    esac
    
    SCRIPT_PATH="$IP_AUTO_SCRIPT"
    LOG_DIR="$ROOT_DIR/logs/cf-ip"
    mkdir -p "$LOG_DIR"
    LOG_PATH="$LOG_DIR/cron.log"
    CRON_CMD="$CRON_EXPR /bin/bash $SCRIPT_PATH >> $LOG_PATH 2>&1"
    
    echo ""
    echo -e "${YELLOW}即将添加以下定时任务：${NC}"
    echo "  执行频率：$CRON_DESC"
    echo "  Cron表达式：$CRON_EXPR"
    echo "  执行脚本：$SCRIPT_PATH"
    echo "  日志文件：$LOG_PATH"
    echo ""
    read -p "确认添加？(y/n，默认y): " CONFIRM_CRON
    CONFIRM_CRON=${CONFIRM_CRON:-y}
    
    if [ "$CONFIRM_CRON" = "y" ] || [ "$CONFIRM_CRON" = "Y" ]; then
        # 先删除旧的，再添加新的
        (crontab -l 2>/dev/null | grep -v "ip_auto.sh"; echo "$CRON_CMD") | crontab -
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[OK] 定时任务添加成功！${NC}"
        else
            echo -e "${RED}[ERROR] 定时任务添加失败${NC}"
        fi
    fi
}

# ====================== 【函数：删除定时任务】 ======================
remove_cron() {
    echo ""
    read -p "确认删除所有 ip_auto.sh 相关的定时任务？(y/n): " CONFIRM_REMOVE
    
    if [ "$CONFIRM_REMOVE" = "y" ] || [ "$CONFIRM_REMOVE" = "Y" ]; then
        crontab -l 2>/dev/null | grep -v "ip_auto.sh" | crontab -
        echo -e "${GREEN}[OK] 定时任务已删除${NC}"
    fi
}

# ====================== 【函数：手动执行测速】 ======================
run_test() {
    if [ ! -f "$IP_AUTO_SCRIPT" ]; then
        echo -e "${RED}[ERROR] ip_auto.sh 不存在${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    echo ""
    echo -e "${YELLOW}开始执行测速...${NC}"
    echo "--------------------------------------------------------"
    CF_OPT_ENTRY=1 bash "$IP_AUTO_SCRIPT"
    echo ""
    read -p "按回车键返回..."
}

# ====================== 【函数：查看日志】 ======================
view_logs() {
    echo ""
    echo -e "${BLUE}【日志查看】${NC}"
    echo "--------------------------------------------------------"
    
    LOG_DIR="$ROOT_DIR/logs/cf-ip"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/cfst_auto.log"
    CRON_LOG="$LOG_DIR/cron.log"
    
    echo "请选择要查看的日志："
    echo "  1) 运行日志 (cfst_auto.log)"
    echo "  2) 定时任务日志 (cron.log)"
    echo "  3) 返回"
    echo ""
    read -p "请选择（1-3）: " LOG_CHOICE
    
    case $LOG_CHOICE in
        1)
            if [ -f "$LOG_FILE" ]; then
                echo ""
                tail -50 "$LOG_FILE"
            else
                echo -e "${YELLOW}[WARN] 日志文件不存在${NC}"
            fi
            ;;
        2)
            if [ -f "$CRON_LOG" ]; then
                echo ""
                tail -50 "$CRON_LOG"
            else
                echo -e "${YELLOW}[WARN] 日志文件不存在${NC}"
            fi
            ;;
        *)
            return
            ;;
    esac
    
    read -p "按回车键返回..."
}

# ====================== 【主程序】 ======================
# 检查入口权限
if [ "${CF_OPT_ENTRY:-}" != "main_menu" ] && [ "${CF_OPT_ENTRY:-}" != "run_sh" ]; then
    echo -e "${RED}[ERROR] 请使用 'cfopt' 命令进入主菜单运行此模块。${NC}"
    exit 1
fi

# 如果配置文件不存在，引导用户进行首次配置
check_config
config_status=$?

if [ $config_status -ne 0 ]; then
    echo -e "${YELLOW}[INFO] 检测到您尚未配置 CF 优选参数，即将进入安装向导...${NC}"
    sleep 2
    install_wizard
fi

# 主循环
while true; do
    show_main_menu
    read -p "请选择功能 [0-8]: " CHOICE
    
    case $CHOICE in
        1)
            install_wizard
            ;;
        2)
            modify_config
            ;;
        3)
            view_config
            ;;
        4)
            manage_cron
            ;;
        5)
            run_test
            ;;
        6)
            view_logs
            ;;
        7)
            show_help
            ;;
        0)
            clear
            show_welcome
            echo "感谢使用 Cloudflare IP 优选工具！"
            echo ""
            echo "祝您使用愉快，再见！"
            echo ""
            exit 0
            ;;
        *)
            echo ""
            show_error "无效选择，请输入 0-7 之间的数字"
            sleep 2
            ;;
    esac
done
