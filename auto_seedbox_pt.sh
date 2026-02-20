#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) 
# qBittorrent + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名 (用于运行服务和登录WebUI)
#   -p : 密码（必须 ≥ 8 位）
#   -c : qBittorrent 缓存大小 (MiB, 仅4.x有效, 5.x使用mmap)
#   -q : qBittorrent 版本 (4, 4.3.9, 5, 5.0.4, latest, 或精确小版本如 5.1.2)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser
#   -t : 启用系统内核优化（强烈推荐）
#   -m : 调优模式 (1: 极限刷流 / 2: 均衡保种) [默认 1]
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP/tar.gz 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

APP_USER="admin"
APP_PASS=""
QB_CACHE=1024
QB_VER_REQ="5.0.4" 
DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false
CACHE_SET_BY_USER=false
TUNE_MODE="1"
VX_RESTORE_URL=""
VX_ZIP_PASS=""
INSTALLED_MAJOR_VER="5"
ACTION="install" 

HB="/root"

TEMP_DIR=$(mktemp -d -t asp-XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 个人专属固化直链库 (兜底与默认版本)
URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V5_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"
URL_V5_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"

# ================= 1. 核心工具函数 & UI 增强 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

execute_with_spinner() {
    local msg="$1"
    shift
    local log="/tmp/asp_install.log"
    "$@" >> "$log" 2>&1 &
    local pid=$!
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    printf "\e[?25l"
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r\033[K ${CYAN}[%c]${NC} %s..." "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    wait $pid
    local ret=$?
    printf "\e[?25h"
    if [ $ret -eq 0 ]; then
        printf "\r\033[K ${GREEN}[√]${NC} %s... 完成!\n" "$msg"
    else
        printf "\r\033[K ${RED}[X]${NC} %s... 失败! (请查看 /tmp/asp_install.log)\n" "$msg"
    fi
    return $ret
}

download_file() {
    local url=$1; local output=$2
    if [[ "$output" == "/usr/bin/qbittorrent-nox" ]]; then
        systemctl stop "qbittorrent-nox@$APP_USER" 2>/dev/null || true
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f "$output" 2>/dev/null || true
    fi
    if ! execute_with_spinner "正在获取资源 $(basename "$output")" wget -q --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "下载失败，请检查网络或 URL: $url"
    fi
}

print_banner() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ $1 ══════════════════╗${NC}"
    echo ""
}

check_root() { 
    if [[ $EUID -ne 0 ]]; then
        log_err "权限不足：请使用 root 用户运行本脚本！"
    fi
}

validate_pass() {
    if [[ ${#1} -lt 8 ]]; then
        log_err "安全性不足：密码长度必须 ≥ 8 位！"
    fi
}

wait_for_lock() {
    local max_wait=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        log_warn "等待系统包管理器锁释放..."
        sleep 2; waited=$((waited + 2))
        [[ $waited -ge $max_wait ]] && break
    done
}

open_port() {
    local port=$1
    local proto=${2:-tcp}
    local added=false

    if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
        ufw allow "$port/$proto" >/dev/null 2>&1
        added=true
    fi

    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        added=true
    fi

    if command -v iptables >/dev/null; then
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            added=true
        fi
    fi
}

check_port_occupied() {
    local port=$1
    if command -v netstat >/dev/null; then
        netstat -tuln | grep -q ":$port " && return 0
    elif command -v ss >/dev/null; then
        ss -tuln | grep -q ":$port " && return 0
    fi
    return 1
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "  ▶ $prompt [默认 $default]: " port < /dev/tty
        port=${port:-$default}
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            log_warn "无效输入，请输入 1-65535 端口号。"
            continue
        fi
        if check_port_occupied "$port"; then
            log_warn "端口 $port 已被占用，请更换！"
            continue
        fi
        echo "$port"
        return 0
    done
}

# ================= 2. 用户管理 =================

setup_user() {
    if [[ "$APP_USER" == "root" ]]; then
        HB="/root"
        log_info "以 Root 身份运行服务。"
        return
    fi

    if id "$APP_USER" &>/dev/null; then
        log_info "系统用户 $APP_USER 已存在，复用之。"
    else
        log_info "创建隔离系统用户: $APP_USER"
        useradd -m -s /bin/bash "$APP_USER"
    fi

    HB=$(eval echo ~$APP_USER)
}

# ================= 3. 深度卸载逻辑 =================

uninstall() {
    local mode=$1
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}        执行深度卸载流程 (含系统回滚)            ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    
    log_info "正在扫描已安装的用户..."
    local detected_users=$(systemctl list-units --full -all --no-legend 'qbittorrent-nox@*' | sed -n 's/.*qbittorrent-nox@\([^.]*\)\.service.*/\1/p' | sort -u | tr '\n' ' ')
    
    if [[ -z "$detected_users" ]]; then
        detected_users="未检测到活跃服务 (可能是 admin)"
    fi
    
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "${YELLOW} 提示: 系统中检测到以下可能的安装用户: ${NC}"
    echo -e "${GREEN} -> [ ${detected_users} ] ${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    
    local default_u=${APP_USER:-admin}
    read -p "请输入要卸载的用户名 [默认: $default_u]: " input_user < /dev/tty
    target_user=${input_user:-$default_u}
    
    target_home=$(eval echo ~$target_user 2>/dev/null || echo "/home/$target_user")

    if [[ "$mode" == "--purge" ]]; then
        log_warn "将清理用户数据并【彻底回滚内核与系统状态】。"
    else
        log_info "仅卸载服务，保留用户数据与内核优化。"
    fi

    read -p "确认要卸载核心组件吗？此操作不可逆！ [y/N]: " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi

    execute_with_spinner "停止并移除服务守护进程" sh -c "
        for svc in \$(systemctl list-units --full -all | grep 'qbittorrent-nox@' | awk '{print \$1}'); do
            systemctl stop \"\$svc\" 2>/dev/null || true
            systemctl disable \"\$svc\" 2>/dev/null || true
            rm -f \"/etc/systemd/system/\$svc\"
        done
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f /usr/bin/qbittorrent-nox
    "

    if command -v docker >/dev/null; then
        execute_with_spinner "清理 Docker 镜像与容器残留" sh -c "
            docker rm -f vertex filebrowser 2>/dev/null || true
            docker rmi lswl/vertex:stable filebrowser/filebrowser:latest 2>/dev/null || true
            docker network prune -f >/dev/null 2>&1 || true
        "
    fi

    execute_with_spinner "移除系统优化与内核回滚" sh -c "
        systemctl stop asp-tune.service 2>/dev/null || true
        systemctl disable asp-tune.service 2>/dev/null || true
        rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
        [ -f /etc/security/limits.conf ] && sed -i '/# Auto-Seedbox-PT/d' /etc/security/limits.conf || true
    "
    
    if [[ "$mode" == "--purge" ]]; then
        log_warn "执行底层状态回滚..."
        if [ -f /etc/asp_original_governor ]; then
            orig_gov=$(cat /etc/asp_original_governor)
            for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [ -f "$f" ] && echo "$orig_gov" > "$f" 2>/dev/null || true
            done
            rm -f /etc/asp_original_governor
        else
            for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [ -f "$f" ] && echo "ondemand" > "$f" 2>/dev/null || true
            done
        fi
        
        ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
        if [ -n "$ETH" ]; then
            ifconfig "$ETH" txqueuelen 1000 2>/dev/null || true
        fi
        DEF_ROUTE=$(ip -o -4 route show to default | head -n1)
        if [[ -n "$DEF_ROUTE" ]]; then
            ip route change $DEF_ROUTE initcwnd 10 initrwnd 10 2>/dev/null || true
        fi
        sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456" >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1 || true
        sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
        sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    
    execute_with_spinner "清理防火墙规则遗留" sh -c "
        if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
            ufw delete allow $QB_WEB_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/udp >/dev/null 2>&1 || true
            ufw delete allow $VX_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $FB_PORT/tcp >/dev/null 2>&1 || true
        fi
        if command -v firewalld >/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --remove-port=\"$QB_WEB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/udp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$VX_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$FB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
        if command -v iptables >/dev/null; then
            iptables -D INPUT -p tcp --dport $QB_WEB_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $VX_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $FB_PORT -j ACCEPT 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    "

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true

    if [[ "$mode" == "--purge" ]]; then
        log_warn "清理配置文件..."
        if [[ -d "$target_home" ]]; then
             rm -rf "$target_home/.config/qBittorrent" "$target_home/vertex" "$target_home/.config/filebrowser"
             log_info "已清理 $target_home 下的配置文件。"
             
             if [[ -d "$target_home/Downloads" ]]; then
                 echo -e "${YELLOW}=================================================${NC}"
                 log_warn "检测到可能包含大量数据的目录: $target_home/Downloads"
                 read -p "是否连同已下载的种子数据一并彻底删除？此操作不可逆！ [y/N]: " del_data < /dev/tty
                 if [[ "$del_data" =~ ^[Yy]$ ]]; then
                     rm -rf "$target_home/Downloads"
                     log_info "💣 已彻底删除 $target_home/Downloads 数据目录。"
                 else
                     log_info "🛡️ 已为您安全保留 $target_home/Downloads 数据目录。"
                 fi
                 echo -e "${YELLOW}=================================================${NC}"
             fi
        fi
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser"
        log_warn "建议重启服务器 (reboot) 以彻底清理内核内存驻留。"
    fi
    
    log_info "卸载完成。"
    exit 0
}

# ================= 4. 智能系统优化 =================

optimize_system() {
    print_banner "系统内核优化 (ASP-Tuned)"
    echo -e "  ${CYAN}▶ 正在深度接管系统调度与网络协议栈...${NC}"
    
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local rmem_max=$((mem_kb * 1024 / 2))
    local tcp_mem_min=$((mem_kb / 16)); local tcp_mem_def=$((mem_kb / 8)); local tcp_mem_max=$((mem_kb / 4))
    
    local dirty_ratio=20
    local dirty_bg_ratio=5
    local dirty_bytes=""
    local dirty_bg_bytes=""
    local backlog=65535
    local syn_backlog=65535
    
    # 智能穿透侦测 BBR 版本
    local avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "bbr cubic reno")
    local kernel_name=$(uname -r | tr '[:upper:]' '[:lower:]')
    local target_cc="bbr"
    local ui_cc="bbr"

    if [[ "$TUNE_MODE" == "1" ]]; then
        rmem_max=1073741824 
        tcp_wmem="4096 65536 1073741824"
        tcp_rmem="4096 87380 1073741824"
        # 修复：防止 mmap 下极限囤积造成 OOM，强制积极刷盘 (绝对字节数策略)
        dirty_bytes=268435456
        dirty_bg_bytes=67108864
        backlog=250000
        syn_backlog=819200
        
        # BBRv3 / BBRx 穿透识别逻辑
        if echo "$avail_cc" | grep -qw "bbrx" || echo "$kernel_name" | grep -q "bbrx"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbrx" && echo "bbrx" || echo "bbr")
            ui_cc="bbrx"
        elif echo "$avail_cc" | grep -qw "bbr3" || echo "$kernel_name" | grep -qE "bbr3|bbrv3"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbr3" && echo "bbr3" || echo "bbr")
            ui_cc="bbrv3"
        fi
        
        if [ ! -f /etc/asp_original_governor ]; then
            cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null > /etc/asp_original_governor || echo "ondemand" > /etc/asp_original_governor
        fi
    else
        [[ $rmem_max -gt 134217728 ]] && rmem_max=134217728
        tcp_wmem="4096 65536 $rmem_max"
        tcp_rmem="4096 87380 $rmem_max"
        dirty_ratio=20
        dirty_bg_ratio=5
    fi

    # 1. 写入极限 sysctl 配置
    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 1048576
fs.nr_open = 1048576
vm.swappiness = 1
EOF

    if [[ "$TUNE_MODE" == "1" ]]; then
        cat >> /etc/sysctl.d/99-ptbox.conf << EOF
vm.dirty_bytes = $dirty_bytes
vm.dirty_background_bytes = $dirty_bg_bytes
EOF
    else
        cat >> /etc/sysctl.d/99-ptbox.conf << EOF
vm.dirty_ratio = $dirty_ratio
vm.dirty_background_ratio = $dirty_bg_ratio
EOF
    fi

    cat >> /etc/sysctl.d/99-ptbox.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $target_cc
net.core.somaxconn = 65535
net.core.netdev_max_backlog = $backlog
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem
net.ipv4.tcp_mem = $tcp_mem_min $tcp_mem_def $tcp_mem_max
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
EOF

    # 2. 解除文件描述符封印
    if ! grep -q "Auto-Seedbox-PT" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF
# Auto-Seedbox-PT Limits
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF
    fi

    # 3. 构造网卡与 CPU 调度器动态脚本
    cat > /usr/local/bin/asp-tune.sh << EOF_SCRIPT
#!/bin/bash
IS_VIRT=\$(systemd-detect-virt 2>/dev/null || echo "none")

if [[ "$TUNE_MODE" == "1" ]]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "\$f" ] && echo "performance" > "\$f" 2>/dev/null
    done
fi

for disk in \$(lsblk -nd --output NAME | grep -v '^md' | grep -v '^loop'); do
    blockdev --setra 4096 "/dev/\$disk" 2>/dev/null
    if [[ "\$IS_VIRT" == "none" ]]; then
        queue_path="/sys/block/\$disk/queue"
        if [ -f "\$queue_path/scheduler" ]; then
            rot=\$(cat "\$queue_path/rotational")
            if [ "\$rot" == "0" ]; then
                echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null || echo "none" > "\$queue_path/scheduler" 2>/dev/null
            else
                echo "bfq" > "\$queue_path/scheduler" 2>/dev/null || echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null
            fi
        fi
    fi
done
ETH=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
if [ -n "\$ETH" ]; then
    ifconfig "\$ETH" txqueuelen 10000 2>/dev/null
    ethtool -G "\$ETH" rx 4096 tx 4096 2>/dev/null || true
    ethtool -G "\$ETH" rx 2048 tx 2048 2>/dev/null || true 
fi
DEF_ROUTE=\$(ip -o -4 route show to default | head -n1)
if [[ -n "\$DEF_ROUTE" ]]; then
    ip route change \$DEF_ROUTE initcwnd 25 initrwnd 25 2>/dev/null || true
fi
EOF_SCRIPT
    chmod +x /usr/local/bin/asp-tune.sh

    cat > /etc/systemd/system/asp-tune.service << EOF
[Unit]
Description=Auto-Seedbox-PT Tuning Service
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/asp-tune.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable asp-tune.service >/dev/null 2>&1

    # 核心应用环节 (带 UI 动画)
    execute_with_spinner "注入百万级并发与高吞吐网络参数" sysctl --system
    execute_with_spinner "重载网卡队列与 CPU 性能调度器" systemctl start asp-tune.service || true
    
    # 构建装逼矩阵面板
    local rmem_mb=$((rmem_max / 1024 / 1024))
    echo ""
    echo -e "  ${PURPLE}[⚡ ASP-Tuned 核心调优矩阵已挂载]${NC}"
    echo -e "  ${CYAN}├─${NC} 拥塞控制算法 : ${GREEN}${ui_cc}${NC} (智能穿透匹配)"
    echo -e "  ${CYAN}├─${NC} 全局并发上限 : ${YELLOW}1,048,576${NC} (解除 Socket 封印)"
    echo -e "  ${CYAN}├─${NC} TCP 缓冲上限 : ${YELLOW}${rmem_mb} MB${NC} (极限吞吐保障)"
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "  ${CYAN}├─${NC} 脏页回写策略 : ${YELLOW}bytes=${dirty_bytes}, bg_bytes=${dirty_bg_bytes}${NC} (防 I/O 阻塞)"
        echo -e "  ${CYAN}├─${NC} CPU 调度策略 : ${RED}performance${NC} (锁定最高主频)"
    else
        echo -e "  ${CYAN}├─${NC} 脏页回写策略 : ${YELLOW}ratio=${dirty_ratio}, bg_ratio=${dirty_bg_ratio}${NC} (防 I/O 阻塞)"
        echo -e "  ${CYAN}├─${NC} CPU 调度策略 : ${GREEN}ondemand/schedutil${NC} (动态节能)"
    fi
    echo -e "  ${CYAN}└─${NC} 磁盘与网卡流 : ${YELLOW}I/O Multi-Queue & TX-Queue 扩容${NC}"
    echo ""

    echo -e " ${GREEN}[√] 底层内核引擎 (Mode $TUNE_MODE) 已全面接管！${NC}"
}

# ================= 5. 应用部署逻辑 =================

install_qbit() {
    print_banner "部署 qBittorrent 引擎"
    local arch=$(uname -m); local url=""
    local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
    
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        INSTALLED_MAJOR_VER="4"
        log_info "锁定版本: 4.x (绑定 libtorrent v1.2.20) -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        
    elif [[ "$QB_VER_REQ" == "5" || "$QB_VER_REQ" == "5.0.4" ]]; then
        INSTALLED_MAJOR_VER="5"
        log_info "锁定版本: 5.x (绑定 libtorrent v2.0.11 支持 mmap) -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
        
    else
        INSTALLED_MAJOR_VER="5"
        log_info "请求动态版本: $QB_VER_REQ -> 正在连接 GitHub API..."
        
        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL --max-time 10 "$api" | jq -r '.[0].tag_name' 2>/dev/null || echo "null")
        else
            tag=$(curl -sL --max-time 10 "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' 2>/dev/null | head -n 1 || echo "null")
        fi
        
        # API 防灾兜底机制
        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_warn "GitHub API 获取失败或受限，触发本地仓库兜底机制！"
            log_info "已自动降级为您个人的稳定内置版本: 5.0.4"
            [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
        else
            log_info "成功获取上游指定版本: $tag"
            local fname="${arch}-qbittorrent-nox"
            url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        fi
    fi
    
    download_file "$url" "/usr/bin/qbittorrent-nox"
    chmod +x /usr/bin/qbittorrent-nox
    
    mkdir -p "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local/share/qBittorrent/BT_backup"
    chown -R "$APP_USER:$APP_USER" "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local"

    rm -f "$HB/.config/qBittorrent/qBittorrent.conf.lock"
    rm -f "$HB/.local/share/qBittorrent/BT_backup/.lock"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")
    local root_disk=$(df $HB | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//;s/\/dev\///')
    local is_ssd=false
    if [ -f "/sys/block/$root_disk/queue/rotational" ] && [ "$(cat /sys/block/$root_disk/queue/rotational)" == "0" ]; then is_ssd=true; fi
    
    # 动态缓存大小计算（如果用户没有指定 -c）
    if [[ "${CACHE_SET_BY_USER:-false}" == "false" ]]; then
        local total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
        if [[ "$TUNE_MODE" == "1" ]]; then
            QB_CACHE=$((total_mem_mb * 35 / 100))
        else
            QB_CACHE=$((total_mem_mb * 15 / 100))
            [[ $QB_CACHE -gt 2048 ]] && QB_CACHE=2048
        fi
    fi
    local cache_val="$QB_CACHE"
    local config_file="$HB/.config/qBittorrent/qBittorrent.conf"

    # 1. 基础引导配置
    cat > "$config_file" << EOF
[LegalNotice]
Accepted=true

[Preferences]
Downloads\SavePath=$HB/Downloads/
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$APP_USER
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16, 172.17.0.0/16
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\LocalHostAuthenticationEnabled=false
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\HTTPS\Enabled=false
Connection\PortRangeMin=$QB_BT_PORT
EOF

    chown "$APP_USER:$APP_USER" "$config_file"
    
    cat > /etc/systemd/system/qbittorrent-nox@.service << EOF
[Unit]
Description=qBittorrent Service (User: %i)
After=network.target
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QB_WEB_PORT
Restart=on-failure
LimitNOFILE=1048576
MemoryHigh=80%
MemoryMax=85%
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable "qbittorrent-nox@$APP_USER" >/dev/null 2>&1
    systemctl start "qbittorrent-nox@$APP_USER"
    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT" "tcp"; open_port "$QB_BT_PORT" "udp"

    # 2. 轮询等待 WebUI 就绪 (带UI增强)
    local api_ready=false
    printf "\e[?25l"
    for i in {1..20}; do
        printf "\r\033[K ${CYAN}[⠧]${NC} 轮询探测 API 接口引擎存活状态... ($i/20)"
        if curl -s -f "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/version" >/dev/null; then
            api_ready=true
            break
        fi
        sleep 1
    done
    printf "\e[?25h"

    # 3. 强制 WebAPI 参数注入
    if [[ "$api_ready" == "true" ]]; then
        printf "\r\033[K ${GREEN}[√]${NC} API 引擎握手成功！开始下发高级底层配置... \n"
        
        # 登录并获取 Cookie
        curl -s -c "$TEMP_DIR/qb_cookie.txt" --data "username=$APP_USER&password=$APP_PASS" "http://127.0.0.1:$QB_WEB_PORT/api/v2/auth/login" >/dev/null
        
        # 组装基础 PT 必选规范载荷 (强制纯TCP, 关DHT/PEX/LSD，开启向所有Tracker汇报)
        local json_payload="{\"bittorrent_protocol\":0,\"dht\":false,\"pex\":false,\"lsd\":false,\"announce_to_all_trackers\":true,\"announce_to_all_tiers\":true,\"queueing_enabled\":false,\"bdecode_depth_limit\":10000,\"bdecode_token_limit\":10000000,\"strict_super_seeding\":false,\"max_ratio_action\":0,\"max_ratio\":-1,\"max_seeding_time\":-1"
        
        # 根据调优模式区分连接与 I/O 策略
        if [[ "$TUNE_MODE" == "1" ]]; then
            # Mode 1: 极限刷流 (全开并发，降低半开连接防封，强制活跃任务数)
            json_payload="${json_payload},\"max_connec\":-1,\"max_connec_per_torrent\":-1,\"max_uploads\":-1,\"max_uploads_per_torrent\":-1,\"max_half_open_connections\":500,\"send_buffer_watermark\":51200,\"send_buffer_low_watermark\":10240,\"send_buffer_tos_mark\":2,\"connection_speed\":1000,\"peer_timeout\":120,\"upload_choking_algorithm\":1,\"seed_choking_algorithm\":1,\"async_io_threads\":32,\"max_active_downloads\":-1,\"max_active_uploads\":-1,\"max_active_torrents\":-1"
        else
            # Mode 2: 均衡保种 (限制并发，降低半开连接，保护 HDD)
            json_payload="${json_payload},\"max_connec\":2000,\"max_connec_per_torrent\":100,\"max_uploads\":500,\"max_uploads_per_torrent\":20,\"max_half_open_connections\":50,\"send_buffer_watermark\":10240,\"send_buffer_low_watermark\":3072,\"send_buffer_tos_mark\":2,\"connection_speed\":500,\"peer_timeout\":120,\"upload_choking_algorithm\":0,\"seed_choking_algorithm\":0,\"async_io_threads\":8"
        fi
        
        # 根据版本区分内存缓存机制
        if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
            # v5 专属：设置工作集限制，并强行切换为 POSIX IO 绕开 mmap，开启 Direct IO
            local hash_threads=$(nproc 2>/dev/null || echo 2)
            json_payload="${json_payload},\"memory_working_set_limit\":$cache_val,\"disk_io_type\":1,\"disk_io_read_mode\":1,\"disk_io_write_mode\":1,\"hashing_threads\":$hash_threads"
        else
            # v4 专属：传统的磁盘缓存控制 (Mode 2 延长过期时间)
            if [[ "$TUNE_MODE" == "1" ]]; then
                json_payload="${json_payload},\"disk_cache\":$cache_val,\"disk_cache_ttl\":600"
            else
                json_payload="${json_payload},\"disk_cache\":$cache_val,\"disk_cache_ttl\":1200"
            fi
        fi
        json_payload="${json_payload}}"

        # 发送设置请求
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$TEMP_DIR/qb_cookie.txt" -X POST --data-urlencode "json=$json_payload" "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/setPreferences")
        
        if [[ "$http_code" == "200" ]]; then
            echo -e " ${GREEN}[√]${NC} 引擎防泄漏与底层网络已完全锁定为极速状态！"
        else
            echo -e " ${RED}[X]${NC} API 注入失败 (Code: $http_code)，请手动配置。"
        fi
        rm -f "$TEMP_DIR/qb_cookie.txt"
    else
        echo -e "\n ${RED}[X]${NC} qBittorrent WebUI 未能在 20 秒内响应！"
    fi
}

install_apps() {
    print_banner "部署容器化应用 (Docker)"
    wait_for_lock
    
    if ! command -v docker >/dev/null; then
        execute_with_spinner "自动安装 Docker 环境" sh -c "curl -fsSL https://get.docker.com | sh || (apt-get update && apt-get install -y docker.io)"
    fi

    if [[ "$DO_VX" == "true" ]]; then
        echo -e " ${CYAN}▶ 正在处理 Vertex (智能轮询) 核心逻辑...${NC}"
        
        docker rm -f vertex &>/dev/null || true
        
        # 1. 预先构建 Vertex 核心目录树
        mkdir -p "$HB/vertex/data/"{client,douban,irc,push,race,rss,rule,script,server,site,watch}
        mkdir -p "$HB/vertex/data/douban/set" "$HB/vertex/data/watch/set"
        mkdir -p "$HB/vertex/data/rule/"{delete,link,rss,race,raceSet}

        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$HB/vertex/data/setting.json"
        local need_init=true

        # 2. 判断并处理数据恢复
        if [[ -n "$VX_RESTORE_URL" ]]; then
            local is_tar=false
            if [[ "$VX_RESTORE_URL" == *.tar.gz* || "$VX_RESTORE_URL" == *.tgz* ]]; then
                is_tar=true
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.tar.gz"
                execute_with_spinner "解压原生 tar.gz 备份数据" tar -xzf "$TEMP_DIR/bk.tar.gz" -C "$HB/vertex/data/"
            else
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.zip"
                local unzip_cmd="unzip -o"
                [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P\"$VX_ZIP_PASS\""
                execute_with_spinner "解压 ZIP 备份数据" sh -c "$unzip_cmd \"$TEMP_DIR/bk.zip\" -d \"$HB/vertex/data/\""
            fi
            need_init=false
        elif [[ -f "$set_file" ]]; then
            log_info "检测到本地已有配置，执行原地接管..."
            need_init=false
        fi

        # 3. 静态注入配置
        if [[ "$need_init" == "false" ]]; then
            log_info "智能桥接备份数据与新网络架构..."
            if [[ -f "$set_file" ]]; then
                jq --arg u "$APP_USER" --arg p "$vx_pass_md5" \
                   '.username = $u | .password = $p' "$set_file" > "${set_file}.tmp" && \
                   mv "${set_file}.tmp" "$set_file" || true
            fi

            local gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
            shopt -s nullglob
            local client_files=("$HB/vertex/data/client/"*.json)
            if [ ${#client_files[@]} -gt 0 ]; then
                for client in "${client_files[@]}"; do
                    if grep -q "qBittorrent" "$client"; then
                         jq --arg url "http://$gw:$QB_WEB_PORT" \
                            --arg user "$APP_USER" \
                            --arg pass "$APP_PASS" \
                            '.clientUrl = $url | .username = $user | .password = $pass' \
                            "$client" > "${client}.tmp" && mv "${client}.tmp" "$client" || true
                    fi
                done
            fi
            shopt -u nullglob
        else
            cat > "$set_file" << EOF
{
  "username": "$APP_USER",
  "password": "$vx_pass_md5",
  "port": 3000
}
EOF
        fi

        chown -R "$APP_USER:$APP_USER" "$HB/vertex"
        chmod -R 777 "$HB/vertex/data"

        execute_with_spinner "拉取 Vertex 镜像 (文件较大，视网络情况约需 1~3 分钟)" docker pull lswl/vertex:stable
        execute_with_spinner "启动 Vertex 容器" docker run -d --name vertex --restart unless-stopped -p $VX_PORT:3000 -v "$HB/vertex":/vertex -e TZ=Asia/Shanghai lswl/vertex:stable
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        echo -e " ${CYAN}▶ 正在处理 FileBrowser 核心逻辑...${NC}"
        rm -rf "$HB/.config/filebrowser" "$HB/fb.db"; mkdir -p "$HB/.config/filebrowser" && touch "$HB/fb.db" && chmod 666 "$HB/fb.db"
        chown -R "$APP_USER:$APP_USER" "$HB/.config/filebrowser" "$HB/fb.db"

        docker rm -f filebrowser &>/dev/null || true
        execute_with_spinner "拉取 FileBrowser 镜像" docker pull filebrowser/filebrowser:latest
        
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest config init >/dev/null 2>&1
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin >/dev/null 2>&1
        execute_with_spinner "启动 FileBrowser 容器" docker run -d --name filebrowser --restart unless-stopped --user 0:0 -v "$HB":/srv -v "$HB/fb.db":/database/filebrowser.db -v "$HB/.config/filebrowser":/config -p $FB_PORT:80 filebrowser/filebrowser:latest
        open_port "$FB_PORT"
    fi
}

# ================= 6. 入口主流程 =================

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --uninstall) ACTION="uninstall"; shift ;;
        --purge) ACTION="purge"; shift ;;
        -u|--user) APP_USER="$2"; shift 2 ;;
        -p|--pass) APP_PASS="$2"; shift 2 ;;
        -c|--cache) QB_CACHE="$2"; CACHE_SET_BY_USER=true; shift 2 ;;
        -q|--qbit) QB_VER_REQ="$2"; shift 2 ;;
        -m|--mode) TUNE_MODE="$2"; shift 2 ;;
        -v|--vertex) DO_VX=true; shift ;;
        -f|--filebrowser) DO_FB=true; shift ;;
        -t|--tune) DO_TUNE=true; shift ;;
        -o|--custom-port) CUSTOM_PORT=true; shift ;;
        -d|--data) VX_RESTORE_URL="$2"; shift 2 ;;
        -k|--key) VX_ZIP_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ "$TUNE_MODE" != "1" && "$TUNE_MODE" != "2" ]]; then
    TUNE_MODE="1"
fi

if [[ "$ACTION" == "uninstall" ]]; then
    uninstall ""
elif [[ "$ACTION" == "purge" ]]; then
    uninstall "--purge"
fi

# ================= 开始全新极客仪表盘 UI =================
clear

echo -e "${CYAN}        ___   _____   ___  ${NC}"
echo -e "${CYAN}       / _ | / __/ |/ _ \\ ${NC}"
echo -e "${CYAN}      / __ |_\\ \\  / ___/ ${NC}"
echo -e "${CYAN}     /_/ |_/___/ /_/     ${NC}"
echo -e "${BLUE}========================================================${NC}"
echo -e "${PURPLE}   ✦ Auto-Seedbox-PT (ASP) 极速部署引擎 v1.6.6 ✦${NC}"
echo -e "${PURPLE}   ✦ 作者：Supcutie Github：yimouleng/Auto-Seedbox-PT ✦${NC}"
echo -e "${BLUE}========================================================${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 环境预检 ══════════════════╗${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "  检查 Root 权限...... [${RED}X${NC}] 拒绝通行"
    log_err "权限不足：请使用 root 用户运行本脚本！"
else
    echo -e "  检查 Root 权限...... [${GREEN}√${NC}] 通行"
fi

mem_kb_chk=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_gb_chk=$((mem_kb_chk / 1024 / 1024))
tune_downgraded=false
if [[ "$TUNE_MODE" == "1" && $mem_gb_chk -lt 4 ]]; then
    TUNE_MODE="2"
    tune_downgraded=true
    echo -e "  检测 物理内存....... [${RED}!${NC}] ${mem_gb_chk} GB ${RED}(不足4G,触发降级保护)${NC}"
else
    echo -e "  检测 物理内存....... [${GREEN}√${NC}] ${mem_gb_chk} GB"
fi

arch_chk=$(uname -m)
echo -e "  检测 系统架构....... [${GREEN}√${NC}] ${arch_chk}"
kernel_chk=$(uname -r)
echo -e "  检测 内核版本....... [${GREEN}√${NC}] ${kernel_chk}"

if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "  检测 网络连通性..... [${GREEN}🌐${NC}] 正常"
else
    echo -e "  检测 网络连通性..... [${YELLOW}!${NC}] 异常 (后续拉取依赖可能失败)"
fi

echo -n -e "  检查 DPKG 锁状态.... "
wait_for_lock_silent() {
    local max_wait=60; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -n "."
        sleep 1; waited=$((waited + 1))
        [[ $waited -ge $max_wait ]] && break
    done
}
wait_for_lock_silent
echo -e "[${GREEN}√${NC}] 就绪"

echo ""
echo -e " ${GREEN}√ 环境预检通过${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 模式配置 ══════════════════╗${NC}"
echo ""

if [[ "$DO_TUNE" == "true" ]]; then
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "  当前选定模式: ${RED}极限刷流 (Mode 1)${NC}"
        echo -e "  推荐场景:     ${YELLOW}大内存/G口/万兆独服抢种${NC}"
        echo -e "  风险提示:     ${RED}会锁定CPU高频并暴增内核缓冲区，极大消耗内存！${NC}"
        echo ""
        echo -e "  ${YELLOW}请确认上方风险，3秒后开始部署...${NC}"
        sleep 3
    else
        echo -e "  当前选定模式: ${GREEN}均衡保种 (Mode 2)${NC}"
        echo -e "  推荐场景:     ${GREEN}家用NAS/普通VPS稳定保种${NC}"
        if [[ "$tune_downgraded" == "true" ]]; then
            echo -e "  ${YELLOW}※ 已触发防呆机制，为您强制降级至此模式以防 OOM 死机。${NC}"
        fi
        echo ""
    fi
else
     echo -e "  当前选定模式: ${GREEN}默认 (未开启系统内核调优)${NC}"
     echo ""
fi

if [[ -z "$APP_USER" ]]; then APP_USER="admin"; fi
if [[ -n "$APP_PASS" ]]; then validate_pass "$APP_PASS"; fi

if [[ -z "$APP_PASS" ]]; then
    while true; do
        echo -n -e "  ▶ 请输入 Web 面板统一密码 (必须 ≥ 8 位): "
        read -s APP_PASS < /dev/tty; echo ""
        if [[ ${#APP_PASS} -ge 8 ]]; then break; fi
        log_warn "密码过短，请重新输入！"
    done
    echo ""
fi

# 使用全新的加载器更新源
export DEBIAN_FRONTEND=noninteractive
execute_with_spinner "部署核心运行依赖 (curl, jq, tar...)" sh -c "apt-get -qq update && apt-get -qq install -y curl wget jq unzip tar python3 net-tools ethtool iptables"

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e " ${CYAN}╔══════════════════ 自定义端口 ════════════════╗${NC}"
    echo ""
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080); QB_BT_PORT=$(get_input_port "qBit BT监听" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

setup_user
install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && optimize_system

PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "ServerIP")

# ================= 极简极客版终端 Dashboard =================
echo ""
echo ""
VX_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")

cat << EOF
========================================================================
                    ✨ AUTO-SEEDBOX-PT 部署完成 ✨                     
========================================================================
  [系统状态] 
EOF
echo -e "  ▶ 调优模式 : $([[ "$TUNE_MODE" == "1" ]] && echo "${RED}Mode 1 (极限刷流)${NC}" || echo "${GREEN}Mode 2 (均衡保种)${NC}")"
echo -e "  ▶ 运行用户 : ${YELLOW}$APP_USER${NC} (已做运行目录隔离，保障安全)"
echo ""
echo -e " ------------------------ ${CYAN}🌐 终端访问地址${NC} ------------------------"
echo -e "  🧩 qBittorrent WebUI : ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"
if [[ "$DO_VX" == "true" ]]; then
echo -e "  🌐 Vertex 智控面板   : ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
echo -e "     └─ 内部直连 qBit  : ${YELLOW}$VX_GW:$QB_WEB_PORT${NC}"
fi
if [[ "$DO_FB" == "true" ]]; then
echo -e "  📁 FileBrowser 文件  : ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
fi

echo ""
echo -e " ------------------------ ${CYAN}🔐 统一鉴权凭证${NC} ------------------------"
echo -e "  👤 面板统一账号 : ${YELLOW}$APP_USER${NC}"
echo -e "  🔑 面板统一密码 : ${YELLOW}$APP_PASS${NC}"
echo -e "  📡 BT 监听端口  : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP 已尝试放行)"

echo ""
echo -e " ------------------------ ${CYAN}📂 核心数据目录${NC} ------------------------"
echo -e "  ⬇️ 种子下载目录 : $HB/Downloads"
echo -e "  ⚙️ qBit 配置文件: $HB/.config/qBittorrent"
[[ "$DO_VX" == "true" ]] && echo -e "  📦 Vertex 数据  : $HB/vertex/data"

echo ""
echo -e " ------------------------ ${CYAN}🛠️ 日常维护指令${NC} ------------------------"
echo -e "  重启 qBit : ${YELLOW}systemctl restart qbittorrent-nox@$APP_USER${NC}"
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && echo -e "  重启容器  : ${YELLOW}docker restart vertex filebrowser${NC}"
echo -e "  卸载脚本  : ${YELLOW}bash ./asp.sh --uninstall${NC}"

echo -e "========================================================================"
if [[ "$DO_TUNE" == "true" ]]; then
echo -e " ⚠️ ${YELLOW}强烈建议: 极速内核参数已注入，请执行 reboot 重启服务器以完全生效！${NC}"
echo -e "========================================================================"
fi
echo ""
