#!/bin/bash
# ==============================================================================
# cfopt - 自动更新组件 (Auto Updater)
# Version: 0.1
# Description: 负责检查和更新 cfopt 所有组件，包括主程序自身
# Usage: bash modules/updater/update.sh [check|update]
# ==============================================================================
# 【安全增强】启用严格模式：命令失败立即退出、未定义变量报错、管道失败整体失败
set -euo pipefail

SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 加载公共函数库 ====================
if [[ -f "${ROOT_DIR}/lib/common.sh" ]]; then
    # shellcheck source=../../lib/common.sh
    source "${ROOT_DIR}/lib/common.sh"
fi

# 【关键修复】检查 common.sh 是否成功加载
if ! declare -f log_info >/dev/null 2>&1; then
    # common.sh 未加载，定义临时的颜色变量（完整定义，避免 set -u 错误）
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    GRAY='\033[0;90m'
    NC='\033[0m'
    echo -e "${RED}[ERROR] 无法加载公共函数库: ${ROOT_DIR}/lib/common.sh${NC}" >&2
    echo -e "${YELLOW}[INFO] 请检查文件是否存在且可读${NC}" >&2
    exit 1
fi

# 【修复】检测是否为 TTY 终端，非 TTY 环境禁用颜色输出
if [[ -t 1 ]]; then
    # TTY 终端，启用颜色
    :
else
    # 非 TTY 环境（管道、重定向），禁用颜色
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    GRAY=''
    NC=''
fi

# ==================== 全局临时文件管理 ====================
# 【修复】记录所有临时文件，确保脚本退出时自动清理
declare -a TEMP_FILES=()

# 注册清理函数
cleanup_temp_files() {
    # 【修复】Bash 4.3 及以下版本中，空数组在 set -u 下会报错
    [[ ${#TEMP_FILES[@]} -eq 0 ]] && return 0
    
    for temp_file in "${TEMP_FILES[@]}"; do
        # 【修复】排除 update.sh.new 和 cfopt.sh.new，这些是需要保留的文件
        if [[ "${temp_file}" != *".sh.new" ]]; then
            rm -f "${temp_file}" 2>/dev/null || true
        fi
    done
}

# 脚本退出时自动清理
trap cleanup_temp_files EXIT INT TERM

# ==================== 配置 ====================
VERSION_FILE="${ROOT_DIR}/version.txt"
GITHUB_REPO="Asunano/Cloudflare-Best-IP-DnsUpdate"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
# 自定义镜像源（优先使用）
MIRROR_BASE_URL="https://mirror.drxian.qzz.io/scripts/Cloudflare-Best-IP-DnsUpdate"

# ==================== 退出码定义 ====================
EXIT_SUCCESS=0        # 成功
EXIT_NETWORK_ERROR=1  # 网络错误
EXIT_PERMISSION_ERROR=2  # 权限错误
EXIT_VALIDATION_ERROR=3  # 校验失败
EXIT_MISSING_TOOL=4   # 缺少必要工具

# 定义需要更新的组件映射
# 格式: "KEY:本地路径:远程相对路径:显示名称"
# 【修复】动态发现所有组件，避免硬编码
declare -a COMPONENTS=()

# 1. 添加主程序入口
COMPONENTS+=("CFOPT:cfopt.sh:cfopt.sh:主程序入口")

# 2. 添加公共函数库
if [[ -f "${ROOT_DIR}/lib/common.sh" ]]; then
    COMPONENTS+=("COMMON_LIB:lib/common.sh:lib/common.sh:公共函数库")
fi

# 3. 动态扫描 modules 目录下的所有 .sh 文件
while IFS= read -r script_file; do
    # 跳过 updater 自身（已经在前面单独处理）
    if [[ "$script_file" == "modules/updater/update.sh" ]]; then
        continue
    fi
    
    # 提取模块名和文件名
    module_dir=$(dirname "$script_file")
    filename=$(basename "$script_file")
    
    # 生成显示名称（根据文件类型）
    case "$filename" in
        core.sh)      display_name="$(basename "$module_dir") 核心" ;;
        setup.sh)     display_name="$(basename "$module_dir") 配置向导" ;;
        menu.sh)      display_name="$(basename "$module_dir") 管理菜单" ;;
        run.sh)       display_name="$(basename "$module_dir") 调度器" ;;
        sync.sh)      display_name="$(basename "$module_dir") 同步工具" ;;
        *)            display_name="$filename" ;;
    esac
    
    # 生成唯一 KEY（大写 + 下划线）
    key=$(echo "$(basename "$module_dir")_${filename%.sh}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    # 【新增】修正自动生成的 KEY 与 version.txt 不匹配的问题
    case "${key}" in
        DNSPOD_DNS_CORE)    key="DNSPOD_CORE" ;;
        DNSPOD_DNS_SETUP)   key="DNSPOD_SETUP" ;;
        IP_SYNC_SYNC)       key="IP_SYNC" ;;
        QUICK_DEPLOY_SETUP) key="QUICK_DEPLOY" ;;
    esac

    # 添加到组件列表
    COMPONENTS+=("${key}:${script_file}:${script_file}:${display_name}")
done < <(cd "${ROOT_DIR}" && find modules -name "*.sh" -type f | sort)

# 4. 添加 updater 自身（最后更新，确保安全）
COMPONENTS+=("UPDATER:modules/updater/update.sh:modules/updater/update.sh:自动更新组件")

# ==================== 核心函数 ====================

# 获取远程版本信息（镜像源优先）
get_remote_version() {
    local remote_version
    local temp_version_file
    temp_version_file=$(mktemp /tmp/cfopt-updater.XXXXXX)
    # 【修复】设置严格的文件权限（仅所有者可读写），防止版本信息泄露
    chmod 600 "${temp_version_file}" 2>/dev/null || true
    TEMP_FILES+=("${temp_version_file}")  # 【修复】注册临时文件
    
    # 【优先】尝试镜像源（国内加速）
    # 【修复】添加 -L 参数支持重定向，-f 参数静默失败
    if curl -sLf --max-time 10 -o "${temp_version_file}" "${MIRROR_BASE_URL}/version.txt" 2>/dev/null; then
        # 【修复】校验文件内容，确保不是 HTML 错误页面
        if [[ -s "${temp_version_file}" ]]; then
            local first_line
            first_line=$(head -1 "${temp_version_file}" 2>/dev/null)
            # 检查是否为有效的 version.txt（以注释或 KEY= 开头）
            if [[ "${first_line}" == "#"* ]] || [[ "${first_line}" == *"="* ]]; then
                remote_version=$(cat "${temp_version_file}")
                # 【修复】不再手动删除，由 cleanup_temp_files 统一处理
                echo "${remote_version}"
                return ${EXIT_SUCCESS}
            fi
        fi
    fi
    
    # 【备用】尝试官方源
    if curl -sLf --max-time 10 -o "${temp_version_file}" "${RAW_BASE_URL}/version.txt" 2>/dev/null; then
        if [[ -s "${temp_version_file}" ]]; then
            local first_line
            first_line=$(head -1 "${temp_version_file}" 2>/dev/null)
            if [[ "${first_line}" == "#"* ]] || [[ "${first_line}" == *"="* ]]; then
                remote_version=$(cat "${temp_version_file}")
                # 【修复】不再手动删除，由 cleanup_temp_files 统一处理
                echo "${remote_version}"
                return ${EXIT_SUCCESS}
            fi
        fi
    fi
    
    # 【修复】不再手动删除，由 cleanup_temp_files 统一处理
    echo ""
    return ${EXIT_NETWORK_ERROR}
}

# 从 version.txt 中获取指定组件的哈希值
get_component_hash() {
    local component_key="$1"
    local version_content="$2"
    
    # 【优化】使用精确匹配，避免重复过滤
    # 格式: KEY=VERSION:HASH 或 KEY=HASH
    local hash_line
    hash_line=$(echo "${version_content}" | grep -F "${component_key}=" | head -1)
    
    if [[ -n "${hash_line}" ]]; then
        # 确保是精确匹配（行首）
        if [[ "${hash_line}" != "${component_key}="* ]]; then
            echo ""
            return 1
        fi
        
        # 提取等号后的内容
        local value_part
        value_part="${hash_line#*=}"
        
        # 判断格式：包含冒号则是 VERSION:HASH，否则直接是 HASH
        if [[ "${value_part}" == *":"* ]]; then
            # 格式1: VERSION:HASH，提取第二个字段
            echo "${value_part##*:}"
        else
            # 格式2: 直接是 HASH
            echo "${value_part}"
        fi
        return ${EXIT_SUCCESS}
    fi
    
    echo ""
    return ${EXIT_VALIDATION_ERROR}
}

# 从 version.txt 中获取指定组件的版本号
get_component_version() {
    local component_key="$1"
    local version_content="$2"
    
    # 【优化】使用精确匹配，避免重复过滤
    # 格式: KEY=VERSION:HASH 或 KEY=HASH
    local version_line
    version_line=$(echo "${version_content}" | grep -F "${component_key}=" | head -1)
    
    if [[ -n "${version_line}" ]]; then
        # 确保是精确匹配（行首）
        if [[ "${version_line}" != "${component_key}="* ]]; then
            echo ""
            return 1
        fi
        
        # 提取等号后的内容
        local value_part
        value_part="${version_line#*=}"
        
        # 判断格式：包含冒号则是 VERSION:HASH，否则直接是 HASH
        if [[ "${value_part}" == *":"* ]]; then
            # 格式1: VERSION:HASH，提取第一个字段
            echo "${value_part%%:*}"
        else
            # 格式2: 直接是 HASH，无版本号信息
            echo "unknown"
        fi
        return ${EXIT_SUCCESS}
    fi
    
    echo ""
    return ${EXIT_VALIDATION_ERROR}
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

# ==================== 【修复】下载重试函数（提取为顶级函数） ====================
# 【修复】从 download_file() 中提取，避免嵌套函数在某些 bash 版本中的变量作用域问题
# 参数: $1=url, $2=output_file
# 返回: 0=成功, 1=失败
download_with_retry() {
    local url="$1"
    local output_file="$2"
    local max_retries=3
    local retry_count=0

    while [[ ${retry_count} -lt ${max_retries} ]]; do
        if [[ ${retry_count} -gt 0 ]]; then
            echo -e "    ${GRAY}[重试] 第 ${retry_count}/${max_retries} 次尝试...${NC}" >&2
            sleep 2
        fi

        local http_code=""
        http_code=$(curl -sLf --max-time 30 \
            -w '%{http_code}' \
            -o "${output_file}" \
            "${url}" 2>/dev/null) || true
        http_code="${http_code:-000}"

        # 4xx/5xx 不重试
        if [[ "${http_code}" =~ ^[45] ]]; then
            echo -e "    ${RED}[ERROR] HTTP ${http_code} — 服务端拒绝${NC}" >&2
            rm -f "${output_file}"
            return 1
        fi

        # 000 = 网络层失败，重试
        if [[ "${http_code}" == "000" ]]; then
            echo -e "    ${YELLOW}[WARN] 连接失败 (网络层)${NC}" >&2
            retry_count=$((retry_count + 1))
            continue
        fi

        # 200/304 — 验证文件
        if [[ -s "${output_file}" ]]; then
            local first_line
            first_line="$(head -1 "${output_file}" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//')"
            if [[ "${first_line}" == "#!"* ]]; then
                return 0
            fi
            local file_size
            file_size=$(wc -c < "${output_file}")
            if [[ ${file_size} -lt 100 ]]; then
                echo -e "    ${YELLOW}[WARN] 文件过小 (${file_size} bytes)${NC}" >&2
            elif grep -qi "^<html\|^<!DOCTYPE" "${output_file}" 2>/dev/null; then
                echo -e "    ${YELLOW}[WARN] 下载到 HTML 页面${NC}" >&2
            else
                return 0
            fi
        fi

        retry_count=$((retry_count + 1))
    done

    echo -e "    ${RED}[ERROR] 下载失败，已重试 ${max_retries} 次${NC}" >&2
    rm -f "${output_file}"
    return 1
}

# 下载单个文件（支持镜像源优先和SHA256校验）
# 【优化】统一退出码规范
download_file() {
    local local_path="$1"
    local remote_path="$2"
    local display_name="$3"
    local expected_hash="${4:-}"  # 可选参数：预期的 SHA256 哈希值
    
    local target_file="${ROOT_DIR}/${local_path}"
    local temp_file
    temp_file=$(mktemp /tmp/cfopt-updater.XXXXXX)
    chmod 600 "${temp_file}"

    # 【特殊处理】updater.sh 自身：下载到 .new 文件，避免覆盖正在运行的脚本
    if [[ "${remote_path}" = "modules/updater/update.sh" ]]; then
        rm -f "${temp_file}"  # 清理原始临时文件，不再需要它
        temp_file="${ROOT_DIR}/modules/updater/update.sh.new"
    else
        TEMP_FILES+=("${temp_file}")  # 只有非 updater 才注册到清理列表
    fi
    
    local download_success=false
    
    echo -e "  ${CYAN}[INFO]${NC} 正在下载 ${display_name}..."
    
    # 【修复】检查目标目录是否有写入权限
    local target_dir
    target_dir=$(dirname "${target_file}")
    
    # 【优化】统一处理：先创建目录，再检查权限
    if [[ ! -d "${target_dir}" ]]; then
        mkdir -p "${target_dir}" 2>/dev/null || {
            echo -e "  ${RED}[FAIL]${NC} ${display_name} (无法创建目录: ${target_dir})"
            rm -f "${temp_file}"
            return ${EXIT_PERMISSION_ERROR}
        }
    fi
    
    # 【修复】目录创建后再次检查权限（避免误报）
    if [[ ! -w "${target_dir}" ]]; then
        echo -e "  ${RED}[FAIL]${NC} ${display_name} (无写入权限: ${target_dir})"
        echo -e "    ${YELLOW}提示: 请检查目录权限或使用 sudo 运行${NC}"
        rm -f "${temp_file}"
        return ${EXIT_PERMISSION_ERROR}
    fi
    
    # 【优先】尝试使用镜像源下载（国内加速）
    local mirror_url="${MIRROR_BASE_URL}/${remote_path}"
    
    # 尝试镜像源
    if download_with_retry "${mirror_url}" "${temp_file}"; then
        download_success=true
    fi
    
    # 【备用】如果镜像源失败，尝试官方源
    if [[ "${download_success}" = false ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} 镜像源失败，尝试官方源..."
        local full_url="${RAW_BASE_URL}/${remote_path}"
        
        # 【修复】从 TEMP_FILES 数组中移除旧的临时文件路径
        local -a new_temp_files=()
        for existing_file in "${TEMP_FILES[@]}"; do
            if [[ "${existing_file}" != "${temp_file}" ]]; then
                new_temp_files+=("${existing_file}")
            fi
        done
        TEMP_FILES=("${new_temp_files[@]}")
        
        rm -f "${temp_file}"

        temp_file=$(mktemp /tmp/cfopt-updater.XXXXXX)
        chmod 600 "${temp_file}"
        TEMP_FILES+=("${temp_file}")

        if download_with_retry "${full_url}" "${temp_file}"; then
            download_success=true
        fi
    fi
    
    # 处理下载结果
    if [[ "${download_success}" = true ]]; then
        # 【强制】SHA256 哈希校验
        if [[ -n "${expected_hash}" ]]; then
            # 【修复】兼容嵌入式系统：优先使用 sha256sum，备用 shasum -a 256
            local actual_hash
            if command -v sha256sum &>/dev/null; then
                actual_hash=$(sha256sum "${temp_file}" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                actual_hash=$(shasum -a 256 "${temp_file}" | awk '{print $1}')
            else
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (缺少哈希校验工具)"
                echo -e "    ${YELLOW}提示: 请安装 coreutils 或 perl-digest-sha${NC}"
                rm -f "${temp_file}"
                return ${EXIT_MISSING_TOOL}
            fi
            
            if [[ "${actual_hash}" != "${expected_hash}" ]]; then
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (哈希校验失败)"
                echo -e "    ${GRAY}预期: ${expected_hash}${NC}"
                echo -e "    ${GRAY}实际: ${actual_hash}${NC}"
                echo -e "    ${YELLOW}可能原因:${NC}"
                echo -e "      1. 网络缓存未刷新，请稍后重试"
                echo -e "      2. 远程文件已被修改，但 version.txt 未更新"
                echo -e "      3. 本地文件被手动修改"
                rm -f "${temp_file}"
                return ${EXIT_VALIDATION_ERROR}
            fi
        fi
        
        # 如果不是 updater.sh 自身，直接移动到目标位置
        if [[ "${remote_path}" != "modules/updater/update.sh" ]]; then
            mv -f "${temp_file}" "${target_file}"
            # 【修复】确保文件有执行权限
            chmod +x "${target_file}" 2>/dev/null || {
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (无法设置执行权限)"
                echo -e "    ${YELLOW}可能原因: 文件系统不支持执行权限或权限不足${NC}"
                return ${EXIT_PERMISSION_ERROR}
            }
        else
            # updater.sh 自身，确保 .new 文件有执行权限
            chmod +x "${temp_file}" 2>/dev/null || true
        fi
        echo -e "  ${GREEN}[OK]${NC} ${display_name}"
        return ${EXIT_SUCCESS}
    else
        rm -f "${temp_file}"
        echo -e "  ${RED}[FAIL]${NC} ${display_name} (网络错误)"
        echo -e "    ${YELLOW}可能原因:${NC}"
        echo -e "      1. 网络连接异常，请检查网络"
        echo -e "      2. GitHub 访问受限，请检查防火墙"
        echo -e "      3. 镜像源暂时不可用，已自动切换到官方源"
        return ${EXIT_NETWORK_ERROR}
    fi
}

# 检查更新
check_updates() {
    # 【修复】非 TTY 环境不执行 clear，避免输出异常字符
    if [[ -t 1 ]]; then
        clear
    fi
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}cfopt 组件更新检查 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    echo -e "${CYAN}[INFO] 正在检查更新...${NC}"
    local remote_versions
    remote_versions=$(get_remote_version)
    
    if [[ -z "${remote_versions}" ]]; then
        echo -e "${RED}[ERROR] 无法获取远程版本信息${NC}"
        echo -e "${YELLOW}提示: 请检查网络连接或 GitHub 访问${NC}"
        echo ""
        # 【修复】非交互式环境直接退出，不等待输入
        if [[ -t 0 ]]; then
            read -r -p "按回车键返回..."
        fi
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
            # 【修复】兼容嵌入式系统：优先使用 sha256sum，备用 shasum -a 256
            if command -v sha256sum &>/dev/null; then
                local_hash=$(sha256sum "${local_file}" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                local_hash=$(shasum -a 256 "${local_file}" | awk '{print $1}')
            else
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (缺少哈希校验工具)"
                echo -e "    ${YELLOW}提示: 请安装 coreutils 或 perl-digest-sha${NC}"
                needs_update=true
                update_list+=("${display_name}")
                continue
            fi
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
        # 【修复】非交互式环境直接退出
        if [[ -t 0 ]]; then
            read -r -p "按回车键返回..."
        fi
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
        # 【修复】非交互式环境自动执行更新
        if [[ -t 0 ]]; then
            read -r -p "是否立即执行更新？[Y/n] (默认 Y): " confirm_update
        else
            confirm_update="Y"  # 非交互式环境默认执行
        fi
        confirm_update="${confirm_update:-Y}"
        if [[ "${confirm_update}" =~ ^[Yy]$ ]] || [[ -z "${confirm_update}" ]]; then
            perform_update
        fi
        return 0
    fi
}

# 执行更新
perform_update() {
    # 【修复】非 TTY 环境不执行 clear，避免输出异常字符
    if [[ -t 1 ]]; then
        clear
    fi
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}cfopt 组件更新 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
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
        # 【修复】非交互式环境直接退出
        if [[ -t 0 ]]; then
            read -r -p "按回车键返回..."
        fi
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
        # 版本号不同，直接全量更新
        if [[ "${local_version}" != "${remote_version}" ]]; then
            echo -e "${YELLOW}[INFO] 发现新版本！${NC}"
            echo ""
        else
            # 版本号相同，但仍需检查每个组件的哈希值
            echo -e "${CYAN}[INFO] 版本号相同，正在检查文件完整性...${NC}"
        fi
    fi
    
    echo -e "${YELLOW}[INFO] 开始更新...${NC}"
    echo ""
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    
    # 增量更新：只下载哈希值不同的组件
    local need_restart=false
    local cfopt_updated=false  # 【修复】跟踪 cfopt.sh 是否更新
    
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
            # 【修复】兼容嵌入式系统：优先使用 sha256sum，备用 shasum -a 256
            if command -v sha256sum &>/dev/null; then
                local_hash=$(sha256sum "${local_file}" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                local_hash=$(shasum -a 256 "${local_file}" | awk '{print $1}')
            else
                echo -e "  ${RED}[FAIL]${NC} ${display_name} (缺少哈希校验工具)"
                echo -e "    ${YELLOW}提示: 请安装 coreutils 或 perl-digest-sha${NC}"
                return ${EXIT_MISSING_TOOL}
            fi
        fi
        
        # 对比哈希值，相同则跳过
        if [[ "${local_hash}" == "${expected_hash}" ]]; then
            echo -e "  ${GREEN}[SKIP]${NC} ${display_name} (已是最新)"
            skip_count=$((skip_count + 1))
            continue
        fi
        
        # 【特殊处理】cfopt.sh 需要更新时，标记并延迟处理
        if [[ "${remote_path}" = "cfopt.sh" ]]; then
            # 【修复】确保目录存在
            local target_dir
            target_dir=$(dirname "${ROOT_DIR}/cfopt.sh.new")
            if [[ ! -d "${target_dir}" ]]; then
                mkdir -p "${target_dir}" 2>/dev/null || {
                    echo -e "  ${RED}[FAIL]${NC} ${display_name} (无法创建目录)"
                    fail_count=$((fail_count + 1))
                    continue
                }
            fi
            
            echo -e "  ${CYAN}[INFO]${NC} ${display_name} (将在重启后应用)"
            need_restart=true
            cfopt_updated=true  # 【修复】标记 cfopt.sh 已更新
            # 先下载到 .new 文件
            if download_file "${local_path}.new" "${remote_path}" "${display_name}" "${expected_hash}"; then
                success_count=$((success_count + 1))  # 【修复】计入成功计数
            else
                fail_count=$((fail_count + 1))
                cfopt_updated=false  # 【修复】下载失败，取消标记
            fi
            continue
        fi
        
        # 【特殊处理】updater.sh 需要更新时，计入统计
        if [[ "${remote_path}" = "modules/updater/update.sh" ]]; then
            if download_file "${local_path}" "${remote_path}" "${display_name}" "${expected_hash}"; then
                success_count=$((success_count + 1))  # 【修复】计入成功计数
            else
                fail_count=$((fail_count + 1))
            fi
            continue
        fi
        
        # 哈希值不同，执行下载
        if download_file "${local_path}" "${remote_path}" "${display_name}" "${expected_hash}"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
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
    if [[ "${cfopt_updated}" = true ]]; then
        echo -e "  待应用: ${CYAN}1${NC} 个组件 (cfopt.sh，需重启)"
    fi
    echo -e "  新版本: ${CYAN}${remote_version}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo ""
    
    # 更新 version.txt
    # 【修复】添加容错处理，检查写入权限
    if echo "${remote_versions}" > "${VERSION_FILE}" 2>/dev/null; then
        echo -e "${GREEN}[OK] 版本号文件已更新${NC}"
    else
        echo -e "${RED}[WARN] 版本号文件更新失败${NC}"
        echo -e "  ${YELLOW}可能原因: 无写入权限或磁盘空间不足${NC}"
        echo -e "  ${YELLOW}建议: 手动执行 'chmod 644 ${VERSION_FILE}' 后重试${NC}"
    fi
    
    # 【修复】清理残留文件
    rm -f "${ROOT_DIR}/.restart_needed" 2>/dev/null || true
    
    # 提示用户重启或重新运行
    if [[ ${success_count} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}[INFO] 建议重新启动以应用所有更新${NC}"
        
        # 如果更新了 updater.sh，给出明确提示
        if [[ -f "${ROOT_DIR}/modules/updater/update.sh.new" ]]; then
            echo -e "${CYAN}注意: 以下组件将在下次运行时自动应用：${NC}"
            echo -e "  • 更新组件 (updater.sh)"
        fi
    fi
    
    # 【关键】如果 cfopt.sh 需要更新，标记并退出
    if [[ "${need_restart}" = true ]] && [[ -f "${ROOT_DIR}/cfopt.sh.new" ]]; then
        echo ""
        echo -e "${CYAN}[INFO] 主程序已更新${NC}"
        
        # 移动 .new 文件覆盖原文件
        mv -f "${ROOT_DIR}/cfopt.sh.new" "${ROOT_DIR}/cfopt.sh"
        chmod +x "${ROOT_DIR}/cfopt.sh"
        
        echo -e "${GREEN}[OK] cfopt.sh 已更新到最新版本${NC}"
        echo ""
        echo -e "${YELLOW}[INFO] 请重新启动 cfopt 以应用新版本${NC}"
        echo -e "${GRAY}(如果您是通过 'cfopt' 命令运行的，建议重新执行该命令)${NC}"
        echo ""
        
        # 【修复】不再使用 exec，而是创建标记文件通知父进程
        # 这样避免了在子shell中exec导致的进程套娃问题
        touch "${ROOT_DIR}/.restart_needed"
        
        # 【修复】清理 updater.sh 的 .new 文件（cfopt.sh.new 已被 mv 移走，无需清理）
        rm -f "${ROOT_DIR}/modules/updater/update.sh.new" 2>/dev/null || true
        
        # 【修复】非交互式环境跳过 read，防止 set -e 触发退出
        if [[ -t 0 ]]; then
            read -r -p "按回车键返回..."
        fi
        exit 0
    fi
    
    echo ""
    # 【修复】非交互式环境直接退出
    if [[ -t 0 ]]; then
        read -r -p "按回车键返回..."
    fi
    return 0
}

# 显示帮助
show_help() {
    # 【修复】非 TTY 环境不执行 clear，避免输出异常字符
    if [[ -t 1 ]]; then
        clear
    fi
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${BOLD}${YELLOW}cfopt 更新工具 v${SCRIPT_VERSION}${NC}"
    echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
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
    # 【修复】非交互式环境直接退出
    if [[ -t 0 ]]; then
        read -r -p "按回车键返回..."
    fi
}

# 执行主函数
main() {
    # 【自动应用】检查是否有待应用的 updater.sh.new
    local updater_new="${ROOT_DIR}/modules/updater/update.sh.new"
    if [[ -f "${updater_new}" ]]; then
        echo -e "${CYAN}[INFO] 检测到更新版本的 updater.sh，正在应用...${NC}"
        mv -f "${updater_new}" "${ROOT_DIR}/modules/updater/update.sh"
        chmod +x "${ROOT_DIR}/modules/updater/update.sh"
        echo -e "${GREEN}[OK] updater.sh 已更新！${NC}"
        echo ""
        
        # 【关键】应用后立即重启，使用新版本执行
        echo -e "${YELLOW}[INFO] 正在使用新版本重新启动...${NC}"
        exec bash "${ROOT_DIR}/modules/updater/update.sh" "$@"
        exit 0  # 这行不会执行，作为保险
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
