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
if [[ ! -x "${SCRIPT_DIR}/run.sh" ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${YELLOW}[WARN] 脚本可能缺少执行权限，正在尝试修复...${NC}"
    chmod +x "${SCRIPT_DIR}/run.sh" 2>/dev/null || true
fi

# ==================== 终端显示配置 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

# ==================== 【安全配置】日志轮转 ====================
# 防止日志文件无限增长（每10MB轮转一次，保留1个备份）
rotate_log() {
    local log_file="$1"
    local max_size=${2:-$((10 * 1024 * 1024))}  # 默认 10MB
    
    if [[ -f "$log_file" ]]; then
        local file_size
        file_size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
        
        if [[ "$file_size" -gt "$max_size" ]]; then
            mv "$log_file" "${log_file}.old"
            rm -f "${log_file}.old.old"
            touch "$log_file"
        fi
    fi
}

# 轮转 scheduler 日志和错误日志
rotate_log "${ROOT_DIR}/logs/scheduler.log"
rotate_log "${ROOT_DIR}/logs/error.log"

# ==================== 【安全配置】测速超时保护 ====================
# 防止 cfst 进程挂起导致 scheduler 无限等待
SCHEDULER_TIMEOUT=${SCHEDULER_TIMEOUT:-600}  # 默认 10 分钟，可通过环境变量覆盖

# 启动看门狗定时器
start_watchdog() {
    local timeout="$1"
    local task_name="$2"
    
    (
        sleep "$timeout"
        echo -e "\n${RED}[TIMEOUT] ${task_name} 超时 (${timeout}秒)，强制终止所有子进程${NC}"
        # 终止当前进程组的所有子进程
        kill -- -$$ 2>/dev/null || true
        exit 1
    ) &
    WATCHDOG_PID=$!
    echo -e "${YELLOW}[INFO] 已启动看门狗：${timeout}秒后超时${NC}"
}

# 停止看门狗定时器
stop_watchdog() {
    if [[ -n "${WATCHDOG_PID:-}" ]]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        unset WATCHDOG_PID
    fi
}

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
    if [[ ! -f "${script_path}" ]]; then
        echo -e "${RED}[ERROR] 脚本不存在: ${script_path}${NC}"
        return 1
    fi
    
    # 执行脚本并捕获退出码
    bash "${script_path}"
    local exit_code=$?
    
    if [[ "${exit_code}" -ne 0 ]]; then
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

# 【性能优化】一次性读取 CF-IP 配置，避免重复解析
declare -A CF_IP_CFG
if [[ -f "${ROOT_DIR}/conf/cf-ip.json" ]]; then
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && CF_IP_CFG["$key"]="$value"
    done < <(jq -r '
        [
            "multi_line_enabled=\(.multi_line.enabled // false)",
            "colo_mobile=\(.multi_line.colo_mobile // \"HKG,SIN,TYO,LON\")",
            "colo_unicom=\(.multi_line.colo_unicom // \"SJC,LAX,SIN,TYO\")",
            "colo_telecom=\(.multi_line.colo_telecom // \"SJC,LAX,TYO,SIN\")"
        ] | .[]
    ' "${ROOT_DIR}/conf/cf-ip.json")
fi

# 检查是否开启多线路测速
ENABLE_MULTI_LINE="${CF_IP_CFG[multi_line_enabled]:-false}"
COLO_MOBILE="${CF_IP_CFG[colo_mobile]:-HKG,SIN,TYO,LON}"
COLO_UNICOM="${CF_IP_CFG[colo_unicom]:-SJC,LAX,SIN,TYO}"
COLO_TELECOM="${CF_IP_CFG[colo_telecom]:-SJC,LAX,TYO,SIN}"

if [[ "${ENABLE_MULTI_LINE}" = "true" ]]; then
    
    # 定义各运营商的 Colo 列表 (优先使用 menu.sh 中配置的参数)
    declare -A ISP_COLOS
    ISP_COLOS["default"]="${COLO_MOBILE:-HKG,SIN,TYO,LON}"
    ISP_COLOS["unicom"]="${COLO_UNICOM:-SJC,LAX,SIN,TYO}"
    ISP_COLOS["mobile"]="${COLO_MOBILE:-HKG,SIN,TYO,LON}"
    ISP_COLOS["telecom"]="${COLO_TELECOM:-SJC,LAX,TYO,SIN}"

    # 【安全修复】改为串行执行，避免 cfst 竞争导致的测速不准确
    echo -e "${YELLOW}[INFO] 多线路模式：串行执行测速（确保结果准确）${NC}"
    for isp in "${!ISP_COLOS[@]}"; do
        colo_list="${ISP_COLOS[$isp]}"
        output_file="${ROOT_DIR}/assets/data/cf-ip/result_${isp}.csv"
        echo -e "${CYAN}  -> 正在执行 ${isp} 线路测速 (Colo: ${colo_list})...${NC}"
        # 【优化】通过环境变量传递配置，避免 core.sh 重复读取文件
        export CF_IP_CFG_LOADED="true"
        export CFG_MULTI_LINE_ENABLED="${ENABLE_MULTI_LINE}"
        export CFG_COLO_MOBILE="${COLO_MOBILE}"
        export CFG_COLO_UNICOM="${COLO_UNICOM}"
        export CFG_COLO_TELECOM="${COLO_TELECOM}"
        # 传入第三个参数作为线路标识，用于进程锁隔离
        # 【修复】串行执行，等待当前线路完成后再执行下一条
        bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${colo_list}" "${output_file}" "${isp}"
        
        # 检查退出码
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[WARN] ${isp} 线路测速失败，继续执行下一条线路${NC}"
        fi
    done
else
    # 【优化】单线路模式：扫描所有已配置的域名，为每个域名独立测速
    echo -e "${YELLOW}[INFO] 单线路模式，正在扫描已配置的域名...${NC}"
    
    has_cf_dns=false
    cf_dns_dir="${ROOT_DIR}/conf/cf-dns"
    
    if [[ -d "${cf_dns_dir}" ]]; then
        # 遍历所有 CF-DNS 配置文件
        while IFS= read -r -d '' json_file; do
            domain_name=$(basename "$json_file" .json)
            
            # 检查模块是否启用
            enabled=$(jq -r '.enabled // false' "$json_file")
            if [[ "${enabled}" != "true" ]]; then
                continue
            fi
            
            # 从配置中读取测速节点（如果有）
            colo_nodes=$(jq -r '.ip_source.colo_nodes // "HKG,NRT"' "$json_file")
            
            # 生成独立的测速结果文件路径
            result_file="${ROOT_DIR}/assets/data/cf-ip/result_${domain_name}.csv"
            
            echo -e "${CYAN}  -> 正在为 ${domain_name} 执行测速 (节点: ${colo_nodes})...${NC}"
            # 【优化】通过环境变量传递配置，避免 core.sh 重复读取文件
            export CF_IP_CFG_LOADED="true"
            # 【修复】串行执行，避免 cfst 竞争
            bash "${ROOT_DIR}/modules/cf-ip/core.sh" "${colo_nodes}" "${result_file}" "${domain_name}"
            
            # 检查退出码
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}[WARN] ${domain_name} 测速失败，继续执行下一个域名${NC}"
            fi
            
            has_cf_dns=true
            
        done < <(find "${cf_dns_dir}" -name "*.json" -type f -print0 2>/dev/null)
    fi
    
    # 如果没有找到任何 CF-DNS 配置，执行默认测速
    if [[ "${has_cf_dns}" = false ]]; then
        echo -e "${YELLOW}[WARN] 未找到已启用的 CF-DNS 配置，执行默认测速...${NC}"
        # 【优化】通过环境变量传递配置，避免 core.sh 重复读取文件
        export CF_IP_CFG_LOADED="true"
        bash "${ROOT_DIR}/modules/cf-ip/core.sh" || exit 1
    fi
fi
echo -e "${GREEN}[OK] IP 优选测速执行成功。${NC}"

# 第二阶段：执行 IP 数据同步（将不同线路的结果分发至对应目录）
run_task "IP 数据同步" "${ROOT_DIR}/modules/ip-sync/sync.sh" || exit 1

# 第三阶段：Cloudflare DNS 记录更新（支持多域名批量更新）
if [[ -d "${ROOT_DIR}/conf/cf-dns" ]] || [[ -f "${ROOT_DIR}/conf/cf-dns.json" ]]; then
    echo -e "${YELLOW}[INFO] 正在更新 Cloudflare DNS (使用默认线路 IP)...${NC}"
    
    # 优先使用批量更新脚本（支持多域名）
    if [[ -f "${ROOT_DIR}/modules/cf-dns/batch.sh" ]]; then
        run_task "Cloudflare DNS 批量更新" "${ROOT_DIR}/modules/cf-dns/batch.sh" || exit 1
    else
        # 向后兼容：如果没有批量脚本，使用旧的单文件方式
        run_task "Cloudflare DNS 更新" "${ROOT_DIR}/modules/cf-dns/core.sh" || exit 1
    fi
else
    echo -e "${YELLOW}[SKIP] 未找到 CF-DNS 配置文件，跳过更新。${NC}"
fi

# 第四阶段：DNSPod DNS 记录更新（支持多域名批量更新和多线路分发）
if [[ -d "${ROOT_DIR}/conf/dnspod" ]] || [[ -f "${ROOT_DIR}/conf/dnspod.json" ]]; then
    echo -e "${YELLOW}[INFO] 正在更新 DNSPod DNS (根据运营商分发)...${NC}"
    
    # 优先使用批量更新脚本（支持多域名）
    if [[ -f "${ROOT_DIR}/modules/dnspod-dns/batch.sh" ]]; then
        run_task "DNSPod DNS 批量更新" "${ROOT_DIR}/modules/dnspod-dns/batch.sh" || exit 1
    else
        # 向后兼容：如果没有批量脚本，使用旧的单文件方式
        run_task "DNSPod DNS 更新" "${ROOT_DIR}/modules/dnspod-dns/core.sh" || exit 1
    fi
else
    echo -e "${YELLOW}[SKIP] 未找到 DNSPod 配置文件，跳过更新。${NC}"
fi

echo -e "\n${CYAN}+------------------------------------------------------------+${NC}"
echo -e "${GREEN}所有调度任务执行完毕！${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
