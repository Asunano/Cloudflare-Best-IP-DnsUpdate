#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# cfopt - 快速部署向导 (Quick Deploy)
# Version: 0.1
# Description: 一键完成 CF-IP 测速和 DNS 解析的全流程配置
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
BOLD='\033[1m'
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
    echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
    echo -e " ${CYAN}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
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
    local record_name="$4"   # 主机记录（如 @、cf、www）
    local deploy_time="$5"
    
    init_deploy_record
    
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg d "$domain" \
       --arg t "$dns_type" \
       --arg m "$mode" \
       --arg r "$record_name" \
       --arg time "$deploy_time" \
       '.domains += [{"domain": $d, "dns_type": $t, "mode": $m, "record_name": $r, "deploy_time": $time}]' \
       "${DEPLOY_RECORD_FILE}" > "$temp_file"
    
    mv "$temp_file" "${DEPLOY_RECORD_FILE}"
    chmod 600 "${DEPLOY_RECORD_FILE}"
}

# 列出所有已部署的域名
list_deployed_domains() {
    init_deploy_record
    jq -r '.domains[].domain' "${DEPLOY_RECORD_FILE}" 2>/dev/null
}

# 根据域名和主机记录获取配置文件路径
get_cf_dns_config_file() {
    local domain="$1"
    local record_name="$2"
    
    local full_domain
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo "${ROOT_DIR}/conf/cf-dns/${full_domain}.json"
}

get_dnspod_config_file() {
    local domain="$1"
    local record_name="$2"
    local mode="${3:-single}"
    
    local full_domain
    if [[ "$mode" == "multi" ]]; then
        full_domain="$domain"
    elif [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo "${ROOT_DIR}/conf/dnspod/${full_domain}.json"
}

# 删除域名配置
delete_domain_config() {
    local domain="$1"
    local dns_type="$2"  # "cloudflare" 或 "dnspod"
    
    init_deploy_record
    
    # 从部署记录中获取 record_name 和 mode
    local record_name="@"
    local mode="single"
    local deploy_info
    deploy_info=$(jq -r --arg d "$domain" '.domains[] | select(.domain == $d)' "${DEPLOY_RECORD_FILE}" 2>/dev/null)
    
    if [[ -n "$deploy_info" ]]; then
        record_name=$(echo "$deploy_info" | jq -r '.record_name // "@"')
        mode=$(echo "$deploy_info" | jq -r '.mode // "single"')
    fi
    
    # 删除配置文件
    if [[ "$dns_type" == "cloudflare" ]]; then
        local cf_dns_file
        cf_dns_file=$(get_cf_dns_config_file "$domain" "$record_name")
        if [[ -f "$cf_dns_file" ]]; then
            rm -f "$cf_dns_file"
            echo -e "  [OK] 已删除: ${cf_dns_file}"
        fi
    elif [[ "$dns_type" == "dnspod" ]]; then
        if [[ "$mode" == "multi" ]]; then
            # 多线路模式：删除所有线路的配置文件
            local dnspod_base="${ROOT_DIR}/conf/dnspod/${domain}"
            for suffix in "" "_unicom" "_mobile" "_telecom"; do
                local dnspod_file="${dnspod_base}${suffix}.json"
                if [[ -f "$dnspod_file" ]]; then
                    rm -f "$dnspod_file"
                    echo -e "  [OK] 已删除: ${dnspod_file}"
                fi
            done
        else
            # 单线路模式
            local dnspod_file
            dnspod_file=$(get_dnspod_config_file "$domain" "$record_name" "$mode")
            if [[ -f "$dnspod_file" ]]; then
                rm -f "$dnspod_file"
                echo -e "  [OK] 已删除: ${dnspod_file}"
            fi
        fi
    fi
    
    # 从部署记录中删除
    local temp_file
    temp_file=$(mktemp)
    jq --arg d "$domain" '.domains = [.domains[] | select(.domain != $d)]' \
       "${DEPLOY_RECORD_FILE}" > "$temp_file"
    mv "$temp_file" "${DEPLOY_RECORD_FILE}"
    chmod 600 "${DEPLOY_RECORD_FILE}"
    echo -e "  [OK] 已删除部署记录"
}

select_colo_nodes() {
    local domain="$1"
    
    # 清屏，保持界面整洁
    clear
    
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e "${CYAN} [步骤 3/5] 选择测速节点（地区）${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e " ${YELLOW}提示: 选择距离您服务器较近的地区可获得更优的延迟${NC}"
    echo ""
    echo -e " ${GREEN}常用节点推荐：${NC}"
    echo -e "   1. 香港 + 东京 (HKG,NRT)          - 亚洲通用推荐"
    echo -e "   2. 新加坡 + 东京 (SIN,NRT)         - 东南亚优化"
    echo -e "   3. 洛杉矶 + 旧金山 (LAX,SJC)       - 北美优化"
    echo -e "   4. 法兰克福 + 伦敦 (FRA,LON)       - 欧洲优化"
    echo -e "   5. 悉尼 + 东京 (SYD,NRT)           - 大洋洲优化"
    echo ""
    echo -e " ${GRAY}其他选项：${NC}"
    echo -e "   6. 自动检测（默认 HKG,NRT）"
    echo -e "   7. 自定义节点（手动输入）"
    echo ""
    
    echo -ne "${CYAN}请选择 [1-7] (默认 1):${NC} "
    read -r colo_choice
    colo_choice=${colo_choice:-1}
    
    case "$colo_choice" in
        1) echo "HKG,NRT" ;;
        2) echo "SIN,NRT" ;;
        3) echo "LAX,SJC" ;;
        4) echo "FRA,LON" ;;
        5) echo "SYD,NRT" ;;
        6)
            # 自动检测（当前逻辑）
            detect_optimal_colo
            ;;
        7)
            echo ""
            echo -e "${YELLOW}请输入 IATA 机场代码，多个用逗号分隔${NC}"
            echo -e "${GRAY}示例: HKG,NRT,LAX 或 SIN,TYO,FRA${NC}"
            echo -e "${GRAY}常见代码: HKG(香港) NRT/TYO(东京) SIN(新加坡) LAX(洛杉矶) SJC(旧金山) FRA(法兰克福) LON(伦敦) SYD(悉尼)${NC}"
            echo -ne "${CYAN}请输入节点代码:${NC} "
            read -r custom_colo
            if [[ -z "$custom_colo" ]]; then
                echo -e "${YELLOW}[WARN] 未输入，使用默认值 HKG,NRT${NC}"
                echo "HKG,NRT"
            else
                # 转换为大写并去除空格
                echo "$custom_colo" | tr '[:lower:]' '[:upper:]' | tr -d ' '
            fi
            ;;
        *)
            echo -e "${YELLOW}[WARN] 无效选择，使用默认值 HKG,NRT${NC}"
            echo "HKG,NRT"
            ;;
    esac
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

# 验证配置一致性（防止 CF-IP 多线路与 DNSPod 单线路冲突）
validate_config_consistency() {
    local cf_ip_file="${ROOT_DIR}/conf/cf-ip.json"
    local dnspod_file="${ROOT_DIR}/conf/dnspod.json"
    local cf_dns_file="${ROOT_DIR}/conf/cf-dns.json"
    
    # 检查 CF-IP 是否开启多线路
    local cf_multi_enabled=false
    if [[ -f "$cf_ip_file" ]]; then
        cf_multi_enabled=$(jq -r '.multi_line.enabled // false' "$cf_ip_file")
    fi
    
    # 检查 DNSPod 模式
    local dnspod_mode="single"
    if [[ -f "$dnspod_file" ]]; then
        dnspod_mode=$(jq -r '.mode // "single"' "$dnspod_file")
    fi
    
    # 检查 Cloudflare DNS 是否启用
    local cf_dns_enabled=false
    if [[ -f "$cf_dns_file" ]]; then
        cf_dns_enabled=$(jq -r '.enabled // false' "$cf_dns_file")
    fi
    
    # 验证逻辑
    local has_error=false
    
    # 1. 如果 CF-IP 开启多线路，DNSPod 也必须是多线路
    if [[ "$cf_multi_enabled" = "true" ]] && [[ "$dnspod_mode" != "multi" ]]; then
        echo -e "${RED}[ERROR] 配置不一致！${NC}"
        echo -e "   CF-IP 已开启多线路测速，但 DNSPod 配置为单线路模式"
        echo -e "   ${YELLOW}建议：${NC}将 DNSPod 模式改为 multi，或关闭 CF-IP 的多线路功能"
        has_error=true
    fi
    
    # 2. 如果 DNSPod 是多线路，CF-IP 也必须开启多线路
    if [[ "$dnspod_mode" = "multi" ]] && [[ "$cf_multi_enabled" != "true" ]]; then
        echo -e "${RED}[ERROR] 配置不一致！${NC}"
        echo -e "   DNSPod 配置为多线路模式，但 CF-IP 未开启多线路测速"
        echo -e "   ${YELLOW}建议：${NC}在 CF-IP 配置中启用 multi_line.enabled"
        has_error=true
    fi
    
    # 3. Cloudflare DNS 只能是单线路（不支持多线路）
    if [[ "$cf_dns_enabled" = "true" ]] && [[ "$cf_multi_enabled" = "true" ]]; then
        echo -e "${YELLOW}[WARN] 配置提示${NC}"
        echo -e "   Cloudflare DNS 仅支持单线路模式"
        echo -e "   即使 CF-IP 开启多线路，CF-DNS 也只会使用 default 线路的 IP"
        echo -e "   ${GRAY}这是正常行为，无需修改${NC}"
    fi
    
    if [[ "$has_error" = true ]]; then
        return 1
    else
        return 0
    fi
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
    local record_name="${5:-dns}"  # 默认值为 dns
    
    # 创建多域名配置目录
    local config_dir="${ROOT_DIR}/conf/dnspod"
    mkdir -p "$config_dir"
    
    # 配置文件路径：conf/dnspod/{record_name}.{domain}.json
    # 这样可以支持同一域名的多个不同主机记录
    local full_domain
    if [[ "$mode" == "multi" ]]; then
        # 多线路模式使用根域名
        full_domain="$domain"
    elif [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    local config_file="${config_dir}/${full_domain}.json"
    local temp_file
    temp_file=$(mktemp)
    
    if [[ "$mode" = "multi" ]]; then
        jq -n \
            --arg domain "$domain" \
            --arg id "$dnspod_id" \
            --arg token "$dnspod_token" \
            --arg mode "multi" \
            --arg record_name "$record_name" \
            --arg ip_file_default "${ROOT_DIR}/assets/data/dnspod-dns/ip_list_default.txt" \
            --arg ip_file_unicom "${ROOT_DIR}/assets/data/dnspod-dns/ip_list_unicom.txt" \
            --arg ip_file_mobile "${ROOT_DIR}/assets/data/dnspod-dns/ip_list_mobile.txt" \
            --arg ip_file_telecom "${ROOT_DIR}/assets/data/dnspod-dns/ip_list_telecom.txt" \
            '{
                "_comment": "DNSPod DNS 更新器配置",
                "_version": "0.1",
                "enabled": true,
                "api": {
                    "id": $id,
                    "token": $token,
                    "timeout": 10,
                    "max_retries": 5
                },
                "dns": {
                    "domain": $domain,
                    "sub_domain": $record_name,
                    "record_type": "A",
                    "ttl": 600,
                    "max_ips_per_record": 2,
                    "mode": $mode,
                    "subdomain_strategy": "separate",
                    "sub_domains": {
                        "default": "default",
                        "unicom": "unicom",
                        "mobile": "mobile",
                        "telecom": "telecom"
                    }
                },
                "ip_source": {
                    "file_path": $ip_file_default,
                    "files": {
                        "default": $ip_file_default,
                        "unicom": $ip_file_unicom,
                        "mobile": $ip_file_mobile,
                        "telecom": $ip_file_telecom
                    }
                },
                "logging": {
                    "log_dir": "./logs/dnspod-dns",
                    "log_rotation_days": 7,
                    "verbose": false
                }
            }' > "$temp_file"
    else
        # 按域名独立存储 IP 列表，避免多域名冲突
        local ip_file="${ROOT_DIR}/assets/data/dnspod-dns/${full_domain}.txt"
            
        jq -n \
            --arg domain "$domain" \
            --arg id "$dnspod_id" \
            --arg token "$dnspod_token" \
            --arg mode "single" \
            --arg record_name "$record_name" \
            --arg ip_file "${ip_file}" \
            '{
                "_comment": "DNSPod DNS 更新器配置",
                "_version": "0.1",
                "enabled": true,
                "api": {
                    "id": $id,
                    "token": $token,
                    "timeout": 10,
                    "max_retries": 5
                },
                "dns": {
                    "domain": $domain,
                    "sub_domain": $record_name,
                    "record_type": "A",
                    "ttl": 600,
                    "max_ips_per_record": 2,
                    "mode": $mode
                },
                "ip_source": {
                    "file_path": $ip_file
                },
                "logging": {
                    "log_dir": "./logs/dnspod-dns",
                    "log_rotation_days": 7,
                    "verbose": false
                }
            }' > "$temp_file"
    fi
    
    mv "$temp_file" "$config_file"
    chmod 600 "$config_file"
    
    echo -e "${GREEN}[OK] DNSPod 配置已生成: ${config_file}${NC}"
}

# 生成 Cloudflare DNS 配置
generate_cf_dns_config() {
    local domain="$1"
    local cf_token="$2"
    local cf_zone_id="$3"
    local record_name="${4:-@}"  # 默认值为 @
    
    # 创建多域名配置目录
    local config_dir="${ROOT_DIR}/conf/cf-dns"
    mkdir -p "$config_dir"
    
    # 配置文件路径：conf/cf-dns/{record_name}.{domain}.json
    # 这样可以支持同一域名的多个不同主机记录
    local full_domain
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    local config_file="${config_dir}/${full_domain}.json"
    local temp_file
    temp_file=$(mktemp)
    
    # 按域名独立存储 IP 列表和测速结果，避免多域名冲突
    local ip_file="${ROOT_DIR}/assets/data/cf-dns/${full_domain}.txt"
    local result_file="${ROOT_DIR}/assets/data/cf-ip/result_${full_domain}.csv"
    
    jq -n \
        --arg domain "$domain" \
        --arg token "$cf_token" \
        --arg zone_id "$cf_zone_id" \
        --arg record_name "$record_name" \
        --arg ip_file "${ip_file}" \
        --arg result_file "${result_file}" \
        --arg colo_nodes "$recommended_colo" \
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
                "record_name": $record_name,
                "record_type": "A",
                "ttl": 600,
                "max_ips_per_record": 2
            },
            "ip_source": {
                "file_path": $ip_file,
                "result_file": $result_file,
                "colo_nodes": $colo_nodes
            }
        }' > "$temp_file"
    
    mv "$temp_file" "$config_file"
    chmod 600 "$config_file"
    
    echo -e "${GREEN}[OK] Cloudflare DNS 配置已生成: ${config_file}${NC}"
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
            
            # 从实际配置文件中读取 record_name（优先）
            local record_name
            if [[ "$dns_type" == "cloudflare" ]]; then
                local config_file="${ROOT_DIR}/conf/cf-dns/${domain}.json"
                if [[ -f "$config_file" ]]; then
                    record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
                else
                    record_name=$(echo "$info" | jq -r '.record_name // "@"')
                fi
            elif [[ "$dns_type" == "dnspod" ]]; then
                local config_file="${ROOT_DIR}/conf/dnspod/${domain}.json"
                if [[ -f "$config_file" ]]; then
                    record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
                else
                    record_name=$(echo "$info" | jq -r '.record_name // "@"')
                fi
            else
                record_name=$(echo "$info" | jq -r '.record_name // "@"')
            fi
            
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
            
            # 构建完整域名显示
            local full_domain
            if [[ "$mode" == "multi" ]]; then
                # 多线路模式显示多个主机记录
                full_domain="${domain} (@, unicom, mobile, telecom)"
            elif [[ "$record_name" == "@" ]]; then
                full_domain="$domain"
            else
                full_domain="${record_name}.${domain}"
            fi
            
            echo -e "   • ${full_domain} (${dns_label}, ${mode_label})"
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
    
    # 如果有已部署的域名，显示管理选项
    if [[ -n "$deployed_domains" ]]; then
        echo ""
        echo -e " ${YELLOW}➤${NC} 3. 管理已部署域名"
        echo -e "      ${CYAN}- 查看、编辑或删除已配置的域名${NC}"
    fi
    
    echo ""
    echo -e " ${RED}➤${NC} 0. 返回主菜单"
    echo ""
    
    read -r -p "请选择 [0-3, 默认 1]: " dns_choice
    dns_choice=${dns_choice:-1}
    
    case "$dns_choice" in
        1)
            deploy_cloudflare_dns
            ;;
        2)
            choose_dnspod_mode
            ;;
        3)
            # 管理已部署域名
            if [[ -n "$deployed_domains" ]]; then
                while true; do
                    manage_deployed_domains_menu
                    local exit_code=$?
                    
                    # 如果返回 1，说明删除了配置，需要检查是否还有域名
                    if [[ $exit_code -eq 1 ]]; then
                        # 重新获取域名列表
                        deployed_domains=$(list_deployed_domains)
                        if [[ -z "$deployed_domains" ]]; then
                            # 没有域名了，退出循环
                            echo -e "${YELLOW}[WARN] 当前没有已部署的域名${NC}"
                            read -r -p "按回车键返回..."
                            break
                        fi
                        # 还有域名，继续循环
                    elif [[ $exit_code -eq 0 ]]; then
                        # 用户选择返回上一级，退出循环
                        break
                    fi
                done
            else
                echo -e "${YELLOW}[WARN] 当前没有已部署的域名${NC}"
                read -r -p "按回车键返回..."
            fi
            ;;
        0)
            # 返回主菜单
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择${NC}"
            read -r -p "按回车键返回..."
            ;;
    esac
}

# 管理已部署域名菜单
manage_deployed_domains_menu() {
    local deployed_domains
    deployed_domains=$(list_deployed_domains)
    
    if [[ -z "$deployed_domains" ]]; then
        echo -e "${YELLOW}[WARN] 当前没有已部署的域名${NC}"
        read -r -p "按回车键返回..."
        return
    fi
    
    show_header
    echo -e "${GREEN}管理已部署域名${NC}"
    echo ""
    
    # 显示域名列表
    echo -e "${CYAN}已部署的域名列表：${NC}"
    echo ""
    local index=1
    local domain_array=()
    while IFS= read -r domain; do
        local info
        info=$(get_domain_info "$domain")
        local dns_type
        dns_type=$(echo "$info" | jq -r '.dns_type')
        local mode
        mode=$(echo "$info" | jq -r '.mode')
        
        # 从实际配置文件中读取 record_name（优先）
        local record_name
        if [[ "$dns_type" == "cloudflare" ]]; then
            local config_file="${ROOT_DIR}/conf/cf-dns/${domain}.json"
            if [[ -f "$config_file" ]]; then
                record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
            else
                record_name=$(echo "$info" | jq -r '.record_name // "@"')
            fi
        elif [[ "$dns_type" == "dnspod" ]]; then
            local config_file="${ROOT_DIR}/conf/dnspod/${domain}.json"
            if [[ -f "$config_file" ]]; then
                record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
            else
                record_name=$(echo "$info" | jq -r '.record_name // "@"')
            fi
        else
            record_name=$(echo "$info" | jq -r '.record_name // "@"')
        fi
        
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
        
        # 构建完整域名显示
        local full_domain
        if [[ "$mode" == "multi" ]]; then
            # 多线路模式显示多个主机记录
            full_domain="${domain} (@, unicom, mobile, telecom)"
        elif [[ "$record_name" == "@" ]]; then
            full_domain="$domain"
        else
            full_domain="${record_name}.${domain}"
        fi
        
        echo -e " ${GREEN}${index})${NC} ${full_domain} (${dns_label}, ${mode_label})"
        domain_array+=("$domain")
        ((index++))
    done <<< "$deployed_domains"
    
    echo ""
    echo -e " ${RED}0)${NC} 返回上一级"
    echo ""
    
    read -r -p "请选择要管理的域名 [0-$((index-1))]: " choice
    
    if [[ "$choice" == "0" ]]; then
        return 1  # 返国1表示用户选择返回上一级
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$index" ]]; then
        local selected_domain="${domain_array[$((choice-1))]}"
        manage_single_domain "$selected_domain"
        local result=$?
        if [[ $result -eq 1 ]]; then
            # 如果子函数返回1，说明配置被删除，需要重新检测
            return 0  # 继续循环，会重新加载列表
        fi
        # 管理完单个域名后，自动返回域名列表（不退出循环）
        return 0
    else
        echo -e "${RED}[ERROR] 无效的选择${NC}"
        read -r -p "按回车键返回..."
        return 0  # 继续显示列表
    fi
}

# 管理单个域名
manage_single_domain() {
    local domain="$1"
    
    show_header
    echo -e "${GREEN}管理已部署域名：${domain}${NC}"
    echo ""
    
    # 获取当前配置信息
    local info
    info=$(get_domain_info "$domain")
    local dns_type
    dns_type=$(echo "$info" | jq -r '.dns_type')
    local mode
    mode=$(echo "$info" | jq -r '.mode')
    local deploy_time
    deploy_time=$(echo "$info" | jq -r '.deploy_time')
    
    # 从实际配置文件中读取 record_name（优先）
    local record_name
    if [[ "$dns_type" == "cloudflare" ]]; then
        local config_file="${ROOT_DIR}/conf/cf-dns/${domain}.json"
        if [[ -f "$config_file" ]]; then
            record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
        else
            # 如果配置文件不存在，从部署记录中读取
            record_name=$(echo "$info" | jq -r '.record_name // "@"')
        fi
    elif [[ "$dns_type" == "dnspod" ]]; then
        local config_file="${ROOT_DIR}/conf/dnspod/${domain}.json"
        if [[ -f "$config_file" ]]; then
            record_name=$(jq -r '.dns.record_name // "@"' "$config_file" 2>/dev/null)
        else
            # 如果配置文件不存在，从部署记录中读取
            record_name=$(echo "$info" | jq -r '.record_name // "@"')
        fi
    else
        record_name=$(echo "$info" | jq -r '.record_name // "@"')
    fi
    
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
    
    # 构建完整域名显示
    local full_domain
    if [[ "$mode" == "multi" ]]; then
        full_domain="${domain} (@, unicom, mobile, telecom)"
    elif [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo -e "${CYAN}当前配置：${NC}"
    echo -e "  • DNS 服务商: ${dns_label}"
    echo -e "  • 工作模式: ${mode_label}"
    echo -e "  • 根域名: ${domain}"
    if [[ "$mode" != "multi" ]]; then
        echo -e "  • 主机记录: ${record_name}"
        echo -e "  • 完整域名: ${full_domain}"
    fi
    echo -e "  • 部署时间: ${deploy_time}"
    echo ""
    
    echo -e "${CYAN}请选择操作：${NC}"
    echo ""
    echo -e " ${GREEN}➤${NC} 1. 重新部署"
    echo -e "      ${CYAN}- 覆盖现有配置，重新执行部署流程${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 2. 删除配置"
    echo -e "      ${CYAN}- 删除该域名的所有配置文件和部署记录${NC}"
    echo ""
    echo -e " ${RED}➤${NC} 0. 返回上一级"
    echo ""
    
    read -r -p "请选择 [0-2]: " manage_choice
    
    case "$manage_choice" in
        1)
            echo -e "${YELLOW}[WARN] 重新部署将覆盖现有配置${NC}"
            read -r -p "是否继续？[y/N] (默认 N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 根据 DNS 类型选择部署方式
                if [[ "$dns_type" == "cloudflare" ]]; then
                    deploy_cloudflare_dns
                elif [[ "$dns_type" == "dnspod" ]]; then
                    if [[ "$mode" == "multi" ]]; then
                        deploy_dnspod_multi
                    else
                        deploy_dnspod_single
                    fi
                fi
            fi
            ;;
        2)
            echo -e "${RED}[WARN] 此操作将删除以下文件：${NC}"
            # 构建正确的配置文件路径
            local config_file
            if [[ "$dns_type" == "cloudflare" ]]; then
                config_file=$(get_cf_dns_config_file "$domain" "$record_name")
            elif [[ "$dns_type" == "dnspod" ]]; then
                config_file=$(get_dnspod_config_file "$domain" "$record_name" "$mode")
            fi
            
            echo -e "  • ${config_file}"
            if [[ "$dns_type" == "dnspod" && "$mode" == "multi" ]]; then
                echo -e "  • ${ROOT_DIR}/conf/dnspod/${domain}_unicom.json"
                echo -e "  • ${ROOT_DIR}/conf/dnspod/${domain}_mobile.json"
                echo -e "  • ${ROOT_DIR}/conf/dnspod/${domain}_telecom.json"
            fi
            echo -e "  • 部署记录中的相关信息"
            echo ""
            read -r -p "确认删除？[y/N] (默认 N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                delete_domain_config "$domain" "$dns_type"
                echo -e "${GREEN}[OK] 配置已删除${NC}"
                read -r -p "按回车键返回..."
                return 1  # 返回1表示需要刷新列表
            fi
            ;;
        0)
            # 返回上一级
            return
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
    
    # 第1步：API 配置
    show_step_header 1 5 "配置 Cloudflare API"
    
    read -r -p "请输入 Cloudflare API Token: " cf_token
    if [[ -z "$cf_token" ]]; then
        echo -e "${RED}[ERROR] Cloudflare API Token 不能为空${NC}"
        return 1
    fi
    
    # 验证 API Token 并获取域名列表
    echo -e "${CYAN}正在验证 API Token...${NC}"
    local zones_response
    zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
        -H "Authorization: Bearer ${cf_token}" \
        -H "Content-Type: application/json")
    
    local zones_count
    zones_count=$(echo "$zones_response" | jq -r '.result_info.total_count // 0')
    
    if [[ "$zones_count" == "0" ]]; then
        echo -e "${RED}[ERROR] API Token 无效或没有可用的域名${NC}"
        echo -e "${YELLOW}请检查：${NC}"
        echo -e "  1. API Token 是否正确"
        echo -e "  2. Token 是否有 'Zone - DNS - Edit' 权限"
        return 1
    fi
    
    echo -e "${GREEN}[OK] 找到 ${zones_count} 个域名${NC}"
    echo ""
    
    # 【新增】API Token 权限说明
    echo -e "${YELLOW}[重要说明]${NC}"
    echo -e "  ${YELLOW}⚠ 此处显示的域名是基于您当前 API Token 的权限范围${NC}"
    echo -e "  ${YELLOW} Cloudflare 支持精细化令牌权限，一个令牌可能只能操作部分域名${NC}"
    echo -e "  ${YELLOW} 如果此处未显示您的全部域名，请检查 API Token 权限设置${NC}"
    echo ""
    echo -e "${GRAY}如需操作其他域名，请重新创建包含该域名权限的 API Token${NC}"
    echo ""
    
    # 显示域名列表（带编号）
    echo -e "${CYAN}可用域名列表：${NC}"
    local domain_array=()
    local index=1
    while IFS= read -r line; do
        local domain_name
        domain_name=$(echo "$line" | awk '{print $1}')
        echo -e " ${GREEN}${index})${NC} ${line}"
        domain_array+=("$domain_name")
        ((index++))
    done <<< "$(echo "$zones_response" | jq -r '.result[] | "\(.name) (Zone ID: \(.id))"' | head -n 10)"
    echo ""
    
    # 让用户选择域名（支持编号或手动输入）
    read -r -p "请选择域名 [1-$((index-1))] 或直接输入域名: " domain_input
    
    local domain
    if [[ "$domain_input" =~ ^[0-9]+$ ]] && [[ "$domain_input" -ge 1 ]] && [[ "$domain_input" -lt "$index" ]]; then
        # 用户选择了编号
        domain="${domain_array[$((domain_input-1))]}"
        echo -e "${GREEN}[OK] 已选择: ${domain}${NC}"
    else
        # 用户手动输入域名
        domain="$domain_input"
    fi
    
    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] 域名不能为空${NC}"
        return 1
    fi
    
    # 从 API 响应中获取 Zone ID
    local zone_id
    zone_id=$(echo "$zones_response" | jq -r --arg domain "$domain" '.result[] | select(.name == $domain) | .id')
    
    if [[ -z "$zone_id" ]]; then
        echo -e "${RED}[ERROR] 未找到域名: ${domain}${NC}"
        echo -e "${YELLOW}请确认域名拼写是否正确${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[OK] 域名验证成功: ${domain}${NC}"
    echo -e "${CYAN}Zone ID: ${zone_id:0:8}...${zone_id: -4}${NC}"
    echo ""
    
    # 第2步：设置主机记录
    show_step_header 2 5 "设置主机记录"
    
    echo -e "${YELLOW}[说明]${NC}"
    echo -e "  主机记录决定了完整的域名格式："
    echo -e "  • 输入 ${GREEN}@${NC} → 解析到根域名 (${domain})"
    echo -e "  • 输入 ${GREEN}www${NC} → 解析到 www.${domain}"
    echo -e "  • 输入 ${GREEN}cf${NC} → 解析到 cf.${domain}"
    echo ""
    
    read -r -p "请输入主机记录 [默认 @]: " record_name
    record_name=${record_name:-@}
    
    # 验证主机记录格式
    if [[ "$record_name" != "@" ]] && ! [[ "$record_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo -e "${RED}[ERROR] 主机记录格式无效${NC}"
        echo -e "${YELLOW}只能使用字母、数字、连字符(-)和下划线(_)，或使用 @ 表示根域名${NC}"
        return 1
    fi
    
    # 构建完整域名用于显示
    local full_domain
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo -e "${GREEN}[OK] 将解析到: ${full_domain}${NC}"
    echo ""
    
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
    
    # 第3步：选择测速节点并生成配置
    # 让用户选择测速节点（函数内部会清屏并显示标题）
    local recommended_colo
    recommended_colo=$(select_colo_nodes "$domain")
    echo -e "${GREEN}[OK] 已选择测速节点: ${recommended_colo}${NC}"
    echo ""
    
    echo -e "${CYAN}正在生成 CF-IP 配置...${NC}"
    generate_cf_ip_config "single" "$recommended_colo" "" "" ""
    echo -e "${GREEN}[OK] CF-IP 配置已生成${NC}"
    
    echo -e "${CYAN}正在生成 Cloudflare DNS 配置...${NC}"
    generate_cf_dns_config "$domain" "$cf_token" "$zone_id" "$record_name"
    echo -e "${GREEN}[OK] Cloudflare DNS 配置已生成: ${ROOT_DIR}/conf/cf-dns/${domain}.json${NC}"
    echo ""
    echo -e "${CYAN}配置信息：${NC}"
    echo -e "  • 完整域名: ${full_domain}"
    echo -e "  • 主机记录: ${record_name}"
    echo -e "  • Zone ID: ${zone_id:0:8}...${zone_id: -4}"  # 隐藏中间部分
    echo -e "  • 测速节点: ${recommended_colo}"
    echo ""
    
    # 第4步：首次测速
    show_step_header 4 5 "执行首次测速"
    
    echo -e "${YELLOW}提示: 首次测速可能需要 2-5 分钟，请耐心等待...${NC}"
    read -r -p "是否立即执行首次测速？[Y/n] (默认 Y): " run_test
    run_test=${run_test:-Y}
    
    if [[ "$run_test" =~ ^[Yy]$ ]]; then
        cd "${ROOT_DIR}" || return 1
        
        # 为当前域名生成独立的测速结果文件
        local result_file="${ROOT_DIR}/assets/data/cf-ip/result_${full_domain}.csv"
        CF_OPT_ENTRY=1 bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${recommended_colo}" "${result_file}" "${full_domain}" || true
        echo -e "${GREEN}[OK] 测速完成${NC}"
        
        # 执行 IP 同步，将测速结果同步到 DNS 模块的 IP 文件
        echo -e "${CYAN}正在同步 IP 数据...${NC}"
        bash "${ROOT_DIR}/modules/ip-sync/sync.sh" || true
        echo -e "${GREEN}[OK] IP 数据已同步到: ${ROOT_DIR}/assets/data/cf-dns/${full_domain}.txt${NC}"
    fi
    
    # 第5步：设置定时任务
    show_step_header 5 5 "设置自动化调度"
    
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
    add_deploy_record "$domain" "cloudflare" "single" "$record_name" "$deploy_time"
    
    # 验证配置一致性
    echo -e "${CYAN}[INFO] 正在验证配置一致性...${NC}"
    if validate_config_consistency; then
        echo -e "${GREEN}[OK] 配置验证通过${NC}"
    else
        echo -e "${YELLOW}[WARN] 配置存在问题，请根据上述提示修正${NC}"
    fi
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    
    # 构建完整域名显示
    local full_domain
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 单线路"
    echo -e "   • 根域名: ${domain}"
    echo -e "   • 主机记录: ${record_name}"
    echo -e "   • 完整域名: ${full_domain}"
    echo -e "   • DNS 服务: Cloudflare DNS"
    echo -e "   • 测速节点: ${recommended_colo}"
    echo ""
    echo -e " ${GRAY}后续操作：${NC}"
    echo -e "   • 运行 'cfopt' 查看和管理配置"
    echo -e "   • 选择 '5. 自动化调度中心' 手动触发更新"
    echo -e "   • 选择 '6. 检查组件更新' 保持最新版本"
    echo ""
    echo -e " ${CYAN}配置文件位置：${NC}"
    echo -e "   • DNS 配置: ${GREEN}${ROOT_DIR}/conf/cf-dns/${full_domain}.json${NC}"
    echo -e "   • IP 列表文件: ${GREEN}${ROOT_DIR}/assets/data/cf-dns/${full_domain}.txt${NC}"
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
    echo -e " ${RED}➤${NC} 0. 返回上一级"
    echo ""
    
    read -r -p "请选择 [0-2, 默认 1]: " mode_choice
    mode_choice=${mode_choice:-1}
    
    case "$mode_choice" in
        1)
            deploy_dnspod_single
            ;;
        2)
            deploy_dnspod_multi
            ;;
        0)
            # 返回上一级（DNS 服务商选择）
            choose_dns_provider
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
    
    # 第2步：设置主机记录
    show_step_header 2 5 "设置主机记录"
    
    echo -e "${YELLOW}[说明]${NC}"
    echo -e "  主机记录决定了完整的域名格式："
    echo -e "  • 输入 ${GREEN}@${NC} → 解析到根域名 (${domain})"
    echo -e "  • 输入 ${GREEN}www${NC} → 解析到 www.${domain}"
    echo -e "  • 输入 ${GREEN}dns${NC} → 解析到 dns.${domain}"
    echo ""
    
    read -r -p "请输入主机记录 [默认 dns]: " record_name
    record_name=${record_name:-dns}
    
    # 验证主机记录格式
    if [[ "$record_name" != "@" ]] && ! [[ "$record_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo -e "${RED}[ERROR] 主机记录格式无效${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[OK] 主机记录已设置: ${record_name}${NC}"
    echo ""
    
    # 第3步：选择测速节点并生成配置
    # 让用户选择测速节点（函数内部会清屏并显示标题）
    local recommended_colo
    recommended_colo=$(select_colo_nodes "$domain")
    echo -e "${GREEN}[OK] 已选择测速节点: ${recommended_colo}${NC}"
    echo ""
    
    echo -e "${CYAN}正在生成 CF-IP 配置...${NC}"
    generate_cf_ip_config "single" "$recommended_colo" "" "" ""
    echo -e "${GREEN}[OK] CF-IP 配置已生成${NC}"
    
    echo -e "${CYAN}正在生成 DNSPod 配置...${NC}"
    generate_dnspod_config "$domain" "$dnspod_id" "$dnspod_token" "single" "$record_name"
    echo -e "${GREEN}[OK] DNSPod 配置已生成${NC}"
    
    # 第4步：首次测速
    show_step_header 4 5 "执行首次测速"
    
    echo -e "${YELLOW}提示: 首次测速可能需要 2-5 分钟，请耐心等待...${NC}"
    read -r -p "是否立即执行首次测速？[Y/n] (默认 Y): " run_test
    run_test=${run_test:-Y}
    
    if [[ "$run_test" =~ ^[Yy]$ ]]; then
        cd "${ROOT_DIR}" || return 1
        
        # 为当前域名生成独立的测速结果文件
        local result_file="${ROOT_DIR}/assets/data/cf-ip/result_${full_domain}.csv"
        CF_OPT_ENTRY=1 bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${recommended_colo}" "${result_file}" "${full_domain}" || true
        echo -e "${GREEN}[OK] 测速完成${NC}"
        
        # 执行 IP 同步，将测速结果同步到 DNS 模块的 IP 文件
        echo -e "${CYAN}正在同步 IP 数据...${NC}"
        bash "${ROOT_DIR}/modules/ip-sync/sync.sh" || true
        echo -e "${GREEN}[OK] IP 数据已同步到: ${ROOT_DIR}/assets/data/cf-dns/${full_domain}.txt${NC}"
    fi
    
    # 第5步：设置定时任务
    show_step_header 5 5 "设置自动化调度"
    
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
    add_deploy_record "$domain" "dnspod" "single" "$record_name" "$deploy_time"
    
    # 验证配置一致性
    echo -e "${CYAN}[INFO] 正在验证配置一致性...${NC}"
    if validate_config_consistency; then
        echo -e "${GREEN}[OK] 配置验证通过${NC}"
    else
        echo -e "${YELLOW}[WARN] 配置存在问题，请根据上述提示修正${NC}"
    fi
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    
    # 构建完整域名显示
    local full_domain
    if [[ "$record_name" == "@" ]]; then
        full_domain="$domain"
    else
        full_domain="${record_name}.${domain}"
    fi
    
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 单线路"
    echo -e "   • 根域名: ${domain}"
    echo -e "   • 主机记录: ${record_name}"
    echo -e "   • 完整域名: ${full_domain}"
    echo -e "   • DNS 服务: DNSPod DNS"
    echo -e "   • 测速节点: ${recommended_colo}"
    echo ""
    echo -e " ${GRAY}后续操作：${NC}"
    echo -e "   • 运行 'cfopt' 查看和管理配置"
    echo -e "   • 选择 '5. 自动化调度中心' 手动触发更新"
    echo -e "   • 选择 '6. 检查组件更新' 保持最新版本"
    echo ""
    echo -e " ${CYAN}配置文件位置：${NC}"
    echo -e "   • DNS 配置: ${GREEN}${ROOT_DIR}/conf/dnspod/${full_domain}.json${NC}"
    echo -e "   • IP 列表文件: ${GREEN}${ROOT_DIR}/assets/data/dnspod-dns/${full_domain}.txt${NC}"
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
    generate_dnspod_config "$domain" "$dnspod_id" "$dnspod_token" "multi" "@"
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
        
        # 执行 IP 同步，将测速结果同步到 DNS 模块的 IP 文件
        echo -e "${CYAN}正在同步 IP 数据...${NC}"
        bash "${ROOT_DIR}/modules/ip-sync/sync.sh" || true
        echo -e "${GREEN}[OK] IP 数据已同步到:${NC}"
        echo -e "   • ${ROOT_DIR}/assets/data/dnspod-dns/ip_list_default.txt"
        echo -e "   • ${ROOT_DIR}/assets/data/dnspod-dns/ip_list_unicom.txt"
        echo -e "   • ${ROOT_DIR}/assets/data/dnspod-dns/ip_list_mobile.txt"
        echo -e "   • ${ROOT_DIR}/assets/data/dnspod-dns/ip_list_telecom.txt"
    fi
    
    # 第5步：设置定时任务
    show_step_header 5 5 "设置自动化调度"
    
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
    add_deploy_record "$domain" "dnspod" "multi" "@,unicom,mobile,telecom" "$deploy_time"
    
    # 验证配置一致性
    echo -e "${CYAN}[INFO] 正在验证配置一致性...${NC}"
    if validate_config_consistency; then
        echo -e "${GREEN}[OK] 配置验证通过${NC}"
    else
        echo -e "${YELLOW}[WARN] 配置存在问题，请根据上述提示修正${NC}"
    fi
    
    # 完成
    show_header
    echo -e " ${GREEN}[OK] 部署完成！${NC}"
    echo ""
    echo -e " ${CYAN}您的配置摘要：${NC}"
    echo -e "   • 工作模式: 多线路"
    echo -e "   • 根域名: ${domain}"
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
    echo -e " ${CYAN}配置文件位置：${NC}"
    echo -e "   • DNS 配置: ${GREEN}${ROOT_DIR}/conf/dnspod/${full_domain}.json${NC}"
    echo -e "   • IP 列表文件: ${GREEN}${ROOT_DIR}/assets/data/dnspod-dns/${full_domain}.txt${NC}"
    echo ""
    
    read -r -p "按回车键返回主菜单..."
}

# 执行主程序
main


