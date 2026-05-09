#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - DNSPod DNS 配置向导 (Setup Wizard)
# Version: 0.1
# Description: 引导用户完成 DNSPod API 配置、运营商分流策略及定时任务设置
# Usage: bash modules/dnspod-dns/setup.sh
# ==============================================================================
# 【安全修复】启用严格模式，防止错误传播
set -euo pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="0.1"

# ==================== 入口校验与路径初始化 ====================

# 【安全修复】检测非 TTY 环境，防止在 cron 中阻塞
if [[ ! -t 0 ]] && [[ -z "${CF_OPT_ENTRY:-}" ]]; then
    echo -e "${RED}[ERROR] 此脚本需要交互式终端，请通过 cfopt 菜单运行${NC}"
    echo -e "${YELLOW}[提示] 正确用法: cfopt -> 4. DNSPod 管理 -> 1. 配置向导${NC}"
    exit 1
fi

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 加载公共函数库 ====================
# shellcheck source=../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

# 限制：此脚本应由主程序 cfopt.sh 统一调度启动
if [ -z "$CF_OPT_ENTRY" ] && [ "$(basename "$0")" != "setup.sh" ]; then
    SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    if [[ "$ROOT_DIR" != *"/cfopt"* ]] && [[ "$ROOT_DIR" != *"/DNSPod-DNS-Updater"* ]]; then
        echo -e "\033[0;31m[ERROR] 禁止直接运行此脚本！\033[0m"
        echo -e "\033[1;33m请使用 'cfopt' 命令进入管理菜单进行操作。\033[0m"
        exit 1
    fi
fi

# 确保 ROOT_DIR 已定义（兜底逻辑）
if [ -z "$ROOT_DIR" ]; then
    SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# 【修复】跨平台列出日志文件信息（替代 find -printf，兼容 macOS/BSD）
# 参数: $1=目录路径, $2=文件名模式 (如 "*.log")
# 输出: 文件名 (大小) 日期 时间
list_log_files() {
    local search_dir="$1"
    local pattern="$2"
    local max_count="${3:-10}"
    
    if stat -c '%Y' /dev/null >/dev/null 2>&1; then
        # Linux
        find "$search_dir" -name "$pattern" -type f -exec sh -c '
            for file do
                size=$(stat -c "%s" "$file")
                date=$(stat -c "%y" "$file" | cut -d" " -f1)
                time=$(stat -c "%y" "$file" | cut -d" " -f2 | cut -d: -f1-2)
                echo "$(basename "$file") ($size) $date $time"
            done
        ' _ {} + | sort -t'(' -k2 -rn | head -n "$max_count"
    elif stat -f '%m' /dev/null >/dev/null 2>&1; then
        # macOS/BSD
        find "$search_dir" -name "$pattern" -type f -exec sh -c '
            for file do
                size=$(stat -f "%z" "$file")
                date=$(stat -f "%Sm" -t "%Y-%m-%d" "$file")
                time=$(stat -f "%Sm" -t "%H:%M" "$file")
                echo "$(basename "$file") ($size) $date $time"
            done
        ' _ {} + | sort -t'(' -k2 -rn | head -n "$max_count"
    else
        # 备用方案：使用 ls -l
        ls -lt "$search_dir"/$pattern 2>/dev/null | head -n "$max_count" | awk '{print $9, "("$5")", $6, $7}'
    fi
}

# 定义菜单边框样式，确保 UI 对齐
MENU_BORDER="+------------------------------------------------------------+"
MENU_BORDER_MID="+------------------------------------------------------------+"
MENU_BORDER_BOTTOM="+------------------------------------------------------------+"
# shellcheck disable=SC2034
SMALL_BORDER="+--------------------------------------------------+"

CONFIG_FILE="$ROOT_DIR/conf/dnspod.json"  # 仅在菜单显示时使用，实际运行时由 core.sh 动态加载
# 【修复】统一锁文件命名规范：.${module_name}_${type}.lock
LOCK_FILE="$ROOT_DIR/modules/dnspod-dns/.dnspod-dns_setup.lock"

# ==================== 进程锁管理 ====================
# 防止多个配置向导实例同时运行导致配置文件冲突

# 获取执行锁
acquire_lock() {
    # 【安全修复】使用 flock 避免 TOCTOU 竞态条件
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}[ERROR] 另一个实例正在运行，无法获取锁"
        echo -e "${YELLOW}提示: 如果确定没有运行，请删除 ${LOCK_FILE}"
        exit 1
    fi
    # 锁会在脚本退出时自动释放（fd 9 关闭）
}

# ==================== 辅助函数：JSON 配置读取 ====================
# 从 JSON 配置文件读取值
# 用法: json_get ".dns.domain" "默认值"
json_get() {
    local key="$1"
    local default="${2:-}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$default"
        return 1
    fi
    
    local value
    value=$(jq -r "${key} // empty" "$CONFIG_FILE" 2>/dev/null || true)
    
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# ==================== 通用辅助函数（重构优化） ====================

# 触发模式切换（统一调用 core.sh）
# 用法: trigger_mode_switch "from_mode" "to_mode" "strategy"
# 返回: 0=成功, 非0=失败
trigger_mode_switch() {
    local from_mode="$1"
    local to_mode="$2"
    local strategy="$3"
    
    # 设置环境变量触发 core.sh 智能处理
    export DNSPOD_MODE_SWITCH=1
    export DNSPOD_FROM_MODE="$from_mode"
    export DNSPOD_TO_MODE="$to_mode"
    export DNSPOD_STRATEGY="$strategy"
    
    # 调用 core.sh
    bash "$(dirname "$0")/core.sh"
    local result=$?
    
    # 清理环境变量
    unset DNSPOD_MODE_SWITCH DNSPOD_FROM_MODE DNSPOD_TO_MODE DNSPOD_STRATEGY
    
    # 返回结果
    return $result
}

# 提示并验证子域名输入
# 用法: prompt_and_validate_subdomain "线路名称" "默认值" "配置路径"
# 返回: 通过 stdout 返回验证后的子域名，失败返回空字符串
prompt_and_validate_subdomain() {
    local line_name="$1"
    local default_value="$2"
    local config_path="$3"
    
    read -r -p "${line_name}子域名 [${default_value}]: " subdomain
    subdomain=${subdomain:-$default_value}
    
    # 验证子域名格式（允许字母、数字、连字符、@符号）
    if ! [[ "$subdomain" =~ ^[a-zA-Z0-9\-@]+$ ]]; then
        echo -e "${RED}[ERROR] 无效的子域名格式: ${subdomain}"
        echo ""
        return 1
    fi
    
    # 更新配置
    update_config_field "$config_path" "$subdomain"
    
    # 返回验证后的子域名
    echo "$subdomain"
    return 0
}

# 执行 core.sh 命令（自动设置权限）
# 用法: run_core_command [参数]
# 返回: core.sh 的退出码
run_core_command() {
    local core_script="$(dirname "$0")/core.sh"
    chmod +x "$core_script" 2>/dev/null
    bash "$core_script" "$@"
    return $?
}

# ==================== 菜单显示函数 ====================

# 显示主配置菜单
show_menu() {
    clear
    
    # 获取当前系统时间及配置状态
    local NOW
    NOW=$(date "+%Y-%m-%d %H:%M:%S")
    local status_text=""
    local lines_info=""
    local strategy_info=""
    
    if [[ -f "$CONFIG_FILE" ]]; then
        # 【性能优化】单次 jq 调用批量读取所有配置字段，减少进程 fork
        local config_data
        config_data=$(jq -r '[
            .dns.mode // "single",
            .dns.domain // "",
            .dns.subdomain_strategy // "separate",
            .dns.isp_lines // "默认",
            .dns.sub_domain_unified // "dns",
            .dns.sub_domains.default // "default",
            .dns.sub_domains.unicom // "unicom",
            .dns.sub_domains.mobile // "mobile",
            .dns.sub_domains.telecom // "telecom",
            .dns.sub_domain // "dns"
        ] | @tsv' "$CONFIG_FILE" 2>/dev/null || echo -e "single\t\tseparate\t默认\tdns\tdefault\tunicom\tmobile\ttelecom\tdns")
        
        # 解析 TSV 数据
        IFS=$'\t' read -r MODE DOMAIN STRATEGY ISP_LINES UNIFIED_SUBDOMAIN \
            SUB_DEFAULT SUB_UNICOM SUB_MOBILE SUB_TELECOM SUB_DOMAIN <<< "$config_data"
        
        # shellcheck disable=SC2153
        if [[ "$MODE" == "multi" ]]; then
            # 根据策略设置显示提示
            if [[ "$STRATEGY" == "unified" ]]; then
                strategy_info=" ${YELLOW}策略: 统一模式"
            else
                strategy_info=" ${YELLOW}策略: 分离模式"
            fi
            
            status_text="多线路模式 | 配置文件：已存在"
            
            if [[ "$STRATEGY" == "unified" ]]; then
                # 统一模式：显示统一子域名
                lines_info="  ${CYAN}线路: ${UNIFIED_SUBDOMAIN}.${DOMAIN}"
            else
                # 分离模式：显示各线路子域名
                lines_info="  ${CYAN}线路:"
                IFS=' ' read -ra line_array <<< "$ISP_LINES"
                for line in "${line_array[@]}"; do
                    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [[ -n "$line" ]]; then
                        local subdomain
                        case "$line" in
                            "默认")
                                subdomain="$SUB_DEFAULT"
                                ;;
                            "联通")
                                subdomain="$SUB_UNICOM"
                                ;;
                            "移动")
                                subdomain="$SUB_MOBILE"
                                ;;
                            "电信")
                                subdomain="$SUB_TELECOM"
                                ;;
                            *)
                                subdomain=$(echo "$line" | tr '[:upper:]' '[:lower:]')
                                ;;
                        esac
                        lines_info="${lines_info}\n    - ${line}: ${subdomain}.${DOMAIN}"
                    fi
                done
            fi
        else
            status_text="单线路模式 | 配置文件：已存在"
            lines_info="  ${CYAN}线路: ${SUB_DOMAIN}.${DOMAIN}"
        fi
    else
        status_text="未配置 | 配置文件：不存在"
    fi
    
    echo -e "${CYAN}${MENU_BORDER}"
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e " 当前时间: ${NOW}"
    if [[ -n "$lines_info" ]]; then
        echo -e "$lines_info"
    fi
    if [[ -n "$strategy_info" ]]; then
        echo -e "$strategy_info"
    fi
    echo -e " ${GREEN}状态: ${status_text}"
    echo -e "${CYAN}${MENU_BORDER_MID}"
    echo -e " ${GREEN}➤${NC} 1. 完整配置向导     ${CYAN}- 首次使用或重新配置所有项${NC}"
    echo -e " ${GREEN}➤${NC} 2. 快速运行         ${CYAN}- 使用当前配置立即运行${NC}"
    echo -e " ${GREEN}➤${NC} 3. 查看当前配置     ${CYAN}- 显示 dnspod.json 配置${NC}"
    echo -e " ${GREEN}➤${NC} 4. 启用/禁用模块    ${CYAN}- 控制是否自动同步 IP 及更新 DNS${NC}"
    echo -e " ${GREEN}➤${NC} 5. 手动同步优选 IP   ${CYAN}- 从测速结果中提取最优 IP 到数据文件${NC}"
    echo -e " ${GREEN}➤${NC} 6. 修改 IP 数量限制 ${CYAN}- 每条DNS记录最多几个IP${NC}"
    echo -e " ${GREEN}➤${NC} 7. 修改配置         ${CYAN}- 选择性修改特定配置项${NC}"
    echo -e " ${GREEN}➤${NC} 8. 日志管理         ${CYAN}- 查看、清理运行日志${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 0. 退出程序"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
}

# 显示配置修改二级菜单
show_modify_menu() {
    clear
    
    # 【性能优化】单次 jq 调用读取运行模式
    local current_mode="single"
    if [[ -f "$CONFIG_FILE" ]]; then
        current_mode=$(jq -r '.dns.mode // "single"' "$CONFIG_FILE" 2>/dev/null || echo "single")
    fi
    
    echo -e "${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}配置修改向导"
    echo -e "${CYAN}${MENU_BORDER_MID}"
    echo -e " ${GREEN}➤${NC} 1. 全部重新配置   ${CYAN}- 重置并重新执行完整配置流程${NC}"
    echo -e " ${GREEN}➤${NC} 2. 域名配置       ${CYAN}- 修改主域名及子域名记录${NC}"
    echo -e " ${GREEN}➤${NC} 3. API 密钥       ${CYAN}- 更新 DNSPod SecretID 与 SecretKey${NC}"
    echo -e " ${GREEN}➤${NC} 4. 工作模式       ${CYAN}- 切换单线路或运营商分流模式${NC}"
    echo -e " ${GREEN}➤${NC} 5. 运营商线路     ${CYAN}- 管理分流的运营商列表 (仅多线路)${NC}"
    echo -e " ${GREEN}➤${NC} 6. IP 文件路径    ${CYAN}- 指定各线路优选 IP 数据源路径${NC}"
    echo -e " ${GREEN}➤${NC} 7. 管理 IP 内容   ${CYAN}- 手动录入或编辑优选 IP 列表${NC}"
    echo -e " ${GREEN}➤${NC} 8. TTL 值         ${CYAN}- 调整 DNS 记录的缓存生存时间${NC}"
    
    # 只在多线路模式下显示选项 9
    if [[ "$current_mode" == "multi" ]]; then
        echo -e " ${GREEN}➤${NC} 9. 子域名策略     ${CYAN}- 切换分离/统一模式${NC}"
    fi
    
    echo ""
    echo -e " ${RED}➤${NC} 0. 返回主菜单"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
}

# 获取进程锁，防止并发执行
acquire_lock

# 检查配置是否有效
check_config_valid() {
    # 检查文件是否存在
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    # 检查文件是否为空
    if [[ ! -s "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    # 使用 jq 验证 JSON 格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}[WARN] 配置文件不是有效的 JSON 格式" >&2
        return 1
    fi
    
    # 【性能优化】单次 jq 调用批量读取所有配置字段，减少进程 fork
    local config_data
    if [[ -f "$CONFIG_FILE" ]]; then
        config_data=$(jq -r '[
            .dns.mode // "single",
            .dns.domain // "",
            .api.id // "",
            .api.token // "",
            .dns.isp_lines // "",
            .dns.subdomain_strategy // "separate",
            .dns.sub_domain_unified // "",
            .dns.sub_domains.default // "",
            .dns.sub_domain // ""
        ] | @tsv' "$CONFIG_FILE" 2>/dev/null || echo -e "single\t\t\t\t\tseparate\t\t\t")
    else
        config_data="$(echo -e "single\t\t\t\t\tseparate\t\t\t")"
    fi
    
    # 解析 TSV 数据
    IFS=$'\t' read -r mode domain secretid secretkey isp_lines strategy unified_sub default_sub sub_domain <<< "$config_data"
    
    if [[ -z "$domain" ]] || [[ -z "$secretid" ]] || [[ -z "$secretkey" ]]; then
        return 1
    fi
    
    # 验证 MODE 值是否合法
    if [[ "$mode" != "single" ]] && [[ "$mode" != "multi" ]]; then
        echo -e "${YELLOW}[WARN] MODE 配置值不合法: ${mode} (应为 single 或 multi)" >&2
        return 1
    fi
    
    # 根据模式检查必要配置（使用已读取的变量）
    if [[ "$mode" == "multi" ]]; then
        # 多线路模式检查
        
        # 检查运营商线路是否配置
        if [[ -z "$isp_lines" ]]; then
            echo -e "${YELLOW}[WARN] 检测到多线路模式但未配置运营商线路" >&2
            return 2  # 返回特殊值表示配置不完整
        fi
        
        # 验证策略值是否合法
        if [[ "$strategy" != "separate" ]] && [[ "$strategy" != "unified" ]]; then
            echo -e "${YELLOW}[WARN] SUBDOMAIN_STRATEGY 配置值不合法: ${strategy}" >&2
            echo -e "${CYAN}提示: 合法值为 separate (分离模式) 或 unified (统一模式)" >&2
            return 2
        fi
        
        # 如果是统一模式,检查统一子域名
        if [[ "$strategy" == "unified" ]]; then
            if [[ -z "$unified_sub" ]]; then
                echo -e "${YELLOW}[WARN] 检测到统一模式但未配置统一子域名" >&2
                return 2
            fi
        else
            # 分离模式,至少检查默认线路子域名
            if [[ -z "$default_sub" ]]; then
                echo -e "${YELLOW}[WARN] 检测到分离模式但未配置默认线路子域名" >&2
                return 2
            fi
        fi
        
    elif [[ "$mode" == "single" ]]; then
        # 单线路模式检查
        if [[ -z "$sub_domain" ]]; then
            echo -e "${YELLOW}[WARN] 检测到单线路模式但未配置子域名(SUB_DOMAIN)" >&2
            return 2
        fi
    fi
    
    return 0
}

# 运行时配置检测 (更严格的检查)
check_runtime_config() {
    echo -e "${CYAN}━━ 运行时配置检测 ━━"
    echo ""
    
    # 【性能优化】单次 jq 调用批量读取所有配置字段
    local config_data
    if [[ -f "$CONFIG_FILE" ]]; then
        config_data=$(jq -r '[
            .dns.mode // "single",
            .dns.domain // "",
            .api.id // "",
            .api.token // ""
        ] | @tsv' "$CONFIG_FILE" 2>/dev/null || echo -e "single\t\t\t")
    else
        config_data="$(echo -e "single\t\t\t")"
    fi
    
    # 解析 TSV 数据
    IFS=$'\t' read -r mode domain secretid secretkey <<< "$config_data"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}[ERROR] 域名格式不合法: ${domain}"
        echo "   示例: drxian.cn, example.com"
        return 1
    else
        echo -e "${GREEN}[OK] 域名格式正确: ${domain}"
    fi
    
    # 检查 API 密钥长度（使用已读取的变量）
    
    if [[ ${#secretid} -lt 10 ]]; then
        echo -e "${RED}[ERROR] SECRETID 长度异常: ${#secretid} 字符"
        return 1
    else
        echo -e "${GREEN}[OK] SECRETID 长度正常: ${#secretid} 字符"
    fi
    
    if [[ ${#secretkey} -lt 20 ]]; then
        echo -e "${RED}[ERROR] SECRETKEY 长度异常: ${#secretkey} 字符"
        return 1
    else
        echo -e "${GREEN}[OK] SECRETKEY 长度正常: ${#secretkey} 字符"
    fi
    
    # 根据模式检查
    if [[ "$mode" == "multi" ]]; then
        echo ""
        echo -e "${CYAN}多线路模式检查:"
        
        local isp_lines strategy
        isp_lines=$(json_get ".dns.isp_lines" "默认")
        strategy=$(json_get ".dns.subdomain_strategy" "separate")
        
        echo -e "  运营商线路: ${isp_lines}"
        
        # 转换为中文显示
        if [[ "$strategy" == "unified" ]]; then
            echo -e "  ${GREEN}[OK] 子域名策略: 统一模式"
        elif [[ "$strategy" == "separate" ]]; then
            echo -e "  ${GREEN}[OK] 子域名策略: 分离模式"
        else
            echo -e "  ${RED}[ERROR] 子域名策略: ${strategy:-未设置} (${YELLOW}不合法)"
            echo -e "  ${CYAN}提示: 多线路模式的 SUBDOMAIN_STRATEGY 必须为 separate 或 unified"
            echo -e "  ${CYAN}解决: 请运行 setup.sh → 5) 修改配置 → 9) 子域名策略"
            return 1
        fi
        
        # 检查 IP 文件是否存在 (如果配置了)
        local has_ip_files=false
        IFS=' ' read -ra lines_array <<< "$isp_lines"
        for line in "${lines_array[@]}"; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -z "$line" ]]; then
                continue
            fi
            
            local ip_file=""
            case "$line" in
                "默认") ip_file=$(json_get ".ip_source.files.default" "") ;;
                "联通") ip_file=$(json_get ".ip_source.files.unicom" "") ;;
                "移动") ip_file=$(json_get ".ip_source.files.mobile" "") ;;
                "电信") ip_file=$(json_get ".ip_source.files.telecom" "") ;;
            esac
            
            if [[ -n "$ip_file" ]] && [[ ! -f "$ip_file" ]]; then
                echo -e "  ${YELLOW}[WARN] IP 文件不存在: ${ip_file} (${line})"
                has_ip_files=true
            fi
        done
        
        if [[ "$has_ip_files" == false ]]; then
            echo -e "  ${GREEN}[OK] IP 文件检查通过"
        fi
        
    elif [[ "$mode" == "single" ]]; then
        echo ""
        echo -e "${CYAN}单线路模式检查:"
        
        local sub_domain
        sub_domain=$(json_get ".dns.sub_domain" "dns")
        echo -e "  子域名: ${sub_domain}"
        
        # 检查 IP 文件
        local ip_file
        ip_file=$(json_get ".ip_source.file_path" "")
        if [[ -n "$ip_file" ]] && [[ ! -f "$ip_file" ]]; then
            echo -e "  ${YELLOW}[WARN] IP 文件不存在: ${ip_file}"
        else
            echo -e "  ${GREEN}[OK] IP 文件检查通过"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}[OK] 运行时配置检测通过"
    echo ""
    
    return 0
}

# 显示菜单
# 快速运行
quick_run() {
    local mode="$1"
    
    echo -e "${CYAN}${MENU_BORDER}"
    if [[ "$mode" == "single" ]]; then
        echo -e " ${YELLOW}快速运行 - 单线路模式"
    else
        echo -e " ${YELLOW}快速运行 - 多线路模式"
    fi
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    # 检查配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 找不到配置文件 ${CONFIG_FILE}"
        echo ""
        echo "请先运行配置向导生成配置文件:"
        echo "  ./setup.sh (选择 1)"
        echo ""
        return 1
    fi
    
    # 运行时配置检测
    echo ""
    if ! check_runtime_config; then
        echo -e "${RED}[ERROR] 配置检测失败,请修复后重试"
        echo ""
        echo "建议操作:"
        echo "  1. 选择 5 (修改配置) 修复问题"
        echo "  2. 或选择 1 (完整配置向导) 重新配置"
        echo ""
        read -r -p "按回车键继续..."
        return 1
    fi
    
    # 显示当前配置摘要
    echo -e "${BLUE}摘要 当前配置摘要:"
    
    # 临时加载配置 (使用子shell避免污染当前环境变量)
    (
        local mode domain sub_domain isp_lines max_ips
        mode=$(jq -r '.dns.mode // "single"' "$CONFIG_FILE" 2>/dev/null || true)
        domain=$(jq -r '.dns.domain // ""' "$CONFIG_FILE" 2>/dev/null || true)
        sub_domain=$(jq -r '.dns.sub_domain // "dns"' "$CONFIG_FILE" 2>/dev/null || true)
        isp_lines=$(jq -r '.dns.isp_lines // "默认"' "$CONFIG_FILE" 2>/dev/null || true)
        max_ips=$(jq -r '.dns.max_ips_per_record // 2' "$CONFIG_FILE" 2>/dev/null || true)
        
        # 转换为中文显示
        if [[ "$mode" == "multi" ]]; then
            echo "  工作模式:   多线路模式"
        else
            echo "  工作模式:   单线路模式"
        fi
        echo "  域名:       ${sub_domain}.${domain}"
        if [[ "$mode" == "multi" ]]; then
            echo "  运营商线路: ${isp_lines}"
        fi
        echo "  IP 数量限制: ${max_ips}"
    )
    echo ""
    
    # 确认运行
    read -r -p "是否立即运行? (y/n): " confirm
    
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        echo "已取消"
        return 0
    fi
    
    # 清屏后执行脚本
    clear
    echo ""
    
    # 根据模式运行相应脚本
    local script_file=""
    if [[ "$mode" == "single" ]]; then
        script_file="$(dirname "$0")/core.sh"
    else
        script_file="$(dirname "$0")/core.sh"
    fi
    
    if [[ ! -f "$script_file" ]]; then
        echo -e "${RED}错误: 找不到脚本文件 ${script_file}"
        return 1
    fi
    
    chmod +x "$script_file"
    echo "正在运行: ${script_file}"
    echo ""
    
    # 运行脚本
    "$script_file"
    
    echo ""
    echo -e "${CYAN}${MENU_BORDER}"
    echo -e " ${GREEN}[OK] 运行完成"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
}

# 查看配置
view_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在"
        echo "请先运行配置向导"
        return 1
    fi
    
    echo -e "${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}当前配置信息"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    # 加载配置
    local domain sub_domain secretid
    domain=$(json_get ".dns.domain" "")
    sub_domain=$(json_get ".dns.sub_domain" "dns")
    secretid=$(json_get ".api.id" "")
    
    echo -e "${CYAN}基本配置:"
    echo "  域名:         ${sub_domain}.${domain}"
    echo "  SecretId:     ${secretid:0:8}...${secretid: -4}"
    echo "  SecretKey:    **** (已隐藏)"
    echo ""
    
    echo -e "${CYAN}工作模式:"
    local mode isp_lines max_ips request_timeout max_retries
    mode=$(json_get ".dns.mode" "single")
    isp_lines=$(json_get ".dns.isp_lines" "默认")
    max_ips=$(json_get ".dns.max_ips_per_record" "2")
    request_timeout=$(json_get ".api.timeout" "10")
    max_retries=$(json_get ".api.max_retries" "3")
    
    echo "  模式:         ${mode}"
    if [[ "$mode" == "multi" ]]; then
        echo "  运营商线路:   ${isp_lines}"
    fi
    echo ""
    
    echo -e "${CYAN}高级配置:"
    echo "  IP 数量限制   = ${max_ips} 个/记录"
    echo "  请求超时时间  = ${request_timeout} 秒"
    echo "  最大重试次数  = ${max_retries} 次"
    echo ""
    
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
}

# 快速修改 IP 数量限制
modify_ip_limit() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在"
        echo "请先运行完整配置向导生成配置文件"
        return 1
    fi
    
    echo -e "\n${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}快速修改 IP 数量限制"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    # 读取当前值
    local current_limit
    current_limit=$(json_get ".dns.max_ips_per_record" "2")
    echo -e "${CYAN}当前设置: ${current_limit:-2} 个/记录"
    echo ""
    echo -e "${YELLOW}说明:"
    echo "  - 设置每条 DNS 记录最多包含几个 IP 地址"
    echo "  - 例如: 设置为 2，则每个域名最多解析到 2 个 IP"
    echo "  - 设置为 0 表示不限制（需要套餐支持）"
    echo ""
    echo -e "${CYAN}提示: DNSPod 套餐负载均衡记录数限制:"
    echo "  - 免费版: 2 条 (默认) ← 推荐"
    echo "  - 专业版: 10 条"
    echo "  - 企业版: 100 条"
    echo "  - 尊享版: 不限制 (输入 0)"
    echo ""
    echo -e "  ${CYAN}文档: 官方文档: https://cloud.tencent.com/document/product/302/104713"
    echo ""
    echo -e "${YELLOW}警告: 注意: 免费版超出限制会导致 API 报错"
    echo "   脚本会自动截取前 N 个 IP,避免报错"
    echo ""
    
    read -r -p "请输入每条记录的 IP 数量 (0=不限制, 直接回车保持 ${current_limit:-2}): " new_limit
    
    if [[ -z "$new_limit" ]]; then
        echo -e "${YELLOW}[INFO] 保持当前设置不变 (${current_limit:-2})"
        return 0
    fi
    
    # 验证是否为数字
    if ! [[ "$new_limit" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[ERROR] 请输入有效的数字"
        return 1
    fi
    
    # 更新配置文件 (使用安全方式)
    update_config_field ".dns.max_ips_per_record" "$new_limit"
    
    echo ""
    if [[ "$new_limit" -eq 0 ]]; then
        echo -e "${GREEN}[OK] IP 数量限制已取消 (不限制)"
        echo -e "   ${YELLOW}[WARN] 请确保您的套餐支持无限负载均衡记录"
    else
        echo -e "${GREEN}[OK] IP 数量限制已更新: 每条记录最多 ${new_limit} 个 IP"
        
        if [[ "$new_limit" -gt 2 ]]; then
            echo -e "   ${YELLOW}[WARN] 请确保您的套餐支持 ${new_limit} 条负载均衡记录"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}提示: 修改后立即生效,下次运行脚本时将使用新设置"
}

# 启用/禁用模块
toggle_module_status() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在"
        echo "请先运行完整配置向导生成配置文件"
        return 1
    fi
    
    echo -e "\n${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}启用/禁用模块"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    local current_status
    current_status=$(json_get ".enabled" "false")
    
    if [[ "$current_status" == "true" ]]; then
        echo -e "${GREEN}当前状态: ${BOLD}已启用"
        echo ""
        echo -e "${YELLOW}功能说明:"
        echo "  - IP 同步组件会自动将测速结果写入此模块"
        echo "  - DNS 更新任务会正常执行"
        echo ""
        read -r -p "是否禁用此模块? (y/n): " confirm
        if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
            update_config_field ".enabled" "false"
            echo -e "${GREEN}[OK] 模块已禁用"
            echo -e "${CYAN}提示: IP 同步和 DNS 更新将跳过此模块"
        fi
    else
        echo -e "${RED}当前状态: ${BOLD}已禁用"
        echo ""
        echo -e "${YELLOW}功能说明:"
        echo "  - IP 同步组件不会为此模块写入 IP"
        echo "  - DNS 更新任务不会执行"
        echo ""
        read -r -p "是否启用此模块? (y/n): " confirm
        if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
            update_config_field ".enabled" "true"
            echo -e "${GREEN}[OK] 模块已启用"
            echo -e "${CYAN}提示: 下次测速后将自动同步 IP 并支持 DNS 更新"
        fi
    fi
}

# ==================== 配置管理功能 ====================

# 调用系统编辑器修改配置文件
edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[ERROR] 配置文件不存在，无法编辑。"
        return 1
    fi
    
    # 自动检测并选择可用的终端编辑器
    local editor=""
    for e in nano vim vi; do
        if command -v "$e" &> /dev/null; then
            editor="$e"
            break
        fi
    done
    
    if [[ -z "$editor" ]]; then
        echo -e "${RED}[ERROR] 未检测到可用的终端编辑器 (nano/vim/vi)。"
        echo "请手动编辑文件: ${CONFIG_FILE}"
        return 1
    fi
    
    echo "正在启动 ${editor} 编辑器..."
    "$editor" "$CONFIG_FILE"
    echo -e "\n${GREEN}[OK] 配置文件已保存并更新。"
}

# 配置修改二级菜单入口
modify_config_menu() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[ERROR] 配置文件不存在"
        echo "请先运行完整配置向导生成配置文件"
        return 1
    fi
    
    show_modify_menu
    
    # 根据模式确定选项范围
    local current_mode
    current_mode=$(json_get ".dns.mode" "single")
    
    if [[ "$current_mode" == "multi" ]]; then
        read -r -p "请选择要修改的配置项 (0-9): " modify_choice
    else
        read -r -p "请选择要修改的配置项 (0-8): " modify_choice
    fi
    
    case "$modify_choice" in
        1)
            # 全部重新配置
            echo ""
            echo -e "${CYAN}提示: 将进入完整配置向导,重新配置所有项目"
            read -r -p "确认继续? (y/n): " confirm
            if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
                # shellcheck disable=SC2034
                RECONFIGURE_ALL=true
                return 2
            else
                echo -e "${YELLOW}[INFO] 已取消"
                return 0
            fi
            ;;
        2)
            clear
            modify_domain_config
            return 1  # 继续显示二级菜单
            ;;
        3)
            clear
            modify_api_keys
            return 1
            ;;
        4)
            clear
            modify_work_mode
            return 1
            ;;
        5)
            clear
            modify_isp_lines
            return 1
            ;;
        6)
            clear
            modify_ip_files
            return 1
            ;;
        7)
            clear
            manage_ip_content
            return 1
            ;;
        8)
            clear
            modify_ttl
            return 1
            ;;
        9)
            modify_subdomain_strategy
            return 1
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择"
            echo ""
            read -r -p "按回车键继续..."
            # 不清屏,让循环自然继续,下次循环开始时会清屏
            ;;
    esac
}

# 修改域名配置
modify_domain_config() {
    echo ""
    echo -e "${CYAN}━━ 域名配置管理 ━━"
    
    local domain sub_domain
    domain=$(json_get ".dns.domain" "")
    sub_domain=$(json_get ".dns.sub_domain" "dns")
    echo "当前解析记录: ${sub_domain}.${domain}"
    echo ""
    
    read -r -p "请输入主域名 (例如: example.com, 直接回车保持不变): " new_domain
    if [[ -n "$new_domain" ]]; then
        # 校验域名格式合法性 (支持多级域名)
        if ! [[ "$new_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
            echo -e "${RED}[ERROR] 无效的域名格式，请检查输入。"
            return 0
        fi
        update_config_field ".dns.domain" "$new_domain"
        domain="$new_domain"
    fi
    
    read -r -p "请输入子域名 (例如: www, @, blog, 直接回车保持不变): " new_subdomain
    if [[ -n "$new_subdomain" ]]; then
        # 校验子域名格式合法性 (允许字母、数字、连字符及根记录符号 @)
        if ! [[ "$new_subdomain" =~ ^[a-zA-Z0-9\-@]+$ ]]; then
            echo -e "${RED}[ERROR] 无效的子域名格式。"
            return 0
        fi
        update_config_field ".dns.sub_domain" "$new_subdomain"
        sub_domain="$new_subdomain"
    fi
    
    echo -e "\n${GREEN}[OK] 域名配置已更新: ${sub_domain}.${domain}"
    echo ""
    read -r -p "按回车键继续..."
}

# 修改 API 密钥
modify_api_keys() {
    echo ""
    echo -e "${CYAN}━━ 修改 API 密钥 ━━"
    echo ""
    echo -e "${CYAN}提示: 如果还没有密钥,请访问:"
    echo "   https://console.cloud.tencent.com/cam/capi"
    echo ""
    
    read -r -p "请输入 SecretId (直接回车保持不变): " new_secretid
    if [[ -n "$new_secretid" ]]; then
        # 安全校验：防止 Shell 注入攻击
        if [[ "$new_secretid" =~ [\;\|\&\$\`\\] ]]; then
            echo -e "${RED}[ERROR] SecretId 包含非法字符，请重新输入。"
            return 0
        fi
        update_config_field ".api.id" "$new_secretid"
        echo -e "${GREEN}[OK] SecretId 已更新"
    fi
    
    # 【安全修复】使用 -s 静默模式，不回显 SecretKey
    echo -e "${CYAN}请输入 SecretKey (直接回车保持不变，输入不会显示):${NC}"
    read -rs new_secretkey
    echo ""
    if [[ -n "$new_secretkey" ]]; then
        # 验证输入不包含危险字符
        if [[ "$new_secretkey" =~ [\;\|\&\$\`\\] ]]; then
            echo -e "${RED}[ERROR] SecretKey 包含非法字符"
            return 0
        fi
        update_config_field ".api.token" "$new_secretkey"
        echo -e "${GREEN}[OK] SecretKey 已更新"
    fi
    echo ""
    read -r -p "按回车键继续..."
}

# 修改工作模式
modify_work_mode() {
    echo ""
    echo -e "${CYAN}━━ 修改工作模式 ━━"
    echo ""
    
    # 获取当前模式
    local current_mode
    current_mode=$(json_get ".dns.mode" "single")
    if [[ "$current_mode" == "multi" ]]; then
        echo "当前模式: 多线路模式"
    else
        echo "当前模式: 单线路模式"
    fi
    echo ""
    echo "  1) 单线路模式 - 为域名设置统一的 CF 优选 IP"
    echo "  2) 多线路模式 - 为不同运营商设置不同的 CF 优选 IP"
    echo ""
    
    read -r -p "请选择新模式 (1/2): " mode_choice
    
    if [[ "$mode_choice" == "1" ]]; then
        # 切换到单线路模式 - 调用 core.sh 的智能处理
        if [[ "$current_mode" == "multi" ]]; then
            echo ""
            echo -e "${YELLOW}[INFO] 正在从多线路切换到单线路..."
            
            # 获取当前策略
            local current_strategy
            current_strategy=$(json_get ".dns.subdomain_strategy" "separate")
            
            # 调用 core.sh 进行智能模式切换
            if trigger_mode_switch "multi" "single" "$current_strategy"; then
                echo ""
                echo -e "${GREEN}[OK] 模式切换成功"
            else
                echo ""
                echo -e "${RED}[ERROR] 模式切换失败"
                return 0
            fi
        else
            # 已经是单线路，无需切换
            update_config_field ".dns.mode" "single"
            echo -e "${GREEN}[OK] 已确认为单线路模式"
        fi
        
    elif [[ "$mode_choice" == "2" ]]; then
        # 切换到多线路模式 - 调用 core.sh 的智能处理
        if [[ "$current_mode" == "single" ]]; then
            echo ""
            echo -e "${YELLOW}[INFO] 正在从单线路切换到多线路..."
            
            # 获取当前策略（如果有的话）
            local current_strategy
            current_strategy=$(json_get ".dns.subdomain_strategy" "separate")
            
            # 调用 core.sh 进行智能模式切换
            if trigger_mode_switch "single" "multi" "$current_strategy"; then
                echo ""
                echo -e "${GREEN}[OK] 模式切换成功"
            else
                echo ""
                echo -e "${RED}[ERROR] 模式切换失败"
                return 0
            fi
        else
            # 已经是多线路，无需切换
            update_config_field ".dns.mode" "multi"
            echo -e "${GREEN}[OK] 已确认为多线路模式"
        fi
    else
        echo -e "${RED}[ERROR] 无效的选择"
        return 0
    fi
    
    echo ""
    read -r -p "按回车键继续..."
}

# 修改子域名策略
modify_subdomain_strategy() {
    echo ""
    echo -e "${CYAN}━━ 修改子域名策略 ━━"
    echo ""
    
    # 获取域名
    local domain mode
    domain=$(json_get ".dns.domain" "你的域名")
    
    # 检查是否为多线路模式
    mode=$(json_get ".dns.mode" "single")
    if [[ "$mode" != "multi" ]]; then
        echo -e "${RED}[ERROR]: 此选项仅适用于多线路模式"
        if [[ "$mode" == "multi" ]]; then
            echo "   当前模式: 多线路模式"
        else
            echo "   当前模式: 单线路模式"
        fi
        echo ""
        echo "请先切换到多线路模式:"
        echo "  选择菜单项 4 (工作模式) → 选择 2 (多线路模式)"
        echo ""
        read -r -p "按回车键继续..."
        return 0
    fi
    
    local current_strategy
    current_strategy=$(json_get ".dns.subdomain_strategy" "separate")
    
    # 转换为中文显示
    if [[ "$current_strategy" == "unified" ]]; then
        echo "当前策略: 统一模式"
    elif [[ "$current_strategy" == "separate" ]]; then
        echo "当前策略: 分离模式"
    else
        echo "当前策略: ${current_strategy}"
    fi
    echo ""
    echo "请选择子域名策略:"
    echo ""
    echo "  1) 分离模式 (推荐) - 每条线路使用独立子域名"
    echo "     例如: default.drxian.cn, unicom.drxian.cn"
    echo "     优点: 清晰明确,便于管理和调试"
    echo ""
    echo "  2) 统一模式 (省心) - 所有线路共用同一子域名"
    echo "     例如: dns.drxian.cn (通过 DNSPod 线路区分)"
    echo "     优点: 配置简单,只需一个子域名"
    echo ""
    read -r -p "请选择策略 (1/2, 默认 1): " strategy_choice
    
    if [[ -z "$strategy_choice" ]]; then
        strategy_choice="1"
    fi
    
    if [[ "$strategy_choice" == "1" ]]; then
        # 切换到分离模式
        local old_strategy="$current_strategy"
        update_config_field ".dns.subdomain_strategy" "separate"
        
        # 如果从统一模式切换过来，询问是否使用统一模式的子域名作为默认线路子域名
        local default_subdomain
        if [[ "$old_strategy" == "unified" ]]; then
            local old_unified_subdomain
            old_unified_subdomain=$(json_get ".dns.sub_domain_unified" "dns")
            
            if [[ -n "$old_unified_subdomain" ]] && [[ "$old_unified_subdomain" != "dns" ]]; then
                # 有自定义的统一模式子域名，询问是否使用
                echo -e "\n${CYAN}检测到统一模式的子域名: ${old_unified_subdomain}"
                echo ""
                echo "请选择分离模式默认线路的子域名："
                echo ""
                echo "  1) 使用统一模式的子域名 (推荐)"
                echo "     - 默认线路使用: ${old_unified_subdomain}.${domain}"
                echo "     - 其他线路使用默认值 (unicom, mobile, telecom)"
                echo ""
                echo "  2) 使用默认子域名"
                echo "     - 默认线路使用: default.${domain}"
                echo ""
                read -r -p "请选择 (1/2, 默认 1): " use_old_subdomain
                use_old_subdomain=${use_old_subdomain:-1}
                
                if [[ "$use_old_subdomain" == "1" ]]; then
                    default_subdomain="$old_unified_subdomain"
                    echo -e "${GREEN}[OK] 已选择使用: ${default_subdomain}"
                else
                    default_subdomain="default"
                fi
            else
                # 没有自定义的统一模式子域名，使用默认值
                default_subdomain="default"
            fi
        else
            # 不是从统一模式切换，使用默认值
            default_subdomain="${SUB_DOMAIN_DEFAULT:-default}"
        fi
        
        update_config_field ".dns.sub_domain" "$default_subdomain"
        update_config_field ".dns.sub_domains.default" "$default_subdomain"
        
        echo -e "\n${GREEN}[OK] 已切换为: 分离模式"
        echo "  主 SUB_DOMAIN 已更新为: ${default_subdomain}"
        echo ""
        echo "各线路子域名前缀 (使用默认值):"
        echo "  - default (默认线路)"
        echo "  - unicom (联通线路)"
        echo "  - mobile (移动线路)"
        echo "  - telecom (电信线路)"
        echo ""
        
        # 如果之前是统一模式，询问是否同步 DNS 记录
        if [[ "$old_strategy" == "unified" ]]; then
            echo -e "${RED}[WARN] 重要提示：从统一模式切换到分离模式"
            echo ""
            echo "请选择如何处理 DNS 记录："
            echo ""
            echo "  1) 自动处理 (推荐)"
            echo "     - 删除 ${SUB_DOMAIN_UNIFIED:-dns}.${domain} 的所有运营商线路记录"
            echo "     - 为各线路创建独立的解析记录"
            echo "     - 使用默认子域名前缀 (default, unicom, mobile, telecom)"
            echo ""
            echo "  2) 自定义子域名"
            echo "     - 删除统一模式记录"
            echo "     - 立即输入各线路的自定义子域名"
            echo "     - 自动创建分离模式记录"
            echo ""
            echo "  3) 取消切换"
            echo "     - 保持统一模式"
            echo ""
            read -r -p "请选择 (1/2/3, 默认 1): " handle_choice
            handle_choice=${handle_choice:-1}
            
            if [[ "$handle_choice" == "1" ]]; then
                # 自动处理 - 调用 core.sh 智能切换
                echo ""
                echo -e "${CYAN}正在切换到分离模式..."
                
                if ! trigger_mode_switch "multi" "multi" "separate"; then
                    echo -e "${RED}[ERROR] 切换失败"
                    return 0
                fi
            elif [[ "$handle_choice" == "2" ]]; then
                # 自定义子域名 - 让用户立即输入
                echo ""
                echo -e "${CYAN}正在切换到分离模式..."
                
                if ! trigger_mode_switch "multi" "multi" "separate"; then
                    echo -e "${RED}[ERROR] 切换失败"
                    return 0
                fi
                
                echo ""
                echo -e "${CYAN}请设置各线路的子域名前缀:"
                echo ""
                
                # 使用新辅助函数读取并验证各线路子域名
                local custom_default custom_unicom custom_mobile custom_telecom
                
                custom_default=$(prompt_and_validate_subdomain "默认线路" "default" ".dns.sub_domains.default") || return 0
                custom_unicom=$(prompt_and_validate_subdomain "联通线路" "unicom" ".dns.sub_domains.unicom") || return 0
                custom_mobile=$(prompt_and_validate_subdomain "移动线路" "mobile" ".dns.sub_domains.mobile") || return 0
                custom_telecom=$(prompt_and_validate_subdomain "电信线路" "telecom" ".dns.sub_domains.telecom") || return 0
                
                # 更新 SUB_DOMAIN 为默认线路的子域名
                update_config_field ".dns.sub_domain" "$custom_default"
                
                echo ""
                echo -e "${GREEN}[OK] 子域名配置完成"
                echo "  - 默认线路: ${custom_default}.${domain}"
                echo "  - 联通线路: ${custom_unicom}.${domain}"
                echo "  - 移动线路: ${custom_mobile}.${domain}"
                echo "  - 电信线路: ${custom_telecom}.${domain}"
                echo ""
                
                # 自动创建分离模式记录
                echo -e "${CYAN}正在创建分离模式记录..."
                sync_records_separate
            else
                # 取消切换
                echo -e "${YELLOW}[INFO] 已取消切换，保持统一模式"
                # 恢复配置
                update_config_field ".dns.subdomain_strategy" "unified"
                update_config_field ".dns.sub_domain" "${SUB_DOMAIN_UNIFIED:-dns}"
                return 0
            fi
        fi
    elif [[ "$strategy_choice" == "2" ]]; then
        # 切换到统一模式
        local old_strategy="$current_strategy"
        # 如果旧策略为空，默认为分离模式
        if [[ -z "$old_strategy" ]]; then
            old_strategy="separate"
        fi
        
        # 立即更新策略配置，确保后续脚本使用正确的模式
        update_config_field ".dns.subdomain_strategy" "unified"
        
        echo -e "\n${GREEN}[OK] 已切换为: 统一模式"
        echo ""
        
        # 检查是否有分离模式的默认线路子域名
        local old_default_subdomain
        old_default_subdomain=$(json_get ".dns.sub_domains.default" "default")
        
        if [[ -n "$old_default_subdomain" ]] && [[ "$old_default_subdomain" != "default" ]]; then
            # 有自定义的默认线路子域名，询问是否沿用
            echo -e "${CYAN}检测到分离模式的默认线路子域名: ${old_default_subdomain}"
            echo ""
            echo "请选择统一模式的子域名："
            echo ""
            echo "  1) 沿用分离模式的默认线路子域名 (推荐)"
            echo "     - 使用: ${old_default_subdomain}.${domain}"
            echo "     - 保持子域名不变，便于管理"
            echo ""
            echo "  2) 使用新的子域名"
            echo "     - 立即输入新的子域名"
            echo ""
            read -r -p "请选择 (1/2, 默认 1): " use_old_subdomain
            use_old_subdomain=${use_old_subdomain:-1}
            
            if [[ "$use_old_subdomain" == "1" ]]; then
                unified_subdomain="$old_default_subdomain"
                echo -e "${GREEN}[OK] 已选择沿用: ${unified_subdomain}"
            else
                read -r -p "请输入统一子域名 [dns]: " unified_subdomain
                unified_subdomain=${unified_subdomain:-dns}
            fi
        else
            # 没有自定义的默认线路子域名，直接让用户输入
            read -r -p "请输入统一子域名 [dns]: " unified_subdomain
            unified_subdomain=${unified_subdomain:-dns}
        fi
        # 验证子域名格式
        if ! [[ "$unified_subdomain" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            echo -e "${RED}[ERROR] 无效的子域名格式"
            return 0
        fi
        update_config_field ".dns.sub_domain_unified" "$unified_subdomain"
        
        # 更新 SUB_DOMAIN 为统一子域名（用于单线路脚本）
        update_config_field ".dns.sub_domain" "$unified_subdomain"
        
        echo ""
        echo -e "${GREEN}[OK] 已切换为: 统一模式"
        echo "  主 SUB_DOMAIN 已更新为: ${unified_subdomain}"
        
        # 根据旧策略决定如何处理记录
        if [[ "$old_strategy" == "separate" ]]; then
            # 从分离模式切换到统一模式
            echo -e "${YELLOW}[WARN] 检测到从分离模式切换到统一模式"
            echo ""
            echo "请选择如何处理 DNS 记录："
            echo ""
            echo "  1) 自动处理 (推荐)"
            echo "     - 删除各线路的独立解析记录 (default.${domain}, unicom.${domain} 等)"
            echo "     - 为统一子域名 ${unified_subdomain}.${domain} 创建所有运营商线路记录"
            echo ""
            echo "  2) 保留旧记录"
            echo "     - 不删除分离模式的记录"
            echo "     - 仅为 ${unified_subdomain}.${domain} 创建新记录"
            echo "     - 两种模式的记录将同时存在"
            echo ""
            echo "  3) 取消切换"
            echo "     - 保持分离模式"
            echo ""
            read -r -p "请选择 (1/2/3, 默认 1): " handle_choice
            handle_choice=${handle_choice:-1}
            
            if [[ "$handle_choice" == "1" ]]; then
                # 自动处理 - 调用 core.sh 智能切换
                echo ""
                echo -e "${CYAN}正在切换到统一模式..."
                
                if ! trigger_mode_switch "multi" "multi" "unified"; then
                    echo -e "${RED}[ERROR] 切换失败"
                    return 0
                fi
                
                echo ""
                echo -e "${GREEN}[OK] 统一模式记录创建成功"
            elif [[ "$handle_choice" == "2" ]]; then
                # 保留旧记录，只创建新记录
                echo ""
                echo -e "${CYAN}正在创建统一模式记录..."
                if run_core_command -m; then
                    echo ""
                    echo -e "${GREEN}[OK] 统一模式记录创建成功"
                    echo -e "${YELLOW}[WARN] 注意: 分离模式记录仍然保留"
                else
                    echo ""
                    echo -e "${YELLOW}[WARN] 统一模式记录创建失败"
                    echo -e "${CYAN}提示: 可以稍后手动运行 ./core.sh -m 创建"
                fi
            elif [[ "$handle_choice" == "3" ]]; then
                # 取消切换
                echo -e "${YELLOW}[INFO] 已取消切换，保持分离模式"
                # 恢复配置
                update_config_field ".dns.subdomain_strategy" "separate"
                update_config_field ".dns.sub_domain" "${SUB_DOMAIN_DEFAULT:-default}"
                return 0
            fi
        elif [[ "$old_strategy" == "unified" ]]; then
            # 从统一模式切换到统一模式（更换子域名）
            local old_unified_subdomain
            old_unified_subdomain=$(json_get ".dns.sub_domain_unified" "dns")
            
            if [[ "$old_unified_subdomain" != "$unified_subdomain" ]]; then
                echo -e "${YELLOW}[WARN] 检测到更换统一子域名"
                echo ""
                echo "旧子域名: ${old_unified_subdomain}.${domain}"
                echo "新子域名: ${unified_subdomain}.${domain}"
                echo ""
                echo "请选择如何处理 DNS 记录："
                echo ""
                echo "  1) 自动处理 (推荐)"
                echo "     - 删除 ${old_unified_subdomain}.${domain} 的所有运营商线路记录"
                echo "     - 为 ${unified_subdomain}.${domain} 创建所有运营商线路记录"
                echo ""
                echo "  2) 保留旧记录"
                echo "     - 不删除 ${old_unified_subdomain}.${domain} 的记录"
                echo "     - 仅为 ${unified_subdomain}.${domain} 创建新记录"
                echo "     - 两种子域名的记录将同时存在"
                echo ""
                echo "  3) 取消切换"
                echo "     - 恢复为旧的子域名 ${old_unified_subdomain}"
                echo ""
                read -r -p "请选择 (1/2/3, 默认 1): " handle_unified_change
                handle_unified_change=${handle_unified_change:-1}
                
                if [[ "$handle_unified_change" == "1" ]]; then
                    # 自动处理 - 调用 core.sh 智能切换
                    echo ""
                    echo -e "${CYAN}正在更新统一模式记录..."
                    
                    if ! trigger_mode_switch "multi" "multi" "unified"; then
                        echo -e "${RED}[ERROR] 更新失败"
                        return 0
                    fi
                    
                    echo ""
                    echo -e "${GREEN}[OK] 新统一模式记录创建成功"
                elif [[ "$handle_unified_change" == "2" ]]; then
                    # 保留旧记录，只创建新记录
                    echo ""
                    echo -e "${CYAN}正在创建新统一模式记录..."
                    if run_core_command -m; then
                        echo ""
                        echo -e "${GREEN}[OK] 新统一模式记录创建成功"
                        echo -e "${YELLOW}[WARN] 注意: 旧记录 ${old_unified_subdomain}.${domain} 仍然保留"
                    else
                        echo ""
                        echo -e "${YELLOW}[WARN] 新统一模式记录创建失败"
                        echo -e "${CYAN}提示: 可以稍后手动运行 ./core.sh -m 创建"
                    fi
                else
                    # 取消切换
                    echo -e "${YELLOW}[INFO] 已取消切换，恢复为旧子域名"
                    update_config_field ".dns.sub_domain_unified" "$old_unified_subdomain"
                    update_config_field ".dns.sub_domain" "$old_unified_subdomain"
                    return 0
                fi
            else
                # 子域名相同，直接创建记录
                echo ""
                echo -e "${CYAN}正在创建统一模式记录..."
                if run_core_command -m; then
                    echo ""
                    echo -e "${GREEN}[OK] 统一模式记录创建成功"
                else
                    echo ""
                    echo -e "${YELLOW}[WARN] 统一模式记录创建失败"
                    echo -e "${CYAN}提示: 可以稍后手动运行 ./core.sh -m 创建"
                fi
            fi
        else
            # 从其他模式（如单线路）切换到统一模式，直接创建记录
            echo ""
            echo -e "${CYAN}正在创建统一模式记录..."
            if run_core_command -m; then
                echo ""
                echo -e "${GREEN}[OK] 统一模式记录创建成功"
            else
                echo ""
                echo -e "${YELLOW}[WARN] 统一模式记录创建失败"
                echo -e "${CYAN}提示: 可以稍后手动运行 ./core.sh -m 创建"
            fi
        fi
        
        echo -e "${CYAN}提示: 所有线路将使用: ${unified_subdomain}.${domain}"
    else
        echo -e "${RED}[ERROR] 无效的选择"
        return 0
    fi
    
    echo ""
    echo -e "${GREEN}[OK] 子域名策略已更新"
    echo ""
    read -r -p "按回车键继续..."
}

# 同步 DNS 记录到分离模式
sync_records_separate() {
    echo ""
    echo -e "${CYAN}正在运行更新脚本创建各线路解析..."
    echo ""
    
    # 直接调用多线路更新脚本
    if run_core_command -m; then
        echo ""
        echo -e "${GREEN}[OK] DNS 记录同步完成"
        echo ""
        echo -e "${CYAN}提示: 各线路已自动创建解析记录"
    else
        echo -e "${RED}[ERROR] DNS 记录同步失败 (退出码: ${exit_code})"
        echo ""
        echo -e "${CYAN}提示: 请检查配置文件和 IP 文件是否正确"
    fi
}


# 修改运营商线路
modify_isp_lines() {
    echo ""
    echo -e "${CYAN}━━ 修改运营商线路 ━━"
    echo ""
    echo "当前线路: $(json_get ".dns.isp_lines" "默认")"
    echo ""
    echo "请选择需要更新的运营商线路 (可多选,用空格分隔):"
    echo ""
    echo "  核心线路 (推荐,覆盖 95%+ 用户):"
    echo "  1) 默认   - 所有用户 (必须)"
    echo "  2) 联通   - 中国联通用户 (~20%)"
    echo "  3) 移动   - 中国移动用户 (~45%)"
    echo "  4) 电信   - 中国电信用户 (~30%)"
    echo ""
    echo "示例输入: 1 2 3 4  (选择默认、联通、移动、电信)"
    echo ""
    read -r -p "请输入选择的号码: " line_choices
    
    if [[ -z "$line_choices" ]]; then
        echo -e "${YELLOW}[INFO] 未输入,保持当前设置"
        echo ""
        read -r -p "按回车键继续..."
        return 0
    fi
    
    # 将数字转换为线路名称
    local ISP_LINES=""
    declare -A line_map=(
        ["1"]="默认"
        ["2"]="联通"
        ["3"]="移动"
        ["4"]="电信"
    )
    
    for choice in $line_choices; do
        if [[ -n "${line_map[$choice]}" ]]; then
            if [[ -n "$ISP_LINES" ]]; then
                ISP_LINES="$ISP_LINES ${line_map[$choice]}"
            else
                ISP_LINES="${line_map[$choice]}"
            fi
        fi
    done
    
    if [[ -z "$ISP_LINES" ]]; then
        echo -e "${RED}[ERROR] 无效的选择"
        echo ""
        read -r -p "按回车键继续..."
        return 1
    fi
    
    update_config_field ".dns.isp_lines" "$ISP_LINES"
    echo -e "${GREEN}[OK] 运营商线路已更新: ${ISP_LINES}"
    echo ""
    read -r -p "按回车键继续..."
}

# 修改 IP 文件路径
modify_ip_files() {
    echo ""
    echo -e "${CYAN}━━ 修改 IP 文件路径 ━━"
    echo ""
    
    local mode
    mode=$(json_get ".dns.mode" "single")
    
    if [[ "$mode" == "single" ]]; then
        local current_ip_file
        current_ip_file=$(json_get ".ip_source.file_path" "")
        echo "当前 IP 文件: ${current_ip_file}"
        echo ""
        echo -e "${CYAN}提示: IP 文件包含优选的 Cloudflare IP 列表"
        echo "   格式: .iplist 标准格式 (IP|延迟|速度|地区码)"
        echo "   示例: $ROOT_DIR/assets/data/dnspod-dns/mobile.iplist"
        echo ""
        read -r -p "请输入新的 IP 文件路径 [${current_ip_file}]: " new_ip_file
        new_ip_file=${new_ip_file:-$current_ip_file}
        
        if [[ -n "$new_ip_file" ]]; then
            # 验证路径格式(只允许字母数字、下划线、斜杠、点、横线)
            if ! [[ "$new_ip_file" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
                echo -e "${RED}[ERROR] 无效的文件路径格式"
                return 0
            fi
            update_config_field ".ip_source.file_path" "$new_ip_file"
            echo -e "${GREEN}[OK] IP 文件路径已更新: ${new_ip_file}"
        fi
    else
        echo "多线路模式下,每个线路有独立的 IP 文件:"
        echo ""
        local ip_default ip_unicom ip_mobile ip_telecom
        ip_default=$(json_get ".ip_source.files.default" "")
        ip_unicom=$(json_get ".ip_source.files.unicom" "")
        ip_mobile=$(json_get ".ip_source.files.mobile" "")
        ip_telecom=$(json_get ".ip_source.files.telecom" "")
        
        echo "  1) 默认线路: ${ip_default}"
        echo "  2) 联通线路: ${ip_unicom}"
        echo "  3) 移动线路: ${ip_mobile}"
        echo "  4) 电信线路: ${ip_telecom}"
        echo ""
        echo "  0) 返回上级菜单"
        echo ""
        echo -e "${CYAN}提示: IP 文件包含优选的 Cloudflare IP 列表"
        echo "   格式: 每行一个 IP,或用逗号分隔"
        echo ""
        
        read -r -p "请选择要修改的线路 (0-4): " line_choice
        
        case "$line_choice" in
            0)
                echo -e "${YELLOW}[INFO] 已取消"
                return 0
                ;;
            1)
                read -r -p "请输入默认线路 IP 文件路径 [${ip_default}]: " new_path
                new_path=${new_path:-$ip_default}
                if [[ -n "$new_path" ]]; then
                    # 验证路径格式
                    if ! [[ "$new_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
                        echo -e "${RED}[ERROR] 无效的文件路径格式"
                        return 0
                    fi
                    update_config_field ".ip_source.files.default" "$new_path"
                    echo -e "${GREEN}[OK] 默认线路 IP 文件已更新: ${new_path}"
                fi
                ;;
            2)
                read -r -p "请输入联通线路 IP 文件路径 [${ip_unicom}]: " new_path
                new_path=${new_path:-$ip_unicom}
                if [[ -n "$new_path" ]]; then
                    # 验证路径格式
                    if ! [[ "$new_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
                        echo -e "${RED}[ERROR] 无效的文件路径格式"
                        return 0
                    fi
                    update_config_field ".ip_source.files.unicom" "$new_path"
                    echo -e "${GREEN}[OK] 联通线路 IP 文件已更新: ${new_path}"
                fi
                ;;
            3)
                read -r -p "请输入移动线路 IP 文件路径 [${ip_mobile}]: " new_path
                new_path=${new_path:-$ip_mobile}
                if [[ -n "$new_path" ]]; then
                    # 验证路径格式
                    if ! [[ "$new_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
                        echo -e "${RED}[ERROR] 无效的文件路径格式"
                        return 0
                    fi
                    update_config_field ".ip_source.files.mobile" "$new_path"
                    echo -e "${GREEN}[OK] 移动线路 IP 文件已更新: ${new_path}"
                fi
                ;;
            4)
                read -r -p "请输入电信线路 IP 文件路径 [${ip_telecom}]: " new_path
                new_path=${new_path:-$ip_telecom}
                if [ -n "$new_path" ]; then
                    # 验证路径格式
                    if ! [[ "$new_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
                        echo -e "${RED}[ERROR] 无效的文件路径格式"
                        return 0
                    fi
                    update_config_field ".ip_source.files.telecom" "$new_path"
                    echo -e "${GREEN}[OK] 电信线路 IP 文件已更新: ${new_path}"
                fi
                ;;
            *)
                echo -e "${YELLOW}[INFO] 无效的选择"
                ;;
        esac
    fi
    echo ""
    read -r -p "按回车键继续..."
}

# ==================== IP 数据管理功能 ====================

# IP 内容管理入口
manage_ip_content() {
    echo ""
    echo -e "${CYAN}━━ IP 优选数据管理 ━━"
    echo ""
    
    local mode ip_file
    mode=$(json_get ".dns.mode" "single")
    
    if [[ "$mode" = "single" ]]; then
        # 单线路模式下的 IP 文件处理
        ip_file=$(json_get ".ip_source.file_path" "")
        echo "当前运行模式: 单线路解析"
        echo "数据存储路径: ${ip_file}"
        
        if [[ -f "$ip_file" ]]; then
            # 提取并展平所有有效 IP (支持逗号或换行分隔)
            local all_ips
            all_ips=$(cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local ip_count
            ip_count=$(echo "$all_ips" | wc -l)
            echo "当前收录 IP 数量: ${ip_count}"
            echo ""
            echo "已录入 IP 列表:"
            echo "$all_ips" | nl -ba
        else
            echo -e "${RED}[ERROR] 目标 IP 数据文件不存在。"
        fi
        
        echo ""
        echo -e "${CYAN}请选择操作:"
        echo ""
        echo -e "  ${GREEN}[OK] 1. 输入/编辑 IP     ${YELLOW}[推荐]"
        echo -e "  ${GREEN}[OK] 2. 清空所有 IP"
        echo -e "  ${GREEN}[OK] 3. 查看完整列表"
        echo -e "  ${GREEN}[OK] 4. 删除指定 IP"
        echo ""
        echo -e "  ${RED}[BACK] 0. 返回主菜单"
        echo ""
        read -r -p "  请输入选项 [0-4]: " action
        
        case "$action" in
            1)
                # 执行 IP 录入或编辑流程
                clear
                if [[ -f "$ip_file" ]]; then
                    local old_count
                    old_count=$(grep -v '^\s*#' "$ip_file" | grep -cv '^\s*$')
                    echo ""
                    echo -e "${CYAN}检测到现有文件 (${old_count} 个 IP)"
                    echo ""
                    echo -e "${CYAN}请选择操作:"
                    echo ""
                    echo -e "  ${GREEN}[OK] 1. 覆盖     ${YELLOW}[备份后清空]"
                    echo -e "  ${GREEN}[OK] 2. 追加     ${YELLOW}[在现有基础上添加]"
                    echo -e "  ${GREEN}[OK] 3. 清空     ${RED}[备份后删除所有]"
                    echo -e "  ${GREEN}[OK] 4. 跳过     ${CYAN}[取消操作]"
                    echo ""
                    read -r -p "  请输入选项 [1-4, 默认 1]: " choice
                    choice=${choice:-1}
                    
                    case "$choice" in
                        1)
                            cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                            echo -e "\n  ${GREEN}[OK] 已备份旧文件"
                            echo -e "  ${YELLOW}[WARN] 将清空现有内容，准备输入新 IP"
                            true > "$ip_file"
                            ;;
                        2)
                            echo -e "\n  ${GREEN}[INFO] 提示: 将在现有 ${old_count} 个 IP 后追加"
                            ;;
                        3)
                            cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                            true > "$ip_file"
                            echo -e "\n  ${GREEN}[OK] 已清空文件 (已备份)"
                            echo -e "  ${YELLOW}[WARN] 所有 IP 已删除，准备输入新 IP"
                            ;;
                        4)
                            echo -e "\n  ${CYAN}[INFO] 已取消操作"
                            read -r -p "  按回车键继续..."
                            return 0
                            ;;
                    esac
                fi
                
                echo ""
                echo -e "${CYAN}请输入 IP 地址 (支持格式: 每行一个 或 逗号分隔):"
                echo "示例: 104.16.132.229,104.16.133.229"
                echo "      或每行一个 IP"
                echo "空行结束输入"
                echo ""
                
                local temp_file
                temp_file=$(mktemp /tmp/cfopt-dnspod.XXXXXX)
                chmod 600 "${temp_file}"
                # shellcheck disable=SC2034
                local invalid_count=0
                
                while IFS= read -r line; do
                    [[ -z "$line" ]] && break
                    
                    # 【优化】使用 awk 一次性完成分隔、去空格、过滤空行，减少进程 fork
                    while read -r ip; do
                        [[ -z "$ip" ]] && continue
                        # 实时验证 IP 格式
                        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                            # 进一步验证每个段是否 <= 255
                            local valid=true
                            IFS='.' read -ra octets <<< "$ip"
                            for octet in "${octets[@]}"; do
                                if [[ "$octet" -gt 255 ]] 2>/dev/null; then
                                    valid=false
                                    break
                                fi
                            done
                            
                            if [[ "$valid" == true ]]; then
                                echo "$ip" >> "$temp_file"
                                echo -e "  ${GREEN}[OK] $ip"
                            else
                                echo -e "  ${RED}[ERROR] $ip ${YELLOW}(无效的 IP 地址)"
                            fi
                        else
                            echo -e "  ${RED}[ERROR] $ip ${YELLOW}(格式错误)"
                        fi
                    done < <(awk '{
                        gsub(/[,;]/, "\n")
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                        if (length($0) > 0) print
                    }' <<< "$line")
                done
                
                # 统计结果
                if [[ -s "$temp_file" ]]; then
                    valid_count=$(wc -l < "$temp_file")
                fi
                
                # 追加到目标文件
                if [[ -s "$temp_file" ]]; then
                    cat "$temp_file" >> "$ip_file"
                    chmod 644 "$ip_file"
                    
                    local new_count
                    new_count=$(grep -v '^\s*#' "$ip_file" | grep -cv '^\s*$')
                    echo ""
                    echo -e "${GREEN}[OK] 已保存 ${valid_count} 个有效 IP"
                    echo -e "   当前总 IP 数: ${new_count}"
                else
                    echo ""
                    echo -e "${YELLOW}[INFO] 未输入任何有效 IP"
                fi
                
                rm -f "$temp_file"
                ;;
            2)
                # 清空
                clear
                if [[ -f "$ip_file" ]]; then
                    cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                    true > "$ip_file"
                    echo -e "${GREEN}[OK] 已清空所有 IP (已备份)"
                else
                    echo -e "${YELLOW}[INFO] 文件不存在,无需清空"
                fi
                ;;
            3)
                # 查看
                clear
                if [[ -f "$ip_file" ]]; then
                    echo ""
                    echo "完整 IP 列表:"
                    cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | nl -ba
                else
                    echo -e "${RED}[ERROR] 文件不存在"
                fi
                ;;
            4)
                # 删除指定 IP
                clear
                if [[ ! -f "$ip_file" ]]; then
                    echo -e "${RED}[ERROR] 文件不存在"
                    read -r -p "按回车键继续..."
                    return 0
                fi
                
                local all_ips
                all_ips=$(cat "$ip_file" | tr ',' '\n' | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                local ip_count
                ip_count=$(echo "$all_ips" | wc -l)
                
                if [[ "$ip_count" -eq 0 ]]; then
                    echo -e "${YELLOW}[INFO] 文件中没有 IP"
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
                
                if [[ -z "$delete_lines" ]]; then
                    echo -e "${YELLOW}[INFO] 未输入,取消删除"
                    read -r -p "按回车键继续..."
                    return 0
                fi
                
                # 验证输入是否为数字(允许多个数字用空格分隔)
                if ! [[ "$delete_lines" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
                    echo -e "${RED}[ERROR] 无效的行号格式,请输入数字(多个用空格分隔)"
                    read -r -p "按回车键继续..."
                    return 0
                fi
                
                # 验证行号是否在有效范围内
                local -a lines_to_delete_arr
                mapfile -t lines_to_delete_arr <<< "$delete_lines"
                for del_line in "${lines_to_delete_arr[@]}"; do
                    if [[ "$del_line" -lt 1 ]] || [[ "$del_line" -gt "$ip_count" ]]; then
                        echo -e "${RED}[ERROR] 行号 ${del_line} 超出范围 (1-${ip_count})"
                        read -r -p "按回车键继续..."
                        return 0
                    fi
                done
                
                # 备份原文件
                cp "$ip_file" "${ip_file}.bak.$(date +%s)"
                echo -e "${GREEN}[OK] 已备份原文件"
                
                # 将行号转换为数组
                local -a lines_to_delete
                mapfile -t lines_to_delete <<< "$delete_lines"
                
                # 构建新的IP列表(排除要删除的行)
                local new_ips=""
                local line_num=0
                while IFS= read -r ip; do
                    line_num=$((line_num + 1))
                    local should_delete=false
                    for del_line in "${lines_to_delete[@]}"; do
                        if [[ "$line_num" -eq "$del_line" ]]; then
                            should_delete=true
                            break
                        fi
                    done
                    
                    if [[ "$should_delete" == false ]]; then
                        if [[ -n "$new_ips" ]]; then
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
                remaining_count=$(grep -v '^\s*#' "$ip_file" | grep -cv '^\s*$')
                echo -e "${GREEN}[OK] 已删除 ${deleted_count} 个 IP,剩余 ${remaining_count} 个"
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[ERROR] 无效的选择"
                ;;
        esac
        
        echo ""
        read -r -p "按回车键继续..."
    else
        # 多线路模式
        echo "当前运行模式: 多线路解析"
        echo ""
        echo "各线路 IP 文件:"
        
        local ip_default ip_unicom ip_mobile ip_telecom
        ip_default=$(json_get ".ip_source.files.default" "")
        ip_unicom=$(json_get ".ip_source.files.unicom" "")
        ip_mobile=$(json_get ".ip_source.files.mobile" "")
        ip_telecom=$(json_get ".ip_source.files.telecom" "")
        
        echo "  1) 默认线路: ${ip_default:-未配置}"
        echo "  2) 联通线路: ${ip_unicom:-未配置}"
        echo "  3) 移动线路: ${ip_mobile:-未配置}"
        echo "  4) 电信线路: ${ip_telecom:-未配置}"
        echo ""
        echo "  5) 执行 IP 同步（从测速结果自动提取）"
        echo ""
        echo -e "  ${RED}➤${NC} 0. 返回主菜单"
        echo ""
        read -r -p "  请输入选项 [0-5]: " action
        
        case "$action" in
            5)
                clear
                echo -e "${GREEN}正在调用 IP 同步组件...${NC}"
                bash "$ROOT_DIR/modules/ip-sync/sync.sh"
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${YELLOW}[INFO] 请使用 ip-sync 模块自动同步多线路 IP${NC}"
                ;;
        esac
        
        echo ""
        read -r -p "按回车键继续..."
    fi
}

# 修改 TTL 值
modify_ttl() {
    echo ""
    echo -e "${CYAN}━━ 修改 TTL 值 ━━"
    echo ""
    
    local current_ttl
    current_ttl=$(json_get ".dns.ttl" "600")
    echo "当前 TTL: ${current_ttl:-600} 秒"
    echo ""
    echo -e "${CYAN}提示: TTL 是 DNS 记录的生存时间"
    echo "   推荐值: 600 (10分钟)"
    echo ""
    
    read -r -p "请输入新的 TTL 值 (秒, 直接回车保持 ${current_ttl:-600}): " new_ttl
    
    if [[ -n "$new_ttl" ]]; then
        if [[ "$new_ttl" =~ ^[0-9]+$ ]]; then
            update_config_field ".dns.ttl" "$new_ttl"
            echo -e "${GREEN}[OK] TTL 值已更新: ${new_ttl} 秒"
        else
            echo -e "${RED}[ERROR] 请输入有效的数字"
        fi
    else
        echo -e "${YELLOW}[INFO] 保持当前设置不变"
    fi
    echo ""
    read -r -p "按回车键继续..."
}

# 日志管理
manage_logs() {
    # 【修复】统一使用与 core.sh 一致的日志目录路径
    local log_dir="${ROOT_DIR}/logs/dnspod-dns"
    
    # 创建日志目录
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
    
    clear
    echo -e "${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}日志管理"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    # 显示日志文件列表
    local -a log_files
    mapfile -t log_files < <(ls -t "$log_dir"/*.log 2>/dev/null)
    local log_count=${#log_files[@]}
    
    if [[ "$log_count" -eq 0 ]]; then
        echo -e "${YELLOW}[INFO] 暂无日志文件"
        echo ""
        echo "日志将在运行脚本时自动生成"
    else
        echo "当前共有 ${log_count} 个日志文件:"
        echo ""
        
        # 显示前10个最新的日志
        local show_count=0
        for log_file in "${log_files[@]}"; do
            if [[ $show_count -ge 10 ]]; then
                break
            fi
            
            local filename
            filename=$(basename "$log_file")
            local filesize
            filesize=$(du -h "$log_file" | cut -f1)
            local filetime
            filetime=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1 || stat -f %Sm "$log_file" 2>/dev/null)
            
            echo -e "  ${BLUE}$((show_count+1))) ${filename} (${filesize})"
            echo "     时间: ${filetime}"
            
            show_count=$((show_count + 1))
        done
        
        if [[ $log_count -gt 10 ]]; then
            echo -e "  ${YELLOW}... 还有 $((log_count - 10)) 个日志文件"
        fi
    fi
    
    echo ""
    echo "请选择操作:"
    echo "  1) 查看最新日志"
    echo "  2) 查看所有日志列表"
    echo "  3) 清理旧日志 (保留最近7天)"
    echo "  4) 清空所有日志"
    echo "  0) 返回主菜单"
    echo ""
    
    read -r -p "请选择 (0-4): " log_choice
    
    case "$log_choice" in
        1)
            # 查看最新日志
            if [[ $log_count -eq 0 ]]; then
                echo -e "${YELLOW}[INFO] 暂无日志"
            else
                local latest_log="${log_files[0]}"
                echo ""
                echo -e "${CYAN}━━ 最新日志: $(basename "$latest_log") ━━"
                echo ""
                tail -n 50 "$latest_log"
                echo ""
                echo -e "${CYAN}提示: 使用 less 或 cat 查看完整日志"
                echo "   less $latest_log"
            fi
            ;;
        2)
            # 查看所有日志
            if [[ $log_count -eq 0 ]]; then
                echo -e "${YELLOW}[INFO] 暂无日志"
            else
                echo ""
                echo -e "${CYAN}━━ 所有日志文件 ━━"
                echo ""
                list_log_files "$log_dir" "*.log" 10
            fi
            ;;
        3)
            # 清理旧日志(保留7天)
            echo ""
            echo -e "${YELLOW}[WARN] 将删除7天前的日志文件"
            read -r -p "确认执行? (y/n): " confirm
            if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
                local deleted
                deleted=$(find "$log_dir" -name "*.log" -mtime +7 -delete -print 2>/dev/null | wc -l || true)
                echo -e "${GREEN}[OK] 已清理 ${deleted} 个旧日志文件"
            else
                echo -e "${YELLOW}[INFO] 已取消"
            fi
            ;;
        4)
            # 清空所有日志
            echo ""
            echo -e "${RED}[WARN] 警告: 将删除所有日志文件!"
            read -r -p "确认执行? (y/n): " confirm
            if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
                rm -f "$log_dir"/*.log
                echo -e "${GREEN}[OK] 已清空所有日志"
            else
                echo -e "${YELLOW}[INFO] 已取消"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择"
            ;;
    esac
    
    echo ""
    read -r -p "按回车键继续..."
}

# ==================== 公共 HTTP 和工具函数 ====================

# 通用 HTTP 请求函数 (带重试)
http_request() {
    local method="$1"
    local url="$2"
    # shellcheck disable=SC2034
    local secret_id="$3"
    # shellcheck disable=SC2034
    local secret_key="$4"
    local data="${5:-}"
    local max_retries="${6:-3}"
    local retry_count=0
    local response=""
    
    while [[ $retry_count -lt $max_retries ]]; do
        if [[ "$method" == "GET" ]]; then
            response=$(curl -s -w "\n%{http_code}" -X GET "$url" \
                --max-time 10)
        elif [[ "$method" == "POST" ]]; then
            response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
                -H "Content-Type: application/json" \
                -d "$data" \
                --max-time 10)
        fi
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        # shellcheck disable=SC2034
        local body
        # shellcheck disable=SC2034
        body=$(echo "$response" | sed '$d')
        
        # 成功或客户端错误不需要重试
        if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]] || [[ "$http_code" =~ ^4 ]]; then
            echo "$response"
            return 0
        fi
        
        # 服务器错误需要重试
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            echo -e "${YELLOW}[WARN] API 请求失败 (HTTP ${http_code}), 第 ${retry_count}/${max_retries} 次重试..." >&2
            sleep 2
        fi
    done
    
    # 所有重试都失败
    echo "$response"
    return 1
}

# 日志脱敏函数
sanitize_log() {
    local message="$1"
    # 脱敏 SecretKey (保留前8位和后4位)
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
            echo -e "${GREEN}[${timestamp}] [INFO] ${sanitized_msg}"
            ;;
        "WARN")
            echo -e "${YELLOW}[${timestamp}] [WARN] ${sanitized_msg}"
            ;;
        "ERROR")
            echo -e "${RED}[${timestamp}] [ERROR] ${sanitized_msg}"
            ;;
        "DEBUG")
            if [ "${DEBUG_MODE:-0}" = "1" ]; then
                echo -e "${CYAN}[${timestamp}] [DEBUG] ${sanitized_msg}"
            fi
            ;;
    esac
}

# 检查配置并决定是否进入菜单或向导
config_check_result=0
check_config_valid
config_check_result=$?

if [ $config_check_result -eq 0 ]; then
    # 配置有效,直接进入菜单模式
    :
elif [ $config_check_result -eq 2 ]; then
    # 配置不完整(多线路模式缺少必要配置)
    echo -e "\n${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 配置检测"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    echo -e "${RED}[ERROR] 检测到配置不完整"
    echo ""
    
    # 读取当前模式
    current_mode=$(json_get ".dns.mode" "single")
    
    # 转换为中文显示
    if [ "$current_mode" = "multi" ]; then
        echo "当前工作模式: 多线路模式"
    else
        echo "当前工作模式: 单线路模式"
    fi
    echo ""
    
    if [ "$current_mode" = "multi" ]; then
        # 多线路模式配置检测
        echo "多线路模式需要以下配置:"
        echo ""
        
        isp_lines=$(json_get ".dns.isp_lines" "")
        strategy=$(json_get ".dns.subdomain_strategy" "")
        
        if [ -z "$isp_lines" ]; then
            echo -e "  ${RED}[ERROR] 运营商线路 (ISP_LINES) - 未配置"
        else
            echo -e "  ${GREEN}[OK] 运营商线路: ${isp_lines}"
        fi
        
        if [ -z "$strategy" ]; then
            echo -e "  ${RED}[ERROR] 子域名策略 (SUBDOMAIN_STRATEGY) - 未配置"
        else
            # 转换为中文显示
            if [ "$strategy" = "unified" ]; then
                echo -e "  ${GREEN}[OK] 子域名策略: 统一模式"
            elif [ "$strategy" = "separate" ]; then
                echo -e "  ${GREEN}[OK] 子域名策略: 分离模式"
            else
                echo -e "  ${YELLOW}[WARN] 子域名策略: ${strategy} (不合法)"
            fi
            
            # 检查具体子域名配置
            if [ "$strategy" = "unified" ]; then
                unified_sub=$(json_get ".dns.sub_domain_unified" "")
                if [ -z "$unified_sub" ]; then
                    echo -e "  ${RED}[ERROR] 统一子域名 (SUB_DOMAIN_UNIFIED) - 未配置"
                else
                    echo -e "  ${GREEN}[OK] 统一子域名: ${unified_sub}"
                fi
            else
                default_sub=$(json_get ".dns.sub_domains.default" "")
                if [ -z "$default_sub" ]; then
                    echo -e "  ${RED}[ERROR] 默认线路子域名 (SUB_DOMAIN_DEFAULT) - 未配置"
                else
                    echo -e "  ${GREEN}[OK] 默认线路子域名: ${default_sub}"
                fi
            fi
        fi
        
    elif [ "$current_mode" = "single" ]; then
        # 单线路模式配置检测
        echo "单线路模式需要以下配置:"
        echo ""
        
        sub_domain=$(json_get ".dns.sub_domain" "")
        if [ -z "$sub_domain" ]; then
            echo -e "  ${RED}[ERROR] 子域名 (SUB_DOMAIN) - 未配置"
        else
            echo -e "  ${GREEN}[OK] 子域名: ${sub_domain}"
        fi
    fi
        
        echo ""
        echo -e "${YELLOW}[WARN] 配置不完整将导致脚本无法正常运行"
        echo ""
        echo -e "${CYAN}建议操作:"
        echo "  1) 立即补全配置 (推荐) - 交互式引导,简单快速"
        echo "  0) 退出脚本"
        echo ""
        
        read -r -p "请选择操作 (0-1): " fix_choice
        
        case "$fix_choice" in
            1)
                # 清屏后进入配置补全流程
                clear
                echo ""
                
                if [ "$current_mode" = "multi" ]; then
                    echo -e "${CYAN}━━ 补全多线路配置 ━━"
                else
                    echo -e "${CYAN}━━ 补全单线路配置 ━━"
                fi
                echo ""
                
                if [ "$current_mode" = "multi" ]; then
                    # 多线路配置补全
                    # 1. 配置运营商线路
                    if [ -z "$isp_lines" ]; then
                        echo "请选择需要更新的运营商线路 (可多选,用空格分隔):"
                        echo ""
                        echo "  核心线路 (推荐,覆盖 95%+ 用户):"
                        echo "  1) 默认   - 所有用户 (必须)"
                        echo "  2) 联通   - 中国联通用户 (~20%)"
                        echo "  3) 移动   - 中国移动用户 (~45%)"
                        echo "  4) 电信   - 中国电信用户 (~30%)"
                        echo ""
                        echo "示例输入: 1 2 3 4  (选择默认、联通、移动、电信)"
                        echo ""
                        read -r -p "请输入选择的号码: " line_choices
                        
                        if [ -n "$line_choices" ]; then
                            ISP_LINES=""
                            declare -A line_map=(
                                ["1"]="默认"
                                ["2"]="联通"
                                ["3"]="移动"
                                ["4"]="电信"
                            )
                            
                            for choice in $line_choices; do
                                if [ -n "${line_map[$choice]}" ]; then
                                    if [ -z "$ISP_LINES" ]; then
                                        ISP_LINES="${line_map[$choice]}"
                                    else
                                        ISP_LINES="$ISP_LINES ${line_map[$choice]}"
                                    fi
                                fi
                            done
                            
                            if [ -n "$ISP_LINES" ]; then
                                # 更新配置
                                update_config_field ".dns.isp_lines" "$ISP_LINES"
                                echo -e "${GREEN}[OK] 线路配置: ${ISP_LINES}"
                            fi
                        fi
                        
                        echo ""
                    fi
                    
                    # 2. 配置子域名策略
                    # 检查策略是否为空或不合法
                    if [ -z "$strategy" ] || { [ "$strategy" != "separate" ] && [ "$strategy" != "unified" ]; }; then
                        echo "请选择子域名策略:"
                        echo ""
                        echo "  1) 分离模式 (推荐) - 每条线路使用独立子域名"
                        echo "     例如: default.drxian.cn, unicom.drxian.cn"
                        echo ""
                        echo "  2) 统一模式 (省心) - 所有线路共用同一子域名"
                        echo "     例如: dns.drxian.cn (通过 DNSPod 线路区分)"
                        echo ""
                        read -r -p "请选择策略 (1/2, 默认 1): " strategy_choice
                        
                        if [ -z "$strategy_choice" ]; then
                            strategy_choice="1"
                        fi
                        
                        if [ "$strategy_choice" = "1" ]; then
                            # 更新配置
                            update_config_field ".dns.subdomain_strategy" "separate"
                            echo -e "${GREEN}[OK] 已选择: 分离模式"
                        else
                            # 更新配置
                            update_config_field ".dns.subdomain_strategy" "unified"
                            echo -e "${GREEN}[OK] 已选择: 统一模式"
                            
                            read -r -p "请输入统一子域名 [dns]: " unified_subdomain
                            unified_subdomain=${unified_subdomain:-dns}
                            # 验证子域名格式
                            if ! [[ "$unified_subdomain" =~ ^[a-zA-Z0-9\-]+$ ]]; then
                                echo -e "${RED}[ERROR] 无效的子域名格式"
                                return 0
                            fi
                            # 更新配置
                            update_config_field ".dns.sub_domain_unified" "$unified_subdomain"
                        fi
                        
                        echo ""
                    fi
                    
                elif [ "$current_mode" = "single" ]; then
                    # 单线路配置补全
                    sub_domain=$(json_get ".dns.sub_domain" "")
                    if [ -z "$sub_domain" ]; then
                        echo "单线路模式需要配置子域名"
                        echo ""
                        echo "示例:"
                        echo "  - 如果你的域名是 drxian.cn"
                        echo "  - 设置 SUB_DOMAIN=dns"
                        echo "  - 最终解析为: dns.drxian.cn"
                        echo ""
                        read -r -p "请输入子域名 [dns]: " input_subdomain
                        input_subdomain=${input_subdomain:-dns}
                        
                        # 验证子域名格式
                        if ! [[ "$input_subdomain" =~ ^[a-zA-Z0-9\-@]+$ ]]; then
                            echo -e "${RED}[ERROR] 无效的子域名格式"
                            return 0
                        fi
                        
                        # 更新配置
                        update_config_field ".dns.sub_domain" "$input_subdomain"
                        
                        echo -e "${GREEN}[OK] 子域名已配置: ${input_subdomain}"
                        echo ""
                    fi
                fi
                
                echo -e "${GREEN}[OK] 配置补全完成!"
                echo ""
                read -r -p "按回车键继续..."
                clear
                ;;
            0|*)
                echo ""
                echo -e "${YELLOW}[INFO] 已退出"
                exit 0
                ;;
        esac
else
    # 配置无效,提示用户并开始引导
    echo -e "\n${CYAN}${MENU_BORDER}"
    echo -e " ${YELLOW}DNSPod DNS 更新器 - 初始化检测"
    echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 配置文件不存在"
        echo "   首次使用需要先进行配置"
    elif [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 配置文件为空"
        echo "   文件存在但没有内容,需要重新配置"
    else
        echo -e "${RED}[ERROR] 配置文件格式错误"
        echo "   检测到缺少必要的配置项:"
        
        # 检查具体缺少哪些配置
        has_domain=$(jq -r '.dns.domain // empty' "$CONFIG_FILE" 2>/dev/null || true)
        has_secretid=$(jq -r '.api.id // empty' "$CONFIG_FILE" 2>/dev/null || true)
        has_secretkey=$(jq -r '.api.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
        
        if [[ -z "$has_domain" ]] || [[ "$has_domain" == "null" ]]; then
            echo -e "   ${YELLOW}- dns.domain (域名)"
        fi
        if [[ -z "$has_secretid" ]] || [[ "$has_secretid" == "null" ]]; then
            echo -e "   ${YELLOW}- api.id (API密钥ID)"
        fi
        if [[ -z "$has_secretkey" ]] || [[ "$has_secretkey" == "null" ]]; then
            echo -e "   ${YELLOW}- api.token (API密钥)"
        fi
        
        echo ""
        echo -e "${YELLOW}[WARN] 配置不规范可能导致脚本运行失败"
    fi
    
    echo ""
    echo -e "${CYAN}提示: 完成配置后即可使用所有功能"
    echo ""
    
    echo -e "${CYAN}请选择:"
    echo "  y - 现在立即开始配置向导"
    echo "  n - 退出脚本"
    echo ""
    read -r -p "请输入 (y/n, 默认 y): " start_config
    start_config=${start_config:-y}
    
    if [ "$start_config" != "y" ] && [ "$start_config" != "Y" ]; then
        echo ""
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        echo -e "${YELLOW}[WARN] 提示:"
        echo "   - 没有有效的配置文件,无法使用运行功能"
        echo "   - 您可以重新运行此脚本进行配置"
        echo -e "${CYAN}+------------------------------------------------------------+${NC}"
        echo ""
        exit 0
    fi
    
    # 清屏后开始配置向导
    clear
    echo ""
    # 跳过菜单,直接进入完整配置向导
    skip_menu=true
fi

# 如果配置无效且用户选择不配置,则已退出
# 如果配置无效但用户选择配置,skip_menu=true,跳过主循环
if [ "${skip_menu:-false}" = "true" ]; then
    # 直接进入配置向导,不显示主菜单
    :
else
    # 配置有效,显示主菜单
    # 确保清屏后再显示主菜单
    clear
    # 主循环
    while true; do
        show_menu
        read -r -p "请选择操作 (0-6): " choice
    
    case "$choice" in
        1)
            # 完整配置向导 - 跳出循环执行
            clear
            break
            ;;
        2)
            # 根据配置文件自动判断模式
            clear
            if [ -f "$CONFIG_FILE" ]; then
                run_mode=$(json_get ".dns.mode" "single")
                quick_run "$run_mode"
            else
                echo -e "${RED}错误: 配置文件不存在"
                echo "请先运行完整配置向导"
            fi
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        3)
            clear
            view_config
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        4)
            clear
            modify_ip_limit
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        5)
            # 进入二级菜单循环
            should_break_main=false
            while true; do
                clear
                modify_config_menu
                result=$?
                if [ $result -eq 0 ]; then
                    # 用户选择返回主菜单
                    break
                elif [ $result -eq 2 ]; then
                    # 【修复】用户选择全部重新配置，使用标志变量替代 break 2
                    RECONFIGURE_ALL=true
                    should_break_main=true
                    break
                elif [ $result -eq 1 ]; then
                    # 修改完成,继续显示二级菜单
                    continue
                fi
                # 否则继续显示二级菜单
            done
            
            # 【修复】检查是否需要跳出主循环
            if [[ "${should_break_main}" = true ]]; then
                break
            fi
            
            # 从二级菜单返回,清屏后再显示主菜单
            clear
            ;;
        0)
            echo ""
            echo -e "${GREEN}[OK] 再见!"
            exit 0
            ;;
        6)
            # 日志管理
            clear
            manage_logs
            clear
            ;;
        *)
            echo ""
            echo -e "${RED}[ERROR] 无效的选择,请重新输入"
            echo ""
            read -r -p "按回车键继续..."
            clear
            ;;
    esac
    done
fi

# 以下是完整的配置向导 (原 setup.sh 内容)
echo ""
echo -e "${CYAN}${MENU_BORDER}"
echo -e " ${YELLOW}DNSPod DNS 更新器 - 完整配置向导"
echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
echo ""
echo -e "${CYAN}━━ 步骤 1/7: 域名配置 ━━"
echo ""
echo -e "${CYAN}提示: DNSPod 不同套餐支持不同的负载均衡记录数量:"
echo "  - 免费版: 2 条 (默认)"
echo "  - 专业版: 10 条"
echo "  - 企业版: 100 条"
echo "  - 尊享版: 不限制"
echo -e "  ${YELLOW}警告: 免费版超出限制会导致 API 报错,脚本会自动限制 IP 数量"
echo -e "  ${CYAN}文档: 套餐详情: https://cloud.tencent.com/document/product/302/104713"
echo ""

read -r -p "请输入你的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误: 域名不能为空"
    exit 1
fi

echo ""
echo -e "${GREEN}[OK] 域名: ${DOMAIN}"
echo ""

# 清屏后进入下一步
clear
echo -e "${CYAN}━━ 步骤 2/7: 工作模式选择 ━━"
echo ""
echo "请选择工作模式:"
echo ""
echo "  1) 单线路模式 - 为域名设置统一的 Cloudflare 优选 IP"
echo "     适合: 所有用户访问同一组优选 IP"
echo "     例如: dns.${DOMAIN} → 所有用户解析到相同的 CF 优选 IP"
echo ""
echo "  2) 多线路模式 - 为不同运营商设置不同的 Cloudflare 优选 IP"
echo "     适合: 根据运营商优化访问速度(联通/移动/电信等)"
echo "     支持: 默认、联通、移动、电信等线路"
echo "     例如: unicom.${DOMAIN} → 联通优选IP, mobile.${DOMAIN} → 移动优选IP"
echo ""
read -r -p "请选择模式 (1/2, 默认 1): " mode_choice

if [ -z "$mode_choice" ]; then
    mode_choice="1"
fi

if [ "$mode_choice" = "1" ]; then
    MODE="single"
    echo -e "\n${GREEN}[OK] 已选择: 单线路模式"
elif [ "$mode_choice" = "2" ]; then
    MODE="multi"
    echo -e "\n${GREEN}[OK] 已选择: 多线路模式"
else
    echo -e "${RED}[ERROR] 无效的选择"
    exit 1
fi

echo ""

# 清屏后进入下一步
clear
echo -e "${CYAN}━━ 步骤 3/7: 腾讯云 API 密钥配置 ━━"
echo ""
echo -e "${CYAN}提示: 如果还没有密钥,请访问:"
echo "   https://console.cloud.tencent.com/cam/capi"
echo ""

read -r -p "请输入 SecretId: " SECRETID

if [ -z "$SECRETID" ]; then
    echo -e "${RED}错误: SecretId 不能为空"
    exit 1
fi

# 【安全修复】使用 -s 静默模式，不回显 SecretKey
echo -e "${CYAN}请输入 SecretKey（输入不会显示在屏幕上）:${NC}"
read -rs SECRETKEY
echo ""

if [ -z "$SECRETKEY" ]; then
    echo -e "${RED}错误: SecretKey 不能为空"
    exit 1
fi

echo ""
echo -e "${GREEN}[OK] 密钥配置完成"
echo ""

# 清屏后进入下一步
clear
if [ "$MODE" = "multi" ]; then
    echo -e "${CYAN}━━ 步骤 4/7: 运营商线路配置 ━━"
else
    echo -e "${CYAN}━━ 步骤 4/7: 跳过运营商线路配置 (单线路模式) ━━"
fi
echo ""

if [ "$MODE" = "multi" ]; then
    echo "请选择需要更新的运营商线路 (可多选,用空格分隔):"
    echo ""
    echo "  核心线路 (推荐,覆盖 95%+ 用户):"
    echo "  1) 默认   - 所有用户 (必须)"
    echo "  2) 联通   - 中国联通用户 (~20%)"
    echo "  3) 移动   - 中国移动用户 (~45%)"
    echo "  4) 电信   - 中国电信用户 (~30%)"
    echo ""
    echo "示例输入: 1 2 3 4  (选择默认、联通、移动、电信)"
    echo ""
    read -r -p "请输入选择的号码: " line_choices
    
    if [ -z "$line_choices" ]; then
        echo -e "${RED}[ERROR] 至少选择一个线路"
        exit 1
    fi
    
    # 将数字转换为线路名称
    ISP_LINES=""
    declare -A line_map=(
        ["1"]="默认"
        ["2"]="联通"
        ["3"]="移动"
        ["4"]="电信"
    )
    
    for choice in $line_choices; do
        if [ -n "${line_map[$choice]}" ]; then
            if [ -z "$ISP_LINES" ]; then
                ISP_LINES="${line_map[$choice]}"
            else
                ISP_LINES="$ISP_LINES ${line_map[$choice]}"
            fi
        else
            echo -e "${YELLOW}[WARN] 无效的选择 '$choice',已跳过"
        fi
    done
    
    if [ -z "$ISP_LINES" ]; then
        echo -e "${RED}[ERROR] 没有有效的线路选择"
        exit 1
    fi
    
    echo -e "\n${GREEN}[OK] 线路配置: ${ISP_LINES}"
else
    # 单线路模式,默认只使用“默认”线路
    ISP_LINES="默认"
    echo -e "${YELLOW}[INFO] 单线路模式,将只更新'默认'线路"
fi

echo ""

# 清屏后进入下一步
clear
if [ "$MODE" = "multi" ]; then
    echo -e "${CYAN}━━ 步骤 5/7: 子域名策略选择 ━━"
else
    echo -e "${CYAN}━━ 步骤 5/7: 子域名配置 ━━"
fi
echo ""

if [ "$MODE" = "single" ]; then
    echo -e "${CYAN}提示: 子域名是解析记录的前缀,例如:"
    echo "  - 输入 www → 最终域名为 www.${DOMAIN}"
    echo "  - 输入 @ → 最终域名为 ${DOMAIN} (根域名)"
    echo "  - 输入 api → 最终域名为 api.${DOMAIN}"
    echo ""
    echo -e "${CYAN}推荐: 使用有意义的名称,如 dns, www, api 等"
    echo ""
    read -r -p "请输入子域名 [dns]: " SUB_DOMAIN
    SUB_DOMAIN=${SUB_DOMAIN:-dns}
    
    if [ -z "$SUB_DOMAIN" ]; then
        echo -e "${RED}错误: 子域名不能为空"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}[OK] 子域名配置: ${SUB_DOMAIN}.${DOMAIN}"
    
    # 设置多线路相关变量(虽然不使用)
    SUBDOMAIN_STRATEGY="single"
    SUB_DOMAIN_DEFAULT="$SUB_DOMAIN"
    SUB_DOMAIN_UNICOM="unicom"
    SUB_DOMAIN_MOBILE="mobile"
    SUB_DOMAIN_TELECOM="telecom"
    
    echo ""
else

if [ "$MODE" = "multi" ]; then
    echo "多线路模式下,请选择子域名策略:"
    echo ""
    echo "  1) 分离模式 (推荐) - 每条线路使用独立子域名"
    echo "     例如: default.drxian.cn, unicom.drxian.cn"
    echo "     优点: 清晰明确,便于管理和调试"
    echo "     缺点: 需要配置多个子域名"
    echo ""
    echo "  2) 统一模式 (省心) - 所有线路共用同一子域名"
    echo "     例如: dns.drxian.cn (通过 DNSPod 线路区分)"
    echo "     优点: 配置简单,只需一个子域名"
    echo "     缺点: 依赖 DNSPod 线路功能"
    echo ""
    read -r -p "请选择策略 (1/2, 默认 1): " strategy_choice
    
    if [ -z "$strategy_choice" ]; then
        strategy_choice="1"
    fi
    
    if [ "$strategy_choice" = "1" ]; then
        SUBDOMAIN_STRATEGY="separate"
        echo -e "\n${GREEN}[OK] 已选择: 分离模式"
        echo ""
        echo "请为每条线路设置子域名前缀 (留空使用默认值):"
        echo ""
        
        read -r -p "默认线路子域名前缀 [default]: " SUB_DOMAIN_DEFAULT
        SUB_DOMAIN_DEFAULT=${SUB_DOMAIN_DEFAULT:-default}
        
        # 检查用户是否选择了联通线路
        if [[ "$ISP_LINES" == *"联通"* ]]; then
            read -r -p "联通线路子域名前缀 [unicom]: " SUB_DOMAIN_UNICOM
            SUB_DOMAIN_UNICOM=${SUB_DOMAIN_UNICOM:-unicom}
        else
            SUB_DOMAIN_UNICOM="unicom"
        fi
        
        # 检查用户是否选择了移动线路
        if [[ "$ISP_LINES" == *"移动"* ]]; then
            read -r -p "移动线路子域名前缀 [mobile]: " SUB_DOMAIN_MOBILE
            SUB_DOMAIN_MOBILE=${SUB_DOMAIN_MOBILE:-mobile}
        else
            SUB_DOMAIN_MOBILE="mobile"
        fi
        
        # 检查用户是否选择了电信线路
        if [[ "$ISP_LINES" == *"电信"* ]]; then
            read -r -p "电信线路子域名前缀 [telecom]: " SUB_DOMAIN_TELECOM
            SUB_DOMAIN_TELECOM=${SUB_DOMAIN_TELECOM:-telecom}
        else
            SUB_DOMAIN_TELECOM="telecom"
        fi
        
        echo ""
        echo -e "${CYAN}提示: 各线路的完整域名为:"
        if [[ "$ISP_LINES" == *"默认"* ]]; then
            echo "  - ${SUB_DOMAIN_DEFAULT}.${DOMAIN} (默认线路)"
        fi
        if [[ "$ISP_LINES" == *"联通"* ]]; then
            echo "  - ${SUB_DOMAIN_UNICOM}.${DOMAIN} (联通线路)"
        fi
        if [[ "$ISP_LINES" == *"移动"* ]]; then
            echo "  - ${SUB_DOMAIN_MOBILE}.${DOMAIN} (移动线路)"
        fi
        if [[ "$ISP_LINES" == *"电信"* ]]; then
            echo "  - ${SUB_DOMAIN_TELECOM}.${DOMAIN} (电信线路)"
        fi
    elif [ "$strategy_choice" = "2" ]; then
        SUBDOMAIN_STRATEGY="unified"
        echo -e "\n${GREEN}[OK] 已选择: 统一模式"
        echo ""
        
        # 统一模式下,自动配置所有运营商线路
        echo -e "${CYAN}提示: 统一模式需要为所有运营商线路创建记录"
        echo "  将自动配置: 默认 联通 移动 电信"
        ISP_LINES="默认 联通 移动 电信"
        echo -e "${GREEN}[OK] 运营商线路已自动配置: ${ISP_LINES}"
        echo ""
        
        echo -e "${CYAN}提示: 所有线路将共用同一个子域名"
        echo "  例如: dns.drxian.cn (通过 DNSPod 线路区分)"
        echo ""
        read -r -p "请输入统一子域名 [dns]: " SUB_DOMAIN_UNIFIED
        SUB_DOMAIN_UNIFIED=${SUB_DOMAIN_UNIFIED:-dns}
        
        echo ""
        echo -e "${CYAN}提示: 所有线路将使用相同子域名:"
        echo "  - ${SUB_DOMAIN_UNIFIED}.${DOMAIN}"
        echo "  DNSPod 将通过 RecordLine 参数区分不同线路"
        
        # 设置分离模式的默认值(以备后续切换)
        SUB_DOMAIN_DEFAULT="default"
        SUB_DOMAIN_UNICOM="unicom"
        SUB_DOMAIN_MOBILE="mobile"
        SUB_DOMAIN_TELECOM="telecom"
    else
        echo -e "${RED}[ERROR] 无效的选择"
        exit 1
    fi
else
    # 单线路模式,不需要选择策略
    SUBDOMAIN_STRATEGY="single"
    SUB_DOMAIN_DEFAULT="default"
    SUB_DOMAIN_UNICOM="unicom"
    SUB_DOMAIN_MOBILE="mobile"
    SUB_DOMAIN_TELECOM="telecom"
    echo -e "${YELLOW}[INFO] 单线路模式,跳过子域名策略选择"
fi
fi

echo ""

# 【用户体验优化】清屏前显示已配置的摘要信息
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}[INFO] 已完成的配置:${NC}"
echo -e "  域名: ${DOMAIN}"
echo -e "  工作模式: ${MODE}"
if [ "$MODE" = "multi" ]; then
    echo -e "  运营商线路: ${ISP_LINES[*]}"
fi
echo -e "  API SecretId: ${SECRETID:0:8}...${SECRETID: -4}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -r -p "按回车键继续配置 IP 文件..."

# 清屏后进入下一步
clear
if [ "$MODE" = "multi" ]; then
    echo -e "${CYAN}━━ 步骤 6/7: IP 文件配置 ━━"
else
    echo -e "${CYAN}━━ 步骤 6/7: IP 文件配置 ━━"
fi
echo ""
echo -e "${CYAN}提示: 优选 IP 将从文本文件读取"
echo "   测速软件会自动生成 IP 列表到默认路径"
echo "   文件格式: .iplist 标准格式 (IP|延迟|速度|地区码)"
echo ""

if [ "$MODE" = "multi" ]; then
    echo "多线路模式下,每个线路有独立的 IP 文件:"
    echo "  - assets/data/dnspod-dns/default.iplist    (默认线路)"
    echo "  - assets/data/dnspod-dns/unicom.iplist     (联通线路)"
    echo "  - assets/data/dnspod-dns/mobile.iplist     (移动线路)"
    echo "  - assets/data/dnspod-dns/telecom.iplist    (电信线路)"
    echo ""
    echo "IP 文件将自动生成到 $ROOT_DIR/assets/data/dnspod-dns/ 目录"
    
    # 询问是否更改默认路径
    read -r -p "是否需要更改 IP 文件基础路径? (y/n, 默认 n): " change_path
    
    if [ "$change_path" = "y" ] || [ "$change_path" = "Y" ]; then
        read -r -p "请输入新的基础路径 (例如: ./my-ips): " base_path
        
        if [ -z "$base_path" ]; then
            base_path="$ROOT_DIR/assets/data/dnspod-dns"
        fi
        
        IP_FILE_DEFAULT="${base_path}/default.iplist"
        IP_FILE_UNICOM="${base_path}/unicom.iplist"
        IP_FILE_MOBILE="${base_path}/mobile.iplist"
        IP_FILE_TELECOM="${base_path}/telecom.iplist"
        
        echo -e "\n${GREEN}[OK] IP 文件基础路径: ${base_path}"
    else
        # shellcheck disable=SC2034
        IP_FILE_DEFAULT="$ROOT_DIR/assets/data/dnspod-dns/default.iplist"
        # shellcheck disable=SC2034
        IP_FILE_UNICOM="$ROOT_DIR/assets/data/dnspod-dns/unicom.iplist"
        # shellcheck disable=SC2034
        IP_FILE_MOBILE="$ROOT_DIR/assets/data/dnspod-dns/mobile.iplist"
        # shellcheck disable=SC2034
        IP_FILE_TELECOM="$ROOT_DIR/assets/data/dnspod-dns/telecom.iplist"
        echo -e "\n${GREEN}[OK] 使用默认路径: $ROOT_DIR/assets/data/dnspod-dns"
    fi
else
    echo -e "${CYAN}默认路径: $ROOT_DIR/assets/data/dnspod-dns/default.iplist"
    echo ""
    read -r -p "是否需要更改 IP 文件路径? (y/n, 默认 n): " change_path
    
    if [ "$change_path" = "y" ] || [ "$change_path" = "Y" ]; then
        read -r -p "请输入新的 IP 文件路径: " IP_FILE_SINGLE
        
        if [ -z "$IP_FILE_SINGLE" ]; then
            IP_FILE_SINGLE="$ROOT_DIR/assets/data/dnspod-dns/default.iplist"
        fi
        
        echo -e "\n${GREEN}[OK] IP 文件路径: ${IP_FILE_SINGLE}"
    else
        IP_FILE_SINGLE="$ROOT_DIR/assets/data/dnspod-dns/default.iplist"
        echo -e "\n${GREEN}[OK] 使用默认路径: ${IP_FILE_SINGLE}"
    fi
fi

echo ""

# 清屏后进入下一步
clear
if [ "$MODE" = "multi" ]; then
    echo -e "${CYAN}━━ 步骤 7/7: IP 数量限制配置 ━━"
else
    echo -e "${CYAN}━━ 步骤 6/6: IP 数量限制配置 ━━"
fi
echo ""
echo -e "${CYAN}提示: DNSPod 套餐负载均衡记录数限制:"
echo "  - 免费版: 2 条 (默认)"
echo "  - 专业版: 10 条"
echo "  - 企业版: 100 条"
echo "  - 尊享版: 不限制"
echo -e "  ${CYAN}文档: 官方文档: https://cloud.tencent.com/document/product/302/104713"
echo ""

echo -e "${YELLOW}说明:"
echo "  - 设置每条 DNS 记录最多包含几个 IP 地址"
echo "  - 例如: 设置为 2，则每个域名最多解析到 2 个 IP"
echo "  - 设置为 0 表示不限制（需要套餐支持）"
echo ""

read -r -p "请输入限制数量 (默认 2, 直接回车使用默认): " MAX_IPS_PER_RECORD_INPUT

if [ -z "$MAX_IPS_PER_RECORD_INPUT" ]; then
    MAX_IPS_PER_RECORD=2
elif [[ "$MAX_IPS_PER_RECORD_INPUT" =~ ^[0-9]+$ ]]; then
    MAX_IPS_PER_RECORD=$MAX_IPS_PER_RECORD_INPUT
else
    echo -e "${YELLOW}无效输入,使用默认值 2"
    MAX_IPS_PER_RECORD=2
fi

if [ "$MAX_IPS_PER_RECORD" -eq 0 ]; then
    echo -e "${GREEN}[OK] IP 数量限制已取消 (不限制)"
else
    echo -e "${GREEN}[OK] IP 数量限制已设置: 每条记录最多 ${MAX_IPS_PER_RECORD} 个 IP"
fi

echo ""

# 清屏后显示确认信息
clear
echo ""
echo -e "${CYAN}━━ 确认配置 ━━"
echo ""
echo "请确认以下配置是否正确:"
echo ""
echo "  工作模式:     ${MODE}"
if [ "$MODE" = "multi" ]; then
    if [ "$SUBDOMAIN_STRATEGY" = "unified" ]; then
        echo "  子域名策略:   统一模式 (${SUB_DOMAIN_UNIFIED}.${DOMAIN})"
    else
        echo "  子域名策略:   分离模式"
        if [[ "$ISP_LINES" == *"默认"* ]]; then
            echo "    - ${SUB_DOMAIN_DEFAULT}.${DOMAIN} (默认线路)"
        fi
        if [[ "$ISP_LINES" == *"联通"* ]]; then
            echo "    - ${SUB_DOMAIN_UNICOM}.${DOMAIN} (联通线路)"
        fi
        if [[ "$ISP_LINES" == *"移动"* ]]; then
            echo "    - ${SUB_DOMAIN_MOBILE}.${DOMAIN} (移动线路)"
        fi
        if [[ "$ISP_LINES" == *"电信"* ]]; then
            echo "    - ${SUB_DOMAIN_TELECOM}.${DOMAIN} (电信线路)"
        fi
    fi
else
    echo "  子域名:       ${SUB_DOMAIN}.${DOMAIN}"
fi
echo "  SecretId:     ${SECRETID:0:8}...${SECRETID: -4}"
echo "  SecretKey:    **** (已隐藏)"
if [ "$MODE" = "multi" ]; then
    echo "  运营商线路:   ${ISP_LINES}"
fi
if [ "$MAX_IPS_PER_RECORD" -eq 0 ]; then
    echo "  IP 数量限制: 不限制"
else
    echo "  IP 数量限制: 每条记录最多 ${MAX_IPS_PER_RECORD} 个 IP"
fi
echo ""

read -r -p "确认保存配置? (y/n): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "\n${RED}[ERROR] 配置已取消"
    exit 0
fi

# 清屏后生成配置
clear
echo ""
echo -e "${CYAN}正在生成配置文件...${NC}"

# 【修复】移除函数外的 local 关键字，改为普通变量
config_dir=$(dirname "$CONFIG_FILE")
mkdir -p "$config_dir"
chmod 755 "$config_dir"

# 使用临时文件 + jq 生成 JSON 配置（原子写入）
temp_file=$(mktemp "${config_dir}/.tmp.XXXXXX")

# 构建基础配置对象
jq -n \
    --arg comment "DNSPod DNS 更新器配置" \
    --arg version "0.1" \
    --argjson enabled true \
    --arg domain "$DOMAIN" \
    --arg secretid "$SECRETID" \
    --arg secretkey "$SECRETKEY" \
    --arg mode "$MODE" \
    --arg subdomain "$SUB_DOMAIN" \
    --arg strategy "${SUBDOMAIN_STRATEGY:-separate}" \
    --arg unified_subdomain "${SUB_DOMAIN_UNIFIED:-dns}" \
    --arg default_subdomain "${SUB_DOMAIN_DEFAULT:-default}" \
    --arg unicom_subdomain "${SUB_DOMAIN_UNICOM:-unicom}" \
    --arg mobile_subdomain "${SUB_DOMAIN_MOBILE:-mobile}" \
    --arg telecom_subdomain "${SUB_DOMAIN_TELECOM:-telecom}" \
    --arg isp_lines "$ISP_LINES" \
    --argjson max_ips "$MAX_IPS_PER_RECORD" \
    '{
        "_comment": $comment,
        "_version": $version,
        "enabled": $enabled,
        "api": {
            "id": $secretid,
            "token": $secretkey,
            "timeout": 10,
            "max_retries": 5
        },
        "dns": {
            "domain": $domain,
            "sub_domain": $subdomain,
            "record_type": "A",
            "ttl": 600,
            "max_ips_per_record": $max_ips,
            "mode": $mode,
            "subdomain_strategy": $strategy,
            "sub_domain_unified": $unified_subdomain,
            "sub_domains": {
                "default": $default_subdomain,
                "unicom": $unicom_subdomain,
                "mobile": $mobile_subdomain,
                "telecom": $telecom_subdomain
            },
            "isp_lines": $isp_lines
        },
        "ip_source": {
            "file_path": (if $mode == "single" then "./assets/data/dnspod-dns/ip_list.iplist" else null end),
            "files": (if $mode == "multi" then {
                "default": "./assets/data/dnspod-dns/default.iplist",
                "unicom": "./assets/data/dnspod-dns/unicom.iplist",
                "mobile": "./assets/data/dnspod-dns/mobile.iplist",
                "telecom": "./assets/data/dnspod-dns/telecom.iplist"
            } else null end)
        },
        "logging": {
            "log_dir": "./logs/dnspod-dns",
            "log_rotation_days": 7,
            "verbose": false
        }
    }' > "$temp_file" 2>/dev/null

if [[ $? -ne 0 ]]; then
    rm -f "$temp_file"
    echo -e "${RED}[ERROR] 配置文件生成失败${NC}"
    exit 1
fi

# 设置安全权限
chmod 600 "$temp_file"

# 原子移动
mv "$temp_file" "$CONFIG_FILE"

echo -e "${GREEN}[OK] 配置文件已生成: ${CONFIG_FILE#${ROOT_DIR}/}${NC}"
echo ""
# 如果是多线路模式,创建 IP 文件模板
if [ "$MODE" = "multi" ]; then
    echo -e "${CYAN}正在创建 IP 文件模板...${NC}"
    echo ""
    
    # 【修复】移除函数外的 local 关键字
    ip_dir=$(jq -r '.ip_source.files // empty' "$CONFIG_FILE" 2>/dev/null || true)
    
    if [[ -z "$ip_dir" ]] || [[ "$ip_dir" == "null" ]]; then
        # 如果配置文件中没有 files 字段，使用默认路径
        ip_dir="${ROOT_DIR}/assets/data/dnspod-dns"
    else
        # 提取目录路径（从第一个文件路径推断）
        local first_file
        first_file=$(echo "$ip_dir" | jq -r 'to_entries[0].value // empty' 2>/dev/null || true)
        if [[ -n "$first_file" ]] && [[ "$first_file" != "null" ]]; then
            ip_dir=$(dirname "$first_file")
        else
            ip_dir="${ROOT_DIR}/assets/data/dnspod-dns"
        fi
    fi
    
    # 确保目录存在
    mkdir -p "$ip_dir"
    chmod 755 "$ip_dir"
    
    # 定义线路和文件名的映射
    declare -A line_files=(
        ["默认"]="default.iplist"
        ["联通"]="unicom.iplist"
        ["移动"]="mobile.iplist"
        ["电信"]="telecom.iplist"
    )
    
    # 遍历配置的线路，创建对应的 IP 文件
    IFS=' ' read -ra lines_array <<< "$ISP_LINES"
    for line in "${lines_array[@]}"; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # 获取对应的文件名
        local filename="${line_files[$line]:-}"
        if [[ -z "$filename" ]]; then
            echo -e "${YELLOW}[WARN] 未知线路: ${line}，跳过${NC}"
            continue
        fi
        
        filepath="${ip_dir}/${filename}"
        
        # 只在文件不存在时创建
        if [[ ! -f "$filepath" ]]; then
            # 【修复】移除函数外的 local 关键字
            temp_file=$(mktemp "${ip_dir}/.tmp.XXXXXX")
            
            cat > "$temp_file" << EOF
# DNSPod ${line}线路优选 IP
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 格式: 每行一个 IP 或逗号分隔
# 请替换为实际的优选 IP
#
# 示例:
# 104.16.0.1
# 104.16.0.2
EOF
            
            # 设置安全权限（仅所有者可读写）
            chmod 600 "$temp_file"
            
            # 原子移动（避免部分写入）
            mv "$temp_file" "$filepath"
            
            echo -e "  ${GREEN}[OK] 创建: ${filepath#${ROOT_DIR}/}${NC}"
        else
            echo -e "  ${CYAN}[SKIP] 已存在: ${filepath#${ROOT_DIR}/}${NC}"
        fi
    done
    
    echo ""
    echo -e "${CYAN}提示: 请编辑上述文件，填入实际的优选 IP${NC}"
    echo -e "${CYAN}      或使用测速程序自动生成 IP 列表${NC}"
    echo ""
fi

echo -e "\n${CYAN}${MENU_BORDER}"
echo -e " ${GREEN}[OK] 配置完成!"
echo -e "${CYAN}${MENU_BORDER_BOTTOM}"
echo ""

# 返回主菜单
echo ""
read -r -p "按回车键返回主菜单..."
clear

# 重新进入主菜单循环
while true; do
    show_menu
    read -r -p "请选择操作 (0-8): " choice
    
    case "$choice" in
        1)
            # 完整配置向导
            clear
            break
            ;;
        2)
            # 快速运行
            clear
            if [ -f "$CONFIG_FILE" ]; then
                run_mode=$(json_get ".dns.mode" "single")
                quick_run "$run_mode"
            else
                echo -e "${RED}错误: 配置文件不存在"
                echo "请先运行完整配置向导"
            fi
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        3)
            clear
            view_config
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        4)
            clear
            toggle_module_status
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        5)
            clear
            echo -e "${GREEN}正在调用 IP 同步组件..."
            bash "$ROOT_DIR/modules/ip-sync/sync.sh"
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        6)
            clear
            modify_ip_limit
            echo ""
            read -r -p "按回车键返回主菜单..."
            clear
            ;;
        7)
            # 修改配置二级菜单
            should_break_main=false
            while true; do
                clear
                modify_config_menu
                result=$?
                if [ $result -eq 0 ]; then
                    break
                elif [ $result -eq 2 ]; then
                    # 【修复】用户选择全部重新配置，使用标志变量替代 break 2
                    RECONFIGURE_ALL=true
                    should_break_main=true
                    break
                elif [ $result -eq 1 ]; then
                    continue
                fi
            done
            
            # 【修复】检查是否需要跳出主循环
            if [[ "${should_break_main}" = true ]]; then
                break
            fi
            
            clear
            ;;
        8)
            # 日志管理
            clear
            manage_logs
            clear
            ;;
        0)
            # 退出子菜单，返回 cfopt 主菜单
            exit 0
            ;;
        *)
            echo ""
            echo -e "${RED}[ERROR] 无效的选择,请重新输入"
            echo ""
            read -r -p "按回车键继续..."
            clear
            ;;
    esac
done

# 正常情况下不会到达这里，但为了安全起见
exit 0
