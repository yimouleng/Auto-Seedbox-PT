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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'

# 默认配置
QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

QB_USER="root"  # 强制 Root
QB_PASS=""
QB_CACHE=1024
QB_VER_REQ="4.3.9" 

# 开关与状态
DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false 
INSTALLED_MAJOR_VER="4"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 静态编译源
URL_V4_AMD64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
URL_V4_ARM64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/aarch64-qbittorrent-nox"

# ================= 1. 工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

check_root() { 
    if [[ $EUID -ne 0 ]]; then 
        log_err "请使用 sudo -i 切换到 root 用户后运行此脚本！"
    fi 
}

# 自动放行端口 (新增功能)
open_port() {
    local port=$1
    local proto=${2:-tcp}
    # 检测 UFW 是否激活
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "$port"; then
            ufw allow "$port/$proto" >/dev/null
            log_info "防火墙 (UFW) 已自动放行端口: $port ($proto)"
        fi
    fi
    # 如果是 iptables (非 UFW 环境)，可在此扩展，但 Debian/Ubuntu 主要是 UFW
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
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}       Auto-Seedbox-PT 卸载程序          ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    read -p "警告：将停止服务并删除配置。确定继续吗？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
    
    log_info "正在停止 qBittorrent 服务..."
    systemctl stop "qbittorrent-nox@root" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@root" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox
    systemctl daemon-reload
    
    if command -v docker >/dev/null; then 
        log_info "正在删除 Docker 容器..."
        docker rm -f vertex filebrowser 2>/dev/null || true
    fi
    
    rm -f /etc/sysctl.d/99-ptbox.conf
    sysctl --system >/dev/null 2>&1

    if [[ "${1:-}" == "--purge" ]]; then
        log_warn "正在深度清理 /root 下的配置文件..."
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/fb.db"
        
        read -p "是否同时删除下载目录 (/root/Downloads)? [y/N]: " del_dl
        if [[ "$del_dl" =~ ^[Yy]$ ]]; then
            rm -rf "/root/Downloads"
            log_info "下载目录已删除。"
        fi
    fi
    log_info "卸载完成。"
    exit 0
}

# ================= 3. 安装逻辑 =================

install_qbit() {
    local hb="/root"
    local url=""
    [[ "$(uname -m)" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"

    log_info "正在安装 qBittorrent (v4.3.9)..."
    wget -q -O /usr/bin/qbittorrent-nox "$url"
    chmod +x /usr/bin/qbittorrent-nox

    mkdir -p "$hb/.config/qBittorrent" "$hb/Downloads"
    
    # [关键修复] 密码 Salt 逻辑：确保生成的 Hash 和配置文件中的 Salt 严格对应
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$QB_PASS")

    # 写入配置
    cat > "$hb/.config/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\DefaultSavePath=$hb/Downloads/
Session\AsyncIOThreadsCount=12
[Preferences]
Connection\PortRangeMin=$QB_BT_PORT
Downloads\DiskWriteCacheSize=$QB_CACHE
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=root
EOF
    
    # 注册服务
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
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "qbittorrent-nox@root" >/dev/null 2>&1
    systemctl restart "qbittorrent-nox@root"

    # 自动放行端口
    open_port "$QB_WEB_PORT"
    open_port "$QB_BT_PORT"
    open_port "$QB_BT_PORT" "udp"
}

install_apps() {
    # 安装 Docker
    if ! command -v docker >/dev/null; then 
        log_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    fi
    
    local hb="/root"

    # 安装 Vertex
    if [[ "$DO_VX" == "true" ]]; then
        log_info "正在部署 Vertex..."
        mkdir -p "$hb/vertex"
        docker rm -f vertex &>/dev/null || true
        # PUID=0 使用 Root 权限
        docker run -d --name vertex --restart unless-stopped \
            -p $VX_PORT:3000 \
            -v "$hb/vertex":/vertex \
            -e TZ=Asia/Shanghai -e PUID=0 -e PGID=0 \
            lswl/vertex:stable >/dev/null
        
        open_port "$VX_PORT"
    fi

    # 安装 FileBrowser
    if [[ "$DO_FB" == "true" ]]; then
        log_info "正在部署 FileBrowser..."
        # 预创建文件，防止被 Docker 识别为目录
        touch "$hb/fb.db" 
        mkdir -p "$hb/.config/filebrowser"
        
        docker rm -f filebrowser &>/dev/null || true
        
        # 使用 --user 0:0 强制 Root 权限，修复 settings.json 写入失败问题
        docker run -d --name filebrowser --restart unless-stopped \
            -v "$hb":/srv \
            -v "$hb/fb.db":/database/filebrowser.db \
            -v "$hb/.config/filebrowser":/config \
            -p $FB_PORT:80 \
            --user 0:0 \
            filebrowser/filebrowser:latest >/dev/null
        
        open_port "$FB_PORT"
    fi
}

sys_tune() {
    log_info "正在应用系统内核优化..."
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak
    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 2097152
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
    sysctl --system >/dev/null 2>&1
}

# ================= 4. 主程序入口 =================

# 优先处理卸载
if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

# 解析参数
while getopts "p:c:q:vfto" opt; do
    case $opt in
        p) QB_PASS=$OPTARG ;; c) QB_CACHE=$OPTARG ;;
        v) DO_VX=true ;; f) DO_FB=true ;; t) DO_TUNE=true ;; o) CUSTOM_PORT=true ;;
    esac
done

check_root
# 安装基础依赖
log_info "正在检查并安装基础依赖 (curl, python3, ufw 等)..."
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools >/dev/null

# 密码交互
if [[ -z "$QB_PASS" ]]; then
    echo -n "请输入 WebUI 密码 (至少12位): "
    read -s QB_PASS
    echo ""
fi

# 端口交互
if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e "${BLUE}--- 进入端口自定义设置 ---${NC}"
    QB_WEB_PORT=$(get_input_port "qBittorrent WebUI" 8080)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

# 执行安装
install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && sys_tune

# 最终汇总输出
PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")

echo ""
echo -e "${BLUE}========================================================${NC}"
echo -e "${GREEN}      Auto-Seedbox-PT 安装成功! (Root独享版)${NC}"
echo -e "${BLUE}========================================================${NC}"
echo -e "运行用户: ${YELLOW}root${NC}"
echo -e "Web 密码: ${YELLOW}(您刚才输入的密码)${NC}"
echo -e "数据目录: ${YELLOW}/root/Downloads${NC}"
echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"
if [[ "$DO_VX" == "true" ]]; then
    echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC} (默认: admin / vertex)"
fi
if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
fi
echo -e "${BLUE}========================================================${NC}"
if [[ "$DO_TUNE" == "true" ]]; then 
    echo -e "${YELLOW}提示: 内核参数已优化，建议重启服务器 (reboot) 以获得最佳性能。${NC}"
fi
