#!/bin/bash
# ==============================================================================
# cfopt - 更新诊断工具
# Description: 检查更新机制是否正常工作
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}+============================================================+${NC}"
echo -e " ${YELLOW}cfopt 更新诊断工具${NC}"
echo -e "${CYAN}+============================================================+${NC}"
echo ""

# 检查项目根目录
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo -e "${CYAN}[1/5] 检查项目路径${NC}"
echo -e "  项目根目录: ${GREEN}${ROOT_DIR}${NC}"
echo ""

# 检查version.txt
echo -e "${CYAN}[2/5] 检查 version.txt${NC}"
if [[ -f "${ROOT_DIR}/version.txt" ]]; then
    echo -e "  ${GREEN}[OK]${NC} version.txt 存在"
    
    # 检查关键组件的哈希值
    echo ""
    echo -e "  ${YELLOW}关键组件哈希值：${NC}"
    for key in UPDATER CFOPT SCHEDULER_RUN CF_DNS_CORE CF_IP_CORE; do
        hash=$(grep "^${key}=" "${ROOT_DIR}/version.txt" | cut -d':' -f2)
        echo -e "    ${key}: ${hash}"
    done
else
    echo -e "  ${RED}[ERROR]${NC} version.txt 不存在"
fi
echo ""

# 检查updater.sh
echo -e "${CYAN}[3/5] 检查 updater.sh${NC}"
if [[ -f "${ROOT_DIR}/modules/updater/update.sh" ]]; then
    echo -e "  ${GREEN}[OK]${NC} updater.sh 存在"
    
    # 检查BOLD变量
    if grep -q "^BOLD=" "${ROOT_DIR}/modules/updater/update.sh"; then
        echo -e "  ${GREEN}[OK]${NC} BOLD变量已定义"
    else
        echo -e "  ${RED}[WARN]${NC} BOLD变量未定义（可能导致标题栏显示错误）"
    fi
else
    echo -e "  ${RED}[ERROR]${NC} updater.sh 不存在"
fi
echo ""

# 检查scheduler/run.sh
echo -e "${CYAN}[4/5] 检查 scheduler/run.sh${NC}"
if [[ -f "${ROOT_DIR}/modules/scheduler/run.sh" ]]; then
    echo -e "  ${GREEN}[OK]${NC} scheduler/run.sh 存在"
    
    # 检查BOLD变量
    if grep -q "^BOLD=" "${ROOT_DIR}/modules/scheduler/run.sh"; then
        echo -e "  ${GREEN}[OK]${NC} BOLD变量已定义"
    else
        echo -e "  ${RED}[WARN]${NC} BOLD变量未定义（可能导致标题栏显示错误）"
    fi
    
    # 检查标题栏格式
    if grep -q "Cloudflare-Best-IP-DnsUpdate" "${ROOT_DIR}/modules/scheduler/run.sh"; then
        echo -e "  ${GREEN}[OK]${NC} 标题栏格式正确"
    else
        echo -e "  ${RED}[WARN]${NC} 标题栏格式可能不正确"
    fi
else
    echo -e "  ${RED}[ERROR]${NC} scheduler/run.sh 不存在"
fi
echo ""

# 检查网络连接
echo -e "${CYAN}[5/5] 检查网络连接${NC}"
if curl -s --max-time 5 "https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main/version.txt" > /dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC} 可以访问 GitHub"
else
    echo -e "  ${RED}[WARN]${NC} 无法访问 GitHub（可能需要使用镜像源）"
fi
echo ""

echo -e "${CYAN}+============================================================+${NC}"
echo -e " ${YELLOW}诊断完成！${NC}"
echo -e "${CYAN}+============================================================+${NC}"
echo ""

# 提供建议
echo -e "${CYAN}建议操作：${NC}"
echo ""
echo -e "1. ${YELLOW}如果所有检查都通过${NC}："
echo -e "   执行 ${CYAN}bash ${ROOT_DIR}/modules/updater/update.sh update${NC} 进行更新"
echo ""
echo -e "2. ${YELLOW}如果发现BOLD变量未定义${NC}："
echo -e "   需要重新安装或手动更新模块文件"
echo ""
echo -e "3. ${YELLOW}如果无法访问GitHub${NC}："
echo -e "   检查网络设置或使用代理"
echo ""

read -r -p "按回车键退出..."
