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
BOLD='\033[1m'
NC='\033[0m'

# 定义测速结果文件的绝对路径
RESULT_CSV="${ROOT_DIR}/assets/data/cf-ip/result.csv"

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
echo -e " ${CYAN}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

# ==================== 配置加载 ====================
CONFIG_FILE="${ROOT_DIR}/conf/cf-ip.json"

# 检查 jq 是否可用
if ! command -v jq &>/dev/null; then
    echo -e "${RED}[ERROR] jq 未安装 (必需工具)${NC}"
    exit 1
fi

# 从配置文件读取 MAX_RETRY，与 cf-ip/core.sh 保持一致
if [[ -f "${CONFIG_FILE}" ]]; then
    export MAX_RETRY=$(jq -r '.speed_test.max_retry // 3' "${CONFIG_FILE}")
else
    # 如果配置文件不存在，使用默认值
    export MAX_RETRY=3
fi

echo -e "${GREEN}[INFO] 最大重试次数: ${MAX_RETRY}${NC}"
echo ""

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

# 自动重新测速函数（用于同步失败时自动重试）
# 【修复】从配置文件读取 MAX_RETRY，与 cf-ip/core.sh 保持一致
auto_retry_test() {
    local result_file="$1"
    local colo_nodes="$2"  # 测速节点，如 "HKG,NRT"
    local line_id="$3"     # 线路标识，用于进程锁
    local max_retries=${MAX_RETRY:-3}  # 【修复】使用配置文件中的值，默认3次
    
    # 检查测速程序是否存在
    local cfst_bin="${ROOT_DIR}/assets/cfst/cfst"
    if [[ ! -f "${cfst_bin}" ]]; then
        echo -e "${RED}[ERROR] 测速程序 cfst 不存在，无法自动重试${NC}"
        return 1
    fi
    
    cd "${ROOT_DIR}" || return 1
    
    # 循环重试，最多 ${max_retries} 次
    for ((i=1; i<=max_retries; i++)); do
        echo -e "\n${CYAN}[INFO] 检测到测速数据无效，正在自动重新测速 (尝试 ${i}/${max_retries})...${NC}"
        
        # 调用 core.sh 执行测速
        CF_OPT_ENTRY=1 bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${colo_nodes}" "${result_file}" "${line_id}"
        
        local exit_code=$?
        if [[ ${exit_code} -eq 0 ]] && [[ -f "${result_file}" ]]; then
            # 【增强】验证测速结果是否有效：检查是否有下载速度 > 0 的 IP
            local valid_ip_count
            valid_ip_count=$(awk -F',' 'NR>1 && $6>0 {count++} END {print count+0}' "${result_file}")
            
            if [[ "${valid_ip_count}" -gt 0 ]]; then
                echo -e "${GREEN}[OK] 自动重新测速完成 (尝试 ${i}/${max_retries})，找到 ${valid_ip_count} 个有效 IP${NC}"
                return 0
            else
                echo -e "${YELLOW}[WARN] 第 ${i} 次测速完成，但所有 IP 下载速度仍为 0，数据无效${NC}"
            fi
        else
            echo -e "${YELLOW}[WARN] 第 ${i} 次测速失败 (Exit Code: ${exit_code})${NC}"
        fi
        
        # 如果不是最后一次，等待一段时间后重试
        if [[ ${i} -lt ${max_retries} ]]; then
            local wait_time=$((i * 10))  # 递增等待时间：10s, 20s, 30s, 40s
            echo -e "${CYAN}[INFO] 等待 ${wait_time} 秒后重试...${NC}"
            sleep ${wait_time}
        fi
    done
    
    # 所有重试都失败
    echo -e "${RED}[ERROR] 自动重新测速失败，已重试 ${max_retries} 次${NC}"
    return 1
}

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
        
        # 从配置中读取限制数量、目标文件路径和测速结果文件路径
        local max_ips target_file result_file
        max_ips=$(jq -r '.dns.max_ips_per_record // 2' "$json_file")
        target_file=$(jq -r '.ip_source.file_path // empty' "$json_file")
        result_file=$(jq -r '.ip_source.result_file // empty' "$json_file")
        
        if [[ -z "${target_file}" ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} ${domain_name}: 未配置 ip_source.file_path，跳过"
            continue
        fi
        
        # 如果未配置 result_file，使用默认路径
        if [[ -z "${result_file}" ]]; then
            result_file="${RESULT_CSV}"
        fi
        
        # 检查测速结果文件是否存在
        if [[ ! -f "${result_file}" ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} ${domain_name}: 测速结果文件不存在 (${result_file})，跳过"
            continue
        fi
        
        # 确保目标文件所在的目录存在
        mkdir -p "$(dirname "${target_file}")"
        
        # 【优化】从 CSV 中提取最优 IP（综合考虑下载速度和延迟）
        # 策略：
        #   1. 跳过标题行
        #   2. 过滤掉下载速度为 0 的 IP（无效数据）
        #   3. 按下载速度降序排序（优先高速 IP）
        #   4. 如果下载速度相同，按延迟升序排序
        #   5. 提取前 max_ips 个 IP
        awk -F',' 'NR>1 && $6>0 {print $0}' "${result_file}" | \
            sort -t',' -k6,6 -rn -k5,5 -n | \
            head -n "${max_ips}" | \
            awk -F',' '{print $1}' > "${target_file}"
        
        local actual_count
        actual_count="$(wc -l < "${target_file}")"
        
        # 【关键】如果没有找到有效 IP（所有 IP 下载速度都为 0），说明测速有问题
        # 在无人值守模式下，自动重新测速
        if [[ "${actual_count}" -eq 0 ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} ${domain_name}: 所有 IP 下载速度均为 0，测速数据无效"
            
            # 从配置中读取测速节点（如果有）
            local colo_nodes
            colo_nodes=$(jq -r '.ip_source.colo_nodes // "HKG,NRT"' "$json_file")
            
            # 自动重新测速
            if auto_retry_test "${result_file}" "${colo_nodes}" "${domain_name}"; then
                # 重新测速成功后，再次尝试同步
                echo -e "  ${CYAN}[INFO]${NC} ${domain_name}: 正在使用新的测速结果进行同步..."
                awk -F',' 'NR>1 && $6>0 {print $0}' "${result_file}" | \
                    sort -t',' -k6,6 -rn -k5,5 -n | \
                    head -n "${max_ips}" | \
                    awk -F',' '{print $1}' > "${target_file}"
                
                actual_count="$(wc -l < "${target_file}")"
                
                # 如果重新测速后仍然失败，跳过
                if [[ "${actual_count}" -eq 0 ]]; then
                    echo -e "  ${RED}[ERROR]${NC} ${domain_name}: 重新测速后数据仍无效，跳过本次同步"
                    rm -f "${target_file}" 2>/dev/null
                    continue
                fi
            else
                # 自动重试失败，跳过
                echo -e "  ${RED}[ERROR]${NC} ${domain_name}: 自动重新测速失败，跳过本次同步"
                rm -f "${target_file}" 2>/dev/null
                continue
            fi
        fi
        
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
            
            # 【优化】从 CSV 中提取最优 IP（综合考虑下载速度和延迟）
            awk -F',' 'NR>1 && $6>0 {print $0}' "${RESULT_CSV}" | \
                sort -t',' -k6,6 -rn -k5,5 -n | \
                head -n "${max_ips}" | \
                awk -F',' '{print $1}' > "${target_file}"
            
            local actual_count
            actual_count="$(wc -l < "${target_file}")"
            
            # 【关键】如果没有找到有效 IP（所有 IP 下载速度都为 0），自动重新测速
            if [[ "${actual_count}" -eq 0 ]]; then
                echo -e "    ${YELLOW}[WARN]${NC} ${domain_name}: 所有 IP 下载速度均为 0，测速数据无效"
                
                # 从配置中读取测速节点（如果有）
                local colo_nodes
                colo_nodes=$(jq -r '.ip_source.colo_nodes // "HKG,NRT"' "$json_file")
                
                # 自动重新测速
                if auto_retry_test "${RESULT_CSV}" "${colo_nodes}" "${domain_name}"; then
                    # 重新测速成功后，再次尝试同步
                    echo -e "    ${CYAN}[INFO]${NC} ${domain_name}: 正在使用新的测速结果进行同步..."
                    awk -F',' 'NR>1 && $6>0 {print $0}' "${RESULT_CSV}" | \
                        sort -t',' -k6,6 -rn -k5,5 -n | \
                        head -n "${max_ips}" | \
                        awk -F',' '{print $1}' > "${target_file}"
                    
                    actual_count="$(wc -l < "${target_file}")"
                    
                    # 如果重新测速后仍然失败，跳过
                    if [[ "${actual_count}" -eq 0 ]]; then
                        echo -e "    ${RED}[ERROR]${NC} ${domain_name}: 重新测速后数据仍无效，跳过本次同步"
                        rm -f "${target_file}" 2>/dev/null
                        continue
                    fi
                else
                    # 自动重试失败，跳过
                    echo -e "    ${RED}[ERROR]${NC} ${domain_name}: 自动重新测速失败，跳过本次同步"
                    rm -f "${target_file}" 2>/dev/null
                    continue
                fi
            fi
            
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
                    
                    # 【优化】从 CSV 中提取最优 IP（综合考虑下载速度和延迟）
                    awk -F',' 'NR>1 && $6>0 {print $0}' "${src_file}" | \
                        sort -t',' -k6,6 -rn -k5,5 -n | \
                        head -n "${max_ips}" | \
                        awk -F',' '{print $1}' > "${target_file}"
                    
                    local actual_count
                    actual_count="$(wc -l < "${target_file}")"
                    
                    # 【关键】如果没有找到有效 IP（所有 IP 下载速度都为 0），自动重新测速
                    if [[ "${actual_count}" -eq 0 ]]; then
                        echo -e "      ${YELLOW}[WARN]${NC} ${isp} 线路: 所有 IP 下载速度均为 0，测速数据无效"
                        
                        # 从配置中读取该线路的测速节点
                        local colo_nodes
                        colo_nodes=$(jq -r ".multi_line.colo_${isp} // \"HKG,NRT\"" "$json_file")
                        
                        # 自动重新测速（针对特定线路）
                        if auto_retry_test "${src_file}" "${colo_nodes}" "${domain_name}_${isp}"; then
                            # 重新测速成功后，再次尝试同步
                            echo -e "      ${CYAN}[INFO]${NC} ${isp} 线路: 正在使用新的测速结果进行同步..."
                            awk -F',' 'NR>1 && $6>0 {print $0}' "${src_file}" | \
                                sort -t',' -k6,6 -rn -k5,5 -n | \
                                head -n "${max_ips}" | \
                                awk -F',' '{print $1}' > "${target_file}"
                            
                            actual_count="$(wc -l < "${target_file}")"
                            
                            # 如果重新测速后仍然失败，跳过
                            if [[ "${actual_count}" -eq 0 ]]; then
                                echo -e "      ${RED}[ERROR]${NC} ${isp} 线路: 重新测速后数据仍无效，跳过本次同步"
                                rm -f "${target_file}" 2>/dev/null
                                continue
                            fi
                        else
                            # 自动重试失败，跳过
                            echo -e "      ${RED}[ERROR]${NC} ${isp} 线路: 自动重新测速失败，跳过本次同步"
                            rm -f "${target_file}" 2>/dev/null
                            continue
                        fi
                    fi
                    
                    echo -e "    ${GREEN}[OK]${NC} ${isp} 线路: 已写入 ${actual_count} 个最优 IP 到: ${target_file} (限制: ${max_ips})"
                else
                    echo -e "    ${YELLOW}[WARN]${NC} ${isp} 线路: 未找到测速结果: ${src_file}"
                fi
            done
            unset ISP_FILES
        fi
        
    done < <(find "${config_dir}" -name "*.json" -type f -print0 2>/dev/null)
}

# ==================== 【标准数据格式】转换函数 ====================

# CSV → .iplist 格式转换
csv_to_iplist() {
    local csv_file="$1"
    local iplist_file="$2"
    
    if [[ ! -f "$csv_file" ]]; then
        echo -e "${RED}[ERROR] CSV 文件不存在: ${csv_file}${NC}"
        return 1
    fi
    
    echo "# Cloudflare 优选 IP 列表" > "$iplist_file"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$iplist_file"
    echo "#" >> "$iplist_file"
    echo "# IP地址|延迟(ms)|下载速度(MB/s)|地区码" >> "$iplist_file"
    
    # 跳过 CSV 标题行，提取需要的字段
    tail -n +2 "$csv_file" | while IFS=',' read -r ip sent recv loss delay speed region; do
        # 清理 Windows 换行符
        region=$(echo "$region" | tr -d '\r' | xargs)
        
        # 只保留有效数据（速度 > 0）
        if [[ "$speed" =~ ^[0-9.]+$ ]] && (( $(echo "$speed > 0" | bc -l) )); then
            echo "${ip}|${delay}|${speed}|${region}" >> "$iplist_file"
        fi
    done
    
    local count
    count=$(grep -v '^#' "$iplist_file" | wc -l)
    echo -e "${GREEN}[OK] CSV → .iplist 转换完成: ${count} 个 IP${NC}"
}

# .iplist → TXT 格式转换（兼容旧模块）
iplist_to_txt() {
    local iplist_file="$1"
    local txt_file="$2"
    
    if [[ ! -f "$iplist_file" ]]; then
        echo -e "${RED}[ERROR] .iplist 文件不存在: ${iplist_file}${NC}"
        return 1
    fi
    
    # 提取第一列（IP地址），跳过注释行
    grep -v '^#' "$iplist_file" | awk -F'|' '{print $1}' > "$txt_file"
    
    local count
    count=$(wc -l < "$txt_file")
    echo -e "${GREEN}[OK] .iplist → TXT 转换完成: ${count} 个 IP${NC}"
}

# TXT → .iplist 格式转换（补充默认元数据）
txt_to_iplist() {
    local txt_file="$1"
    local iplist_file="$2"
    
    if [[ ! -f "$txt_file" ]]; then
        echo -e "${RED}[ERROR] TXT 文件不存在: ${txt_file}${NC}"
        return 1
    fi
    
    echo "# 注意: 此文件由 TXT 格式升级而来" > "$iplist_file"
    echo "# 延迟、速度、地区码字段为默认值，建议重新测速" >> "$iplist_file"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$iplist_file"
    echo "#" >> "$iplist_file"
    echo "# IP地址|延迟(ms)|下载速度(MB/s)|地区码" >> "$iplist_file"
    
    while IFS= read -r ip; do
        # 跳过空行和注释
        [[ -z "$ip" ]] && continue
        [[ "$ip" =~ ^# ]] && continue
        
        # 清理空格
        ip=$(echo "$ip" | xargs)
        
        # 使用默认值（因为 TXT 格式不包含这些信息）
        echo "${ip}|0|0.0|UNKNOWN" >> "$iplist_file"
    done < "$txt_file"
    
    local count
    count=$(grep -v '^#' "$iplist_file" | wc -l)
    echo -e "${GREEN}[OK] TXT → .iplist 转换完成: ${count} 个 IP${NC}"
    echo -e "${YELLOW}[WARN] 元数据为默认值，建议重新测速以获取准确的延迟和速度信息${NC}"
}

# 自动检测文件格式并转换
detect_and_convert() {
    local source_file="$1"
    local target_file="$2"
    local target_format="$3"  # iplist, txt, csv
    
    if [[ ! -f "$source_file" ]]; then
        echo -e "${RED}[ERROR] 源文件不存在: ${source_file}${NC}"
        return 1
    fi
    
    # 检测源文件格式
    local source_format
    if [[ "$source_file" == *.iplist ]]; then
        source_format="iplist"
    elif [[ "$source_file" == *.csv ]]; then
        source_format="csv"
    elif [[ "$source_file" == *.txt ]]; then
        source_format="txt"
    else
        # 根据内容判断
        if head -n 1 "$source_file" | grep -q '|'; then
            source_format="iplist"
        elif head -n 1 "$source_file" | grep -q ','; then
            source_format="csv"
        else
            source_format="txt"
        fi
    fi
    
    echo -e "${CYAN}[INFO] 检测到源文件格式: ${source_format}${NC}"
    echo -e "${CYAN}[INFO] 目标文件格式: ${target_format}${NC}"
    
    # 如果格式相同，直接复制
    if [[ "$source_format" == "$target_format" ]]; then
        cp "$source_file" "$target_file"
        echo -e "${GREEN}[OK] 格式相同，直接复制${NC}"
        return 0
    fi
    
    # 执行转换
    case "${source_format}-${target_format}" in
        csv-iplist)
            csv_to_iplist "$source_file" "$target_file"
            ;;
        iplist-txt)
            iplist_to_txt "$source_file" "$target_file"
            ;;
        txt-iplist)
            txt_to_iplist "$source_file" "$target_file"
            ;;
        *)
            echo -e "${RED}[ERROR] 不支持的转换: ${source_format} → ${target_format}${NC}"
            return 1
            ;;
    esac
}

# ==================== 执行同步任务 ====================

# 1. 同步 Cloudflare DNS 模块数据（支持多域名）
sync_cf_dns_ips

# 2. 同步 DNSPod DNS 模块数据（支持多域名和多线路）
sync_dnspod_ips

echo -e "\n${CYAN}+------------------------------------------------------------+${NC}"
echo -e "${GREEN}同步任务执行完毕！${NC}"
