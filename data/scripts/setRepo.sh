#!/bin/bash
#
# 云服务器初始化脚本
# 功能: 优化内核参数 | 阿里腾讯源测速选优 | SSH端口设置为8899
# 兼容: Debian/Ubuntu & CentOS/RHEL/AlmaLinux/Rocky
#

set -euo pipefail

# ===========================
# 颜色输出
# ===========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ===========================
# Root 检查
# ===========================
if [ "$EUID" -ne 0 ]; then
    err "请以 root 权限运行此脚本。"
    exit 1
fi

# ===========================
# 系统检测
# ===========================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_NAME="${PRETTY_NAME}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        OS_NAME=$(cat /etc/redhat-release)
    else
        err "无法识别操作系统"
        exit 1
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|almalinux|rocky|fedora|ol)
            PKG_MANAGER="yum"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            fi
            ;;
        *)
            err "不支持的操作系统: $OS_ID"
            exit 1
            ;;
    esac

    info "检测到系统: ${OS_NAME}"
    info "包管理器: ${PKG_MANAGER}"
}

# ===========================
# 获取系统信息
# ===========================
show_system_info() {
    echo ""
    echo "=========================================="
    echo "         系统信息概览"
    echo "=========================================="
    echo " 主机名:   $(hostname)"
    echo " 系统:     ${OS_NAME}"
    echo " 内核:     $(uname -r)"
    echo " CPU:      $(nproc) 核"
    echo " 内存:     $(free -h | awk '/Mem:/{print $2}')"
    echo " 磁盘:     $(df -h / | awk 'NR==2{print $2}')"
    echo "=========================================="
    echo ""
}

# ===========================
# 优化内核参数
# ===========================
optimize_kernel() {
    info "正在优化内核参数..."

    # 获取系统内存 (KB)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_BYTES=$((TOTAL_MEM_KB * 1024))

    # 根据内存动态计算 tcp_mem (页为单位, 4096 bytes/page)
    TCP_MEM_MIN=$((TOTAL_MEM_KB / 8))
    TCP_MEM_PRESSURE=$((TOTAL_MEM_KB / 4))
    TCP_MEM_MAX=$((TOTAL_MEM_KB / 2))

    # shmmax 设置为总物理内存的 80%
    SHMMAX=$((TOTAL_MEM_BYTES * 8 / 10))
    SHMALL=$((SHMMAX / 4096))

    # 设置文件描述符上限
    ulimit -SHn 1024000

    # 备份原配置
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
        ok "已备份 /etc/sysctl.conf"
    fi

    cat > /etc/sysctl.conf <<EOF
# ===== 云服务器优化内核参数 =====
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 系统内存: $((TOTAL_MEM_KB / 1024)) MB

# --- 内核基础 ---
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = ${SHMMAX}
kernel.shmall = ${SHMALL}

# --- 文件系统 ---
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# --- 网络核心 ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.core.netdev_max_backlog = 262144
net.core.somaxconn = 65535
net.core.default_qdisc = fq

# --- IPv4 基础 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.ip_local_port_range = 1024 65535

# --- TCP 连接优化 ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 20000
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 5

# --- TCP 内存 (根据 ${TOTAL_MEM_KB}KB 内存动态计算) ---
net.ipv4.tcp_mem = ${TCP_MEM_MIN} ${TCP_MEM_PRESSURE} ${TCP_MEM_MAX}
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- TCP BBR 拥塞控制 ---
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1

# --- IPv6 (禁用) ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    # 应用参数
    sysctl -p >/dev/null 2>&1
    ok "内核参数已优化"

    # 验证 BBR
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
        ok "BBR 拥塞控制已启用"
    else
        warn "BBR 未启用 (当前: $cc)，可能需要更新内核"
    fi

    # 设置 limits.conf
    cat > /etc/security/limits.d/99-cloud-init.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 65535
root hard nproc 65535
EOF
    ok "文件描述符限制已设置"
}

# ===========================
# 测速函数
# ===========================
test_mirror_speed() {
    local url="$1"
    local name="$2"
    local tmpfile
    tmpfile=$(mktemp)

    # 下载测试文件，取平均速度
    local speed
    speed=$(curl -fsSL -o "$tmpfile" -w '%{speed_download}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "0")
    rm -f "$tmpfile"

    # 转换为 KB/s
    local speed_kb
    speed_kb=$(awk "BEGIN {printf \"%.1f\", ${speed}/1024}")

    echo "$speed_kb"
}

# ===========================
# Debian/Ubuntu 源测速与配置
# ===========================
setup_apt_repo() {
    local codename
    codename=$(lsb_release -sc 2>/dev/null || echo "")

    # 如果 lsb_release 不可用，从 os-release 获取
    if [ -z "$codename" ]; then
        if [ "$OS_ID" = "debian" ]; then
            case "$OS_VERSION" in
                12*) codename="bookworm" ;;
                11*) codename="bullseye" ;;
                10*) codename="buster" ;;
                *) codename="bookworm" ;;
            esac
        elif [ "$OS_ID" = "ubuntu" ]; then
            case "$OS_VERSION" in
                24.04*) codename="noble" ;;
                22.04*) codename="jammy" ;;
                20.04*) codename="focal" ;;
                *) codename="jammy" ;;
            esac
        fi
    fi

    info "系统代号: ${codename}"
    echo ""

    # 测速 URL
    local ali_test_url tencent_test_url
    if [ "$OS_ID" = "ubuntu" ]; then
        ali_test_url="http://mirrors.aliyun.com/ubuntu/dists/${codename}/Release"
        tencent_test_url="http://mirrors.cloud.tencent.com/ubuntu/dists/${codename}/Release"
    else
        ali_test_url="http://mirrors.aliyun.com/debian/dists/${codename}/Release"
        tencent_test_url="http://mirrors.cloud.tencent.com/debian/dists/${codename}/Release"
    fi

    info "正在测速阿里云镜像..."
    local ali_speed
    ali_speed=$(test_mirror_speed "$ali_test_url" "阿里云")
    info "  阿里云:   ${ali_speed} KB/s"

    info "正在测速腾讯云镜像..."
    local tencent_speed
    tencent_speed=$(test_mirror_speed "$tencent_test_url" "腾讯云")
    info "  腾讯云:   ${tencent_speed} KB/s"

    # 选择最快的源
    local best_mirror best_name
    local ali_faster
    ali_faster=$(awk "BEGIN {print (${ali_speed} > ${tencent_speed}) ? 1 : 0}")

    if [ "$ali_faster" -eq 1 ]; then
        best_name="阿里云"
        if [ "$OS_ID" = "ubuntu" ]; then
            best_mirror="mirrors.aliyun.com/ubuntu"
        else
            best_mirror="mirrors.aliyun.com/debian"
        fi
    else
        best_name="腾讯云"
        if [ "$OS_ID" = "ubuntu" ]; then
            best_mirror="mirrors.cloud.tencent.com/ubuntu"
        else
            best_mirror="mirrors.cloud.tencent.com/debian"
        fi
    fi

    ok "选择最快源: ${best_name}"
    echo ""

    # 备份
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
        ok "已备份 /etc/apt/sources.list"
    fi

    # 写入源配置
    if [ "$OS_ID" = "ubuntu" ]; then
        cat > /etc/apt/sources.list <<EOL
# ${best_name}镜像源 - 自动配置于 $(date '+%Y-%m-%d %H:%M:%S')
deb http://${best_mirror} ${codename} main restricted universe multiverse
deb http://${best_mirror} ${codename}-updates main restricted universe multiverse
deb http://${best_mirror} ${codename}-backports main restricted universe multiverse
deb http://${best_mirror} ${codename}-security main restricted universe multiverse
EOL
    else
        # Debian
        local security_mirror
        if [ "$ali_faster" -eq 1 ]; then
            security_mirror="mirrors.aliyun.com/debian-security"
        else
            security_mirror="mirrors.cloud.tencent.com/debian-security"
        fi

        cat > /etc/apt/sources.list <<EOL
# ${best_name}镜像源 - 自动配置于 $(date '+%Y-%m-%d %H:%M:%S')
deb http://${best_mirror} ${codename} main contrib non-free non-free-firmware
deb http://${best_mirror} ${codename}-updates main contrib non-free non-free-firmware
deb http://${security_mirror} ${codename}-security main contrib non-free non-free-firmware
EOL
    fi

    ok "已写入 ${best_name} 镜像源"

    # 更新索引
    info "正在更新软件包索引..."
    if apt update -qq 2>&1; then
        ok "软件包索引更新成功"
    else
        warn "软件包索引更新失败，请检查网络"
    fi
}

# ===========================
# CentOS/RHEL 源测速与配置
# ===========================
setup_yum_repo() {
    local major_ver
    major_ver=$(echo "$OS_VERSION" | grep -oE '^[0-9]+')

    info "系统主版本: ${major_ver}"
    echo ""

    # 测速 URL
    local ali_test_url tencent_test_url
    case "$OS_ID" in
        centos)
            if [ "$major_ver" -ge 8 ]; then
                ali_test_url="http://mirrors.aliyun.com/centos-stream/${major_ver}-stream/BaseOS/x86_64/os/repodata/repomd.xml"
                tencent_test_url="http://mirrors.cloud.tencent.com/centos-stream/${major_ver}-stream/BaseOS/x86_64/os/repodata/repomd.xml"
            else
                ali_test_url="http://mirrors.aliyun.com/centos/${major_ver}/os/x86_64/repodata/repomd.xml"
                tencent_test_url="http://mirrors.cloud.tencent.com/centos/${major_ver}/os/x86_64/repodata/repomd.xml"
            fi
            ;;
        almalinux)
            ali_test_url="http://mirrors.aliyun.com/almalinux/${major_ver}/BaseOS/x86_64/os/repodata/repomd.xml"
            tencent_test_url="http://mirrors.cloud.tencent.com/almalinux/${major_ver}/BaseOS/x86_64/os/repodata/repomd.xml"
            ;;
        rocky)
            ali_test_url="http://mirrors.aliyun.com/rockylinux/${major_ver}/BaseOS/x86_64/os/repodata/repomd.xml"
            tencent_test_url="http://mirrors.cloud.tencent.com/rockylinux/${major_ver}/BaseOS/x86_64/os/repodata/repomd.xml"
            ;;
        *)
            ali_test_url="http://mirrors.aliyun.com/centos/${major_ver}/os/x86_64/repodata/repomd.xml"
            tencent_test_url="http://mirrors.cloud.tencent.com/centos/${major_ver}/os/x86_64/repodata/repomd.xml"
            ;;
    esac

    info "正在测速阿里云镜像..."
    local ali_speed
    ali_speed=$(test_mirror_speed "$ali_test_url" "阿里云")
    info "  阿里云:   ${ali_speed} KB/s"

    info "正在测速腾讯云镜像..."
    local tencent_speed
    tencent_speed=$(test_mirror_speed "$tencent_test_url" "腾讯云")
    info "  腾讯云:   ${tencent_speed} KB/s"

    local ali_faster
    ali_faster=$(awk "BEGIN {print (${ali_speed} > ${tencent_speed}) ? 1 : 0}")

    local best_name best_base
    if [ "$ali_faster" -eq 1 ]; then
        best_name="阿里云"
        best_base="http://mirrors.aliyun.com"
    else
        best_name="腾讯云"
        best_base="http://mirrors.cloud.tencent.com"
    fi

    ok "选择最快源: ${best_name}"
    echo ""

    # 备份现有 repo
    local backup_dir="/etc/yum.repos.d/backup.$(date +%Y%m%d%H%M%S)"
    mkdir -p "$backup_dir"
    mv /etc/yum.repos.d/CentOS-*.repo "$backup_dir/" 2>/dev/null || true
    mv /etc/yum.repos.d/almalinux*.repo "$backup_dir/" 2>/dev/null || true
    mv /etc/yum.repos.d/Rocky-*.repo "$backup_dir/" 2>/dev/null || true
    ok "已备份原有 repo 文件到 ${backup_dir}"

    # 写入新 repo
    case "$OS_ID" in
        centos)
            if [ "$major_ver" -ge 8 ]; then
                cat > /etc/yum.repos.d/CentOS-Stream-Base.repo <<EOL
# ${best_name}镜像源 - 自动配置
[baseos]
name=CentOS Stream ${major_ver} - BaseOS
baseurl=${best_base}/centos-stream/${major_ver}-stream/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[appstream]
name=CentOS Stream ${major_ver} - AppStream
baseurl=${best_base}/centos-stream/${major_ver}-stream/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOL
            else
                cat > /etc/yum.repos.d/CentOS-Base.repo <<EOL
# ${best_name}镜像源 - 自动配置
[base]
name=CentOS-${major_ver} - Base
baseurl=${best_base}/centos/${major_ver}/os/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-${major_ver}

[updates]
name=CentOS-${major_ver} - Updates
baseurl=${best_base}/centos/${major_ver}/updates/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-${major_ver}

[extras]
name=CentOS-${major_ver} - Extras
baseurl=${best_base}/centos/${major_ver}/extras/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-${major_ver}
EOL
            fi
            ;;
        almalinux)
            cat > /etc/yum.repos.d/almalinux-base.repo <<EOL
# ${best_name}镜像源 - 自动配置
[baseos]
name=AlmaLinux ${major_ver} - BaseOS
baseurl=${best_base}/almalinux/${major_ver}/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${major_ver}

[appstream]
name=AlmaLinux ${major_ver} - AppStream
baseurl=${best_base}/almalinux/${major_ver}/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${major_ver}
EOL
            ;;
        rocky)
            cat > /etc/yum.repos.d/rocky-base.repo <<EOL
# ${best_name}镜像源 - 自动配置
[baseos]
name=Rocky Linux ${major_ver} - BaseOS
baseurl=${best_base}/rockylinux/${major_ver}/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${major_ver}

[appstream]
name=Rocky Linux ${major_ver} - AppStream
baseurl=${best_base}/rockylinux/${major_ver}/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${major_ver}
EOL
            ;;
    esac

    ok "已写入 ${best_name} 镜像源"

    # 重建缓存
    info "正在重建 ${PKG_MANAGER} 缓存..."
    ${PKG_MANAGER} clean all >/dev/null 2>&1
    if ${PKG_MANAGER} makecache 2>&1; then
        ok "${PKG_MANAGER} 缓存重建成功"
    else
        warn "${PKG_MANAGER} 缓存重建失败，请检查网络"
    fi
}

# ===========================
# 设置 SSH 端口
# ===========================
setup_ssh() {
    local SSH_PORT=8899
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    info "正在设置 SSH 端口为 ${SSH_PORT}..."

    if [ ! -f "$SSHD_CONFIG" ]; then
        err "找不到 ${SSHD_CONFIG}"
        return 1
    fi

    # 备份
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    ok "已备份 ${SSHD_CONFIG}"

    # 修改/添加 Port 配置
    if grep -qE '^\s*#?\s*Port\s+' "$SSHD_CONFIG"; then
        # 替换已有的 Port 行（包括被注释掉的）
        sed -i -E "s/^\s*#?\s*Port\s+.*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
    else
        # 在文件开头添加
        sed -i "1i Port ${SSH_PORT}" "$SSHD_CONFIG"
    fi

    # 同时检查并处理 sshd_config.d 目录下的覆盖文件
    if [ -d /etc/ssh/sshd_config.d ]; then
        for conf_file in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$conf_file" ] && grep -qE '^\s*Port\s+' "$conf_file"; then
                sed -i -E "s/^\s*Port\s+.*/Port ${SSH_PORT}/" "$conf_file"
                ok "已更新 ${conf_file} 中的端口设置"
            fi
        done
    fi

    # 确认配置
    local configured_port
    configured_port=$(grep -E '^\s*Port\s+' "$SSHD_CONFIG" | awk '{print $2}' | tail -1)
    if [ "$configured_port" = "$SSH_PORT" ]; then
        ok "SSH 端口已配置为 ${SSH_PORT}"
    else
        warn "SSH 端口配置可能不正确，请手动检查 ${SSHD_CONFIG}"
    fi

    # 重启 sshd
    info "正在重启 SSH 服务..."
    if systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null; then
        ok "SSH 服务已重启"
    else
        warn "SSH 服务重启失败，请手动重启: systemctl restart sshd"
    fi

    echo ""
    warn "⚠️  SSH 端口已改为 ${SSH_PORT}，下次连接请使用:"
    echo -e "   ${GREEN}ssh -p ${SSH_PORT} root@<服务器IP>${NC}"
    echo ""
}

# ===========================
# 安装基础工具
# ===========================
install_essentials() {
    info "正在安装基础工具..."

    if [ "$PKG_MANAGER" = "apt" ]; then
        apt install -y -qq curl wget vim htop net-tools lsof unzip tar >/dev/null 2>&1
    else
        ${PKG_MANAGER} install -y curl wget vim htop net-tools lsof unzip tar >/dev/null 2>&1
    fi

    ok "基础工具安装完成"
}

# ===========================
# 主流程
# ===========================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       云服务器一键初始化脚本 v2.0       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    # Step 1: 检测系统
    detect_os
    show_system_info

    # Step 2: 优化内核参数
    echo "──────────── 1/4 内核参数优化 ────────────"
    optimize_kernel
    echo ""

    # Step 3: 配置软件源 (测速选优)
    echo "──────────── 2/4 软件源配置 ──────────────"
    if [ "$PKG_MANAGER" = "apt" ]; then
        setup_apt_repo
    else
        setup_yum_repo
    fi
    echo ""

    # Step 4: 安装基础工具
    echo "──────────── 3/4 安装基础工具 ────────────"
    install_essentials
    echo ""

    # Step 5: 设置 SSH 端口
    echo "──────────── 4/4 SSH 端口配置 ────────────"
    setup_ssh
    echo ""

    # 完成
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          ✅ 初始化完成！                ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  SSH 端口: 8899                         ║${NC}"
    echo -e "${GREEN}║  BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')                              ║${NC}"
    echo -e "${GREEN}║  请用新端口重新连接测试                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
