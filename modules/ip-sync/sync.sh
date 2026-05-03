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

# 模块 IP 同步通用函数 (JSON 配置版)
# 参数:
#   $1: 模块名称标识 (如 CF-DNS, DNSPod)
#   $2: 模块 JSON 配置文件路径
#   $3: 默认最大 IP 数量
#   $4: 默认目标 IP 文件路径
sync_ips_for_module() {
    local module_name="$1"
    local json_file="$2"
    local default_max_ips="$3"
    local default_ip_file="$4"

    # 检查配置文件是否存在
    if [[ ! -f "${json_file}" ]]; then
        return
    fi

    # 检查 jq 是否可用
    if ! command -v jq &>/dev/null; then
        echo -e "  ${RED}[ERROR]${NC} jq 未安装，无法读取 ${module_name} 配置"
        return
    fi

    # 从 JSON 读取配置
    local enabled
    enabled=$(jq -r '.enabled // false' "$json_file")

    # 1. 检查模块启用状态
    if [[ "${enabled}" != "true" ]]; then
        echo -e "  ${YELLOW}[SKIP]${NC} ${module_name} 模块未启用 (enabled=false)"
        return
    fi

    # 2. 验证关键配置项是否已填写
    local is_configured=false
    if [[ "${module_name}" == *"CF-DNS"* ]]; then
        local api_token zone_id
        api_token=$(jq -r '.api.token // empty' "$json_file")
        zone_id=$(jq -r '.api.zone_id // empty' "$json_file")
        if [[ -n "${api_token}" ]] && [[ -n "${zone_id}" ]]; then
            is_configured=true
        fi
    elif [[ "${module_name}" == *"DNSPod"* ]]; then
        local dnspod_id dnspod_token
        dnspod_id=$(jq -r '.api.id // empty' "$json_file")
        dnspod_token=$(jq -r '.api.token // empty' "$json_file")
        if [[ -n "${dnspod_id}" ]] && [[ -n "${dnspod_token}" ]]; then
            is_configured=true
        fi
    fi

    if [[ "${is_configured}" = true ]]; then
        echo -e "\n${GREEN}[INFO] 检测到 ${module_name} 模块已启用，正在执行同步...${NC}"
        
        # 从配置中读取限制数量，若未配置则使用默认值
        local max_ips
        if [[ "${module_name}" == *"CF-DNS"* ]]; then
            max_ips=$(jq -r '.dns.max_ips_per_record // '"${default_max_ips}" "$json_file")
        else
            max_ips="${default_max_ips}"
        fi
        
        local target_file
        if [[ "${module_name}" == *"CF-DNS"* ]]; then
            target_file=$(jq -r '.ip_source.file_path // "'"${default_ip_file}"'"' "$json_file")
        else
            target_file="${default_ip_file}"
        fi
        
        # 确保目标文件所在的目录存在
        mkdir -p "$(dirname "${target_file}")"
        
        # 从 CSV 中提取前 N 个最优 IP（跳过标题行）并写入目标文件
        head -n $((max_ips + 1)) "${RESULT_CSV}" | tail -n "${max_ips}" | awk -F',' '{print $1}' > "${target_file}"
        
        local actual_count
        actual_count="$(wc -l < "${target_file}")"
        echo -e "  ${GREEN}[OK]${NC} 已写入 ${actual_count} 个最优 IP 到: ${target_file}"
        echo -e "  ${CYAN}[INFO]${NC} 限制数量: ${max_ips}"
    fi
}

# ==================== 执行同步任务 ====================

# 1. 同步 Cloudflare DNS 模块数据
sync_ips_for_module "CF-DNS" "${ROOT_DIR}/conf/cf-dns.json" "2" "${ROOT_DIR}/assets/data/cf-dns/ip_list.txt"

# 2. 同步 DNSPod DNS 模块数据
if [[ -f "${ROOT_DIR}/conf/dnspod.json" ]]; then
    # 检查 DNSPod 是否启用
    dnspod_enabled=$(jq -r '.enabled // false' "${ROOT_DIR}/conf/dnspod.json")
    if [[ "${dnspod_enabled}" = "true" ]]; then
        dnspod_id=$(jq -r '.api.id // empty' "${ROOT_DIR}/conf/dnspod.json")
        dnspod_token=$(jq -r '.api.token // empty' "${ROOT_DIR}/conf/dnspod.json")
        
        if [[ -n "${dnspod_id}" ]] && [[ -n "${dnspod_token}" ]]; then
            dnspod_mode=$(jq -r '.mode // "single"' "${ROOT_DIR}/conf/dnspod.json")
            
            if [[ "${dnspod_mode}" = "single" ]]; then
                # 单线路模式：直接同步通用 IP 列表
                sync_ips_for_module "DNSPod(单线路)" "${ROOT_DIR}/conf/dnspod.json" "5" "${ROOT_DIR}/assets/data/dnspod-dns/ip_list.txt"
            else
                # 多线路模式：根据运营商分别同步
                echo -e "\n${GREEN}[INFO] DNSPod 处于多线路模式，正在执行分线路同步...${NC}"
                
                # 定义运营商与测速结果文件的映射
                declare -A ISP_FILES
                ISP_FILES["default"]="${ROOT_DIR}/assets/data/cf-ip/result_default.csv"
                ISP_FILES["unicom"]="${ROOT_DIR}/assets/data/cf-ip/result_unicom.csv"
                ISP_FILES["mobile"]="${ROOT_DIR}/assets/data/cf-ip/result_mobile.csv"
                ISP_FILES["telecom"]="${ROOT_DIR}/assets/data/cf-ip/result_telecom.csv"

                max_ips=$(jq -r '.dns.max_ips_per_record // 5' "${ROOT_DIR}/conf/dnspod.json")

                for isp in "${!ISP_FILES[@]}"; do
                    src_file="${ISP_FILES[$isp]}"
                    if [[ -f "${src_file}" ]]; then
                        # 提取前 N 个 IP 并写入对应的 DNSPod 数据文件
                        target_file="${ROOT_DIR}/assets/data/dnspod-dns/ip_list_${isp}.txt"
                        head -n $((max_ips + 1)) "${src_file}" | tail -n "${max_ips}" | awk -F',' '{print $1}' > "${target_file}"
                        echo -e "  ${GREEN}[OK]${NC} ${isp} 线路已同步 (${target_file})"
                    else
                        echo -e "  ${YELLOW}[WARN]${NC} 未找到 ${isp} 线路的测速结果: ${src_file}"
                    fi
                done
            fi
        fi
    fi
fi

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}同步任务执行完毕！${NC}"
