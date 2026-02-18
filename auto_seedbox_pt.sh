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

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 默认端口配置
QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

# 用户输入变量
QB_USER=""
QB_PASS=""
QB_CACHE=1024
QB_VER_REQ="4.3.9" 

# 功能开关
DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false 
VX_RESTORE_URL=""
VX_ZIP_PASS=""

# 内部状态
INSTALLED_MAJOR_VER="4"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 4.3.9 黄金版本硬编码源
URL_V4_AMD64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
URL_V4_ARM64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/aarch64-qbittorrent-nox"

# ================= 1. 基础工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

# 修复：使用 if 结构确保函数在 Root 权限下返回状态码 0
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "必须使用 root 权限运行 (sudo bash ...)"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_err "本脚本仅支持 Debian 或 Ubuntu 系统。"
        fi
    else
        log_err "无法检测操作系统类型。"
    fi
}

# 修复：使用 ! 逻辑确保端口空闲时函数返回 0（成功）
is_port_free() {
    local port=$1
    if command -v ss >/dev/null; then
        ! ss -tuln | grep -q ":$port "
    else
        ! netstat -tuln 2>/dev/null | grep -q ":$port "
    fi
}

get_input_port() {
    local prompt=$1
    local default=$2
    local port
    while true; do
        read -p "$prompt [默认 $default]: " port
        port=${port:-$default}
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_warn "请输入 1-65535 之间的数字"
            continue
        fi
        if ! is_port_free "$port"; then
            log_warn "端口 $port 已被占用，请更换!"
            continue
        fi
        echo "$port"
        break
    done
}

prepare_env() {
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
        log_err "不支持的 CPU 架构: $ARCH"
    fi

    local deps=("curl" "wget" "jq" "unzip" "python3")
    local install_needed=false
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null; then install_needed=true; break; fi
    done

    if [[ "$install_needed" == "true" ]]; then
        log_info "正在安装必要组件 (jq, curl, unzip, python3)..."
        export DEBIAN_FRONTEND=noninteractive
        # 增加等待 apt 锁释放的逻辑
        apt-get -qq update && apt-get -qq install -y "${deps[@]}" net-tools >/dev/null
    fi
}

# ================= 2. qBittorrent 模块 =================

install_qbit() {
    local home="/home/$QB_USER"
    local url=""

    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        log_info "锁定经典版本: 4.3.9 (Static)"
        [[ "$ARCH" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        INSTALLED_MAJOR_VER="4"
    else
        log_info "正在搜索请求的版本: $QB_VER_REQ ..."
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL "${api}/latest" | jq -r .tag_name)
        else
            tag=$(curl -sL "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
        fi

        [[ -z "$tag" || "$tag" == "null" ]] && log_err "未找到匹配版本。"
        
        local fname="x86_64-qbittorrent-nox"
        [[ "$ARCH" == "aarch64" ]] && fname="aarch64-qbittorrent-nox"
        url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        [[ "$tag" =~ release-5 ]] && INSTALLED_MAJOR_VER="5" || INSTALLED_MAJOR_VER="4"
    fi

    wget -q --show-progress -t 3 -O /usr/bin/qbittorrent-nox "$url"
    chmod +x /usr/bin/qbittorrent-nox

    if ! id "$QB_USER" &>/dev/null; then useradd -m -s /bin/bash "$QB_USER"; fi
    mkdir -p "$home/.config/qBittorrent" "$home/Downloads"
    chown -R "$QB_USER:$QB_USER" "$home"

    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), os.urandom(16), 100000); print(f'@ByteArray({base64.b64encode(os.urandom(16)).decode()}:{base64.b64encode(dk).decode()})')" "$QB_PASS")

    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        cat > "$home/.config/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\DefaultSavePath=$home/Downloads/
Session\AsyncIOThreadsCount=0
Session\SendBufferWatermark=3072
Session\QueueingSystemEnabled=false
Session\IgnoreLimitsOnLocalNetwork=true
Session\SuggestMode=true
[Preferences]
Connection\PortRangeMin=$QB_BT_PORT
Downloads\DiskWriteCacheSize=-1
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$QB_USER
EOF
    else
        local aio=4; local buf=10240
        cat > "$home/.config/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\DefaultSavePath=$home/Downloads/
Session\AsyncIOThreadsCount=$aio
Session\SendBufferWatermark=$buf
Session\QueueingSystemEnabled=false
Session\IgnoreLimitsOnLocalNetwork=true
[Preferences]
Connection\PortRangeMin=$QB_BT_PORT
Downloads\DiskWriteCacheSize=$QB_CACHE
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$QB_USER
EOF
    fi
    chown "$QB_USER:$QB_USER" "$home/.config/qBittorrent/qBittorrent.conf"

    cat > /etc/systemd/system/qbittorrent-nox@.service << EOF
[Unit]
Description=qBittorrent Service
After=network.target
[Service]
Type=simple
User=%i
Group=%i
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QB_WEB_PORT
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "qbittorrent-nox@$QB_USER" >/dev/null 2>&1
    systemctl restart "qbittorrent-nox@$QB_USER"
}

# ================= 3. Docker 模块 =================

install_apps() {
    if ! command -v docker >/dev/null; then
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
        systemctl enable docker; systemctl start docker
    fi
    
    local uid=$(id -u "$QB_USER")
    local gid=$(id -g "$QB_USER")
    local home="/home/$QB_USER"

    if [[ "$DO_VX" == "true" ]]; then
        mkdir -p "$home/vertex"
        if [[ -n "$VX_RESTORE_URL" ]]; then
            wget -q -O "$TEMP_DIR/v.zip" "$VX_RESTORE_URL"
            local u_cmd="unzip -o"
            [[ -n "$VX_ZIP_PASS" ]] && u_cmd="unzip -o -P $VX_ZIP_PASS"
            $u_cmd "$TEMP_DIR/v.zip" -d "$home/vertex/" >/dev/null
            find "$home/vertex/data/client" -name "*.json" -print0 2>/dev/null | xargs -0 sed -i "s/\"port\": [0-9]*/\"port\": $QB_WEB_PORT/g" 2>/dev/null || true
        fi
        chown -R "$uid:$gid" "$home/vertex"
        docker rm -f vertex &>/dev/null || true
        docker run -d --name vertex --restart unless-stopped \
            -p $VX_PORT:3000 -v "$home/vertex":/vertex \
            -e TZ=Asia/Shanghai -e PUID=$uid -e PGID=$gid lswl/vertex:stable >/dev/null
    fi

    if [[ "$DO_FB" == "true" ]]; then
        touch "$home/fb.db" && chown "$uid:$gid" "$home/fb.db"
        docker rm -f filebrowser &>/dev/null || true
        docker run -d --name filebrowser --restart unless-stopped \
            -v "$home":/srv -v "$home/fb.db":/database/filebrowser.db \
            -p $FB_PORT:80 -u $uid:$gid filebrowser/filebrowser:latest >/dev/null
    fi
}

# ================= 4. 系统优化 =================

sys_tune() {
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak
    cat > /etc/sysctl.d/99-ptbox-base.conf << EOF
fs.file-max = 2097152
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 1
vm.dirty_ratio = 80
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 50
EOF
    else
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
EOF
    fi
    sysctl --system >/dev/null 2>&1
}

# ================= 5. 卸载模块 =================

uninstall() {
    read -p "请输入要卸载的用户名: " u
    [[ -z "$u" ]] && exit 1
    systemctl stop "qbittorrent-nox@$u" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@$u" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox
    if command -v docker >/dev/null; then docker rm -f vertex filebrowser 2>/dev/null || true; fi
    rm -f /etc/sysctl.d/99-ptbox-*.conf
    sysctl --system >/dev/null 2>&1
    [[ "$1" == "--purge" ]] && { userdel -r "$u" 2>/dev/null || rm -rf "/home/$u"; }
    log_info "卸载完成。"
    exit 0
}

# ================= 6. 主程序入口 =================

if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

while getopts "u:p:c:q:vfd:k:toh" opt; do
    case $opt in
        u) QB_USER=$OPTARG ;;
        p) QB_PASS=$OPTARG ;;
        c) QB_CACHE=$OPTARG ;;
        q) QB_VER_REQ=$OPTARG ;;
        v) DO_VX=true ;;
        f) DO_FB=true ;;
        d) VX_RESTORE_URL=$OPTARG ;;
        k) VX_ZIP_PASS=$OPTARG ;;
        t) DO_TUNE=true ;;
        o) CUSTOM_PORT=true ;;
        h) echo "See README"; exit 0 ;;
    esac
done

check_root; check_os; prepare_env

[[ -z "$QB_USER" ]] && read -p "请输入用户名: " QB_USER
[[ -z "$QB_PASS" ]] && { echo -n "请输入密码 (≥12位): "; read -s QB_PASS; echo ""; }
while [[ ${#QB_PASS} -lt 12 ]]; do
    log_warn "密码太短!"
    echo -n "请设置至少 12 位密码: "
    read -s QB_PASS; echo ""
done

if [[ "$CUSTOM_PORT" == "true" ]]; then
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBit BT监听" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
else
    if ! is_port_free "$QB_WEB_PORT" || ! is_port_free "$QB_BT_PORT"; then
        log_err "默认端口被占用，请使用 -o 运行!"
    fi
fi

install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && sys_tune

PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")
echo -e "\n${GREEN}Auto-Seedbox-PT 安装成功!${NC}"
echo "--------------------------------------------------------"
echo "🧩 qBittorrent: http://$PUB_IP:$QB_WEB_PORT"
[[ "$DO_VX" == "true" ]] && echo "🌐 Vertex:      http://$PUB_IP:$VX_PORT"
[[ "$DO_FB" == "true" ]] && echo "📁 FileBrowser: http://$PUB_IP:$FB_PORT"
echo "--------------------------------------------------------"
if [ "$DO_TUNE" = true ]; then echo -e "${YELLOW}提示: 已应用内核深度优化，建议重启服务器 (reboot)${NC}"; fi
