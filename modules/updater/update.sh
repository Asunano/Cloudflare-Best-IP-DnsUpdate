#!/bin/bash
# ==============================================================================
# cfopt - 自动更新组件 (Auto Updater)
# Version: 0.1
# Description: 负责检查和更新 cfopt 所有组件，包括主程序自身
# Usage: bash modules/updater/update.sh [check|update]
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ==================== 配置 ====================
VERSION_FILE="${ROOT_DIR}/version.txt"
GITHUB_REPO="Asunano/Cloudflare-Best-IP-DnsUpdate"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
# 自定义镜像源（优先使用）
MIRROR_BASE_URL="https://mirror.drxian.qzz.io/scripts/Cloudflare-Best-IP-DnsUpdate"

# 定义需要更新的组件映射
# 格式: "KEY:本地路径:远程相对路径:显示名称"
declare -a COMPONENTS=(
    "UPDATER:modules/updater/update.sh:modules/updater/update.sh:自动更新组件"
    "QUICK_DEPLOY:modules/quick-deploy/setup.sh:modules/quick-deploy/setup.sh:快速部署向导"
    "CF_IP_MENU:modules/cf-ip/menu.sh:modules/cf-ip/menu.sh:CF-IP 测速管理"
    "CF_IP_CORE:modules/cf-ip/core.sh:modules/cf-ip/core.sh:CF-IP 核心引擎"
    "CF_DNS_CORE:modules/cf-dns/core.sh:modules/cf-dns/core.sh:CF DNS 核心"
    "CF_DNS_SETUP:modules/cf-dns/setup.sh:modules/cf-dns/setup.sh:CF DNS 配置向导"
    "DNSPOD_CORE:modules/dnspod-dns/core.sh:modules/dnspod-dns/core.sh:DNSPod 核心"
    "DNSPOD_SETUP:modules/dnspod-dns/setup.sh:modules/dnspod-dns/setup.sh:DNSPod 配置向导"
    "SCHEDULER_RUN:modules/scheduler/run.sh:modules/scheduler/run.sh:自动化调度器"
    "IP_SYNC:modules/ip-sync/sync.sh:modules/ip-sync/sync.sh:IP 同步工具"
    "CFOPT:cfopt.sh:cfopt.sh:主程序入口"
)

# ==================== 核心函数 ====================

# 获取远程版本信息（镜像源优先）
get_remote_version() {
    local remote_version
    
    # 【优先】尝试镜像源（国内加速）
    remote_version=$(curl -s --max-time 10 "${MIRROR_BASE_URL}/version.txt" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "${remote_version}" ]]; then
        echo "${remote_version}"
        return 0
    fi
    
    # 【备用】尝试官方源
    remote_version=$(curl -s --max-time 10 "${RAW_BASE_URL}/version.txt" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "${remote_version}" ]]; then
        echo "${remote_version}"
        return 0
    fi
    
    echo ""
    return 1
}

# 从 version.txt 中获取指定组件的哈希值
get_component_hash() {
    local component_key="$1"
    local version_content="$2"
    
    # 从 version.txt 中提取对应组件的哈希值
    local hash_line
    hash_line=$(echo "${version_content}" | grep "^${component_key}=" | head -1)
    
    if [[ -n "${hash_line}" ]]; then
        # 格式: KEY=VERSION:HASH
        echo "${hash_line}" | cut -d':' -f2
        return 0
    fi
    
    echo ""
    return 1
}

# 从 version.txt 中获取指定组件的版本号
get_component_version() {
    local component_key="$1"
    local version_content="$2"
    
    # 从 version.txt 中提取对应组件的版本号
    local version_line
    version_line=$(echo "${version_content}" | grep "^${component_key}=" | head -1)
    
    if [[ -n "${version_line}" ]]; then
        # 格式: KEY=VERSION:HASH
        echo "${version_line}" | cut -d'=' -f2 | cut -d':' -f1
        return 0
    fi
    
    echo ""
    return 1
}

# 获取本地版本号
get_local_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        cat "${VERSION_FILE}"
    else
        echo "unknown"
    fi
}

# 从 version.txt 中提取第一个组件的版本号（用于显示）
get_display_version() {
    local version_content="$1"
    
    # 如果是 "unknown"，直接返回
    if [[ "${version_content}" == "unknown" ]]; then
        echo "unknown"
        return
    fi
    
    # 提取第一行非注释、非空行的版本号
    local first_entry
    first_entry=$(echo "${version_content}" | grep -v '^#' | grep -v '^$' | head -1)
    
    if [[ -n "${first_entry}" ]]; then
        # 格式: KEY=VERSION:HASH
        echo "${first_entry}" | cut -d'=' -f2 | cut -d':' -f1
    else
        echo "unknown"
    fi
}

# 下载单个文件（支持镜像源优先和SHA256校验）
download_file() {
    local local_path="$1"
    local remote_path="$2"
    local display_name="$3"
    local expected_hash="${4:-}"  # 可选参数：预期的 SHA256 哈希值
    
    local target_file="${ROOT_DIR}/${local_path}"
    local temp_file
    temp_file=$(mktemp)
    
    # 【特殊处理】updater.sh 自身：下载到 .new 文件，避免覆盖正在运行的脚本
    if [[ "${remote_path}" = "modules/updater/update.sh" ]]; then
        temp_file="${ROOT_DIR}/modules/updater/update.sh.new"
    fi
    
    local download_success=false
    
    echo -e "  ${CYAN}[INFO]${NC} 正在下载 ${display_name}..."
    
    # 【优先】尝试使用镜像源下载（国内加速）
    local mirror_url="${MIRROR_BASE_URL}/${remote_path}"
    
    if curl -s --max-time 30 -o "${temp_file}" "${mirror_url}" 2>/dev/null; then
        # 验证下载的文件非空且有效
        if [[ -s "${temp_file}" ]]; then
            # 先检查是否为有效的 Shell 脚本
            local is_valid_script=false
            local first_line
            first_line="$(head -1 "${temp_file}" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//')"
            if [[ "${first_line}" == "#!"* ]]; then
                is_valid_script=true
            fi
            
            # 如果是有效的 Shell 脚本，跳过 HTML 检查
            if [[ "${is_valid_script}" = true ]]; then
                download_success=true
            else
                # 非脚本文件才进行 HTML 检查
                if ! grep -qi "^<html\|^<!DOCTYPE" "${temp_file}" 2>/dev/null && \
                   ! grep -q "404 Not Found\|403 Forbidden" "${temp_file}" 2>/dev/null; then
                    download_success=true
                fi
            fi
        fi
    fi
    
    # 【备用】如果镜像源失败，尝试官方源
    if [[ "${download_success}" = false ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} 镜像源失败，尝试官方源..."
        local full_url="${RAW_BASE_URL}/${remote_path}"
        rm -f "${temp_file}"
        temp_file=$(mktemp)
        
        if curl -s --max-time 30 -o "${temp_file}" "${full_url}" 2>/dev/null; then
            if [[ -s "${temp_file}" ]]; then
                # 先检查是否为有效的 Shell 脚本
                local is_valid_script=false
                local first_line
                first_line="$(head -1 "${temp_file}" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//')"
                if [[ "${first_line}" == "#!"* ]]; then
                    is_valid_script=true
                fi
                
                # 如果是有效的 Shell 脚本，跳过 HTML 检查
                if [[ "${is_valid_script}" = true ]]; then
                    download_success=true
                else
                    # 非脚本文件才进行 HTML 检查
                    if ! grep -qi "^<html\|^<!DOCTYPE" "${temp_file}" 2>/dev/null && \
                       ! grep -q "404 Not Found\|403 Forbidden" "${temp_file}" 2>/dev/null; then
                        download_success=true
                    fi
                fi
            fi
        fi
    fi
    
    # 处理下载结果
    if [[ "${download_success}" = true ]]; then
        # 【强制】SHA256 哈希校验
        if [[ -n "${expected_hash}" ]]; then
            local actual_hash
            actual_hash=$(sha256sum "${temp_file}" | awk '{print $1}')
            
            if [[ "${actual_hash}" != "${expected_hash}" ]]; then
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (哈希校验失败)"
                echo -e "    预期: ${expected_hash}"
                echo -e "    实际: ${actual_hash}"
                echo -e "    ${YELLOW}提示: 这可能是网络缓存导致的，请稍后重试${NC}"
                rm -f "${temp_file}"
                return 1
            fi
        fi
        
        # 如果不是 updater.sh 自身，直接移动到目标位置
        if [[ "${remote_path}" != "modules/updater/update.sh" ]]; then
            mv "${temp_file}" "${target_file}"
            chmod +x "${target_file}" 2>/dev/null || true
        fi
        echo -e "  ${GREEN}[OK]${NC} ${display_name}"
        return 0
    else
        rm -f "${temp_file}"
        echo -e "  ${RED}[FAIL]${NC} ${display_name} (网络错误)"
        return 1
    fi
}

# 检查更新
check_updates() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}cfopt 组件更新检查${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    echo -e "${CYAN}[INFO] 正在检查更新...${NC}"
    local remote_versions
    remote_versions=$(get_remote_version)
    
    if [[ -z "${remote_versions}" ]]; then
        echo -e "${RED}[ERROR] 无法获取远程版本信息${NC}"
        echo -e "${YELLOW}提示: 请检查网络连接或 GitHub 访问${NC}"
        echo ""
        read -r -p "按回车键返回..."
        return 1
    fi
    
    local needs_update=false
    local update_list=()
    
    # 逐个检查每个组件
    for component in "${COMPONENTS[@]}"; do
        IFS=':' read -r key local_path remote_path display_name <<< "${component}"
        
        # 获取云端版本号和哈希值
        local remote_version
        remote_version=$(get_component_version "${key}" "${remote_versions}")
        local remote_hash
        remote_hash=$(get_component_hash "${key}" "${remote_versions}")
        
        if [[ -z "${remote_version}" ]] || [[ -z "${remote_hash}" ]]; then
            echo -e "  ${GRAY}[SKIP]${NC} ${display_name} (云端信息缺失)"
            continue
        fi
        
        # 计算本地文件哈希值
        local local_file="${ROOT_DIR}/${local_path}"
        local local_hash=""
        if [[ -f "${local_file}" ]]; then
            local_hash=$(sha256sum "${local_file}" | awk '{print $1}')
        else
            echo -e "  ${YELLOW}[MISS]${NC} ${display_name} (文件不存在)"
            needs_update=true
            update_list+=("${display_name}")
            continue
        fi
        
        # 【策略】对比哈希值
        if [[ "${local_hash}" != "${remote_hash}" ]]; then
            echo -e "  ${YELLOW}[UPDATE]${NC} ${display_name}"
            needs_update=true
            update_list+=("${display_name}")
        else
            echo -e "  ${GREEN}[OK]${NC} ${display_name}"
        fi
    done
    
    echo ""
    
    if [[ "${needs_update}" = false ]]; then
        echo -e "${GREEN}[OK] 所有组件已是最新版本${NC}"
        echo ""
        read -r -p "按回车键返回..."
        return 0
    else
        echo -e "${YELLOW}[INFO] 发现 ${#update_list[@]} 个组件需要更新！${NC}"
        echo ""
        echo -e "${CYAN}需要更新的组件：${NC}"
        
        for item in "${update_list[@]}"; do
            echo -e "  • ${item}"
        done
        
        echo ""
        echo -e "${YELLOW}运行以下命令进行更新：${NC}"
        echo -e "  ${CYAN}bash modules/updater/update.sh update${NC}"
        echo ""
        read -r -p "是否立即执行更新？[Y/n] (默认 Y): " confirm_update
        confirm_update="${confirm_update:-Y}"
        if [[ "${confirm_update}" =~ ^[Yy]$ ]] || [[ -z "${confirm_update}" ]]; then
            perform_update
        fi
        return 0
    fi
}

# 执行更新
perform_update() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}cfopt 组件更新${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 获取版本信息
    local local_versions
    local_versions=$(get_local_version)
    
    echo -e "${CYAN}[INFO] 正在检查更新...${NC}"
    local remote_versions
    remote_versions=$(get_remote_version)
    
    if [[ -z "${remote_versions}" ]]; then
        echo -e "${RED}[ERROR] 无法获取远程版本信息${NC}"
        echo ""
        read -r -p "按回车键返回..."
        return 1
    fi
    
    # 提取版本号用于显示
    local local_version
    local_version=$(get_display_version "${local_versions}")
    local remote_version
    remote_version=$(get_display_version "${remote_versions}")
    
    echo -e "  本地版本: ${GRAY}${local_version}${NC}"
    echo -e "  远程版本: ${CYAN}${remote_version}${NC}"
    echo ""
    
    # 【特殊处理】如果本地版本是 unknown（首次安装或 version.txt 损坏），直接全量更新
    if [[ "${local_version}" == "unknown" ]]; then
        echo -e "${YELLOW}[INFO] 检测到首次安装或版本文件损坏，执行全量更新...${NC}"
        echo ""
    else
        # 版本号相同，无需更新
        if [[ "${local_version}" == "${remote_version}" ]]; then
            echo -e "${GREEN}[OK] 已是最新版本，无需更新${NC}"
            echo ""
            read -r -p "按回车键返回..."
            return 0
        fi
    fi
    
    echo -e "${YELLOW}[INFO] 开始更新...${NC}"
    echo ""
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    
    # 增量更新：只下载哈希值不同的组件
    for component in "${COMPONENTS[@]}"; do
        IFS=':' read -r key local_path remote_path display_name <<< "${component}"
        
        # 获取该组件的预期哈希值
        local expected_hash
        expected_hash=$(get_component_hash "${key}" "${remote_versions}")
        
        if [[ -z "${expected_hash}" ]]; then
            continue
        fi
        
        # 计算本地文件哈希值
        local local_file="${ROOT_DIR}/${local_path}"
        local local_hash=""
        if [[ -f "${local_file}" ]]; then
            local_hash=$(sha256sum "${local_file}" | awk '{print $1}')
        fi
        
        # 对比哈希值，相同则跳过
        if [[ "${local_hash}" == "${expected_hash}" ]]; then
            echo -e "  ${GREEN}[SKIP]${NC} ${display_name} (已是最新)"
            ((skip_count++))
            continue
        fi
        
        # 哈希值不同，执行下载
        if download_file "${local_path}" "${remote_path}" "${display_name}" "${expected_hash}"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    echo ""
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e "${GREEN}更新完成！${NC}"
    echo -e "  成功: ${success_count} 个组件"
    if [[ ${skip_count} -gt 0 ]]; then
        echo -e "  跳过: ${GRAY}${skip_count}${NC} 个组件 (已是最新)"
    fi
    if [[ ${fail_count} -gt 0 ]]; then
        echo -e "  失败: ${RED}${fail_count}${NC} 个组件"
    fi
    echo -e "  新版本: ${CYAN}${remote_version}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 更新 version.txt
    echo "${remote_versions}" > "${VERSION_FILE}"
    echo -e "${GREEN}[OK] 版本号文件已更新${NC}"
    
    # 提示用户重启或重新运行
    if [[ ${success_count} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}[INFO] 建议重新启动以应用所有更新${NC}"
        
        # 如果更新了 updater.sh，给出明确提示（cfopt.sh 直接覆盖，无需特殊处理）
        if [[ -f "${ROOT_DIR}/modules/updater/update.sh.new" ]]; then
            echo -e "${CYAN}注意: 以下组件将在下次运行时自动应用：${NC}"
            echo -e "  • 更新组件 (updater.sh)"
        fi
    fi
    
    echo ""
    read -r -p "按回车键返回..."
    return 0
}

# 显示帮助
show_help() {
    clear
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}cfopt 更新工具${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${CYAN}用法:${NC}"
    echo -e "  bash modules/updater/update.sh [command]"
    echo ""
    echo -e "${CYAN}命令:${NC}"
    echo -e "  check   - 检查是否有可用更新"
    echo -e "  update  - 执行更新操作"
    echo -e "  help    - 显示此帮助信息"
    echo ""
    echo -e "${CYAN}示例:${NC}"
    echo -e "  bash modules/updater/update.sh check"
    echo -e "  bash modules/updater/update.sh update"
    echo ""
    read -r -p "按回车键返回..."
}

# 执行主函数
main() {
    # 【自动应用】检查是否有待应用的 updater.sh.new
    local updater_new="${ROOT_DIR}/modules/updater/update.sh.new"
    if [[ -f "${updater_new}" ]]; then
        echo -e "${CYAN}[INFO] 检测到更新版本的 updater.sh，正在应用...${NC}"
        mv "${updater_new}" "${ROOT_DIR}/modules/updater/update.sh"
        chmod +x "${ROOT_DIR}/modules/updater/update.sh"
        echo -e "${GREEN}[OK] updater.sh 已更新！${NC}"
        echo ""
    fi
    
    local command="${1:-help}"
    
    case "${command}" in
        check)
            check_updates
            ;;
        update)
            perform_update
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}[ERROR] 未知命令: ${command}${NC}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
