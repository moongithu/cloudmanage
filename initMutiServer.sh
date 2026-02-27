#!/bin/bash
#
# 批量服务器管理工具
# 功能: 读取 serverInfo 批量 SSH 登录执行指定脚本/命令，结果友好展示
# 用法:
#   bash initMutiServer.sh [选项] [脚本路径]
#
#   选项:
#     -f <文件>    指定 serverInfo 路径 (默认: 同目录下的 serverInfo)
#     -c <命令>    直接执行命令（与脚本路径二选一）
#     -j <数量>    并发数 (默认: 5)
#     -t <秒>      SSH 超时时间 (默认: 30)
#     -h           显示帮助
#
#   示例:
#     bash initMutiServer.sh ./initcloud/setRepo.sh
#     bash initMutiServer.sh -c "hostname && uptime"
#     bash initMutiServer.sh -j 10 -c "df -h"
#

set -uo pipefail

# ===========================
# 颜色与符号
# ===========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

TICK="${GREEN}✅${NC}"
CROSS="${RED}❌${NC}"
ARROW="${CYAN}▶${NC}"
CLOCK="${YELLOW}⏱${NC}"

# ===========================
# 脚本所在目录
# ===========================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ===========================
# 默认参数
# ===========================
SERVER_FILE="${SCRIPT_DIR}/serverInfo"
COMMAND=""
SCRIPT_PATH=""
MAX_PARALLEL=5
SSH_TIMEOUT=30

# ===========================
# 临时目录
# ===========================
TMP_DIR=""
cleanup() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ===========================
# 帮助信息
# ===========================
usage() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║      批量服务器管理工具 v1.0                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $(basename "$0") [选项] [脚本路径]"
    echo ""
    echo -e "${BOLD}选项:${NC}"
    echo "  -f <文件>    指定 serverInfo 路径 (默认: ./serverInfo)"
    echo "  -c <命令>    直接执行命令（与脚本路径二选一）"
    echo "  -j <数量>    并发数 (默认: 5)"
    echo "  -t <秒>      SSH 超时时间 (默认: 30)"
    echo "  -h           显示帮助"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  $(basename "$0") ./initcloud/setRepo.sh"
    echo "  $(basename "$0") -c 'hostname && uptime && df -h'"
    echo "  $(basename "$0") -j 10 -c 'uname -a'"
    echo ""
    echo -e "${BOLD}serverInfo 格式:${NC} (每行一台服务器)"
    echo "  IP  端口  用户名  密码"
    echo "  1.1.1.1 22 root password123"
    exit 0
}

# ===========================
# 解析参数
# ===========================
while getopts "f:c:j:t:h" opt; do
    case $opt in
        f) SERVER_FILE="$OPTARG" ;;
        c) COMMAND="$OPTARG" ;;
        j) MAX_PARALLEL="$OPTARG" ;;
        t) SSH_TIMEOUT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# 剩余参数作为脚本路径
if [ $# -gt 0 ]; then
    SCRIPT_PATH="$1"
fi

# ===========================
# 自动安装依赖
# ===========================
auto_install() {
    local pkg="$1"
    echo -e "  ${ARROW} 正在自动安装 ${BOLD}${pkg}${NC} ..."

    if [ -f /etc/debian_version ]; then
        # Debian / Ubuntu
        apt-get update -qq >/dev/null 2>&1
        if apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
            echo -e "  ${TICK} ${pkg} 安装成功"
            return 0
        fi
    elif [ -f /etc/redhat-release ]; then
        # CentOS / RHEL / Rocky / Alma
        if command -v dnf &>/dev/null; then
            if dnf install -y -q "$pkg" >/dev/null 2>&1; then
                echo -e "  ${TICK} ${pkg} 安装成功"
                return 0
            fi
        elif command -v yum &>/dev/null; then
            if yum install -y -q "$pkg" >/dev/null 2>&1; then
                echo -e "  ${TICK} ${pkg} 安装成功"
                return 0
            fi
        fi
    fi

    echo -e "  ${CROSS} ${pkg} 自动安装失败"
    return 1
}

# ===========================
# 检查环境 & 自动安装依赖
# ===========================
REQUIRED_CMDS=("sshpass" "scp" "ssh")

check_and_install_deps() {
    echo -e "${BOLD}  🔍 环境检查${NC}"

    local missing=0
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ├── ${cmd}: ${GREEN}已安装${NC} ($(command -v "$cmd"))"
        else
            echo -e "  ├── ${cmd}: ${RED}未安装${NC}"

            # 判断操作系统，尝试自动安装
            if [[ "$(uname)" == "Darwin" ]]; then
                echo -e "  │   ${YELLOW}macOS 请手动安装:${NC}"
                if [ "$cmd" = "sshpass" ]; then
                    echo -e "  │   ${DIM}brew install hudochenkov/sshpass/sshpass${NC}"
                else
                    echo -e "  │   ${DIM}brew install ${cmd}${NC}"
                fi
                missing=$((missing + 1))
            else
                # Linux: 尝试自动安装
                if [ "$(id -u)" -eq 0 ]; then
                    if auto_install "$cmd"; then
                        continue  # 安装成功，跳过
                    fi
                    missing=$((missing + 1))
                else
                    echo -e "  │   ${YELLOW}请以 root 运行以自动安装，或手动执行:${NC}"
                    if [ -f /etc/debian_version ]; then
                        echo -e "  │   ${DIM}sudo apt install -y ${cmd}${NC}"
                    else
                        echo -e "  │   ${DIM}sudo yum install -y ${cmd}${NC}"
                    fi
                    missing=$((missing + 1))
                fi
            fi
        fi
    done

    echo ""
    if [ $missing -gt 0 ]; then
        echo -e "${RED}[ERROR]${NC} 有 ${missing} 个依赖缺失，无法继续"
        exit 1
    fi
    echo -e "  ${TICK} 所有依赖检查通过"
    echo ""
}

# ===========================
# 前置检查
# ===========================
preflight_check() {
    local errors=0

    # 环境依赖检查（自动安装）
    check_and_install_deps

    # 检查 serverInfo
    if [ ! -f "$SERVER_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} 服务器列表文件不存在: ${SERVER_FILE}"
        errors=$((errors + 1))
    fi

    # 检查是否指定了任务
    if [ -z "$COMMAND" ] && [ -z "$SCRIPT_PATH" ]; then
        echo -e "${RED}[ERROR]${NC} 请指定要执行的脚本路径或命令 (-c)"
        echo -e "  ${DIM}$(basename "$0") -h 查看帮助${NC}"
        errors=$((errors + 1))
    fi

    # 如果指定了脚本，检查脚本是否存在
    if [ -n "$SCRIPT_PATH" ]; then
        # 支持相对路径（相对于脚本目录）
        if [[ "$SCRIPT_PATH" != /* ]]; then
            SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
        fi
        if [ ! -f "$SCRIPT_PATH" ]; then
            echo -e "${RED}[ERROR]${NC} 脚本文件不存在: ${SCRIPT_PATH}"
            errors=$((errors + 1))
        fi
    fi

    if [ $errors -gt 0 ]; then
        exit 1
    fi
}

# ===========================
# 读取服务器列表
# ===========================
declare -a SERVERS=()

load_servers() {
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # 解析: IP 端口 用户名 密码
        local ip port user pass
        read -r ip port user pass <<< "$line"

        if [ -z "$ip" ] || [ -z "$port" ] || [ -z "$user" ] || [ -z "$pass" ]; then
            echo -e "${YELLOW}[WARN]${NC} 第 ${line_num} 行格式错误，已跳过: ${line}"
            continue
        fi

        SERVERS+=("${ip}|${port}|${user}|${pass}")
    done < "$SERVER_FILE"

    if [ ${#SERVERS[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR]${NC} 服务器列表为空"
        exit 1
    fi
}

# ===========================
# 格式化耗时
# ===========================
format_duration() {
    local seconds=$1
    if [ "$seconds" -ge 60 ]; then
        printf "%dm%ds" $((seconds / 60)) $((seconds % 60))
    else
        printf "%ds" "$seconds"
    fi
}

# ===========================
# 截断文本
# ===========================
truncate_text() {
    local text="$1"
    local max_len="${2:-60}"
    # 取第一行非空内容
    local first_line
    first_line=$(echo "$text" | grep -v '^$' | head -1 | sed 's/^[ \t]*//')
    if [ ${#first_line} -gt "$max_len" ]; then
        echo "${first_line:0:$((max_len - 3))}..."
    else
        echo "$first_line"
    fi
}

# ===========================
# 对单台服务器执行任务
# ===========================
run_on_server() {
    local idx="$1"
    local server_info="$2"
    local result_dir="$3"

    IFS='|' read -r ip port user pass <<< "$server_info"

    local start_time
    start_time=$(date +%s)

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=${SSH_TIMEOUT} -o LogLevel=ERROR -p ${port}"
    local output_file="${result_dir}/${idx}_${ip}.log"
    local status_file="${result_dir}/${idx}_${ip}.status"

    echo -e "  ${ARROW} [${idx}] ${BOLD}${ip}:${port}${NC} — 连接中..." >&2

    if [ -n "$SCRIPT_PATH" ]; then
        # 模式一: 上传脚本并执行
        local remote_script="/tmp/_batch_exec_$(basename "$SCRIPT_PATH")_$$"

        # SCP 上传
        if ! sshpass -p "$pass" scp $ssh_opts "$SCRIPT_PATH" "${user}@${ip}:${remote_script}" >/dev/null 2>&1; then
            local end_time
            end_time=$(date +%s)
            echo "FAIL" > "$status_file"
            echo "SCP 上传失败 — 连接超时或认证错误" > "$output_file"
            echo "$((end_time - start_time))" >> "$status_file"
            echo -e "  ${CROSS} [${idx}] ${ip}:${port} — ${RED}上传失败${NC}" >&2
            return 1
        fi

        # SSH 执行
        sshpass -p "$pass" ssh $ssh_opts "${user}@${ip}" \
            "chmod +x '${remote_script}' && bash '${remote_script}' 2>&1; ret=\$?; rm -f '${remote_script}'; exit \$ret" \
            > "$output_file" 2>&1
        local exit_code=$?
    else
        # 模式二: 直接执行命令
        sshpass -p "$pass" ssh $ssh_opts "${user}@${ip}" \
            "${COMMAND}" \
            > "$output_file" 2>&1
        local exit_code=$?
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $exit_code -eq 0 ]; then
        echo "OK" > "$status_file"
        echo -e "  ${TICK} [${idx}] ${ip}:${port} — ${GREEN}完成${NC} (${duration}s)" >&2
    else
        echo "FAIL" > "$status_file"
        echo -e "  ${CROSS} [${idx}] ${ip}:${port} — ${RED}失败 (exit: ${exit_code})${NC} (${duration}s)" >&2
    fi
    echo "$duration" >> "$status_file"
}

# ===========================
# 打印分隔线
# ===========================
print_line() {
    local char="${1:-─}"
    local width="${2:-80}"
    printf '%*s\n' "$width" '' | tr ' ' "$char"
}

# ===========================
# 打印结果表格
# ===========================
print_results() {
    local result_dir="$1"

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                            执 行 结 果 汇 总                              ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 表头
    printf "${BOLD}  %-4s  %-18s  %-6s  %-8s  %-38s${NC}\n" "序号" "服务器" "状态" "耗时" "输出摘要"
    print_line "─" 80

    local success=0
    local fail=0
    local total_time=0

    for i in $(seq 0 $((${#SERVERS[@]} - 1))); do
        local idx=$((i + 1))
        IFS='|' read -r ip port user pass <<< "${SERVERS[$i]}"

        local status_file="${result_dir}/${idx}_${ip}.status"
        local output_file="${result_dir}/${idx}_${ip}.log"

        local status="N/A"
        local duration=0
        local summary="(无输出)"

        if [ -f "$status_file" ]; then
            status=$(head -1 "$status_file")
            duration=$(tail -1 "$status_file")
        fi

        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            summary=$(truncate_text "$(cat "$output_file")" 38)
        fi

        total_time=$((total_time + duration))
        local dur_str
        dur_str=$(format_duration "$duration")

        local status_icon
        if [ "$status" = "OK" ]; then
            status_icon="${GREEN}✅ 成功${NC}"
            success=$((success + 1))
        else
            status_icon="${RED}❌ 失败${NC}"
            fail=$((fail + 1))
        fi

        printf "  %-4s  %-18s  ${status_icon}  %-8s  ${DIM}%-38s${NC}\n" \
            "$idx" "${ip}:${port}" "$dur_str" "$summary"
    done

    print_line "─" 80

    # 汇总
    echo ""
    local total_dur_str
    total_dur_str=$(format_duration "$total_time")

    echo -e "${BOLD}  📊 汇总${NC}"
    echo -e "  ├── 总计: ${BOLD}${#SERVERS[@]}${NC} 台服务器"
    echo -e "  ├── ${GREEN}成功: ${success}${NC}"
    echo -e "  ├── ${RED}失败: ${fail}${NC}"
    echo -e "  └── ${CLOCK} 总耗时: ${BOLD}${total_dur_str}${NC}"
    echo ""

    # 如果有失败，展示详细错误
    if [ $fail -gt 0 ]; then
        echo -e "${BOLD}${RED}  ⚠️  失败服务器详细日志:${NC}"
        print_line "─" 80
        for i in $(seq 0 $((${#SERVERS[@]} - 1))); do
            local idx=$((i + 1))
            IFS='|' read -r ip port user pass <<< "${SERVERS[$i]}"

            local status_file="${result_dir}/${idx}_${ip}.status"
            local output_file="${result_dir}/${idx}_${ip}.log"

            if [ -f "$status_file" ] && [ "$(head -1 "$status_file")" = "FAIL" ]; then
                echo -e "\n  ${RED}━━ [${idx}] ${ip}:${port} ━━${NC}"
                if [ -f "$output_file" ]; then
                    sed 's/^/    /' "$output_file" | head -20
                    local total_lines
                    total_lines=$(wc -l < "$output_file")
                    if [ "$total_lines" -gt 20 ]; then
                        echo -e "    ${DIM}... (共 ${total_lines} 行, 仅显示前 20 行)${NC}"
                    fi
                fi
            fi
        done
        echo ""
    fi

    # 提示查看完整日志
    echo -e "  ${DIM}📁 完整日志目录: ${result_dir}${NC}"
    echo ""
}

# ===========================
# 主流程
# ===========================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       批量服务器管理工具 v1.0                   ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # 前置检查
    preflight_check

    # 加载服务器列表
    load_servers

    # 创建临时目录
    TMP_DIR=$(mktemp -d /tmp/batch_server_XXXXXX)

    # 打印任务信息
    echo -e "${BOLD}  📋 任务信息${NC}"
    echo -e "  ├── 服务器列表: ${BLUE}${SERVER_FILE}${NC}"
    echo -e "  ├── 服务器数量: ${BOLD}${#SERVERS[@]}${NC} 台"
    if [ -n "$SCRIPT_PATH" ]; then
        echo -e "  ├── 执行脚本:   ${BLUE}$(basename "$SCRIPT_PATH")${NC}"
    else
        echo -e "  ├── 执行命令:   ${BLUE}${COMMAND}${NC}"
    fi
    echo -e "  ├── 并发数:     ${BOLD}${MAX_PARALLEL}${NC}"
    echo -e "  └── SSH 超时:   ${BOLD}${SSH_TIMEOUT}s${NC}"
    echo ""
    print_line "─" 50
    echo ""
    echo -e "${BOLD}  🚀 开始执行...${NC}"
    echo ""

    local total_start
    total_start=$(date +%s)

    # 并发执行
    local running=0
    local pids=()
    for i in $(seq 0 $((${#SERVERS[@]} - 1))); do
        local idx=$((i + 1))
        run_on_server "$idx" "${SERVERS[$i]}" "$TMP_DIR" &
        pids+=($!)
        running=$((running + 1))

        # 达到并发上限，等待一个完成
        if [ $running -ge $MAX_PARALLEL ]; then
            wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null
            # 简化处理：等待任一进程
            running=$((running - 1))
        fi
    done

    # 等待所有剩余任务
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    local total_end
    total_end=$(date +%s)

    echo ""
    print_line "─" 50
    echo -e "  ${CLOCK} 全部任务完成 (实际耗时: $(format_duration $((total_end - total_start))))"

    # 打印结果
    print_results "$TMP_DIR"
}

main "$@"
