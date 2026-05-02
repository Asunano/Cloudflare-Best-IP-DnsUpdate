#!/bin/bash
# ==============================================================================
# cfopt - 自动化调度组件 (Scheduler)
# Version: 0.1
# Description: 负责串联 IP 测速、数据同步及 DNS 记录更新的全链路任务
# Usage: bash modules/scheduler/run.sh
# ==============================================================================
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
# 获取当前脚本所在目录及项目根目录，确保在不同调用环境下路径正确
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ==================== 权限与入口校验 ====================
# 确保脚本具有执行权限，并在非 Root 环境下尝试自动修复
if [ ! -x "$SCRIPT_DIR/run.sh" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}[WARN] 脚本可能缺少执行权限，正在尝试修复...${NC}"
    chmod +x "$SCRIPT_DIR/run.sh" 2>/dev/null || true
fi

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${YELLOW}自动化调度中心 v${SCRIPT_VERSION}${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ==================== 核心函数定义 ====================

# 任务执行封装函数
# 参数:
#   $1: 任务描述名称
#   $2: 待执行的脚本绝对路径
# 返回值: 0 (成功) / 1 (失败)
run_task() {
    local task_name="$1"
    local script_path="$2"
    
    echo -e "\n${CYAN}[TASK] 正在执行: ${task_name}${NC}"
    
    # 检查目标脚本是否存在
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[ERROR] 脚本不存在: $script_path${NC}"
        return 1
    fi
    
    # 执行脚本并捕获退出码
    bash "$script_path"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}[FAIL] ${task_name} 执行失败 (Exit Code: ${exit_code})，终止后续任务。${NC}"
        return 1
    else
        echo -e "${GREEN}[OK] ${task_name} 执行成功。${NC}"
        return 0
    fi
}

# ==================== 自动化任务链 ====================

# 第一阶段：IP 优选测速（根据 CF-IP 模块配置决定是单线路还是多线路测速）
echo -e "\n${CYAN}[TASK] 正在执行: IP 优选测速${NC}"

# 加载 CF-IP 模块配置以获取分流策略
if [ -f "$ROOT_DIR/modules/cf-ip/config.conf" ]; then
    source "$ROOT_DIR/modules/cf-ip/config.conf"
fi

# 检查是否开启多线路测速
if [ "${ENABLE_MULTI_LINE:-false}" = "true" ]; then
    echo -e "${YELLOW}[INFO] 检测到已开启多线路分流测速...${NC}"
    
    # 定义各运营商的 Colo 列表 (优先使用 menu.sh 中配置的参数)
    declare -A ISP_COLOS
    ISP_COLOS["default"]="${COLO_MOBILE:-HKG,SIN,TYO,LON}"
    ISP_COLOS["unicom"]="${COLO_UNICOM:-SJC,LAX,SIN,TYO}"
    ISP_COLOS["mobile"]="${COLO_MOBILE:-HKG,SIN,TYO,LON}"
    ISP_COLOS["telecom"]="${COLO_TELECOM:-SJC,LAX,TYO,SIN}"

    for isp in "${!ISP_COLOS[@]}"; do
        local colo_list=${ISP_COLOS[$isp]}
        local output_file="$ROOT_DIR/assets/data/cf-ip/result_${isp}.csv"
        echo -e "${CYAN}  -> 正在后台启动 ${isp} 线路测速 (Colo: ${colo_list})...${NC}"
        # 传入第三个参数作为线路标识，用于进程锁隔离
        # 使用 & 符号让其在后台运行，实现多线程并发测速
        bash "$ROOT_DIR/modules/cf-ip/core.sh" "$colo_list" "$output_file" "$isp" &
    done
    
    # 等待所有后台测速任务完成
    echo -e "${YELLOW}[INFO] 等待所有线路测速任务完成...${NC}"
    wait
else
    # 单线路模式：仅执行一次通用测速
    bash "$ROOT_DIR/modules/cf-ip/core.sh" || exit 1
fi
echo -e "${GREEN}[OK] IP 优选测速执行成功。${NC}"

# 第二阶段：执行 IP 数据同步（将不同线路的结果分发至对应目录）
run_task "IP 数据同步" "$ROOT_DIR/modules/ip-sync/sync.sh" || exit 1

# 第三阶段：Cloudflare DNS 记录更新（解决矛盾：CF 仅使用 default 线路结果）
if [ -f "$ROOT_DIR/conf/cfdns.conf" ]; then
    source "$ROOT_DIR/conf/cfdns.conf"
    if [ "${ENABLED:-false}" = "true" ]; then
        echo -e "${YELLOW}[INFO] 正在更新 Cloudflare DNS (使用默认线路 IP)...${NC}"
        run_task "Cloudflare DNS 更新" "$ROOT_DIR/modules/cf-dns/core.sh" || exit 1
    else
        echo -e "${YELLOW}[SKIP] CF-DNS 模块已禁用，跳过更新。${NC}"
    fi
fi

# 第四阶段：DNSPod DNS 记录更新（支持多线路分发）
if [ -f "$ROOT_DIR/conf/dnspod.conf" ]; then
    source "$ROOT_DIR/conf/dnspod.conf"
    if [ "${ENABLED:-false}" = "true" ]; then
        echo -e "${YELLOW}[INFO] 正在更新 DNSPod DNS (根据运营商分发)...${NC}"
        run_task "DNSPod DNS 更新" "$ROOT_DIR/modules/dnspod-dns/core.sh" || exit 1
    else
        echo -e "${YELLOW}[SKIP] DNSPod 模块已禁用，跳过更新。${NC}"
    fi
fi

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}所有调度任务执行完毕！${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
