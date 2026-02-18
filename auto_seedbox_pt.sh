#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v1.0 
# qBittorrent  + libtorrent  + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名
#   -p : 密码
#   -c : qBittorrent 缓存大小 (MiB)
#   -q : qBittorrent 版本 (4.3.9)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser
#   -t : 启用系统内核优化（强烈推荐）
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
################################################################################

您非常敏锐！这正是我在从 V1.x 重构到 V2.3 时遗漏的一个关键细节。

qBittorrent v4 (基于 libtorrent 1.x) 和 v5 (基于 libtorrent 2.x) 的核心存储机制完全不同：

v4：高度依赖软件自身的内存缓存 (DiskWriteCacheSize) 和 异步 I/O 线程。

v5：使用 内存映射 (Memory Mapped I/O)，应该禁用软件缓存 (DiskWriteCacheSize=-1)，转而让 Linux 内核（通过 PageCache）来管理内存。

在 V2.3 中，我虽然做了内核级的 sysctl 优化，但 qBittorrent 的配置文件 (qBittorrent.conf) 没有针对 v5 做区分。

为了达到您要求的“完美”，必须补上这个逻辑。

🚀 Auto-Seedbox-PT (ASP) v2.4 - 双核深度优化版
本次更新 (V2.4) 的核心升级：

v4/v5 智能分流：

v4 模式：启用应用层缓存 (-c 参数生效)，根据 SSD/HDD 自动计算 I/O 线程数。

v5 模式：强制关闭应用层缓存 (DiskWriteCacheSize=-1)，将内存管理权交给我们在 sys_tune 中优化过的 Linux 内核，这是 v5 跑满带宽的关键。

磁盘类型检测：在生成配置时自动检测是 SSD 还是 HDD，分别设置不同的线程策略。

请使用此版本覆盖 GitHub：

Bash
#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v2.4 - 双核深度优化版
# 
# [V2.4 升级日志]
# 1. v4/v5 差异化配置：
#    - v4: 使用 RAM Cache + 多线程 I/O (适合 Libtorrent 1.x)
#    - v5: 使用 OS PageCache (MMap) + 禁用应用缓存 (适合 Libtorrent 2.x)
# 2. 硬件感知：根据 SSD/HDD 自动调整 v4 的 AsyncIO 线程数。
# 3. 继承 V2.3 所有特性：锁等待、Docker 重试、自动防火墙、Root 独享。
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'

QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

APP_USER="admin"     
APP_PASS=""          
QB_CACHE=1024
QB_VER_REQ="4.3.9" 

DO_VX=false; DO_FB=false; DO_TUNE=false; CUSTOM_PORT=false 
INSTALLED_MAJOR_VER="4"  # 默认初始值

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

URL_V4_AMD64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
URL_V4_ARM64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/aarch64-qbittorrent-nox"

# ================= 1. 核心工具 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

check_root() { if [[ $EUID -ne 0 ]]; then log_err "请使用 sudo -i 切换到 root 后运行！"; fi; }

wait_for_lock() {
    local max_wait=300
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -eq 0 ]; then log_warn "系统后台正在更新，等待锁释放..."; fi
        sleep 2
        waited=$((waited + 2))
        if [ $waited -ge $max_wait ]; then
            log_warn "等待超时，尝试强制解锁..."
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock
            break
        fi
    done
}

open_port() {
    local port=$1; local proto=${2:-tcp}
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "$port"; then ufw allow "$port/$proto" >/dev/null; fi
    fi
}

is_port_free() {
    local port=$1
    if command -v ss >/dev/null; then ! ss -tuln | grep -q ":$port "; else ! netstat -tuln 2>/dev/null | grep -q ":$port "; fi
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "$prompt [默认 $default]: " port; port=${port:-$default}
        [[ ! "$port" =~ ^[0-9]+$ ]] && continue
        if ! is_port_free "$port"; then log_warn "端口 $port 被占用"; continue; fi
        echo "$port"; break
    done
}

# ================= 2. 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}=== 卸载模式 ===${NC}"
    read -p "警告：将停止服务并删除配置。确定继续吗？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
    
    systemctl stop "qbittorrent-nox@root" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@root" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox
    systemctl daemon-reload
    
    if command -v docker >/dev/null; then docker rm -f vertex filebrowser 2>/dev/null || true; fi
    rm -f /etc/sysctl.d/99-ptbox.conf
    sysctl --system >/dev/null 2>&1

    if [[ "${1:-}" == "--purge" ]]; then
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/fb.db"
        read -p "是否删除下载目录 (/root/Downloads)? [y/N]: " del_dl
        [[ "$del_dl" =~ ^[Yy]$ ]] && rm -rf "/root/Downloads"
    fi
    log_info "卸载完成。"
    exit 0
}

# ================= 3. 安装逻辑 =================

install_qbit() {
    local hb="/root"
    local url=""
    local arch=$(uname -m)

    # 版本判断逻辑
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        log_info "锁定经典版本: 4.3.9"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        INSTALLED_MAJOR_VER="4"
    else
        log_info "正在搜索版本: $QB_VER_REQ ..."
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=$(curl -sL "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
        
        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_warn "未找到匹配版本，回退至 4.3.9"
            [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
            INSTALLED_MAJOR_VER="4"
        else
            url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${arch}-qbittorrent-nox"
            if [[ "$tag" =~ release-5 ]]; then
                INSTALLED_MAJOR_VER="5"
            else
                INSTALLED_MAJOR_VER="4"
            fi
        fi
    fi

    log_info "正在下载 qBittorrent (核心: v${INSTALLED_MAJOR_VER})..."
    wget -q -O /usr/bin/qbittorrent-nox "$url"
    chmod +x /usr/bin/qbittorrent-nox
    mkdir -p "$hb/.config/qBittorrent" "$hb/Downloads"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")

    # [深度优化] 针对 v4 和 v5 生成不同的配置
    local cache_val=""
    local threads_val=""
    
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        # v5 (Libtorrent 2.x): 必须禁用应用层缓存，依赖 OS PageCache (MMap)
        log_info "检测到 v5 内核：应用 MMap 优化策略 (DiskWriteCacheSize=-1)"
        cache_val="-1" 
        threads_val="0" # v5 通常自动管理
    else
        # v4 (Libtorrent 1.x): 必须使用应用层缓存
        log_info "检测到 v4 内核：应用 RAM Cache 策略 ($QB_CACHE MiB)"
        cache_val="$QB_CACHE"
        
        # 简单的磁盘类型检测 (SSD vs HDD)
        local root_disk=$(df /root | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//;s/\/dev\///')
        # 尝试查找物理设备名
        local rot_path="/sys/block/$root_disk/queue/rotational"
        # 如果是 LVM 或其他情况找不到，尝试 lsblk
        if [ ! -f "$rot_path" ]; then
             root_disk=$(lsblk -nd -o NAME | head -1)
             rot_path="/sys/block/$root_disk/queue/rotational"
        fi

        if [ -f "$rot_path" ] && [ "$(cat $rot_path)" == "0" ]; then
            log_info "检测到 SSD：启用高性能多线程 I/O (16 threads)"
            threads_val="16"
        else
            log_info "检测到 HDD 或未知存储：使用保守 I/O (4 threads)"
            threads_val="4"
        fi
    fi

    cat > "$hb/.config/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\DefaultSavePath=$hb/Downloads/
Session\AsyncIOThreadsCount=$threads_val
[Preferences]
Connection\PortRangeMin=$QB_BT_PORT
Downloads\DiskWriteCacheSize=$cache_val
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$APP_USER
EOF
    
    cat > /etc/systemd/system/qbittorrent-nox@.service << EOF
[Unit]
Description=qBittorrent Service (Root)
After=network.target
[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QB_WEB_PORT
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "qbittorrent-nox@root" >/dev/null 2>&1
    systemctl restart "qbittorrent-nox@root"

    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT"; open_port "$QB_BT_PORT" "udp"
}

install_docker_retry() {
    if command -v docker >/dev/null; then return 0; fi
    log_info "正在安装 Docker..."
    local retries=3
    local count=0
    until [ $count -ge $retries ]; do
        wait_for_lock
        if curl -fsSL https://get.docker.com | bash; then return 0; fi
        count=$((count+1))
        log_warn "Docker 安装失败，5秒后重试 ($count/$retries)..."
        sleep 5
    done
    log_err "Docker 安装彻底失败，请检查网络。"
}

install_apps() {
    install_docker_retry
    local hb="/root"

    if [[ "$DO_VX" == "true" ]]; then
        log_info "正在部署 Vertex..."
        mkdir -p "$hb/vertex"
        docker rm -f vertex &>/dev/null || true
        docker run -d --name vertex --restart unless-stopped -p $VX_PORT:3000 -v "$hb/vertex":/vertex -e TZ=Asia/Shanghai -e PUID=0 -e PGID=0 lswl/vertex:stable >/dev/null
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        log_info "正在部署 FileBrowser..."
        rm -f "$hb/fb.db" && touch "$hb/fb.db" 
        mkdir -p "$hb/.config/filebrowser"
        docker rm -f filebrowser &>/dev/null || true
        
        docker run --rm -v "$hb/fb.db":/database/filebrowser.db --user 0:0 filebrowser/filebrowser:latest config init >/dev/null
        docker run --rm -v "$hb/fb.db":/database/filebrowser.db --user 0:0 filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin >/dev/null
        
        docker run -d --name filebrowser --restart unless-stopped \
            -v "$hb":/srv \
            -v "$hb/fb.db":/database/filebrowser.db \
            -v "$hb/.config/filebrowser":/config \
            -p $FB_PORT:80 --user 0:0 filebrowser/filebrowser:latest >/dev/null
        open_port "$FB_PORT"
    fi
}

sys_tune() {
    log_info "应用深度内核优化 (PT专用)..."
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak
    
    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 0
EOF
    sysctl --system >/dev/null 2>&1

    log_info "优化磁盘调度器..."
    for disk in $(lsblk -nd --output NAME 2>/dev/null | grep -v '^md'); do
        if [ -f /sys/block/$disk/queue/scheduler ]; then
            rotational=$(cat /sys/block/$disk/queue/rotational 2>/dev/null || echo 1)
            # SSD 使用 none/kyber, HDD 使用 mq-deadline
            if [ "$rotational" == "0" ]; then
                echo none > /sys/block/$disk/queue/scheduler 2>/dev/null || true
            else
                echo mq-deadline > /sys/block/$disk/queue/scheduler 2>/dev/null || true
            fi
        fi
    done

    log_info "优化网卡队列 (txqueuelen)..."
    local eth=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    if [ -n "$eth" ]; then
        ifconfig "$eth" txqueuelen 10000 2>/dev/null || ip link set "$eth" txqueuelen 10000 2>/dev/null || true
    fi
}

# ================= 4. 入口 =================

if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

while getopts "u:p:c:q:vfto" opt; do
    case $opt in
        u) APP_USER=$OPTARG ;; 
        p) APP_PASS=$OPTARG ;; 
        c) QB_CACHE=$OPTARG ;;
        v) DO_VX=true ;; f) DO_FB=true ;; t) DO_TUNE=true ;; o) CUSTOM_PORT=true ;;
    esac
done

check_root
wait_for_lock
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool >/dev/null

if [[ -z "$APP_USER" ]]; then
    read -p "请输入 Web 面板用户名 (默认 admin): " APP_USER
    APP_USER=${APP_USER:-admin}
fi

if [[ -z "$APP_PASS" ]]; then
    echo -n "请输入 Web 面板密码 (至少12位): "
    read -s APP_PASS; echo ""
fi

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e "${BLUE}--- 进入端口自定义设置 ---${NC}"
    QB_WEB_PORT=$(get_input_port "qBit Web" 8080)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && sys_tune

PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")

echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}      Auto-Seedbox-PT 安装成功! (V2.4 双核优化版)${NC}"
echo -e "${BLUE}========================================================${NC}"
echo -e "核心版本: ${YELLOW}qBittorrent v${INSTALLED_MAJOR_VER}${NC}"
echo -e "Web 账号: ${YELLOW}$APP_USER${NC}"
echo -e "Web 密码: ${YELLOW}(您刚才输入的密码)${NC}"
echo -e "数据目录: ${YELLOW}/root/Downloads${NC}"
echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"
[[ "$DO_VX" == "true" ]] && echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC} (初始账号 admin / vertex)"
[[ "$DO_FB" == "true" ]] && echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
echo -e "${BLUE}========================================================${NC}"
if [[ "$DO_TUNE" == "true" ]]; then echo -e "${YELLOW}提示: 深度内核优化已应用，建议重启服务器生效。${NC}"; fi
