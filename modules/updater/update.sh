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
# 镜像源（用于加速国内访问）
MIRROR_BASE_URL="https://hk.gh-proxy.org/https://raw.githubusercontent.com/${GITHUB_REPO}/main"

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

# 获取远程版本号（支持镜像源回退）
get_remote_version() {
    local remote_version
    
    # 尝试原始 URL
    remote_version=$(curl -s --max-time 10 "${RAW_BASE_URL}/version.txt" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "${remote_version}" ]]; then
        echo "${remote_version}"
        return 0
    fi
    
    # 尝试镜像源
    remote_version=$(curl -s --max-time 10 "${MIRROR_BASE_URL}/version.txt" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "${remote_version}" ]]; then
        echo "${remote_version}"
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

# 下载单个文件（支持镜像源回退）
download_file() {
    local local_path="$1"
    local remote_path="$2"
    local display_name="$3"
    
    local target_file="${ROOT_DIR}/${local_path}"
    local temp_file
    temp_file=$(mktemp)
    
    # 【特殊处理】updater.sh 自身：下载到 .new 文件，避免覆盖正在运行的脚本
    if [[ "${remote_path}" = "modules/updater/update.sh" ]]; then
        temp_file="${ROOT_DIR}/modules/updater/update.sh.new"
    fi
    
    # 尝试使用原始 URL 下载
    local full_url="${RAW_BASE_URL}/${remote_path}"
    local download_success=false
    
    echo -e "  ${CYAN}[INFO]${NC} 正在下载 ${display_name}..."
    
    if curl -s --max-time 30 -o "${temp_file}" "${full_url}" 2>/dev/null; then
        # 验证下载的文件非空且有效
        if [[ -s "${temp_file}" ]]; then
            # 检查是否为 HTML 错误页
            if ! grep -qi "<html\|404 Not Found\|403 Forbidden" "${temp_file}" 2>/dev/null; then
                download_success=true
            fi
        fi
    fi
    
    # 如果原始 URL 失败，尝试镜像源
    if [[ "${download_success}" = false ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} 原始地址失败，尝试镜像源..."
        local mirror_url="${MIRROR_BASE_URL}/${remote_path}"
        rm -f "${temp_file}"
        temp_file=$(mktemp)
        
        if curl -s --max-time 30 -o "${temp_file}" "${mirror_url}" 2>/dev/null; then
            if [[ -s "${temp_file}" ]]; then
                if ! grep -qi "<html\|404 Not Found\|403 Forbidden" "${temp_file}" 2>/dev/null; then
                    download_success=true
                fi
            fi
        fi
    fi
    
    # 处理下载结果
    if [[ "${download_success}" = true ]]; then
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
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}cfopt 更新检查 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 获取版本信息
    local local_version
    local_version=$(get_local_version)
    
    echo -e "${CYAN}正在检查更新...${NC}"
    local remote_version
    remote_version=$(get_remote_version)
    
    if [[ -z "${remote_version}" ]]; then
        echo -e "${RED}[ERROR] 无法获取远程版本信息${NC}"
        echo -e "${YELLOW}提示: 请检查网络连接或 GitHub 访问${NC}"
        return 1
    fi
    
    echo -e "  本地版本: ${GRAY}${local_version}${NC}"
    echo -e "  远程版本: ${CYAN}${remote_version}${NC}"
    echo ""
    
    if [[ "${local_version}" == "${remote_version}" ]]; then
        echo -e "${GREEN}[OK] 已是最新版本${NC}"
        return 0
    else
        echo -e "${YELLOW}[INFO] 发现新版本！${NC}"
        echo ""
        echo -e "${CYAN}可更新的组件：${NC}"
        
        for component in "${COMPONENTS[@]}"; do
            IFS=':' read -r key local_path remote_path display_name <<< "${component}"
            echo -e "  • ${display_name}"
        done
        
        echo ""
        echo -e "${YELLOW}运行以下命令进行更新：${NC}"
        echo -e "  ${CYAN}bash ${ROOT_DIR}/modules/updater/update.sh update${NC}"
        return 0
    fi
}

# 执行更新
perform_update() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}cfopt 自动更新 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 获取版本信息
    local local_version
    local_version=$(get_local_version)
    
    echo -e "${CYAN}正在检查更新...${NC}"
    local remote_version
    remote_version=$(get_remote_version)
    
    if [[ -z "${remote_version}" ]]; then
        echo -e "${RED}[ERROR] 无法获取远程版本信息${NC}"
        return 1
    fi
    
    echo -e "  本地版本: ${GRAY}${local_version}${NC}"
    echo -e "  远程版本: ${CYAN}${remote_version}${NC}"
    echo ""
    
    if [[ "${local_version}" == "${remote_version}" ]]; then
        echo -e "${GREEN}[OK] 已是最新版本，无需更新${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}[INFO] 开始更新...${NC}"
    echo ""
    
    local success_count=0
    local fail_count=0
    
    # 更新所有组件
    for component in "${COMPONENTS[@]}"; do
        IFS=':' read -r key local_path remote_path display_name <<< "${component}"
        
        if download_file "${local_path}" "${remote_path}" "${display_name}"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}更新完成！${NC}"
    echo -e "  成功: ${success_count} 个组件"
    if [[ ${fail_count} -gt 0 ]]; then
        echo -e "  失败: ${RED}${fail_count}${NC} 个组件"
    fi
    echo -e "  新版本: ${CYAN}${remote_version}${NC}"
    echo ""
    
    # 更新 version.txt
    echo "${remote_version}" > "${VERSION_FILE}"
    echo -e "${GREEN}[OK] 版本号文件已更新${NC}"
    
    # 提示用户重启或重新运行
    if [[ ${success_count} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}[INFO] 建议重新启动以应用所有更新${NC}"
        
        # 如果更新了 cfopt.sh 或 updater.sh，给出明确提示
        if [[ -f "${INSTALL_DIR}/cfopt.sh.new" ]] || [[ -f "${ROOT_DIR}/modules/updater/update.sh.new" ]]; then
            echo -e "${CYAN}注意: 以下组件将在下次运行时自动应用：${NC}"
            [[ -f "${INSTALL_DIR}/cfopt.sh.new" ]] && echo -e "  • 主程序 (cfopt.sh)"
            [[ -f "${ROOT_DIR}/modules/updater/update.sh.new" ]] && echo -e "  • 更新组件 (updater.sh)"
        fi
    fi
    
    return 0
}

# 显示帮助
show_help() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}cfopt 更新工具 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
