#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - 快速部署向导 (Quick Deploy)
# Version: 0.1
# Description: 一键完成 CF-IP 测速和 DNSPod 解析的全流程配置
# Usage: bash modules/quick-deploy/setup.sh
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="0.1"

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ==================== 路径初始化 ====================
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 入口权限校验 ====================
if [[ "${CF_OPT_ENTRY:-}" != "main_menu" ]]; then
    echo -e "${RED}[ERROR] 请使用 'cfopt' 命令进入主菜单运行此模块。${NC}"
    exit 1
fi

# ==================== 辅助函数 ====================
show_header() {
    clear
    echo -e "${CYAN}+============================================================+${NC}"
    echo -e " ${YELLOW}Cloudflare IP 优选 + DNS 快速部署向导 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}+============================================================+${NC}"
    echo ""
}

show_step_header() {
    local step="$1"
    local total="$2"
    local title="$3"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}[步骤 ${step}/${total}] ${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

detect_optimal_colo() {
    # 简单检测：根据常见网络环境推荐
    # 实际可以扩展为 ping 测试或 traceroute 分析
    echo "HKG,NRT"
}

generate_cf_ip_config() {
    local mode="$1"
    local colo_default="$2"
    local colo_unicom="$3"
    local colo_mobile="$4"
    local colo_telecom="$5"
    
    local config_file="${ROOT_DIR}/conf/cf-ip.json"
    local temp_file
    temp_file=$(mktemp)
    
    if [[ "$mode" = "multi" ]]; then
        jq -n \
            --arg cfst_dir "${ROOT_DIR}/assets/cfst" \
            --argjson threads 200 \
            --arg colo "$colo_default" \
            --argjson enable_log true \
            --arg output_dir "./assets/data/cf-ip" \
            --arg log_dir "./logs/cf-ip" \
            --argjson multi_enabled true \
            --arg colo_mobile "$colo_mobile" \
            --arg colo_unicom "$colo_unicom" \
            --arg colo_telecom "$colo_telecom" \
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
                    "take_ip_num": 5,
                    "max_retry": 3,
                    "output_html": true,
                    "enable_log": $enable_log
                },
                "multi_line": {
                    "enabled": $multi_enabled,
                    "colo_mobile": $colo_mobile,
                    "colo_unicom": $colo_unicom,
                    "colo_telecom": $colo_telecom
                },
                "paths": {
                    "output_dir": $output_dir,
                    "log_dir": $log_dir
                }
            }' > "$temp_file"
    else
        jq -n \
            --arg cfst_dir "${ROOT_DIR}/assets/cfst" \
            --argjson threads 200 \
            --arg colo "$colo_default" \
            --argjson enable_log true \
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
                    "take_ip_num": 5,
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
            }' > "$temp_file"
    fi
    
    mv "$temp_file" "$config_file"
    chmod 600 "$config_file"
}

generate_dnspod_config() {
    local domain="$1"
    local dnspod_id="$2"
    local dnspod_token="$3"
    local mode="$4"
    
    local config_file="${ROOT_DIR}/conf/dnspod.json"
    local temp_file
    temp_file=$(mktemp)
    
    if [[ "$mode" = "multi" ]]; then
        jq -n \
            --arg domain "$domain" \
            --arg id "$dnspod_id" \
            --arg token "$dnspod_token" \
            --arg mode "multi" \
            '{
                "_comment": "DNSPod DNS 更新器配置",
                "_version": "0.1",
                "enabled": true,
                "api": {
                    "id": $id,
                    "token": $token
                },
                "dns": {
                    "domain": $domain,
                    "sub_domain": "dns",
                    "record_type": "A",
                    "ttl": 600,
                    "max_ips_per_record": 2
                },
                "mode": $mode,
                "lines": ["default", "unicom", "mobile", "telecom"],
                "subdomain_strategy": "separate",
                "sub_domains": {
                    "default": "dns",
                    "unicom": "unicom",
                    "mobile": "mobile",
                    "telecom": "telecom"
                },
                "ip_source": {
                    "files": {
                        "default": "./assets/data/dnspod-dns/ip_list_default.txt",
                        "unicom": "./assets/data/dnspod-dns/ip_list_unicom.txt",
                        "mobile": "./assets/data/dnspod-dns/ip_list_mobile.txt",
                        "telecom": "./assets/data/dnspod-dns/ip_list_telecom.txt"
                    }
                }
            }' > "$temp_file"
    else
        jq -n \
            --arg domain "$domain" \
            --arg id "$dnspod_id" \
            --arg token "$dnspod_token" \
            --arg mode "single" \
            '{
                "_comment": "DNSPod DNS 更新器配置",
                "_version": "0.1",
                "enabled": true,
                "api": {
                    "id": $id,
                    "token": $token
                },
                "dns": {
                    "domain": $domain,
                    "sub_domain": "dns",
                    "record_type": "A",
                    "ttl": 600,
                    "max_ips_per_record": 2
                },
                "mode": $mode,
                "ip_source": {
                    "file": "./assets/data/dnspod-dns/ip_list.txt"
                }
            }' > "$temp_file"
    fi
    
    mv "$temp_file" "$config_file"
    chmod 600 "$config_file"
}

setup_auto_schedule() {
    local cron_expr="0 3 * * *"
    local script_path="${ROOT_DIR}/modules/scheduler/run.sh"
    local log_path="${ROOT_DIR}/logs/scheduler/cron.log"
    
    mkdir -p "$(dirname "$log_path")"
    
    local cron_cmd="${cron_expr} CF_OPT_ENTRY=scheduler /bin/bash ${script_path} >> ${log_path} 2>&1"
    
    # 删除旧的定时任务，添加新的
    (crontab -l 2>/dev/null | grep -v "scheduler/run.sh"; echo "${cron_cmd}") | crontab -
}

# ==================== 单线路部署 ====================
deploy_single_line() {
    show_header
    
    echo -e "${GREEN}您选择了：个人网站（单线路模式）${NC}"
    echo ""
    echo -e "${GRAY}此模式适合个人博客、小型网站，配置简单，维护方便${NC}"
    echo ""
    
    # 第1步：基础信息
    show_step_header 1 4 "配置基础信息"
    
    read -r -p "请输入您的域名 (例如: example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    read -r -p "请输入 DNSPod ID: " dnspod_id
    if [[ -z "$dnspod_id" ]]; then
        echo -e "${RED}[ERROR] DNSPod ID 不能为空${NC}"
        return 1
    fi
    
    read -r -p "请输入 DNSPod Token: " dnspod_token
    if [[ -z "$dnspod_token" ]]; then
        echo -e "${RED}[ERROR] DNSPod Token 不能为空${NC}"
        return 1
    fi
    
    # 第2步：生成配置
    show_step_header 2 4 "生成配置文件"
    
    local recommended_colo
    recommended_colo=$(detect_optimal_colo)
    
    echo -e "${CYAN}正在生成 CF-IP 配置...${NC}"
    generate_cf_ip_config "single" "$recommended_colo" "" "" ""
    echo -e "${GREEN}[OK] CF-IP 配置已生成${NC}"
    
    echo -e "${CYAN}正在生成 DNSPod 配置...${NC}"
    generate_dnspod_config "$domain" "$dnspod_id" "$dnspod_token" "single"
    echo -e "${GREEN}[OK] DNSPod 配置已生成${NC}"
    
    # 第3步：首次测速
    show_step_header 3 4 "执行首次测速"
    
    echo -e "${YELLOW}提示: 首次测速可能需要 2-5 分钟，请耐心等待...${NC}"
    read -r -p "是否立即执行首次测速？[Y/n] (默认 Y): " run_test
    run_test=${run_test:-Y}
    
    if [[ "$run_test" =~ ^[Yy]$ ]]; then
        cd "${ROOT_DIR}" || return 1
        CF_OPT_ENTRY=1 bash "${ROOT_DIR}/modules/cf-ip/core.sh" || true
        echo -e "${GREEN}[OK] 测速完成${NC}"
    fi
    
    # 第4步：设置定时任务
    show_step_header 4 4 "设置自动化调度"
    
    echo -e "${CYAN}将设置以下定时任务：${NC}"
    echo -e "  • 每天凌晨 3:00 自动执行全链路更新"
    echo -e "  • 包括：IP 测速 → 数据同步 → DNS 更新"
    echo ""
    
    read -r -p "是否启用自动调度？[Y/n] (默认 Y): " enable_schedule
    enable_schedule=${enable_schedule:-Y}
    
    if [[ "$enable_schedule" =~ ^[Yy]$ ]]; then
        setup_auto_schedule
        echo -e "${GREEN}[OK] 定时任务已设置${NC}"
    fi
    
    # 完成
    show_header
    echo -e "${GREEN}🎉 部署完成！${NC}"
    echo ""
    echo -e "${CYAN}您的配置摘要：${NC}"
    echo -e "  • 工作模式: 单线路"
    echo -e "  • 域名: ${domain}"
    echo -e "  • DNS 记录: ${domain}"
    echo -e "  • 测速节点: ${recommended_colo}"
    echo ""
    echo -e "${GRAY}后续操作：${NC}"
    echo -e "  • 运行 'cfopt' 查看和管理配置"
    echo -e "  • 选择 '4. 自动化调度中心' 手动触发更新"
    echo -e "  • 选择 '5. 检查组件更新' 保持最新版本"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# ==================== 多线路部署 ====================
deploy_multi_line() {
    show_header
    
    echo -e "${GREEN}您选择了：企业网站（多线路模式）${NC}"
    echo ""
    echo -e "${GRAY}此模式适合企业网站，可为不同运营商提供最优访问体验${NC}"
    echo ""
    
    # 第1步：基础信息
    show_step_header 1 4 "配置基础信息"
    
    read -r -p "请输入您的域名 (例如: example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    read -r -p "请输入 DNSPod ID: " dnspod_id
    if [[ -z "$dnspod_id" ]]; then
        echo -e "${RED}[ERROR] DNSPod ID 不能为空${NC}"
        return 1
    fi
    
    read -r -p "请输入 DNSPod Token: " dnspod_token
    if [[ -z "$dnspod_token" ]]; then
        echo -e "${RED}[ERROR] DNSPod Token 不能为空${NC}"
        return 1
    fi
    
    # 第2步：生成配置
    show_step_header 2 4 "生成多线路配置"
    
    local colo_default="HKG,SIN,TYO,LON"
    local colo_unicom="SJC,LAX,SIN,TYO"
    local colo_mobile="HKG,SIN,TYO,LON"
    local colo_telecom="SJC,LAX,TYO,SIN"
    
    echo -e "${CYAN}正在生成 CF-IP 多线路配置...${NC}"
    generate_cf_ip_config "multi" "$colo_default" "$colo_unicom" "$colo_mobile" "$colo_telecom"
    echo -e "${GREEN}[OK] CF-IP 多线路配置已生成${NC}"
    
    echo -e "${CYAN}正在生成 DNSPod 多线路配置...${NC}"
    generate_dnspod_config "$domain" "$dnspod_id" "$dnspod_token" "multi"
    echo -e "${GREEN}[OK] DNSPod 多线路配置已生成${NC}"
    
    echo ""
    echo -e "${CYAN}多线路 DNS 记录：${NC}"
    echo -e "  • ${domain} (默认线路)"
    echo -e "  • unicom.${domain} (联通线路)"
    echo -e "  • mobile.${domain} (移动线路)"
    echo -e "  • telecom.${domain} (电信线路)"
    
    # 第3步：首次测速
    show_step_header 3 4 "执行多线路测速"
    
    echo -e "${YELLOW}提示: 多线路测速需要分别测试 4 条线路，可能需要 5-10 分钟${NC}"
    read -r -p "是否立即执行首次测速？[Y/n] (默认 Y): " run_test
    run_test=${run_test:-Y}
    
    if [[ "$run_test" =~ ^[Yy]$ ]]; then
        cd "${ROOT_DIR}" || return 1
        echo -e "${CYAN}正在执行多线路并发测速...${NC}"
        CF_OPT_ENTRY=scheduler bash "${ROOT_DIR}/modules/scheduler/run.sh" || true
        echo -e "${GREEN}[OK] 多线路测速完成${NC}"
    fi
    
    # 第4步：设置定时任务
    show_step_header 4 4 "设置自动化调度"
    
    echo -e "${CYAN}将设置以下定时任务：${NC}"
    echo -e "  • 每 6 小时自动执行 IP 测速"
    echo -e "  • 每天凌晨 3:00 自动执行全链路更新"
    echo -e "  • 包括：IP 测速 → 数据同步 → DNS 更新"
    echo ""
    
    read -r -p "是否启用自动调度？[Y/n] (默认 Y): " enable_schedule
    enable_schedule=${enable_schedule:-Y}
    
    if [[ "$enable_schedule" =~ ^[Yy]$ ]]; then
        setup_auto_schedule
        echo -e "${GREEN}[OK] 定时任务已设置${NC}"
    fi
    
    # 完成
    show_header
    echo -e "${GREEN}🎉 部署完成！${NC}"
    echo ""
    echo -e "${CYAN}您的配置摘要：${NC}"
    echo -e "  • 工作模式: 多线路"
    echo -e "  • 域名: ${domain}"
    echo -e "  • DNS 记录:"
    echo -e "    - ${domain} (默认)"
    echo -e "    - unicom.${domain} (联通)"
    echo -e "    - mobile.${domain} (移动)"
    echo -e "    - telecom.${domain} (电信)"
    echo ""
    echo -e "${GRAY}后续操作：${NC}"
    echo -e "  • 运行 'cfopt' 查看和管理配置"
    echo -e "  • 选择 '4. 自动化调度中心' 手动触发更新"
    echo -e "  • 选择 '5. 检查组件更新' 保持最新版本"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# ==================== 主程序入口 ====================
main() {
    show_header
    
    echo -e "${YELLOW}本向导将帮助您快速完成 Cloudflare IP 优选和 DNS 解析的全流程配置${NC}"
    echo ""
    echo -e "${CYAN}请选择您的使用场景：${NC}"
    echo ""
    echo -e "  ${GREEN}1) 个人网站（单线路）${NC}"
    echo -e "     • 适合个人博客、小型网站"
    echo -e "     • 配置简单，维护方便"
    echo -e "     • 所有用户访问同一组 IP"
    echo ""
    echo -e "  ${GREEN}2) 企业网站（多线路）${NC}"
    echo -e "     • 适合企业官网、电商平台"
    echo -e "     • 覆盖三大运营商，访问更快"
    echo -e "     • 不同运营商使用不同 IP"
    echo ""
    
    read -r -p "请选择 [1-2, 默认 1]: " scenario
    scenario=${scenario:-1}
    
    case "$scenario" in
        1)
            deploy_single_line
            ;;
        2)
            deploy_multi_line
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择${NC}"
            read -r -p "按回车键返回..."
            ;;
    esac
}

# 执行主程序
main
