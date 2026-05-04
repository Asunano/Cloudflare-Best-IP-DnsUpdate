#!/bin/bash
# ==============================================================================
# cfopt - 快速更新脚本 (Quick Update)
# Description: 用于从旧版本快速升级到最新版本
# Usage: bash quick-update.sh
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${YELLOW}cfopt 快速更新工具${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo ""

# 检测安装目录
INSTALL_DIR="/root/cfopt"
if [[ ! -d "${INSTALL_DIR}" ]]; then
    INSTALL_DIR="${HOME}/cfopt"
fi

if [[ ! -d "${INSTALL_DIR}" ]]; then
    echo -e "${RED}[ERROR] 未找到 cfopt 安装目录${NC}"
    exit 1
fi

echo -e "${CYAN}检测到安装目录: ${INSTALL_DIR}${NC}"
echo ""

# 询问更新方式
echo -e "${YELLOW}请选择更新方式：${NC}"
echo "  1) 仅更新 updater 模块（推荐，快速）"
echo "  2) 完整更新所有组件（需要较长时间）"
echo "  3) 完全重新安装（会保留配置）"
echo ""
read -r -p "请选择 [1-3] (默认 1): " choice
choice="${choice:-1}"

case "${choice}" in
    1)
        echo ""
        echo -e "${CYAN}[INFO] 正在更新 updater 模块...${NC}"
        
        # 创建目录
        mkdir -p "${INSTALL_DIR}/modules/updater"
        
        # 下载 update.sh（优先使用镜像源）
        if curl -sL --max-time 30 \
            "https://hk.gh-proxy.org/https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main/modules/updater/update.sh" \
            -o "${INSTALL_DIR}/modules/updater/update.sh" 2>/dev/null; then
            chmod +x "${INSTALL_DIR}/modules/updater/update.sh"
            echo -e "${GREEN}[OK] updater 模块已更新${NC}"
            echo ""
            
            # 立即运行更新
            echo -e "${CYAN}[INFO] 正在执行组件更新...${NC}"
            bash "${INSTALL_DIR}/modules/updater/update.sh" update
        else
            echo -e "${RED}[ERROR] 下载失败，请检查网络连接${NC}"
            exit 1
        fi
        ;;
        
    2)
        echo ""
        echo -e "${CYAN}[INFO] 正在执行完整更新...${NC}"
        
        # 先更新 updater
        mkdir -p "${INSTALL_DIR}/modules/updater"
        if curl -sL --max-time 30 \
            "https://hk.gh-proxy.org/https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main/modules/updater/update.sh" \
            -o "${INSTALL_DIR}/modules/updater/update.sh" 2>/dev/null; then
            chmod +x "${INSTALL_DIR}/modules/updater/update.sh"
            echo -e "${GREEN}[OK] updater 模块已更新${NC}"
        else
            echo -e "${RED}[ERROR] 下载 updater 失败${NC}"
            exit 1
        fi
        
        echo ""
        # 运行完整更新
        bash "${INSTALL_DIR}/modules/updater/update.sh" update
        ;;
        
    3)
        echo ""
        echo -e "${YELLOW}[WARN] 即将执行完全重新安装${NC}"
        echo -e "${YELLOW}此操作会：${NC}"
        echo "  • 保留 conf/ 目录下的所有配置"
        echo "  • 删除 modules/ 和 assets/ 目录"
        echo "  • 重新下载所有组件"
        echo ""
        read -r -p "确认继续？[y/N] (默认 N): " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[INFO] 已取消${NC}"
            exit 0
        fi
        
        echo ""
        echo -e "${CYAN}[INFO] 正在备份配置文件...${NC}"
        if [[ -d "${INSTALL_DIR}/conf" ]]; then
            cp -r "${INSTALL_DIR}/conf" "${INSTALL_DIR}/conf.backup.$(date +%Y%m%d_%H%M%S)"
            echo -e "${GREEN}[OK] 配置已备份${NC}"
        fi
        
        echo -e "${CYAN}[INFO] 正在删除旧组件...${NC}"
        rm -rf "${INSTALL_DIR}/modules" "${INSTALL_DIR}/assets"
        
        echo -e "${CYAN}[INFO] 正在重新安装...${NC}"
        # 下载并执行安装脚本
        if curl -sL --max-time 60 \
            "https://hk.gh-proxy.org/https://raw.githubusercontent.com/Asunano/Cloudflare-Best-IP-DnsUpdate/main/install.sh" \
            | bash; then
            echo ""
            echo -e "${GREEN}[OK] 重新安装完成！${NC}"
            echo -e "${YELLOW}[INFO] 请运行 'cfopt' 启动程序${NC}"
        else
            echo -e "${RED}[ERROR] 安装失败${NC}"
            exit 1
        fi
        ;;
        
    *)
        echo -e "${RED}[ERROR] 无效的选择${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e "${GREEN}更新完成！${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo ""
echo -e "${YELLOW}提示:${NC} 如果更新了 cfopt.sh 主程序，请重新运行 'cfopt' 以应用新版本"
