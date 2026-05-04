#!/bin/bash
# ==============================================================================
# cfopt - IP 数据同步组件 (IP Sync)
# Version: 0.1
# Description: 负责将测速结果分发至各 DNS 模块的数据目录，支持状态检测与有效性校验
# Usage: bash modules/ip-sync/sync.sh
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
# 动态获取脚本所在目录及项目根目录，确保路径引用的健壮性
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 定义测速结果文件的绝对路径
RESULT_CSV="${ROOT_DIR}/assets/data/cf-ip/result.csv"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${YELLOW}IP 数据同步组件 v${SCRIPT_VERSION}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ==================== 前置条件检查 ====================
if [[ ! -f "${RESULT_CSV}" ]]; then
    echo -e "${RED}[ERROR] 未找到测速结果文件: ${RESULT_CSV}${NC}"
    echo -e "${YELLOW}提示: 请先运行 CF-IP 优选程序进行测速。${NC}"
    exit 1
fi

# ==================== 数据有效性校验 ====================
# 提取第二行（跳过标题）的第一个字段，防止因测速程序 Bug 导致写入全 0 或空数据
FIRST_IP="$(sed -n '2p' "${RESULT_CSV}" | awk -F',' '{print $1}')"
if [[ -z "${FIRST_IP}" ]] || [[ "${FIRST_IP}" = "0.0.0.0" ]] || [[ ! "${FIRST_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}[ERROR] 检测到测速结果数据异常 (首个 IP: ${FIRST_IP:-空})${NC}"
    echo -e "${YELLOW}提示: 这可能是测速程序的临时 Bug，请重新运行测速。${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] 数据有效性检查通过 (首个 IP: ${FIRST_IP})${NC}"
echo ""

# ==================== 核心函数定义 ====================

# Cloudflare DNS IP 同步函数（支持多域名）
sync_cf_dns_ips() {
    local config_dir="${ROOT_DIR}/conf/cf-dns"
    
    if [[ ! -d "${config_dir}" ]]; then
        return
    fi
    
    # 扫描所有 CF-DNS 配置文件
    local has_synced=false
    while IFS= read -r -d '' json_file; do
        local domain_name
        domain_name=$(basename "$json_file" .json)
        
        # 检查模块是否启用
        local enabled
        enabled=$(jq -r '.enabled // false' "$json_file")
        if [[ "${enabled}" != "true" ]]; then
            continue
        fi
        
        # 验证关键配置项
        local api_token zone_id
        api_token=$(jq -r '.api.token // empty' "$json_file")
        zone_id=$(jq -r '.api.zone_id // empty' "$json_file")
        
        if [[ -z "${api_token}" ]] || [[ -z "${zone_id}" ]]; then
            continue
        fi
        
        if [[ "${has_synced}" = false ]]; then
            echo -e "\n${GREEN}[INFO] 检测到 Cloudflare DNS 模块已启用，正在执行同步...${NC}"
            has_synced=true
        fi
        
        # 从配置中读取限制数量和目标文件路径
        local max_ips target_file
        max_ips=$(jq -r '.dns.max_ips_per_record // 2' "$json_file")
        target_file=$(jq -r '.ip_source.file_path // empty' "$json_file")
        
        if [[ -z "${target_file}" ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} ${domain_name}: 未配置 ip_source.file_path，跳过"
            continue
        fi
        
        # 确保目标文件所在的目录存在
        mkdir -p "$(dirname "${target_file}")"
        
        # 从 CSV 中提取前 N 个最优 IP（跳过标题行）并写入目标文件
        head -n $((max_ips + 1)) "${RESULT_CSV}" | tail -n "${max_ips}" | awk -F',' '{print $1}' > "${target_file}"
        
        local actual_count
        actual_count="$(wc -l < "${target_file}")"
        echo -e "  ${GREEN}[OK]${NC} ${domain_name}: 已写入 ${actual_count} 个最优 IP 到: ${target_file} (限制: ${max_ips})"
        
    done < <(find "${config_dir}" -name "*.json" -type f -print0 2>/dev/null)
}

# DNSPod DNS IP 同步函数（支持多域名和多线路）
sync_dnspod_ips() {
    local config_dir="${ROOT_DIR}/conf/dnspod"
    
    if [[ ! -d "${config_dir}" ]]; then
        return
    fi
    
    # 扫描所有 DNSPod 配置文件
    local has_synced=false
    while IFS= read -r -d '' json_file; do
        local domain_name
        domain_name=$(basename "$json_file" .json)
        
        # 检查模块是否启用
        local enabled
        enabled=$(jq -r '.enabled // false' "$json_file")
        if [[ "${enabled}" != "true" ]]; then
            continue
        fi
        
        # 验证关键配置项
        local dnspod_id dnspod_token
        dnspod_id=$(jq -r '.api.id // empty' "$json_file")
        dnspod_token=$(jq -r '.api.token // empty' "$json_file")
        
        if [[ -z "${dnspod_id}" ]] || [[ -z "${dnspod_token}" ]]; then
            continue
        fi
        
        if [[ "${has_synced}" = false ]]; then
            echo -e "\n${GREEN}[INFO] 检测到 DNSPod DNS 模块已启用，正在执行同步...${NC}"
            has_synced=true
        fi
        
        # 获取工作模式
        local mode
        mode=$(jq -r '.mode // "single"' "$json_file")
        
        if [[ "${mode}" = "single" ]]; then
            # 单线路模式：直接同步通用 IP 列表
            local max_ips target_file
            max_ips=$(jq -r '.dns.max_ips_per_record // 5' "$json_file")
            target_file=$(jq -r '.ip_source.file_path // empty' "$json_file")
            
            if [[ -z "${target_file}" ]]; then
                echo -e "  ${YELLOW}[WARN]${NC} ${domain_name}: 未配置 ip_source.file_path，跳过"
                continue
            fi
            
            mkdir -p "$(dirname "${target_file}")"
            head -n $((max_ips + 1)) "${RESULT_CSV}" | tail -n "${max_ips}" | awk -F',' '{print $1}' > "${target_file}"
            
            local actual_count
            actual_count="$(wc -l < "${target_file}")"
            echo -e "  ${GREEN}[OK]${NC} ${domain_name}(单线路): 已写入 ${actual_count} 个最优 IP 到: ${target_file} (限制: ${max_ips})"
            
        else
            # 多线路模式：根据运营商分别同步
            echo -e "  ${CYAN}[INFO]${NC} ${domain_name}: 处于多线路模式，正在执行分线路同步..."
            
            # 定义运营商与测速结果文件的映射
            declare -A ISP_FILES
            ISP_FILES["default"]="${ROOT_DIR}/assets/data/cf-ip/result_default.csv"
            ISP_FILES["unicom"]="${ROOT_DIR}/assets/data/cf-ip/result_unicom.csv"
            ISP_FILES["mobile"]="${ROOT_DIR}/assets/data/cf-ip/result_mobile.csv"
            ISP_FILES["telecom"]="${ROOT_DIR}/assets/data/cf-ip/result_telecom.csv"
            
            local max_ips
            max_ips=$(jq -r '.dns.max_ips_per_record // 5' "$json_file")
            
            for isp in "${!ISP_FILES[@]}"; do
                local src_file="${ISP_FILES[$isp]}"
                if [[ -f "${src_file}" ]]; then
                    # 从配置中读取对应线路的目标文件路径
                    local target_file
                    target_file=$(jq -r ".ip_source.files.${isp} // empty" "$json_file")
                    
                    if [[ -z "${target_file}" ]]; then
                        echo -e "    ${YELLOW}[WARN]${NC} ${isp} 线路: 未配置 ip_source.files.${isp}，跳过"
                        continue
                    fi
                    
                    mkdir -p "$(dirname "${target_file}")"
                    head -n $((max_ips + 1)) "${src_file}" | tail -n "${max_ips}" | awk -F',' '{print $1}' > "${target_file}"
                    
                    local actual_count
                    actual_count="$(wc -l < "${target_file}")"
                    echo -e "    ${GREEN}[OK]${NC} ${isp} 线路: 已写入 ${actual_count} 个最优 IP 到: ${target_file} (限制: ${max_ips})"
                else
                    echo -e "    ${YELLOW}[WARN]${NC} ${isp} 线路: 未找到测速结果: ${src_file}"
                fi
            done
            unset ISP_FILES
        fi
        
    done < <(find "${config_dir}" -name "*.json" -type f -print0 2>/dev/null)
}

# ==================== 执行同步任务 ====================

# 1. 同步 Cloudflare DNS 模块数据（支持多域名）
sync_cf_dns_ips

# 2. 同步 DNSPod DNS 模块数据（支持多域名和多线路）
sync_dnspod_ips

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}同步任务执行完毕！${NC}"
