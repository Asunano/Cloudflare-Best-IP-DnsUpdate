#!/bin/bash
# ==============================================================================
# cfopt - Cloudflare IP 优选与 DNS 管理套件 (主入口)
# Version: 0.1
# Description: 自动化测速、IP 同步及 DNS 记录更新的综合管理入口
# Author: cfopt Team
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

# --- 终端颜色定义 (必须最先定义，防止 set -u 报错) ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# --- 全局配置区 ---
SCRIPT_VERSION="0.1"
REMOTE_URL="https://raw.githubusercontent.com/Ausnana/Cloudflare-Best-IP-DnsUpdate/main"
VERSION_FILE_REMOTE="$REMOTE_URL/version.txt"

# 根据用户权限动态确定安装目录
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/root/cfopt"
else
    INSTALL_DIR="$HOME/cfopt"
fi

# --- 自动归位逻辑：确保脚本在标准目录下运行 ---
CURRENT_SCRIPT_PATH=$(readlink -f "$0")
TARGET_SCRIPT_PATH="$INSTALL_DIR/cfopt.sh"

if [ "$CURRENT_SCRIPT_PATH" != "$TARGET_SCRIPT_PATH" ]; then
    echo -e "${CYAN}[INFO] 检测到脚本位于非标准目录，正在迁移至: $INSTALL_DIR${NC}"
    mkdir -p "$INSTALL_DIR"
    
    # 移动脚本并保留执行权限
    if mv "$CURRENT_SCRIPT_PATH" "$TARGET_SCRIPT_PATH"; then
        chmod +x "$TARGET_SCRIPT_PATH"
        echo -e "${GREEN}[OK] 迁移成功，正在从新位置启动...${NC}"
        # 使用 exec 替换当前进程，从新位置重新启动
        exec bash "$TARGET_SCRIPT_PATH"
    else
        echo -e "${RED}[ERROR] 迁移失败，请检查权限。${NC}"
        exit 1
    fi
fi

echo -e "${CYAN}----------------------------------------${NC}"
echo -e "   ${YELLOW}Cloudflare IP 优选工具 - 智能启动器${NC}"
echo -e "${CYAN}----------------------------------------${NC}"

# --- 系统命令安装逻辑 ---
SYSTEM_CMD_PATH="/usr/local/bin/cfopt"

install_system_cmd() {
    # 若已安装或处于临时运行环境（如 wget 管道），则跳过
    if [ "$(readlink -f "$0" 2>/dev/null)" = "$SYSTEM_CMD_PATH" ] || [ ! -f "$0" ]; then
        return 0
    fi

    echo ""
    echo -e "${BLUE}[INFO] 建议将 'cfopt' 安装为系统全局命令。${NC}"
    echo "       (安装后可在任意终端直接输入 cfopt 运行)"
    read -p "是否现在安装？(y/n，默认y): " INSTALL_CMD
    INSTALL_CMD=${INSTALL_CMD:-y}

    if [[ "$INSTALL_CMD" =~ ^[Yy]$ ]]; then
        local cp_cmd="cp"
        local chmod_cmd="chmod +x"
        
        # 非 Root 用户尝试提权处理
        if [ "$EUID" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                cp_cmd="sudo cp"
                chmod_cmd="sudo chmod +x"
            else
                echo -e "${RED}[ERROR] 需要 root 权限或 sudo 支持。${NC}"
                return 1
            fi
        fi

        # 执行复制和赋权
        local exec_result=0
        if [ "$EUID" -ne 0 ]; then
            sudo cp "$0" "$SYSTEM_CMD_PATH" && sudo chmod +x "$SYSTEM_CMD_PATH" || exec_result=1
        else
            cp "$0" "$SYSTEM_CMD_PATH" && chmod +x "$SYSTEM_CMD_PATH" || exec_result=1
        fi

        if [ $exec_result -eq 0 ]; then
            echo -e "${GREEN}[OK] 安装成功！路径: $SYSTEM_CMD_PATH${NC}"
            # 设置标记，跳过后续的安装确认环节
            SKIP_INSTALL_CONFIRM=true
            return 0
        else
            echo -e "${RED}[ERROR] 安装失败，请检查权限。${NC}"
        fi
    fi
}

# --- 辅助函数：带重试的下载与校验 ---
download_with_retry() {
    local url="$1"
    local output="$2"
    local expected_hash="$3" # 可选参数：预期的 SHA256 哈希值
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        # 确保输出文件的父目录存在
        local output_dir=$(dirname "$output")
        mkdir -p "$output_dir" 2>/dev/null
        
        # 使用 curl 进行下载
        if curl -sL --connect-timeout 10 --max-time 60 -o "$output" "$url" 2>/dev/null; then
            # 基础校验：文件非空且不是 HTML 错误页
            if [ -s "$output" ] && ! grep -q "403 Forbidden" "$output" 2>/dev/null && ! grep -q "404 Not Found" "$output" 2>/dev/null; then
                # 哈希校验（如果提供了哈希值）
                if [ -n "$expected_hash" ]; then
                    local actual_hash=$(sha256sum "$output" | awk '{print $1}')
                    if [ "$actual_hash" = "$expected_hash" ]; then
                        return 0
                    else
                        echo -e "${YELLOW}[WARN] 哈希校验失败 (期望: ${expected_hash:0:16}... 实际: ${actual_hash:0:16}...)，正在重试...${NC}"
                    fi
                else
                    return 0
                fi
            else
                echo -e "${YELLOW}[WARN] 下载的文件无效 (空文件或错误页面)，正在重试...${NC}"
            fi
        else
            echo -e "${YELLOW}[WARN] curl 下载失败 (退出码: $?)，正在重试...${NC}"
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}[WARN] 第 $retry_count 次重试失败，等待 2 秒后重试...${NC}"
            sleep 2
        fi
    done
    
    echo -e "${RED}[ERROR] 无法下载或校验失败: $(basename "$url")${NC}"
    echo -e "${YELLOW}[DEBUG] URL: $url${NC}"
    if [ -f "$output" ]; then
        echo -e "${YELLOW}[DEBUG] 文件大小: $(wc -c < "$output") bytes${NC}"
        head -5 "$output" 2>/dev/null | while read -r line; do
            echo -e "${YELLOW}[DEBUG] 内容预览: $line${NC}"
        done
    fi
    return 1
}

# --- 环境检测与依赖安装 ---
check_environment() {
    echo -e "${CYAN}━━ 正在执行系统环境检测 ━━${NC}"
    local has_error=false
    local missing_tools=()
    
    # 检查必要的系统命令
    local required_cmds=("curl" "openssl" "grep" "sed" "awk" "jq")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_tools+=("$cmd")
            has_error=true
        fi
    done
    
    if [ "$has_error" = true ]; then
        echo -e "${RED}[ERROR] 缺失必要工具: ${missing_tools[*]}${NC}"
        echo -e "${YELLOW}[INFO] 正在尝试自动安装...${NC}"
        
        local install_cmd=""
        if command -v apt-get &> /dev/null; then
            install_cmd="apt-get install -y"
        elif command -v yum &> /dev/null; then
            install_cmd="yum install -y"
        elif command -v apk &> /dev/null; then
            install_cmd="apk add"
        fi

        if [ -n "$install_cmd" ]; then
            sudo $install_cmd "${missing_tools[@]}" 2>/dev/null || true
        fi
        
        # 安装后二次检查，若仍缺失则报错退出
        for cmd in "${missing_tools[@]}"; do
            if ! command -v "$cmd" &> /dev/null; then
                echo -e "${RED}[ERROR] $cmd 安装失败，请手动安装后重试。${NC}"
                exit 1
            fi
        done
    fi
    echo -e "${GREEN}[OK] 环境检测通过，开始初始化...${NC}"
}

# --- 辅助函数：获取模块状态图标 ---
get_module_status() {
    local module_name=$1
    local conf_file=$2
    local data_file=$3
    
    # 1. 检查配置文件是否存在且已启用
    if [ -f "$conf_file" ]; then
        source "$conf_file"
        if [ "${ENABLED:-false}" = "true" ]; then
            # 2. 检查数据文件是否新鲜 (24小时内)
            if [ -n "$data_file" ] && [ -f "$data_file" ]; then
                local now=$(date +%s)
                local file_time=$(stat -c %Y "$data_file" 2>/dev/null || stat -f %m "$data_file" 2>/dev/null)
                if [ $((now - file_time)) -lt 86400 ]; then
                    echo -e "${GREEN}[OK]${NC}"
                else
                    echo -e "${YELLOW}[WAIT]${NC}"
                fi
            else
                echo -e "${CYAN}[CFG]${NC}"
            fi
        else
            echo -e "${GRAY}[OFF]${NC}"
        fi
    else
        echo -e "${RED}[NONE]${NC}"
    fi
}

# --- 主菜单逻辑 ---
show_main_menu() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}cfopt - Cloudflare 优选与 DNS 管理套件 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 加载状态配置
    STATUS_CONF="$INSTALL_DIR/conf/status.conf"
    if [ -f "$STATUS_CONF" ]; then source "$STATUS_CONF"; fi
    
    # 获取各模块状态
    local cf_ip_status=$(get_module_status "CF-IP" "$INSTALL_DIR/modules/cf-ip/config.conf" "$INSTALL_DIR/assets/data/cf-ip/result.csv")
    local cf_dns_status=$(get_module_status "CF-DNS" "$INSTALL_DIR/conf/cfdns.conf" "$INSTALL_DIR/assets/data/cf-dns/ip_list.txt")
    local dnspod_status=$(get_module_status "DNSPod" "$INSTALL_DIR/conf/dnspod.conf" "$INSTALL_DIR/assets/data/dnspod-dns/ip_list.txt")
    local scheduler_status="${SCHEDULER_ENABLED:-false}"
    if [ "$scheduler_status" = "true" ]; then
        scheduler_status=$(echo -e "${GREEN}[RUN]${NC}")
    else
        scheduler_status=$(echo -e "${GRAY}[STOP]${NC}")
    fi

    echo -e " ${CYAN}[系统状态]${NC}"
    echo -e "   CF-IP 测速: $cf_ip_status   |   自动化调度: $scheduler_status"
    echo -e "   CF DNS 更新: $cf_dns_status   |   DNSPod 更新: $dnspod_status"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    echo -e " ${GREEN}➤${NC} 1. CF IP 优选管理     ${CYAN}- 测速程序、参数配置、定时任务${NC}"
    echo -e " ${GREEN}➤${NC} 2. CF DNS 记录更新    ${CYAN}- 将优选 IP 同步到 Cloudflare DNS${NC}"
    echo -e " ${GREEN}➤${NC} 3. DNSPod DNS 更新    ${CYAN}- 腾讯云 DNSPod 分线路解析管理${NC}"
    echo -e " ${GREEN}➤${NC} 4. 自动化调度中心    ${CYAN}- 一键执行全链路测速、同步与更新${NC}"
    echo -e " ${GREEN}➤${NC} 5. 检查组件更新       ${CYAN}- 同步远程最新版本${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 9. 一键跑路         ${CYAN}- 删除脚本及相关配置${NC}"
    echo -e " ${RED}➤${NC} 0. 退出程序"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 确保从终端读取输入，防止管道安装时 stdin 被占用
    local input_device="/dev/tty"
    if [ ! -e "$input_device" ]; then input_device="/dev/stdin"; fi

    read -p "请选择功能 [0-5, 9]: " choice < "$input_device"

    case $choice in
        1)
            export CF_OPT_ENTRY="main_menu"
            bash "$INSTALL_DIR/modules/cf-ip/menu.sh"
            ;;
        2)
            export CF_OPT_ENTRY="main_menu"
            bash "$INSTALL_DIR/modules/cf-dns/setup.sh"
            ;;
        3)
            export CF_OPT_ENTRY="main_menu"
            bash "$INSTALL_DIR/modules/dnspod-dns/setup.sh"
            ;;
        4)
            manage_scheduler
            ;;
        5)
            check_and_update_components
            ;;
        9)
            uninstall_cfopt
            ;;
        0)
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重试。${NC}"
            sleep 1
            show_main_menu
            ;;
    esac
}

# ====================== 【组件更新逻辑】 ======================

# --- 自动化调度管理逻辑 ---
manage_scheduler() {
    while true; do
        clear
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        echo -e " ${YELLOW}自动化调度管理中心${NC}"
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        
        # 检测当前定时任务状态
        local cron_status="未配置"
        local cron_info=$(crontab -l 2>/dev/null | grep "scheduler/run.sh" || true)
        if [ -n "$cron_info" ]; then
            cron_status="${GREEN}已启用${NC}"
        else
            cron_status="${RED}未启用${NC}"
        fi
        
        echo -e " 当前状态: $cron_status"
        echo -e " 执行脚本: ${INSTALL_DIR}/modules/scheduler/run.sh"
        echo ""
        echo -e " ${GREEN}➤${NC} 1. 立即执行一次       ${CYAN}- 手动触发全链路测速与更新${NC}"
        echo -e " ${GREEN}➤${NC} 2. 启用/修改定时任务   ${CYAN}- 设置自动运行间隔${NC}"
        echo -e " ${GREEN}➤${NC} 3. 停止定时任务       ${CYAN}- 取消后台自动执行${NC}"
        echo -e " ${GREEN}➤${NC} 4. 查看调用命令       ${CYAN}- 获取宝塔/1Panel Cron 指令${NC}"
        echo ""
        echo -e " ${RED}➤${NC} 0. 返回主菜单"
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        read -p "请选择功能 [0-4]: " sched_choice
        
        case $sched_choice in
            1)
                clear
                if [ -f "$INSTALL_DIR/modules/scheduler/run.sh" ]; then
                    bash "$INSTALL_DIR/modules/scheduler/run.sh"
                else
                    echo -e "${RED}[ERROR] 调度组件不存在。${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            2)
                setup_auto_cron
                ;;
            3)
                if crontab -l 2>/dev/null | grep -q "scheduler/run.sh"; then
                    (crontab -l 2>/dev/null | grep -v "scheduler/run.sh") | crontab -
                    echo -e "${GREEN}[OK] 定时任务已停止。${NC}"
                else
                    echo -e "${YELLOW}[INFO] 当前没有正在运行的定时任务。${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                show_panel_commands
                ;;
            0)
                break
                ;;
        esac
    done
}

# --- 定时任务配置逻辑 ---
setup_auto_cron() {
    # 检查系统是否安装 crontab
    if ! command -v crontab &> /dev/null; then
        echo -e "${RED}[ERROR] 系统未检测到 crontab 组件。${NC}"
        echo -e "${YELLOW}提示:${NC} 定时任务依赖于 cronie (CentOS) 或 cron (Debian/Ubuntu)。"
        read -p "是否现在尝试自动安装？(y/n，默认y): " INSTALL_CRON
        INSTALL_CRON=${INSTALL_CRON:-y}
        
        if [[ "$INSTALL_CRON" =~ ^[Yy]$ ]]; then
            local install_cmd=""
            if command -v apt-get &> /dev/null; then
                install_cmd="apt-get update && apt-get install -y cron"
            elif command -v yum &> /dev/null; then
                install_cmd="yum install -y cronie"
            elif command -v dnf &> /dev/null; then
                install_cmd="dnf install -y cronie"
            elif command -v apk &> /dev/null; then
                install_cmd="apk add --no-cache busybox-suid openrc && rc-update add cron default && service cron start"
            fi

            if [ -n "$install_cmd" ]; then
                echo -e "${CYAN}[INFO] 正在执行安装命令...${NC}"
                if sudo bash -c "$install_cmd"; then
                    # 尝试启动服务
                    sudo systemctl enable crond 2>/dev/null || sudo service cron start 2>/dev/null || true
                    echo -e "${GREEN}[OK] 安装成功！正在进入配置界面...${NC}"
                else
                    echo -e "${RED}[ERROR] 自动安装失败，请手动安装后重试。${NC}"
                    read -p "按回车键继续..."
                    return
                fi
            else
                echo -e "${RED}[ERROR] 无法识别当前系统的包管理器，请手动安装 cron。${NC}"
                read -p "按回车键继续..."
                return
            fi
        else
            echo -e "${YELLOW}[INFO] 已取消安装。${NC}"
            read -p "按回车键继续..."
            return
        fi
    fi

    echo ""
    echo -e "${YELLOW}请选择执行频率：${NC}"
    echo "  1) 每 4 小时执行一次 (推荐，保持最优速度)"
    echo "  2) 每 6 小时执行一次 (平衡性能与资源)"
    echo "  3) 每天凌晨 3:00 (低频，节省资源)"
    echo "  4) 每天凌晨 3:00 和下午 3:00 (每日两次)"
    echo "  5) 每小时执行一次 (极致追新，适合高要求)"
    echo "  6) 自定义 Cron 表达式"
    echo ""
    read -p "请输入选项 [1-6] (默认 1): " freq_choice
    freq_choice=${freq_choice:-1}
    
    local cron_expr="0 */4 * * *"
    case $freq_choice in
        1) cron_expr="0 */4 * * *" ;;
        2) cron_expr="0 */6 * * *" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3,15 * * *" ;;
        5) cron_expr="0 * * * *" ;;
        6) 
            echo -e "${CYAN}提示:${NC} Cron 格式为 '分 时 日 月 周'"
            read -p "请输入 Cron 表达式: " custom_cron
            if [ -n "$custom_cron" ]; then cron_expr="$custom_cron"; fi
            ;;
    esac
    
    local log_file="$INSTALL_DIR/logs/scheduler.log"
    mkdir -p "$(dirname "$log_file")"
    local full_cmd="$cron_expr /bin/bash $INSTALL_DIR/modules/scheduler/run.sh >> $log_file 2>&1"
    
    # 移除旧的定时任务，添加新的
    (crontab -l 2>/dev/null | grep -v "scheduler/run.sh"; echo "$full_cmd") | crontab -
    
    echo ""
    echo -e "${GREEN}[OK] 定时任务已成功设置！${NC}"
    echo -e "   频率: ${YELLOW}$cron_expr${NC}"
    echo -e "   日志: ${CYAN}$log_file${NC}"
    read -p "按回车键继续..."
}

# --- 面板命令生成器 ---
show_panel_commands() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}面板 Cron 命令生成器 (宝塔/1Panel)${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${YELLOW}操作说明:${NC}"
    echo "  1. 在面板中选择【计划任务】->【添加任务】->【Shell脚本】"
    echo "  2. 设置好执行周期（如每天 3:00）"
    echo "  3. 将下方的【脚本内容】复制粘贴到输入框中"
    echo ""
    echo -e "${GREEN}--- 脚本内容 (直接复制下方整行) ---${NC}"
    echo "/bin/bash $INSTALL_DIR/modules/scheduler/run.sh >> $INSTALL_DIR/logs/scheduler.log 2>&1"
    echo -e "${GREEN}-------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}提示:${NC} 请确保面板中的执行用户有权限访问 $INSTALL_DIR 目录。"
    read -p "按回车键返回..."
}

# --- 一键跑路逻辑 (卸载清理) ---
uninstall_cfopt() {
    clear
    echo -e "${RED}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}⚠️ 警告：即将执行卸载清理 (一键跑路) ⚠️${NC}"
    echo -e "${RED}+------------------------------------------------------------+${NC}"
    echo ""
    echo "此操作将永久删除以下内容："
    echo "  1. 安装目录: $INSTALL_DIR"
    echo "  2. 全局命令: /usr/local/bin/cfopt"
    echo "  3. 定时任务: 所有包含 'scheduler/run.sh' 的 Crontab 项"
    echo ""
    echo -e "${YELLOW}注意:${NC} 此操作不会卸载系统级组件 (如 crontab, wget 等)。"
    echo ""
    read -p "确认要彻底删除并跑路吗？(输入 yes 确认): " CONFIRM_UNINSTALL
    
    if [ "$CONFIRM_UNINSTALL" != "yes" ]; then
        echo -e "${GREEN}[INFO] 已取消卸载，欢迎继续使用。${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi

    echo -e "${CYAN}[INFO] 正在清理 Crontab 定时任务...${NC}"
    if command -v crontab &> /dev/null; then
        (crontab -l 2>/dev/null | grep -v "scheduler/run.sh") | crontab -
    fi

    echo -e "${CYAN}[INFO] 正在删除全局命令链接...${NC}"
    rm -f /usr/local/bin/cfopt

    echo -e "${CYAN}[INFO] 正在删除安装目录及所有数据...${NC}"
    rm -rf "$INSTALL_DIR"

    echo ""
    echo -e "${GREEN}[OK] 清理完成！cfopt 已从您的系统中消失。${NC}"
    echo -e "${YELLOW}感谢曾经的陪伴，再见！👋${NC}"
    echo ""
    exit 0
}

# --- 组件更新逻辑 ---
check_and_update_components() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}正在检查组件更新...${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    REMOTE_VERSIONS=$(curl -sL --connect-timeout 10 "$VERSION_FILE_REMOTE" 2>/dev/null)
    if [ -z "$REMOTE_VERSIONS" ]; then
        echo -e "${RED}[ERROR] 无法连接远程服务器，请检查网络。${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 定义模块映射: [KEY]="本地路径:远程文件"
    declare -A MODULE_MAP
    MODULE_MAP=(
        ["CF_IP_MENU"]="$INSTALL_DIR/modules/cf-ip/menu.sh:modules/cf-ip/menu.sh"
        ["CF_IP_CORE"]="$INSTALL_DIR/modules/cf-ip/core.sh:modules/cf-ip/core.sh"
        ["CF_DNS_CORE"]="$INSTALL_DIR/modules/cf-dns/core.sh:modules/cf-dns/core.sh"
        ["CF_DNS_SETUP"]="$INSTALL_DIR/modules/cf-dns/setup.sh:modules/cf-dns/setup.sh"
        ["DNSPOD_CORE"]="$INSTALL_DIR/modules/dnspod-dns/core.sh:modules/dnspod-dns/core.sh"
        ["DNSPOD_SETUP"]="$INSTALL_DIR/modules/dnspod-dns/setup.sh:modules/dnspod-dns/setup.sh"
        ["CFOPT_ENTRY"]="$0:cfopt.sh"
    )

    HAS_UPDATE=false
    HAS_ERROR=false
    TEMP_DIR=$(mktemp -d)
    
    for KEY in "${!MODULE_MAP[@]}"; do
        IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
        # 特殊处理 cfopt.sh 自身路径
        if [ "$REMOTE_FILE" = "cfopt.sh" ]; then LOCAL_PATH="$0"; fi
        
        REMOTE_INFO=$(echo "$REMOTE_VERSIONS" | grep "^${KEY}=" | cut -d'=' -f2)
        REMOTE_VER=$(echo "$REMOTE_INFO" | cut -d':' -f1)
        REMOTE_HASH=$(echo "$REMOTE_INFO" | cut -d':' -f2)
        
        LOCAL_VER="0.0"
        if [ -f "$LOCAL_PATH" ]; then
            LOCAL_VER=$(grep -m1 "^SCRIPT_VERSION=" "$LOCAL_PATH" | awk -F'"' '{print $2}')
            [ -z "$LOCAL_VER" ] && LOCAL_VER="0.0"
        fi

        if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
            echo -e "  ${YELLOW}[UPDATE]${NC} $KEY: $LOCAL_VER -> $REMOTE_VER"
            if download_with_retry "$REMOTE_URL/$REMOTE_FILE" "$TEMP_DIR/$REMOTE_FILE" "$REMOTE_HASH"; then
                HAS_UPDATE=true
            else
                HAS_ERROR=true
                echo -e "  ${RED}[FAIL]${NC}   $KEY 更新失败 (请检查 version.txt 哈希值或网络)"
            fi
        else
            echo -e "  ${GREEN}[OK]${NC}      $KEY: $LOCAL_VER (最新)"
        fi
    done

    echo ""
    if [ "$HAS_UPDATE" = true ]; then
        read -p "是否立即应用已下载的更新？(y/n，默认y): " APPLY_UPDATE
        APPLY_UPDATE=${APPLY_UPDATE:-y}
        
        if [[ "$APPLY_UPDATE" =~ ^[Yy]$ ]]; then
            for KEY in "${!MODULE_MAP[@]}"; do
                IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
                if [ -f "$TEMP_DIR/$REMOTE_FILE" ]; then
                    mkdir -p "$(dirname "$LOCAL_PATH")"
                    mv "$TEMP_DIR/$REMOTE_FILE" "$LOCAL_PATH"
                    chmod +x "$LOCAL_PATH"
                fi
            done
            echo -e "${GREEN}[OK] 更新已应用！${NC}"
        fi
    elif [ "$HAS_ERROR" = true ]; then
        echo -e "${YELLOW}[WARN] 部分组件更新失败，请检查网络连接或远程文件完整性。${NC}"
    else
        echo -e "${GREEN}[OK] 所有组件已是最新版本。${NC}"
    fi
    
    rm -rf "$TEMP_DIR"
    read -p "按回车键返回主菜单..."
}

# --- 初始化流程 ---
init_cfopt() {
    # 1. 环境检测
    check_environment

    # 2. 智能启动检测
    STATUS_CONF="$INSTALL_DIR/conf/status.conf"
    
    # 核心判断：如果状态文件存在、标记为已安装、且核心模块目录齐全，则直接启动
    if [ -f "$STATUS_CONF" ] && \
       grep -q '^INSTALL_CHECKED="true"' "$STATUS_CONF" && \
       [ -d "$INSTALL_DIR/modules/cf-ip" ] && \
       [ -d "$INSTALL_DIR/modules/scheduler" ]; then
        show_main_menu
        return
    fi
    
    # 3. 安装前确认
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}安装前确认${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " 即将执行以下操作："
    echo -e "   1. 创建安装目录: ${GREEN}$INSTALL_DIR${NC}"
    echo -e "   2. 下载并配置核心组件 (CF-IP, DNS, Scheduler)"
    if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        echo -e "   3. 尝试安装全局命令: ${GREEN}/usr/local/bin/cfopt${NC} (需要 sudo 权限)"
    elif [ "$EUID" -eq 0 ]; then
        echo -e "   3. 安装全局命令: ${GREEN}/usr/local/bin/cfopt${NC}"
    fi
    echo ""
    read -p "是否继续安装？(y/n，默认y): " CONFIRM_INSTALL < /dev/tty
    CONFIRM_INSTALL=${CONFIRM_INSTALL:-y}
        
    if [[ ! "$CONFIRM_INSTALL" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[INFO] 已取消安装。${NC}"
        exit 0
    fi
    
    # 4. 安装全局命令
    install_system_cmd

    # 4. 创建目录结构
    mkdir -p "$INSTALL_DIR/modules/manager" \
             "$INSTALL_DIR/modules/cf-ip" \
             "$INSTALL_DIR/modules/cf-dns" \
             "$INSTALL_DIR/modules/dnspod-dns" \
             "$INSTALL_DIR/modules/scheduler" \
             "$INSTALL_DIR/modules/ip-sync" \
             "$INSTALL_DIR/assets/bin/cfst" \
             "$INSTALL_DIR/assets/data/cf-ip" \
             "$INSTALL_DIR/assets/data/cf-dns" \
             "$INSTALL_DIR/assets/data/dnspod-dns" \
             "$INSTALL_DIR/conf" \
             "$INSTALL_DIR/logs"

    # 初始化状态配置文件 (如果不存在)
    STATUS_CONF="$INSTALL_DIR/conf/status.conf"
    if [ ! -f "$STATUS_CONF" ]; then
        cat > "$STATUS_CONF" << 'EOF'
# cfopt 模块状态配置文件
CF_IP_ENABLED="true"
CF_DNS_ENABLED="false"
DNSPOD_ENABLED="false"
SCHEDULER_ENABLED="false"
LAST_UPDATE_TIME=""
INSTALL_CHECKED="true"
EOF
    else
        # 如果文件已存在但未标记，则追加标记
        if ! grep -q '^INSTALL_CHECKED=' "$STATUS_CONF"; then
            echo 'INSTALL_CHECKED="true"' >> "$STATUS_CONF"
        fi
    fi

    # 5. 静默版本检测与更新
    echo -e "${CYAN}[INFO] 正在下载组件文件...${NC}"
    
    # 下载 version.txt（增加超时和进度提示）
    echo -e "${CYAN}[INFO] 正在获取版本索引...${NC}"
    REMOTE_VERSIONS=$(curl -sL --connect-timeout 10 --max-time 30 "$VERSION_FILE_REMOTE" 2>/dev/null)
    
    if [ -z "$REMOTE_VERSIONS" ]; then
        echo -e "${YELLOW}[WARN] 无法获取 version.txt，将跳过哈希校验直接下载...${NC}"
    else
        echo -e "${GREEN}[OK] 版本索引获取成功！${NC}"
    fi
    
    declare -A MODULE_MAP
    MODULE_MAP=(
        ["CF_IP_MENU"]="$INSTALL_DIR/modules/cf-ip/menu.sh:modules/cf-ip/menu.sh"
        ["CF_IP_CORE"]="$INSTALL_DIR/modules/cf-ip/core.sh:modules/cf-ip/core.sh"
        ["CF_DNS_CORE"]="$INSTALL_DIR/modules/cf-dns/core.sh:modules/cf-dns/core.sh"
        ["CF_DNS_SETUP"]="$INSTALL_DIR/modules/cf-dns/setup.sh:modules/cf-dns/setup.sh"
        ["DNSPOD_CORE"]="$INSTALL_DIR/modules/dnspod-dns/core.sh:modules/dnspod-dns/core.sh"
        ["DNSPOD_SETUP"]="$INSTALL_DIR/modules/dnspod-dns/setup.sh:modules/dnspod-dns/setup.sh"
        ["SCHEDULER_RUN"]="$INSTALL_DIR/modules/scheduler/run.sh:modules/scheduler/run.sh"
        ["IP_SYNC"]="$INSTALL_DIR/modules/ip-sync/sync.sh:modules/ip-sync/sync.sh"
    )

    HAS_UPDATE=false
    # 计数器：用于显示进度
    TOTAL_FILES=${#MODULE_MAP[@]}
    CURRENT_FILE=0
    
    if [ -n "$REMOTE_VERSIONS" ]; then
        # 有 version.txt，进行版本对比和哈希校验
        for KEY in "${!MODULE_MAP[@]}"; do
            CURRENT_FILE=$((CURRENT_FILE + 1))
            IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
            REMOTE_INFO=$(echo "$REMOTE_VERSIONS" | grep "^${KEY}=" | cut -d'=' -f2)
            REMOTE_VER=$(echo "$REMOTE_INFO" | cut -d':' -f1)
            REMOTE_HASH=$(echo "$REMOTE_INFO" | cut -d':' -f2)
            
            LOCAL_VER="0.0"
            if [ -f "$LOCAL_PATH" ]; then
                LOCAL_VER=$(grep -m1 "^SCRIPT_VERSION=" "$LOCAL_PATH" | awk -F'"' '{print $2}')
                [ -z "$LOCAL_VER" ] && LOCAL_VER="0.0"
            fi

            # 判断是否需要下载：文件不存在 或 版本不同
            NEED_DOWNLOAD=false
            if [ ! -f "$LOCAL_PATH" ]; then
                NEED_DOWNLOAD=true
                echo -e "${CYAN}[INFO] [$CURRENT_FILE/$TOTAL_FILES] 下载 $KEY...${NC}"
            elif [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
                NEED_DOWNLOAD=true
                echo -e "${CYAN}[INFO] [$CURRENT_FILE/$TOTAL_FILES] 更新 $KEY (v$LOCAL_VER -> v$REMOTE_VER)...${NC}"
            fi

            if [ "$NEED_DOWNLOAD" = true ]; then
                # 确保目标目录存在
                mkdir -p "$(dirname "$LOCAL_PATH")" 2>/dev/null
                
                # 直接在目标位置下载
                if download_with_retry "$REMOTE_URL/$REMOTE_FILE" "$LOCAL_PATH" "$REMOTE_HASH"; then
                    HAS_UPDATE=true
                else
                    echo -e "${RED}[ERROR] $KEY 下载失败，请检查网络或稍后重试。${NC}"
                    # 清理可能的残留文件
                    rm -f "$LOCAL_PATH" 2>/dev/null
                fi
            fi
        done
    else
        # 无 version.txt，跳过哈希校验直接下载所有文件（首次安装或网络问题）
        for KEY in "${!MODULE_MAP[@]}"; do
            CURRENT_FILE=$((CURRENT_FILE + 1))
            IFS=':' read -r LOCAL_PATH REMOTE_FILE <<< "${MODULE_MAP[$KEY]}"
            
            # 仅下载不存在的文件
            if [ ! -f "$LOCAL_PATH" ]; then
                echo -e "${CYAN}[INFO] [$CURRENT_FILE/$TOTAL_FILES] 下载 $KEY...${NC}"
                # 确保目标目录存在
                mkdir -p "$(dirname "$LOCAL_PATH")" 2>/dev/null
                
                # 直接在目标位置下载
                if download_with_retry "$REMOTE_URL/$REMOTE_FILE" "$LOCAL_PATH" ""; then
                    HAS_UPDATE=true
                else
                    echo -e "${RED}[ERROR] $KEY 下载失败，请检查网络连接。${NC}"
                    # 清理可能的残留文件
                    rm -f "$LOCAL_PATH" 2>/dev/null
                fi
            fi
        done
    fi

    if [ "$HAS_UPDATE" = true ]; then
        echo -e "${GREEN}[OK] 组件安装完成！${NC}"
    else
        echo -e "${YELLOW}[WARN] 没有可更新的组件。${NC}"
    fi

    # 6. 进入主菜单
    show_main_menu
}

# 启动执行
init_cfopt
