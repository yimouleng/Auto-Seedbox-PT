#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v1.0 
# qBittorrent  + libtorrent  + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名 (用于运行服务和登录WebUI)
#   -p : 密码（必须 ≥ 8 位）
#   -c : qBittorrent 缓存大小 (MiB)
#   -q : qBittorrent 版本 (4.3.9)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser
#   -t : 启用系统内核优化（强烈推荐）
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
QB_VER_REQ="4.3.9" 
DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false
VX_RESTORE_URL=""
VX_ZIP_PASS=""
INSTALLED_MAJOR_VER="4"

# 默认 Home 目录，稍后根据用户动态调整
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
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f "$output" 2>/dev/null || true
    fi
    if ! wget -q --show-progress --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "下载失败，请检查网络或 URL: $url"
    fi
}

print_banner() {
    echo -e "${BLUE}------------------------------------------------${NC}"
    echo -e "${BLUE}   Auto-Seedbox-PT  >>  $1${NC}"
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
    local port=$1; local proto=${2:-tcp}
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$port/$proto" >/dev/null 2>&1 || true
    fi
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "$prompt [默认 $default]: " port < /dev/tty
        port=${port:-$default}
        [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] && echo "$port" && return 0
        log_warn "无效输入，请输入 1-65535 端口号。"
    done
}

# ================= 2. 用户管理 (核心逻辑) =================

setup_user() {
    # 兼容 Root 用户
    if [[ "$APP_USER" == "root" ]]; then
        HB="/root"
        log_info "以 Root 身份运行服务。"
        return
    fi

    # 检测系统用户是否存在
    if id "$APP_USER" &>/dev/null; then
        log_info "系统用户 $APP_USER 已存在，将直接复用。"
    else
        log_info "创建系统用户: $APP_USER"
        useradd -m -s /bin/bash "$APP_USER"
    fi

    # 动态获取该用户的 Home 目录
    HB=$(eval echo ~$APP_USER)
    log_info "工作目录设定为: $HB"
}

# ================= 3. 深度卸载逻辑 =================

uninstall() {
    local mode=$1
    print_banner "执行深度卸载流程"
    read -p "确认要卸载所有组件吗？此操作不可逆！ [y/n]: " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi

    log_info "1. 停止并移除服务..."
    # 停止所有相关服务
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
        if [[ "$mode" == "--purge" ]]; then
            log_warn "执行 Docker 系统级清理..."
            docker system prune -af --volumes >/dev/null 2>&1 || true
        fi
    fi

    log_info "3. 移除系统优化..."
    systemctl stop asp-tune.service 2>/dev/null || true
    systemctl disable asp-tune.service 2>/dev/null || true
    rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
    if [ -f /etc/security/limits.conf ]; then
        sed -i '/# Auto-Seedbox-PT/d' /etc/security/limits.conf || true
    fi
    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true

    if [[ "$mode" == "--purge" ]]; then
        log_warn "4. 尝试清理用户数据..."
        read -p "是否删除相关的配置文件? (不会删除用户本身) [y/n]: " del_conf < /dev/tty
        if [[ "$del_conf" =~ ^[Yy]$ ]]; then
             rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser"
             rm -rf "/home/*/.config/qBittorrent" "/home/*/vertex" "/home/*/.config/filebrowser"
             log_info "配置文件已清除。"
        fi
    fi
    
    log_info "卸载完成。"
    exit 0
}

# ================= 4. 智能系统优化 (增强版) =================

optimize_system() {
    print_banner "应用智能系统优化 (ASP-Tuned)"
    
    # 动态内存计算 (更精确适配不同内存大小)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local rmem_max=$((mem_kb * 1024 / 2)); [[ $rmem_max -gt 134217728 ]] && rmem_max=134217728
    local tcp_mem_min=$((mem_kb / 16)); local tcp_mem_def=$((mem_kb / 8)); local tcp_mem_max=$((mem_kb / 4))

    # 1. Sysctl 内核参数优化
    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 1048576
fs.nr_open = 1048576
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 65536 $rmem_max
net.ipv4.tcp_mem = $tcp_mem_min $tcp_mem_def $tcp_mem_max
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
EOF
    sysctl --system >/dev/null 2>&1 || true

    # 2. 优化文件句柄限制
    if ! grep -q "Auto-Seedbox-PT" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF
# Auto-Seedbox-PT Limits
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF
    fi

    # 3. 增强版开机启动脚本 (虚拟化检测 + 磁盘调度 + 网卡优化)
    cat > /usr/local/bin/asp-tune.sh << 'EOF_SCRIPT'
#!/bin/bash

# 1. 虚拟化检测 (避免在虚拟机中无效设置调度器)
IS_VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")

# 2. 磁盘 I/O 优化
for disk in $(lsblk -nd --output NAME | grep -v '^md' | grep -v '^loop'); do
    # 通用优化：预读 (Read-Ahead) - 对物理机和虚拟机都有效
    blockdev --setra 4096 "/dev/$disk" 2>/dev/null

    # 仅物理机调整调度器
    if [[ "$IS_VIRT" == "none" ]]; then
        queue_path="/sys/block/$disk/queue"
        if [ -f "$queue_path/scheduler" ]; then
            rot=$(cat "$queue_path/rotational")
            if [ "$rot" == "0" ]; then
                echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || echo "none" > "$queue_path/scheduler" 2>/dev/null
            else
                echo "bfq" > "$queue_path/scheduler" 2>/dev/null || echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null
            fi
        fi
    fi
done

# 3. 网络物理层与路由优化
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
if [ -n "$ETH" ]; then
    # 增加传输队列
    ifconfig "$ETH" txqueuelen 10000 2>/dev/null
    # Ring Buffer (接收/发送缓冲区)
    ethtool -G "$ETH" rx 4096 tx 4096 2>/dev/null || true
    ethtool -G "$ETH" rx 2048 tx 2048 2>/dev/null || true 
fi

# 4. 拥塞窗口优化 (InitCWND) - 提升慢启动速度
DEF_ROUTE=$(ip -o -4 route show to default | head -n1)
if [[ -n "$DEF_ROUTE" ]]; then
    ip route change $DEF_ROUTE initcwnd 25 initrwnd 25 2>/dev/null || true
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
    log_info "智能系统优化 (内核+磁盘+网络) 已应用。"
}

# ================= 5. 应用部署逻辑 =================

install_qbit() {
    print_banner "部署 qBittorrent"
    local arch=$(uname -m); local url=""
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        INSTALLED_MAJOR_VER="4"
    else
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=$(curl -sL "$api" | jq -r --arg v "$QB_VER_REQ" 'if $v == "latest" then .[0].tag_name else .[].tag_name | select(contains($v)) end' | head -n 1)
        local fname="${arch}-qbittorrent-nox"; [[ "$arch" == "x86_64" ]] && fname="x86_64-qbittorrent-nox"
        url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        [[ "$tag" =~ release-5 ]] && INSTALLED_MAJOR_VER="5" || INSTALLED_MAJOR_VER="4"
    fi
    
    download_file "$url" "/usr/bin/qbittorrent-nox"
    chmod +x /usr/bin/qbittorrent-nox
    
    mkdir -p "$HB/.config/qBittorrent" "$HB/Downloads"
    chown -R "$APP_USER:$APP_USER" "$HB/.config/qBittorrent" "$HB/Downloads"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")
    local threads_val="4"; local cache_val="$QB_CACHE"
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then cache_val="-1"; threads_val="0"
    else
        local root_disk=$(df /root | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//;s/\/dev\///')
        if [ -f "/sys/block/$root_disk/queue/rotational" ] && [ "$(cat /sys/block/$root_disk/queue/rotational)" == "0" ]; then threads_val="16"; fi
    fi

    cat > "$HB/.config/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\DefaultSavePath=$HB/Downloads/
Session\AsyncIOThreadsCount=$threads_val
[Preferences]
Connection\PortRangeMin=$QB_BT_PORT
Downloads\DiskWriteCacheSize=$QB_CACHE
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$APP_USER
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16, 172.17.0.0/16
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\LocalHostAuthenticationEnabled=false
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\HTTPS\Enabled=false
EOF
    chown "$APP_USER:$APP_USER" "$HB/.config/qBittorrent/qBittorrent.conf"
    
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
    systemctl restart "qbittorrent-nox@$APP_USER"
    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT" "tcp"; open_port "$QB_BT_PORT" "udp"
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
        print_banner "部署 Vertex (Smart-Polling)"
        
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

        # 启动容器
        log_info "启动 Vertex 容器..."
        docker run -d --name vertex \
            --restart unless-stopped \
            -p $VX_PORT:3000 \
            -v "$HB/vertex":/vertex \
            -e TZ=Asia/Shanghai \
            lswl/vertex:stable

        if [[ "$need_init" == "true" ]]; then
            log_info "等待容器初始化目录结构..."
            local count=0
            while [ ! -d "$HB/vertex/data/rule" ] && [ $count -lt 30 ]; do
                echo -n "."
                sleep 1
                ((count++))
            done
            echo ""
            docker stop vertex >/dev/null 2>&1 || true
        else
            log_info "智能修正备份中的下载器配置..."
            docker stop vertex >/dev/null 2>&1 || true
            local gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
            if ls "$HB/vertex/data/client/"*.json 1> /dev/null 2>&1; then
                for client in "$HB/vertex/data/client/"*.json; do
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
        fi

        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$HB/vertex/data/setting.json"
        
        if [[ -f "$set_file" ]]; then
            log_info "同步面板访问配置..."
            jq --arg u "$APP_USER" --arg p "$vx_pass_md5" --argjson pt 3000 \
                '.username = $u | .password = $p | .port = $pt' "$set_file" > "${set_file}.tmp" && \
                mv "${set_file}.tmp" "$set_file"
        else
            cat > "$set_file" << EOF
{
  "username": "$APP_USER",
  "password": "$vx_pass_md5",
  "port": 3000
}
EOF
        fi
        
        chown "$APP_USER:$APP_USER" "$HB/vertex"

        log_info "重启 Vertex 服务..."
        docker start vertex
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        print_banner "部署 FileBrowser"
        rm -rf "$HB/.config/filebrowser" "$HB/fb.db"; mkdir -p "$HB/.config/filebrowser" && touch "$HB/fb.db" && chmod 666 "$HB/fb.db"
        chown -R "$APP_USER:$APP_USER" "$HB/.config/filebrowser" "$HB/fb.db"

        docker rm -f filebrowser &>/dev/null || true
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest config init
        docker run --rm --user 0:0 -v "$HB/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin
        
        docker run -d --name filebrowser --restart unless-stopped --user 0:0 -v "$HB":/srv -v "$HB/fb.db":/database/filebrowser.db -v "$HB/.config/filebrowser":/config -p $FB_PORT:80 filebrowser/filebrowser:latest
        open_port "$FB_PORT"
    fi
}

# ================= 6. 入口主流程 =================

case "${1:-}" in
    --uninstall) uninstall "";;
    --purge) uninstall "--purge";;
esac

while getopts "u:p:c:q:vftod:k:" opt; do
    case $opt in u) APP_USER=$OPTARG ;; p) APP_PASS=$OPTARG ;; c) QB_CACHE=$OPTARG ;; q) QB_VER_REQ=$OPTARG ;; v) DO_VX=true ;; f) DO_FB=true ;; t) DO_TUNE=true ;; o) CUSTOM_PORT=true ;; d) VX_RESTORE_URL=$OPTARG ;; k) VX_ZIP_PASS=$OPTARG ;; esac
done

check_root
if [[ -z "$APP_USER" ]]; then APP_USER="admin"; fi
if [[ -n "$APP_PASS" ]]; then validate_pass "$APP_PASS"; fi

print_banner "环境初始化"
wait_for_lock; export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool >/dev/null

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
echo -e "${GREEN}           Auto-Seedbox-PT 安装成功!                    ${NC}"
echo -e "${GREEN}########################################################${NC}"

echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"

if [[ "$DO_VX" == "true" ]]; then
    VX_IN_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vertex 2>/dev/null || echo "Unknown")
    VX_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
    echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
    echo -e "    └─ Docker 内网: ${BLUE}$VX_IN_IP:3000${NC}"
    echo -e "    └─ 内网连接qBit: ${YELLOW}$VX_GW:$QB_WEB_PORT${NC}"
fi

if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
fi

echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🔐 ${GREEN}账号信息${NC}"
echo -e "系统用户: ${YELLOW}$APP_USER${NC}"
echo -e "Web 密码: ${YELLOW}$APP_PASS${NC}"
echo -e "BT 端口 : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP)"
echo -e "${BLUE}========================================================${NC}"

[[ "$DO_TUNE" == "true" ]] && echo -e "${YELLOW}提示: 智能系统优化已生效。${NC}"
warn "建议重启系统以确保所有优化生效 (命令: reboot)"
echo ""
