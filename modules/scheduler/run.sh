#!/bin/bash
# ==============================================================================
# cfopt - 自动化调度组件 (Scheduler)
# Version: 0.1
# Description: 负责串联 IP 测速、数据同步及 DNS 记录更新的全链路任务
# Usage: bash modules/scheduler/run.sh
# ==============================================================================
# 【安全修复】启用严格模式，防止错误传播
set -euo pipefail
SCRIPT_VERSION="0.1"

# ==================== 路径初始化 ====================
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 【修复】加载公共函数库
# shellcheck source=../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

_LOG_MODULE="scheduler"
# 【修复】设置日志文件路径，使 log_info 等函数能写入文件
mkdir -p "${ROOT_DIR}/logs"
_LOG_FILE="${ROOT_DIR}/logs/scheduler.log"

# ==================== 权限与入口校验 ====================
# 确保脚本具有执行权限，并在非 Root 环境下尝试自动修复
if [[ ! -x "${SCRIPT_DIR}/run.sh" ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${YELLOW}[WARN] 脚本可能缺少执行权限，正在尝试修复...${NC}"
    chmod +x "${SCRIPT_DIR}/run.sh" 2>/dev/null || true
fi

echo -e "${CYAN}+------------------------------------------------------------+${NC}"
echo -e " ${BOLD}${YELLOW}Cloudflare-Best-IP-DnsUpdate v${SCRIPT_VERSION}${NC}"
echo -e " ${MAGENTA}项目仓库: https://github.com/Asunano/Cloudflare-Best-IP-DnsUpdate${NC}"
echo -e " 启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"

# ==================== 【安全配置】日志轮转 ====================
# 防止日志文件无限增长（每10MB轮转一次，保留1个备份）
# 【修复】使用 lib/common.sh 中的公共 get_file_size 和 rotate_log

# 轮转 scheduler 日志和错误日志
rotate_log "${ROOT_DIR}/logs/scheduler.log"
rotate_log "${ROOT_DIR}/logs/error.log"

# ==================== 【安全配置】测速超时保护 ====================
# 防止 cfst 进程挂起导致 scheduler 无限等待
SCHEDULER_TIMEOUT=${SCHEDULER_TIMEOUT:-600}  # 默认 10 分钟，可通过环境变量覆盖
TASK_PID=""  # 记录当前任务的 PID
# 【修复】使用文件传递 PID，解决子 shell 无法获取父 shell 后续变量的问题
WATCHDOG_PID_FILE=$(mktemp /tmp/cfopt_watchdog.XXXXXX)

# 启动看门狗定时器
# 【修复】看门狗通过文件获取任务 PID，而非依赖子 shell 变量继承
start_watchdog() {
    local timeout="$1"
    local task_name="$2"
    local pid_file="$3"

    # 清空 PID 文件
    : > "${pid_file}"

    (
        sleep "$timeout"
        
        # 【修复】检查父进程是否存活，防止成为僵尸进程
        if ! kill -0 "$PPID" 2>/dev/null; then
            # 父进程已退出，看门狗自行退出
            exit 0
        fi
        
        # 【修复】从文件读取 PID（子 shell 创建时变量尚未赋值）
        local task_pid
        task_pid=$(cat "${pid_file}" 2>/dev/null | tr -d '[:space:]')

        if [[ -n "${task_pid}" ]] && [[ "${task_pid}" =~ ^[0-9]+$ ]]; then
            echo -e "\n${RED}[TIMEOUT] ${task_name} 超时 (${timeout}秒)，强制终止所有子进程${NC}"
            
            # 【安全修复】使用进程组杀死整个进程树
            # 方法1: 尝试杀死整个进程组（最彻底，需要 setsid）
            kill -- -"${task_pid}" 2>/dev/null || true
            
            # 方法2: 递归杀死所有子进程（通用方案）
            pkill -P "${task_pid}" 2>/dev/null || true
            
            # 方法3: 最后杀死主进程
            kill "${task_pid}" 2>/dev/null || true
            
            # 等待进程完全退出
            sleep 1
            
            # 如果还有残留进程，强制杀死
            if kill -0 "${task_pid}" 2>/dev/null; then
                kill -9 -- -"${task_pid}" 2>/dev/null || true
                kill -9 "${task_pid}" 2>/dev/null || true
                # 再次尝试杀死所有子进程
                pkill -9 -P "${task_pid}" 2>/dev/null || true
            fi
        fi
        exit 1
    ) &
    WATCHDOG_PID=$!
    echo -e "${YELLOW}[INFO] 已启动看门狗：${timeout}秒后超时${NC}"
}

# 停止看门狗定时器
stop_watchdog() {
    if [[ -n "${WATCHDOG_PID:-}" ]]; then
        if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
            kill "$WATCHDOG_PID" 2>/dev/null || true
            wait "$WATCHDOG_PID" 2>/dev/null || true
        fi
        unset WATCHDOG_PID
    fi
    # 清理临时文件
    rm -f "${WATCHDOG_PID_FILE}" 2>/dev/null || true
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
    
    # 【新增】启动超时保护看门狗
    start_watchdog "${SCHEDULER_TIMEOUT}" "${task_name}" "${WATCHDOG_PID_FILE}"
    
    # 执行脚本并捕获退出码
    # 【安全修复】使用 setsid 创建新进程组，确保 kill -- -PID 能杀死整个进程树
    # 【修复】设置 CF_OPT_ENTRY=scheduler，允许子模块通过入口校验
    export CF_OPT_ENTRY=scheduler
    
    # 【安全修复】尝试使用 setsid 创建新进程组（推荐方式）
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "${script_path}" &
        TASK_PID=$!
    else
        # 备用方案：直接后台执行（无进程组隔离）
        bash "${script_path}" &
        TASK_PID=$!
    fi

    # 【修复】将 PID 写入文件，供看门狗子 shell 读取
    echo "${TASK_PID}" > "${WATCHDOG_PID_FILE}"
    
    wait "${TASK_PID}"
    local exit_code=$?
    TASK_PID=""  # 清空 TASK_PID
    
    # 【新增】停止看门狗（任务完成或失败后都需要停止）
    stop_watchdog
    
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
            "cfst_colo=\(.cfst.colo // \"HKG,NRT\")",
            "multi_line_enabled=\(.multi_line.enabled // false)",
            "colo_mobile=\(.multi_line.colo_mobile // \"HKG,SIN,TYO,LON\")",
            "colo_unicom=\(.multi_line.colo_unicom // \"SJC,LAX,SIN,TYO\")",
            "colo_telecom=\(.multi_line.colo_telecom // \"SJC,LAX,TYO,SIN\")"
        ] | .[]
    ' "${ROOT_DIR}/conf/cf-ip.json")
fi

# 检查是否开启多线路测速
CFST_COLO="${CF_IP_CFG[cfst_colo]:-HKG,NRT}"
ENABLE_MULTI_LINE="${CF_IP_CFG[multi_line_enabled]:-false}"
COLO_MOBILE="${CF_IP_CFG[colo_mobile]:-HKG,SIN,TYO,LON}"
COLO_UNICOM="${CF_IP_CFG[colo_unicom]:-SJC,LAX,SIN,TYO}"
COLO_TELECOM="${CF_IP_CFG[colo_telecom]:-SJC,LAX,TYO,SIN}"

if [[ "${ENABLE_MULTI_LINE}" = "true" ]]; then
    
    # 定义各运营商的 Colo 列表 (优先使用 menu.sh 中配置的参数)
    declare -A ISP_COLOS
    # 【修复】default 使用通用 Colo 列表，避免与 mobile 重复测速
    ISP_COLOS["default"]="${CF_IP_CFG[cfst_colo]:-HKG,NRT}"
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
            export CF_OPT_ENTRY=scheduler
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

# 第二阶段：执行 IP 数据同步与 DNS 批量更新（已合并到 sync.sh）
run_task "IP 数据同步与 DNS 批量更新" "${ROOT_DIR}/modules/ip-sync/sync.sh" || exit 1

# 【已移除】第三、四阶段：DNS 批量更新已合并到 sync.sh 中统一执行

echo -e "\n${CYAN}+------------------------------------------------------------+${NC}"
echo -e "${GREEN}所有调度任务执行完毕！${NC}"
echo -e "${CYAN}+------------------------------------------------------------+${NC}"
