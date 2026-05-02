#!/bin/bash
# ==============================================================================
# cfopt - 部署辅助工具 (Deploy Script)
# Version: 1.0
# Description: 自动化计算项目组件 SHA256 并生成版本索引文件 (version.txt)
# Usage: ./deploy.sh
# ==============================================================================

set -e

# --- 终端颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 解析项目根目录
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${YELLOW}cfopt - 版本哈希生成器 v1.0${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

# --- 版本文件生成逻辑 ---
echo -e "${CYAN}[INFO] 正在计算文件哈希值并生成 version.txt...${NC}"

generate_version_file() {
    local output_file="$LOCAL_DIR/version.txt"
    
    # 写入 version.txt 头部信息
    echo "# ============================================================" > "$output_file"
    echo "# Cloudflare IP 优选工具 - 统一版本管理中心" >> "$output_file"
    echo "# 格式: KEY=VERSION:SHA256" >> "$output_file"
    echo "# 说明：由 deploy.sh 自动生成，请勿手动修改" >> "$output_file"
    echo "# ============================================================" >> "$output_file"
    echo "" >> "$output_file"

    # 定义需要追踪的文件列表 (白名单机制)
    declare -A FILES=(
        ["CFOPT"]="cfopt.sh"
        ["CF_IP_MENU"]="modules/cf-ip/menu.sh"
        ["CF_IP_CORE"]="modules/cf-ip/core.sh"
        ["CF_DNS_CORE"]="modules/cf-dns/core.sh"
        ["CF_DNS_SETUP"]="modules/cf-dns/setup.sh"
        ["DNSPOD_CORE"]="modules/dnspod-dns/core.sh"
        ["DNSPOD_SETUP"]="modules/dnspod-dns/setup.sh"
        ["SCHEDULER_RUN"]="modules/scheduler/run.sh"
        ["IP_SYNC"]="modules/ip-sync/sync.sh"
    )

    for KEY in "${!FILES[@]}"; do
        local file="${FILES[$KEY]}"
        if [ -f "$LOCAL_DIR/$file" ]; then
            # 1. 从脚本中提取 SCRIPT_VERSION
            local ver=$(grep -m1 "^SCRIPT_VERSION=" "$LOCAL_DIR/$file" | awk -F'"' '{print $2}')
            [ -z "$ver" ] && ver="0.1"
            
            # 2. 计算 SHA256 哈希值
            local hash=$(sha256sum "$LOCAL_DIR/$file" | awk '{print $1}')
            
            # 3. 写入文件 (格式: KEY=VERSION:HASH)
            echo "${KEY}=${ver}:${hash}" >> "$output_file"
            echo -e "  ${CYAN}[INFO]${NC} $KEY: v$ver"
        else
            echo -e "  ${YELLOW}[WARN]${NC} $KEY: 文件不存在 ($file)"
        fi
    done
    
    echo -e "\n${GREEN}[OK] version.txt 已更新，请同步至服务器。${NC}"
}

generate_version_file

echo ""
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${GREEN}[OK] 生成完成！${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
