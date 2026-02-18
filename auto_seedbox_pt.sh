#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v1.0 
# qBittorrent  + libtorrent  + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名
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

# ================= 0. 全局变量与配色 =================
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

TEMP_DIR=$(mktemp -d -t asp-XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/x86_64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/ARM64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"

# ================= 1. 核心工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

download_file() {
    local url=$1
    local output=$2
    log_info "正在从网络获取资源: $(basename "$output")"
    if ! wget -q --show-progress --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "文件下载失败！请检查网络连接或链接是否有效。\nURL: $url"
    fi
}

print_banner() {
    echo -e "${BLUE}------------------------------------------------${NC}"
    echo -e "${BLUE}   Auto-Seedbox-PT  >>  $1${NC}"
    echo -e "${BLUE}------------------------------------------------${NC}"
}

check_root() { 
    [[ $EUID -ne 0 ]] && log_err "权限不足：请使用 root 用户运行本脚本！"
}

# 密码安全性检查
validate_pass() {
    if [[ ${#1} -lt 8 ]]; then
        log_err "密码安全性不足：长度必须大于或等于 8 位！当前长度为 ${#1}。"
    fi
}

wait_for_lock() {
    local max_wait=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        sleep 2; waited=$((waited + 2))
        [[ $waited -ge $max_wait ]] && break
    done
}

open_port() {
    local port=$1; local proto=${2:-tcp}
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$port/$proto" >/dev/null 2>&1 || log_warn "UFW 端口 $port 放行失败。"
    fi
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "$prompt [默认 $default]: " port < /dev/tty
        port=${port:-$default}
        [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] && echo "$port" && return 0
        log_warn "输入无效，请输入 1-65535 之间的数字。"
    done
}

# ================= 2. 卸载逻辑 =================

uninstall() {
    local mode=$1
    print_banner "执行卸载流程"
    read -p "确认要卸载所有组件吗？ [y/n]: " confirm < /dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    log_info "清理原生服务..."
    systemctl stop "qbittorrent-nox@root" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@root" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox

    log_info "移除 Docker 容器..."
    if command -v docker >/dev/null; then
        docker rm -f vertex filebrowser 2>/dev/null || true
    fi

    log_info "还原系统优化..."
    systemctl stop asp-tune.service 2>/dev/null || true
    systemctl disable asp-tune.service 2>/dev/null || true
    rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
    systemctl daemon-reload
    sysctl --system || true

    if [[ "$mode" == "--purge" ]]; then
        log_warn "深度清理用户配置..."
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/fb.db"
        read -p "是否同步删除下载目录 /root/Downloads ? [y/n]: " del_dl < /dev/tty
        [[ "$del_dl" =~ ^[Yy]$ ]] && rm -rf "/root/Downloads"
    fi
    log_info "卸载完成。"
    exit 0
}

# ================= 3. 系统持久化优化 (-t) =================

optimize_system() {
    print_banner "应用持久化系统优化"
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local rmem_max=$((mem_kb * 1024 / 2)); [[ $rmem_max -gt 134217728 ]] && rmem_max=134217728
    local tcp_mem_min=$((mem_kb / 16)); local tcp_mem_def=$((mem_kb / 8)); local tcp_mem_max=$((mem_kb / 4))

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
EOF
    sysctl --system || log_warn "部分内核参数无法应用。"

    cat > /usr/local/bin/asp-tune.sh << 'EOF_SCRIPT'
#!/bin/bash
for disk in $(lsblk -nd --output NAME | grep -v '^md' | grep -v '^loop'); do
    queue_path="/sys/block/$disk/queue"
    if [ -f "$queue_path/scheduler" ]; then
        rot=$(cat "$queue_path/rotational")
        [[ "$rot" == "0" ]] && (echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || echo "none" > "$queue_path/scheduler" 2>/dev/null) \
                           || (echo "bfq" > "$queue_path/scheduler" 2>/dev/null || echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null)
        blockdev --setra 4096 "/dev/$disk" 2>/dev/null
    fi
done
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
[[ -n "$ETH" ]] && (ifconfig "$ETH" txqueuelen 10000 2>/dev/null; ethtool -G "$ETH" rx 4096 tx 4096 2>/dev/null || true)
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
    systemctl start asp-tune.service || log_warn "优化服务启动异常。"
}

# ================= 4. 应用部署逻辑 =================

install_qbit() {
    print_banner "部署 qBittorrent"
    local hb="/root"; local arch=$(uname -m); local url=""
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
    mkdir -p "$hb/.config/qBittorrent" "$hb/Downloads"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")
    local threads_val="4"; local cache_val="$QB_CACHE"
    [[ "$INSTALLED_MAJOR_VER" == "5" ]] && (cache_val="-1"; threads_val="0") || \
    ([[ -f "/sys/block/sda/queue/rotational" && "$(cat /sys/block/sda/queue/rotational)" == "0" ]] && threads_val="16")

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
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16, 172.17.0.0/16
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\HTTPS\Enabled=false
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
    systemctl daemon-reload && systemctl enable "qbittorrent-nox@root" >/dev/null 2>&1
    systemctl restart "qbittorrent-nox@root"
    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT" "tcp"; open_port "$QB_BT_PORT" "udp"
}

install_apps() {
    wait_for_lock; apt-get -qq install docker.io -y || log_err "Docker 安装失败。"
    local hb="/root"
    if [[ "$DO_VX" == "true" ]]; then
        print_banner "部署 Vertex (Smart-Polling 模式)"
        mkdir -p "$hb/vertex/data" && chmod -R 777 "$hb/vertex"
        docker rm -f vertex &>/dev/null || true
        log_info "启动 Vertex 容器..."
        docker run -d --name vertex -p $VX_PORT:3000 -v "$hb/vertex":/vertex -e TZ=Asia/Shanghai lswl/vertex:stable
        
        log_info "监控内部结构生成..."
        local wait_count=0
        while true; do
            if [[ -f "$hb/vertex/data/setting.json" ]] && [[ -d "$hb/vertex/data/rule" ]]; then
                log_info "检测到原生结构已就绪。"
                break
            fi
            sleep 1; wait_count=$((wait_count+1))
            [[ $wait_count -ge 60 ]] && log_warn "初始化超时，强制继续。" && break
        done
        
        docker stop vertex || true
        
        if [[ -n "$VX_RESTORE_URL" ]]; then
            download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.zip"
            local unzip_cmd="unzip -o"
            [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P\"$VX_ZIP_PASS\""
            eval "$unzip_cmd \"$TEMP_DIR/bk.zip\" -d \"$hb/vertex/\"" || log_warn "备份解压失败。"
        fi
        
        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$hb/vertex/data/setting.json"
        if [[ -f "$set_file" ]]; then
            log_info "原子化写入配置..."
            jq --arg u "$APP_USER" --arg p "$vx_pass_md5" --argjson pt 3000 \
               '.username = $u | .password = $p | .port = $pt' "$set_file" > "${set_file}.tmp" && \
               mv "${set_file}.tmp" "$set_file" || log_err "jq 处理配置文件失败。"
        else
            cat > "$set_file" << EOF
{ "username": "$APP_USER", "password": "$vx_pass_md5", "port": 3000 }
EOF
        fi
        docker start vertex || log_err "Vertex 启动失败。"
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        print_banner "部署 FileBrowser"
        rm -rf "$hb/.config/filebrowser" "$hb/fb.db"; mkdir -p "$hb/.config/filebrowser" && touch "$hb/fb.db" && chmod 666 "$hb/fb.db"
        docker rm -f filebrowser &>/dev/null || true
        docker run --rm --user 0:0 -v "$hb/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest config init
        docker run --rm --user 0:0 -v "$hb/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin
        docker run -d --name filebrowser --restart unless-stopped --user 0:0 -v "$hb":/srv -v "$hb/fb.db":/database/filebrowser.db -v "$hb/.config/filebrowser":/config -p $FB_PORT:80 filebrowser/filebrowser:latest
        open_port "$FB_PORT"
    fi
}

# ================= 5. 主流程控制 =================

case "${1:-}" in
    --uninstall) uninstall "";;
    --purge) uninstall "--purge";;
esac

while getopts "u:p:c:q:vftod:k:" opt; do
    case $opt in u) APP_USER=$OPTARG ;; p) APP_PASS=$OPTARG ;; c) QB_CACHE=$OPTARG ;; q) QB_VER_REQ=$OPTARG ;; v) DO_VX=true ;; f) DO_FB=true ;; t) DO_TUNE=true ;; o) CUSTOM_PORT=true ;; d) VX_RESTORE_URL=$OPTARG ;; k) VX_ZIP_PASS=$OPTARG ;; esac
done

check_root
# 如果通过参数传入了密码，立刻校验
[[ -n "$APP_PASS" ]] && validate_pass "$APP_PASS"

print_banner "环境预检"
wait_for_lock; export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool >/dev/null

if [[ -z "$APP_PASS" ]]; then
    while true; do
        echo -n "请输入 Web 面板统一密码 (必须 ≥ 8 位): "
        read -s APP_PASS < /dev/tty
        echo ""
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

install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && optimize_system

PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "ServerIP")

echo ""
echo -e "${GREEN}########################################################${NC}"
echo -e "${GREEN}          Auto-Seedbox-PT 安装成功!                    ${NC}"
echo -e "${GREEN}########################################################${NC}"
echo -e "Web 账号: ${YELLOW}$APP_USER${NC}"
echo -e "Web 密码: ${YELLOW}(您设定的密码)${NC}"
echo -e "BT 端口 : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP)"
echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"
if [[ "$DO_VX" == "true" ]]; then
    echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
    echo -e "   └─ 提示: 下载器地址请填 ${YELLOW}172.17.0.1:$QB_WEB_PORT${NC}"
fi
if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
fi
echo -e "${BLUE}========================================================${NC}"
[[ "$DO_TUNE" == "true" ]] && echo -e "${YELLOW}提示: 深度持久化优化已生效。${NC}"
