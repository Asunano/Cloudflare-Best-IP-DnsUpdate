#!/bin/bash
# ==============================================================================
# cfopt - Cloudflare DNS 批量更新器 (Batch Updater)
# Version: 0.1
# Description: 遍历 conf/cf-dns/ 目录中的所有域名配置，依次执行 DNS 更新
# Usage: bash modules/cf-dns/batch.sh
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
NC='\033[0m'

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
echo -e " ${CYAN}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

# ==================== 配置目录 ====================
CONFIG_DIR="${ROOT_DIR}/conf/cf-dns"

# ==================== 收集所有配置文件 ====================
declare -a CONFIG_FILES=()

# 检查多域名配置目录
if [[ -d "$CONFIG_DIR" ]]; then
    while IFS= read -r -d '' config_file; do
        CONFIG_FILES+=("$config_file")
    done < <(find "$CONFIG_DIR" -name "*.json" -type f -print0 2>/dev/null)
fi

# 如果没有找到配置，退出
if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] 未找到任何 Cloudflare DNS 配置文件${NC}"
    echo -e "${YELLOW}提示:${NC} 请先运行配置向导或手动创建配置文件"
    exit 1
fi

echo -e "${GREEN}[OK] 找到 ${#CONFIG_FILES[@]} 个域名配置${NC}"
echo ""

# ==================== 批量执行更新 ====================
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for config_file in "${CONFIG_FILES[@]}"; do
    domain_name=$(basename "$config_file" .json)
    
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    echo -e " ${YELLOW}正在处理域名: ${domain_name}${NC}"
    echo -e "${CYAN}+------------------------------------------------------------+${NC}"
    
    # 检查配置文件是否启用
    if command -v jq &>/dev/null; then
        enabled=$(jq -r '.enabled // false' "$config_file" 2>/dev/null)
        if [[ "$enabled" != "true" ]]; then
            echo -e "${YELLOW}[SKIP] 域名 ${domain_name} 已禁用 (enabled=false)${NC}"
            ((SKIP_COUNT++))
            echo ""
            continue
        fi
    fi
    
    # 执行单个域名的更新
    echo -e "${CYAN}[INFO] 启动 CF-DNS 更新进程...${NC}"
    if CF_DNS_DOMAIN="$domain_name" bash "${ROOT_DIR}/modules/cf-dns/core.sh" "$config_file"; then
        echo -e "${GREEN}[OK] 域名 ${domain_name} 更新成功${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}[FAIL] 域名 ${domain_name} 更新失败${NC}"
        ((FAIL_COUNT++))
    fi
    
    echo ""
done

# ==================== 汇总报告 ====================
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${YELLOW}批量更新完成报告${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " 总计配置: ${#CONFIG_FILES[@]}"
echo -e " ${GREEN}成功: ${SUCCESS_COUNT}${NC}"
echo -e " ${RED}失败: ${FAIL_COUNT}${NC}"
echo -e " ${YELLOW}跳过: ${SKIP_COUNT}${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
else
    exit 0
fi
