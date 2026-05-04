#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - 快速部署向导 (Quick Deploy)
# Version: 0.2
# Description: 一键完成 CF-IP 测速和 DNS 解析的全流程配置
# Usage: bash modules/quick-deploy/setup.sh
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="0.2"

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
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}快速部署向导 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
}

show_step_header() {
    local step="$1"
    local total="$2"
    local title="$3"
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}[步骤 ${step}/${total}] ${title}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
}

# ==================== 部署记录管理 ====================
DEPLOY_RECORD_FILE="${ROOT_DIR}/conf/deployments.json"

# 初始化部署记录文件
init_deploy_record() {
    if [[ ! -f "${DEPLOY_RECORD_FILE}" ]]; then
        echo '{"domains": []}' > "${DEPLOY_RECORD_FILE}"
        chmod 600 "${DEPLOY_RECORD_FILE}"
    fi
}

# 检查域名是否已部署
is_domain_deployed() {
    local domain="$1"
    init_deploy_record
    
    local count
    count=$(jq -r --arg d "$domain" '.domains[] | select(.domain == $d) | .domain' "${DEPLOY_RECORD_FILE}" 2>/dev/null | wc -l)
    
    if [[ "$count" -gt 0 ]]; then
        return 0  # 已部署
    else
        return 1  # 未部署
    fi
}

# 获取域名的部署信息
get_domain_info() {
    local domain="$1"
    init_deploy_record
    
    jq -r --arg d "$domain" '.domains[] | select(.domain == $d)' "${DEPLOY_RECORD_FILE}" 2>/dev/null
}

# 添加部署记录
add_deploy_record() {
    local domain="$1"
    local dns_type="$2"      # "cloudflare" 或 "dnspod"
    local mode="$3"          # "single" 或 "multi"
    local deploy_time="$4"
    
    init_deploy_record
    
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg d "$domain" \
       --arg t "$dns_type" \
       --arg m "$mode" \
       --arg time "$deploy_time" \
       '.domains += [{"domain": $d, "dns_type": $t, "mode": $m, "deploy_time": $time}]' \
       "${DEPLOY_RECORD_FILE}" > "$temp_file"
    
    mv "$temp_file" "${DEPLOY_RECORD_FILE}"
    chmod 600 "${DEPLOY_RECORD_FILE}"
}

# 列出所有已部署的域名
list_deployed_domains() {
    init_deploy_record
    jq -r '.domains[].domain' "${DEPLOY_RECORD_FILE}" 2>/dev/null
}

detect_optimal_colo() {
    # 简单检测：根据常见网络环境推荐
    # 实际可以扩展为 ping 测试或 traceroute 分析
    echo "HKG,NRT"
}

# 检查是否存在 Cloudflare DNS 配置
has_cf_dns_config() {
    [[ -f "${ROOT_DIR}/conf/cf-dns.json" ]] && \
    jq -r '.enabled // false' "${ROOT_DIR}/conf/cf-dns.json" 2>/dev/null | grep -q "true"
}

# 检查是否存在 DNSPod DNS 配置
has_dnspod_dns_config() {
    [[ -f "${ROOT_DIR}/conf/dnspod.json" ]] && \
    jq -r '.enabled // false' "${ROOT_DIR}/conf/dnspod.json" 2>/dev/null | grep -q "true"
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

# 生成 Cloudflare DNS 配置
generate_cf_dns_config() {
    local domain="$1"
    local cf_token="$2"
    local cf_zone_id="$3"
    
    local config_file="${ROOT_DIR}/conf/cf-dns.json"
    local temp_file
    temp_file=$(mktemp)
    
    jq -n \
        --arg domain "$domain" \
        --arg token "$cf_token" \
        --arg zone_id "$cf_zone_id" \
        '{
            "_comment": "Cloudflare DNS 更新器配置",
            "_version": "0.1",
            "enabled": true,
            "api": {
                "token": $token,
                "zone_id": $zone_id
            },
            "dns": {
                "domain": $domain,
                "sub_domain": "@",
                "record_type": "A",
                "ttl": 600,
                "max_ips_per_record": 2
            },
            "ip_source": {
                "file": "./assets/data/cf-dns/ip_list.txt"
            }
        }' > "$temp_file"
    
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

# ==================== 主程序入口 ====================
main() {
    show_header
    
    echo -e " ${YELLOW}本向导将帮助您快速完成 Cloudflare IP 优选和 DNS 解析的全流程配置${NC}"
    echo ""
    
    # 显示已部署的域名（如果有）
    local deployed_domains
    deployed_domains=$(list_deployed_domains)
    if [[ -n "$deployed_domains" ]]; then
        echo -e " ${CYAN}[提示] 当前已部署的域名：${NC}"
        while IFS= read -r domain; do
            local info
            info=$(get_domain_info "$domain")
            local dns_type
            dns_type=$(echo "$info" | jq -r '.dns_type')
            local mode
            mode=$(echo "$info" | jq -r '.mode')
            
            local dns_label
            if [[ "$dns_type" == "cloudflare" ]]; then
                dns_label="Cloudflare DNS"
            else
                dns_label="DNSPod DNS"
            fi
            
            local mode_label
            if [[ "$mode" == "multi" ]]; then
                mode_label="多线路"
            else
                mode_label="单线路"
            fi
            
            echo -e "   • ${domain} (${dns_label}, ${mode_label})"
        done <<< "$deployed_domains"
        echo ""
    fi
    
    echo -e " ${CYAN}请选择 DNS 服务商：${NC}"
    echo ""
    echo -e " ${GREEN}➤${NC} 1. Cloudflare DNS"
    echo -e "      ${CYAN}- 适合使用 Cloudflare 管理 DNS 的用户${NC}"
    echo -e "      ${CYAN}- 仅支持单线路模式${NC}"
    echo ""
    echo -e " ${GREEN}➤${NC} 2. DNSPod DNS (腾讯云)"
    echo -e "      ${CYAN}- 适合使用 DNSPod 管理 DNS 的用户${NC}"
    echo -e "      ${CYAN}- 支持单线路和多线路模式${NC}"
    echo ""
    
    read -r -p "请选择 [1-2, 默认 1]: " dns_choice
    dns_choice=${dns_choice:-1}
    
    case "$dns_choice" in
        1)
            deploy_cloudflare_dns
            ;;
        2)
            choose_dnspod_mode
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择${NC}"
            read -r -p "按回车键返回..."
            ;;
    esac
}

# Cloudflare DNS 部署（仅单线路）
deploy_cloudflare_dns() {
    show_header
    
    echo -e "${GREEN}您选择了：Cloudflare DNS（单线路模式）${NC}"
    echo ""
    
    # 第1步：基础信息
    show_step_header 1 4 "配置基础信息"
    
    read -r -p "请输入您的域名 (例如: example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    # 检查是否已部署
    if is_domain_deployed "$domain"; then
        echo -e "${YELLOW}[WARN] 该域名已部署过${NC}"
        local existing_info
        existing_info=$(get_domain_info "$domain")
        local existing_dns
        existing_dns=$(echo "$existing_info" | jq -r '.dns_type')
        local existing_mode
        existing_mode=$(echo "$existing_info" | jq -r '.mode')
        
        echo -e "   当前配置: ${existing_dns} (${existing_mode} 模式)"
        echo ""
        read -r -p "是否覆盖现有配置？[y/N] (默认 N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}[INFO] 已取消操作${NC}"
            read -r -p "按回车键返回..."
            return 0
        fi
    fi
    
    read -r -p "请输入 Cloudflare API Token: " cf_token
    if [[ -z "$cf_token" ]]; then
        echo -e "${RED}[ERROR] Cloudflare API Token 不能为空${NC}"
        return 1
    fi
    
    read -r -p "请输入 Cloudflare Zone ID: " cf_zone_id
    if [[ -z "$cf_zone_id" ]]; then
        echo -e "${RED}[ERROR] Cloudflare Zone ID 不能为空${NC}"
        return 1
    fi
    
    # 第2步：生成配置
    show_step_header 2 4 "生成配置文件"
    
    local recommended_colo
    recommended_colo=$(detect_optimal_colo)
    
    echo -e "${CYAN}正在生成 CF-IP 配置...${NC}"
    generate_cf_ip_config "single" "$recommended_colo" "" "" ""
    echo -e "${GREEN}[OK] CF-IP 配置已生成${NC}"
    
    echo -e "${CYAN}正在生成 Cloudflare DNS 配置...${NC}"
    generate_cf_dns_config "$domain" "$cf_token" "$cf_zone_id"
    echo -e "${GREEN}[OK] Cloudflare DNS 配置已生成${NC}"
    
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
    
    # 记录部署信息
    local deploy_time
    deploy_time=$(date '+%Y-%m-%d %H:%M:%S')
    add_deploy_record "$domain" "cloudflare" "single" "$deploy_time"
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 单线路"
    echo -e "   • 域名: ${domain}"
    echo -e "   • DNS 服务: Cloudflare DNS"
    echo -e "   • DNS 记录: ${domain}"
    echo -e "   • 测速节点: ${recommended_colo}"
    echo ""
    echo -e " ${GRAY}后续操作：${NC}"
    echo -e "   • 运行 'cfopt' 查看和管理配置"
    echo -e "   • 选择 '5. 自动化调度中心' 手动触发更新"
    echo -e "   • 选择 '6. 检查组件更新' 保持最新版本"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# 选择 DNSPod 模式
choose_dnspod_mode() {
    show_header
    
    echo -e "${GREEN}您选择了：DNSPod DNS${NC}"
    echo ""
    echo -e " ${CYAN}请选择工作模式：${NC}"
    echo ""
    echo -e " ${GREEN}➤${NC} 1. 单线路模式"
    echo -e "      ${CYAN}- 适合个人博客、小型网站${NC}"
    echo -e "      ${CYAN}- 所有用户访问同一组 IP${NC}"
    echo ""
    echo -e " ${GREEN}➤${NC} 2. 多线路模式"
    echo -e "      ${CYAN}- 适合企业官网、电商平台${NC}"
    echo -e "      ${CYAN}- 覆盖三大运营商，访问更快${NC}"
    echo -e "      ${CYAN}- 不同运营商使用不同 IP${NC}"
    echo ""
    
    read -r -p "请选择 [1-2, 默认 1]: " mode_choice
    mode_choice=${mode_choice:-1}
    
    case "$mode_choice" in
        1)
            deploy_dnspod_single
            ;;
        2)
            deploy_dnspod_multi
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择${NC}"
            read -r -p "按回车键返回..."
            ;;
    esac
}

# DNSPod 单线路部署
deploy_dnspod_single() {
    show_header
    
    echo -e "${GREEN}您选择了：DNSPod DNS（单线路模式）${NC}"
    echo ""
    
    # 第1步：基础信息
    show_step_header 1 4 "配置基础信息"
    
    read -r -p "请输入您的域名 (例如: example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    # 检查是否已部署
    if is_domain_deployed "$domain"; then
        echo -e "${YELLOW}[WARN] 该域名已部署过${NC}"
        local existing_info
        existing_info=$(get_domain_info "$domain")
        local existing_dns
        existing_dns=$(echo "$existing_info" | jq -r '.dns_type')
        local existing_mode
        existing_mode=$(echo "$existing_info" | jq -r '.mode')
        
        echo -e "   当前配置: ${existing_dns} (${existing_mode} 模式)"
        echo ""
        read -r -p "是否覆盖现有配置？[y/N] (默认 N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}[INFO] 已取消操作${NC}"
            read -r -p "按回车键返回..."
            return 0
        fi
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
    
    # 记录部署信息
    local deploy_time
    deploy_time=$(date '+%Y-%m-%d %H:%M:%S')
    add_deploy_record "$domain" "dnspod" "single" "$deploy_time"
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 单线路"
    echo -e "   • 域名: ${domain}"
    echo -e "   • DNS 服务: DNSPod DNS"
    echo -e "   • DNS 记录: ${domain}"
    echo -e "   • 测速节点: ${recommended_colo}"
    echo ""
    echo -e " ${GRAY}后续操作：${NC}"
    echo -e "   • 运行 'cfopt' 查看和管理配置"
    echo -e "   • 选择 '5. 自动化调度中心' 手动触发更新"
    echo -e "   • 选择 '6. 检查组件更新' 保持最新版本"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# DNSPod 多线路部署
deploy_dnspod_multi() {
    show_header
    
    echo -e "${GREEN}您选择了：DNSPod DNS（多线路模式）${NC}"
    echo ""
    
    # 第1步：基础信息
    show_step_header 1 4 "配置基础信息"
    
    read -r -p "请输入您的域名 (例如: example.com): " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    # 检查是否已部署
    if is_domain_deployed "$domain"; then
        echo -e "${YELLOW}[WARN] 该域名已部署过${NC}"
        local existing_info
        existing_info=$(get_domain_info "$domain")
        local existing_dns
        existing_dns=$(echo "$existing_info" | jq -r '.dns_type')
        local existing_mode
        existing_mode=$(echo "$existing_info" | jq -r '.mode')
        
        echo -e "   当前配置: ${existing_dns} (${existing_mode} 模式)"
        echo ""
        read -r -p "是否覆盖现有配置？[y/N] (默认 N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}[INFO] 已取消操作${NC}"
            read -r -p "按回车键返回..."
            return 0
        fi
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
    echo -e " ${CYAN}多线路 DNS 记录：${NC}"
    echo -e "   • ${domain} (默认线路)"
    echo -e "   • unicom.${domain} (联通线路)"
    echo -e "   • mobile.${domain} (移动线路)"
    echo -e "   • telecom.${domain} (电信线路)"
    
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
    
    # 记录部署信息
    local deploy_time
    deploy_time=$(date '+%Y-%m-%d %H:%M:%S')
    add_deploy_record "$domain" "dnspod" "multi" "$deploy_time"
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 多线路"
    echo -e "   • 域名: ${domain}"
    echo -e "   • DNS 服务: DNSPod DNS"
    echo -e "   • DNS 记录:"
    echo -e "     - ${domain} (默认)"
    echo -e "     - unicom.${domain} (联通)"
    echo -e "     - mobile.${domain} (移动)"
    echo -e "     - telecom.${domain} (电信)"
    echo ""
    echo -e " ${GRAY}后续操作：${NC}"
    echo -e "   • 运行 'cfopt' 查看和管理配置"
    echo -e "   • 选择 '5. 自动化调度中心' 手动触发更新"
    echo -e "   • 选择 '6. 检查组件更新' 保持最新版本"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# 执行主程序
main
