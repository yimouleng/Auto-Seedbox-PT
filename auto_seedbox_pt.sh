#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v1.6.3
# qBittorrent  + libtorrent  + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名 (用于运行服务和登录WebUI)
#   -p : 密码（必须 ≥ 8 位）
#   -c : qBittorrent 缓存大小 (MiB, 仅4.x有效, 5.x使用mmap)
#   -q : qBittorrent 版本 (4.3.9, 5, latest, 或精确小版本如 5.0.4)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser
#   -t : 启用系统内核优化（强烈推荐）
#   -m : 调优模式 (1: 极限刷流 / 2: 均衡保种) [默认 1]
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
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
TUNE_MODE="1"
VX_RESTORE_URL=""
VX_ZIP_PASS=""
INSTALLED_MAJOR_VER="5"
ACTION="install" 

HB="/root"

TEMP_DIR=$(mktemp -d -t asp-XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/x86_64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/ARM64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"

# ================= 1. 核心工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

download_file() {
    local url=$1; local output=$2
    log_info "正在获取资源: $(basename "$output")"
    if [[ "$output" == "/usr/bin/qbittorrent-nox" ]]; then
        systemctl stop "qbittorrent-nox@$APP_USER" 2>/dev/null || true
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f "$output" 2>/dev/null || true
    fi
    if ! wget -q --show-progress --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "下载失败，请检查网络或 URL: $url"
    fi
}

print_banner() {
    echo -e "${BLUE}------------------------------------------------${NC}"
    echo -e "${BLUE}    Auto-Seedbox-PT  >>  $1${NC}"
    echo -e "${BLUE}------------------------------------------------${NC}"
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
        log_info "防火墙(UFW) 已放行端口: $port/$proto"
        added=true
    fi

    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "防火墙(Firewalld) 已放行端口: $port/$proto"
        added=true
    fi

    if command -v iptables >/dev/null; then
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
            log_info "防火墙(iptables) 已放行端口: $port/$proto"
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            added=true
        fi
    fi

    if [[ "$added" == "false" ]]; then
        log_warn "未检测到活跃的防火墙服务，端口 $port 可能已开放或需手动设置。"
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
        read -p "$prompt [默认 $default]: " port < /dev/tty
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
        log_info "创建系统用户: $APP_USER"
        useradd -m -s /bin/bash "$APP_USER"
    fi

    HB=$(eval echo ~$APP_USER)
    log_info "工作目录设定为: $HB"
}

# ================= 3. 深度卸载逻辑 =================

uninstall() {
    local mode=$1
    print_banner "执行深度卸载流程 (含系统回滚)"
    
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

    log_info "1. 停止并移除服务..."
    for svc in $(systemctl list-units --full -all | grep "qbittorrent-nox@" | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc"
    done
    pkill -9 qbittorrent-nox 2>/dev/null || true
    rm -f /usr/bin/qbittorrent-nox

    log_info "2. 清理 Docker 资源..."
    if command -v docker >/dev/null; then
        docker rm -f vertex filebrowser 2>/dev/null || true
        docker rmi lswl/vertex:stable filebrowser/filebrowser:latest 2>/dev/null || true
        docker network prune -f >/dev/null 2>&1 || true
    fi

    log_info "3. 移除系统优化与内核回滚..."
    systemctl stop asp-tune.service 2>/dev/null || true
    systemctl disable asp-tune.service 2>/dev/null || true
    rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
    if [ -f /etc/security/limits.conf ]; then
        sed -i '/# Auto-Seedbox-PT/d' /etc/security/limits.conf || true
    fi
    
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
    
    if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
        ufw delete allow $QB_WEB_PORT/tcp >/dev/null 2>&1 || true
        ufw delete allow $QB_BT_PORT/tcp >/dev/null 2>&1 || true
        ufw delete allow $QB_BT_PORT/udp >/dev/null 2>&1 || true
        ufw delete allow $VX_PORT/tcp >/dev/null 2>&1 || true
        ufw delete allow $FB_PORT/tcp >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --remove-port="$QB_WEB_PORT/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$QB_BT_PORT/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$QB_BT_PORT/udp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$VX_PORT/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$FB_PORT/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
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

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true

    if [[ "$mode" == "--purge" ]]; then
        log_warn "4. 清理配置文件..."
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
    print_banner "应用智能系统优化 (ASP-Tuned - 模式 $TUNE_MODE)"
    
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local rmem_max=$((mem_kb * 1024 / 2))
    local tcp_mem_min=$((mem_kb / 16)); local tcp_mem_def=$((mem_kb / 8)); local tcp_mem_max=$((mem_kb / 4))
    
    local dirty_ratio=60
    local dirty_bg_ratio=5
    local backlog=65535
    local syn_backlog=65535
    
    local avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "bbr cubic reno")
    local target_cc="bbr"

    if [[ "$TUNE_MODE" == "1" ]]; then
        rmem_max=1073741824 
        tcp_wmem="4096 65536 1073741824"
        tcp_rmem="4096 87380 1073741824"
        dirty_ratio=60
        dirty_bg_ratio=10
        backlog=250000
        syn_backlog=819200
        
        if echo "$avail_cc" | grep -qw "bbrx"; then
            target_cc="bbrx"
            log_warn "已侦测到 BBRx 自定义内核，自动挂载抢跑算法！"
        elif echo "$avail_cc" | grep -qw "bbr3"; then
            target_cc="bbr3"
            log_warn "已侦测到 BBRv3 内核，自动挂载高级拥塞算法！"
        fi
        
        if [ ! -f /etc/asp_original_governor ]; then
            cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null > /etc/asp_original_governor || echo "ondemand" > /etc/asp_original_governor
        fi
        
        log_warn "已启用极限内核参数，为 G口/万兆网卡 提供最大化吞吐支持！"
    else
        [[ $rmem_max -gt 134217728 ]] && rmem_max=134217728
        tcp_wmem="4096 65536 $rmem_max"
        tcp_rmem="4096 87380 $rmem_max"
        dirty_ratio=20
        dirty_bg_ratio=5
    fi

    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 1048576
fs.nr_open = 1048576
vm.swappiness = 1
vm.dirty_ratio = $dirty_ratio
vm.dirty_background_ratio = $dirty_bg_ratio
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
EOF
    sysctl --system >/dev/null 2>&1 || true

    if ! grep -q "Auto-Seedbox-PT" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF
# Auto-Seedbox-PT Limits
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF
    fi

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
    systemctl start asp-tune.service || true
    log_info "系统核心优化 (模式 $TUNE_MODE, TCP: $target_cc) 已应用完毕。"
}

# ================= 5. 应用部署逻辑 =================

install_qbit() {
    print_banner "部署 qBittorrent (WebAPI 自动化注入版)"
    local arch=$(uname -m); local url=""
    local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
    
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        INSTALLED_MAJOR_VER="4"
        log_info "锁定版本: 4.x (绑定 libtorrent v1.2.x)"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
    else
        INSTALLED_MAJOR_VER="5"
        log_info "锁定大版本: 5.x (绑定 libtorrent v2.0.x 支持 mmap)"
        local tag=""
        if [[ "$QB_VER_REQ" == "5" || "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL "$api" | jq -r '.[0].tag_name')
            log_info "正在拉取最新版本: $tag"
        else
            tag=$(curl -sL "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
            if [[ -z "$tag" || "$tag" == "null" ]]; then
                log_err "在 GitHub 仓库中未找到指定的 qBittorrent 版本: $QB_VER_REQ"
            fi
            log_info "正在拉取指定版本: $tag"
        fi
        local fname="${arch}-qbittorrent-nox"
        url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
    fi
    
    download_file "$url" "/usr/bin/qbittorrent-nox"
    chmod +x /usr/bin/qbittorrent-nox
    
    log_info "环境清理，挂起旧进程..."
    systemctl stop "qbittorrent-nox@$APP_USER" 2>/dev/null || true
    pkill -9 -u "$APP_USER" qbittorrent-nox 2>/dev/null || true
    
    mkdir -p "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local/share/qBittorrent/BT_backup"
    chown -R "$APP_USER:$APP_USER" "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local"

    rm -f "$HB/.config/qBittorrent/qBittorrent.conf.lock"
    rm -f "$HB/.local/share/qBittorrent/BT_backup/.lock"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")
    local root_disk=$(df $HB | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//;s/\/dev\///')
    local is_ssd=false
    if [ -f "/sys/block/$root_disk/queue/rotational" ] && [ "$(cat /sys/block/$root_disk/queue/rotational)" == "0" ]; then is_ssd=true; fi
    local threads_val="4"; local cache_val="$QB_CACHE"
    local config_file="$HB/.config/qBittorrent/qBittorrent.conf"

    # 1. 基础引导配置（仅保留最基础的存活要素，确保引擎能被启动）
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
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable "qbittorrent-nox@$APP_USER" >/dev/null 2>&1
    systemctl start "qbittorrent-nox@$APP_USER"
    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT" "tcp"; open_port "$QB_BT_PORT" "udp"

    # 2. 轮询等待 WebUI 就绪
    log_info "等待 qBittorrent 引擎初始化并提供 Web API 接口..."
    local api_ready=false
    for i in {1..20}; do
        if curl -s -f "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/version" >/dev/null; then
            api_ready=true
            break
        fi
        sleep 1
    done

    # 3. 强制 WebAPI 参数注入
    if [[ "$api_ready" == "true" ]]; then
        log_info "引擎就绪，正在通过官方 API 强推防泄漏与极限调优参数..."
        
        # 登录并获取 Cookie
        curl -s -c "$TEMP_DIR/qb_cookie.txt" --data "username=$APP_USER&password=$APP_PASS" "http://127.0.0.1:$QB_WEB_PORT/api/v2/auth/login" >/dev/null
        
        # [严谨修复] 官方最新底层 API 的精确拼写为 max_connec 及 max_connec_per_torrent (无 "s")
        # 组装基础 JSON 载荷
        local json_payload="{\"dht\":false,\"pex\":false,\"lsd\":false,\"announce_to_all_trackers\":true,\"announce_to_all_tiers\":true,\"max_connec\":-1,\"max_connec_per_torrent\":-1,\"max_uploads\":-1,\"max_uploads_per_torrent\":-1,\"max_ratio_action\":0,\"max_ratio\":-1,\"max_seeding_time\":-1,\"queueing_enabled\":false"
        
        # 注入 libtorrent 高级底层调优参数 (防爆内存与防吸血机制)
        json_payload="${json_payload},\"bdecode_depth_limit\":10000,\"bdecode_token_limit\":10000000,\"upload_choking_algorithm\":1,\"seed_choking_algorithm\":1,\"strict_super_seeding\":false"
        
        # 追加极限网络参数
        if [[ "$TUNE_MODE" == "1" ]]; then
            json_payload="${json_payload},\"max_half_open_connections\":1000,\"send_buffer_watermark\":51200,\"send_buffer_low_watermark\":10240,\"send_buffer_tos_mark\":2,\"connection_speed\":1000,\"peer_timeout\":120"
        fi
        
        # 追加版本差异参数
        if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
            json_payload="${json_payload},\"memory_working_set_limit\":$cache_val"
        else
            if [[ "$is_ssd" == "true" ]]; then 
                threads_val=$([[ "$TUNE_MODE" == "1" ]] && echo "32" || echo "16")
            else
                threads_val=$([[ "$TUNE_MODE" == "1" ]] && echo "8" || echo "4")
            fi
            json_payload="${json_payload},\"disk_cache\":$cache_val,\"async_io_threads\":$threads_val,\"disk_cache_ttl\":600"
        fi
        json_payload="${json_payload}}"

        # 发送设置请求
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$TEMP_DIR/qb_cookie.txt" -X POST --data-urlencode "json=$json_payload" "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/setPreferences")
        
        if [[ "$http_code" == "200" ]]; then
            log_info "API 配置下发完毕！引擎防泄漏与底层网络已锁定极速状态。"
        else
            log_warn "API 参数注入失败 (HTTP 状态码: $http_code)，请在 WebUI 中手动确认高级设置。"
        fi
        rm -f "$TEMP_DIR/qb_cookie.txt"
    else
        log_err "qBittorrent WebUI 未能在 20 秒内响应，请检查端口是否冲突或系统日志。"
    fi
}

install_apps() {
    print_banner "部署 Docker 及应用"
    wait_for_lock
    
    if ! command -v docker >/dev/null; then
        log_info "使用官方脚本安装 Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh >/dev/null 2>&1 || {
            log_warn "官方脚本安装失败，尝试回退到 APT 安装..."
            apt-get update && apt-get install -y docker.io
        }
        rm -f get-docker.sh
    fi

    if [[ "$DO_VX" == "true" ]]; then
        print_banner "部署 Vertex (智能轮询)"
        
        # 恢复初始版本最稳定的容器自身驱动架构逻辑
        mkdir -p "$HB/vertex/data"
        chmod 777 "$HB/vertex/data"
        docker rm -f vertex &>/dev/null || true
        
        local need_init=true
        if [[ -n "$VX_RESTORE_URL" ]]; then
            log_info "下载备份数据..."
            download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.zip"
            local unzip_cmd="unzip -o"
            [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P\"$VX_ZIP_PASS\""
            eval "$unzip_cmd \"$TEMP_DIR/bk.zip\" -d \"$HB/vertex/\"" || true
            need_init=false
        elif [[ -f "$HB/vertex/data/setting.json" ]]; then
             log_info "检测到已有配置，跳过初始化等待..."
             need_init=false
        fi

        log_info "启动 Vertex 容器..."
        docker run -d --name vertex \
            --restart unless-stopped \
            -p $VX_PORT:3000 \
            -v "$HB/vertex":/vertex \
            -e TZ=Asia/Shanghai \
            lswl/vertex:stable >/dev/null 2>&1

        # 让容器先跑起来释放文件，脚本进行安全等待
        echo -n -e "${YELLOW}等待 Vertex 容器初始化目录结构 ${NC}"
        sleep 5

        if [[ "$need_init" == "true" ]]; then
            local count=0
            while [ ! -d "$HB/vertex/data/rule" ] && [ $count -lt 30 ]; do
                echo -n "."
                sleep 1
                count=$((count + 1))
            done
            echo ""
            
            if [[ ! -d "$HB/vertex/data/rule" ]]; then
                log_warn "Vertex 目录初始化结束，正在触发智能干预，手动补全核心目录结构..."
                mkdir -p "$HB/vertex/data/"{client,douban,irc,push,race,rss,rule,script,server,site,watch}
                mkdir -p "$HB/vertex/data/douban/set" "$HB/vertex/data/watch/set"
                mkdir -p "$HB/vertex/data/rule/"{delete,link,rss,race,raceSet}
            else
                log_info "Vertex 初始目录结构已自动生成就绪。"
            fi
            
            log_info "修正目录权限..."
            chown -R "$APP_USER:$APP_USER" "$HB/vertex"
            chmod -R 777 "$HB/vertex/data"
            
            # 停止容器以防写入冲突
            docker stop vertex >/dev/null 2>&1 || true
        else
            log_info "智能修正备份中的下载器配置..."
            docker stop vertex >/dev/null 2>&1 || true
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
                log_info "连接信息已修正。"
            fi
            shopt -u nullglob
        fi

        # 强制精准注入用户指定的 Web 密码，彻底修复无效 bug
        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$HB/vertex/data/setting.json"
        
        if [[ -f "$set_file" ]]; then
            log_info "同步面板访问配置..."
            jq --arg u "$APP_USER" --arg p "$vx_pass_md5" \
                '.username = $u | .password = $p' "$set_file" > "${set_file}.tmp" && \
                mv "${set_file}.tmp" "$set_file" || true
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

        log_info "重启 Vertex 服务..."
        docker start vertex >/dev/null 2>&1 || true
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        print_banner "部署 FileBrowser"
        rm -rf "$HB/.config/filebrowser" "$HB/fb.db"; mkdir -p "$HB/.config/filebrowser" && touch "$HB/fb.db" && chmod 666 "$HB/fb.db"
        chown -R "$APP_USER:$APP_USER" "$HB/.config/filebrowser" "$HB/fb.db"

        docker rm -f filebrowser &>/dev/null || true
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest config init >/dev/null 2>&1
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin >/dev/null 2>&1
        
        docker run -d --name filebrowser --restart unless-stopped --user 0:0 -v "$HB":/srv -v "$HB/fb.db":/database/filebrowser.db -v "$HB/.config/filebrowser":/config -p $FB_PORT:80 filebrowser/filebrowser:latest >/dev/null 2>&1
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
        -c|--cache) QB_CACHE="$2"; shift 2 ;;
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

print_banner "环境初始化与前置检测"

mem_kb_chk=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_gb_chk=$((mem_kb_chk / 1024 / 1024))
if [[ "$TUNE_MODE" == "1" && $mem_gb_chk -lt 4 ]]; then
    echo -e "${RED}================================================================${NC}"
    echo -e "${RED} [拦截] 内存防呆机制触发！检测到系统物理内存不足 4GB (当前: ${mem_gb_chk}GB)！${NC}"
    echo -e "${RED} ⚠️ 极限模式 (分配 1GB TCP 发送/接收缓冲区) 会导致本机瞬间 OOM 死机！${NC}"
    echo -e "${RED} ⚠️ 已为您强制降级为 Balanced (均衡保种) 模式！${NC}"
    echo -e "${RED}================================================================${NC}"
    TUNE_MODE="2"
    sleep 3
fi

if [[ "$DO_TUNE" == "true" ]]; then
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "${RED}================================================================${NC}"
        echo -e "${RED} [警告] 您选择了 1 (极限刷流) 调优模式！${NC}"
        echo -e "${RED} ⚠️ 此模式会锁定 CPU 最高频率、暴增内核网络缓冲区，极大消耗内存！${NC}"
        echo -e "${RED} ⚠️ 仅推荐用于 大内存/G口/SSD 的独立服务器进行极限刷流抢种！${NC}"
        echo -e "${RED} ⚠️ 家用 NAS、或者只想保种刷流请终止安装，使用 -m 2 重新运行！${NC}"
        echo -e "${RED}================================================================${NC}"
        
        echo -e "${YELLOW}请仔细阅读以上高危警告，3秒后开始执行底层环境检测...${NC}"
        sleep 3
    else
        echo -e "${GREEN} -> 当前系统调优模式: 2 (均衡保种)${NC}"
    fi
fi

if [[ -z "$APP_USER" ]]; then APP_USER="admin"; fi
if [[ -n "$APP_PASS" ]]; then validate_pass "$APP_PASS"; fi

echo ""
log_info "-> [1/4] 检测系统基础架构与资源..."
arch_chk=$(uname -m); kernel_chk=$(uname -r)
echo -e "   架构: ${arch_chk} | 内核: ${kernel_chk} | 物理内存: ${mem_gb_chk} GB"
sleep 1 

log_info "-> [2/4] 验证管理员权限与网络连通性..."
check_root
if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "   网络连通性: 正常"
else
    log_warn "   网络连通性异常，后续依赖拉取可能失败！"
fi

log_info "-> [3/4] 检查系统包管理器状态 (等待 apt/dpkg 锁释放)..."
wait_for_lock
echo -e "   包管理器: 就绪 (无占用)"

log_info "-> [4/4] 更新软件源并安装核心依赖 (curl, jq, unzip, python3...)"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool iptables >/dev/null
echo -e "${GREEN} [就绪] 基础环境初始化与依赖部署完成！${NC}\n"

if [[ -z "$APP_PASS" ]]; then
    while true; do
        echo -n "请输入 Web 面板统一密码 (必须 ≥ 8 位): "
        read -s APP_PASS < /dev/tty; echo ""
        if [[ ${#APP_PASS} -ge 8 ]]; then break; fi
        log_warn "密码过短，请重新输入！"
    done
fi

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e "${BLUE}=======================================${NC}"
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080); QB_BT_PORT=$(get_input_port "qBit BT监听" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

setup_user
install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && optimize_system

PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "ServerIP")

echo ""
echo -e "${GREEN}########################################################${NC}"
echo -e "${GREEN}            Auto-Seedbox-PT 安装成功!                     ${NC}"
echo -e "${GREEN}########################################################${NC}"

echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"

if [[ "$DO_VX" == "true" ]]; then
    VX_IN_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vertex 2>/dev/null || echo "Unknown")
    VX_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
    echo -e "🌐 Vertex:       ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
    echo -e "    └─ 下载器连接填写: ${YELLOW}$VX_GW:$QB_WEB_PORT${NC}"
fi

if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
fi

echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🔐 ${GREEN}账号信息${NC}"
echo -e "系统用户: ${YELLOW}$APP_USER${NC}"
echo -e "Web 密码: ${YELLOW}$APP_PASS${NC}"
echo -e "BT 监听端口 : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP)"
echo -e "当前调优模式: ${YELLOW}$([[ "$TUNE_MODE" == "1" ]] && echo "1 (极限刷流)" || echo "2 (均衡保种)")${NC}"
echo -e "${BLUE}========================================================${NC}"

[[ "$DO_TUNE" == "true" ]] && echo -e "${YELLOW}提示: 智能系统优化已生效。${NC}"
log_warn "建议重启系统以确保所有优化生效 (命令: reboot)"
echo ""
