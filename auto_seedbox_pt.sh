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

# ================= 0. 全局变量与配色 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# 默认端口
QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

# 参数默认值
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

TEMP_DIR=$(mktemp -d); trap 'rm -rf "$TEMP_DIR"' EXIT

# 下载源
URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/x86_64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent-4.3.9/ARM64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"

# ================= 1. 核心工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

print_banner() {
    echo -e "${BLUE}------------------------------------------------${NC}"
    echo -e "${BLUE}   Auto-Seedbox-PT  >>  $1${NC}"
    echo -e "${BLUE}------------------------------------------------${NC}"
}

check_root() { 
    if [[ $EUID -ne 0 ]]; then log_err "权限不足：请使用 sudo -i 切换到 root 用户后运行！"; fi 
}

wait_for_lock() {
    local max_wait=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -eq 0 ]; then log_warn "系统更新进程运行中，等待锁释放..."; fi
        sleep 2; waited=$((waited + 2))
        if [ $waited -ge $max_wait ]; then rm -f /var/lib/dpkg/lock*; break; fi
    done
}

open_port() {
    local port=$1; local proto=${2:-tcp}
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "$port"; then ufw allow "$port/$proto" >/dev/null; log_info "防火墙 UFW 已放行: $port/$proto"; fi
    fi
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "$prompt [默认 $default]: " port < /dev/tty
        port=${port:-$default}
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then log_warn "输入错误：请输入纯数字。"; continue; fi
        if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then log_warn "范围错误：端口需在 1-65535 之间。"; continue; fi
        if ss -tuln | grep -q ":$port "; then log_warn "提示：端口 $port 已被占用，请更换。"; continue; fi
        echo "$port"; return 0;
    done
}

# ================= 2. 安装与配置逻辑 =================

uninstall() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}      Auto-Seedbox-PT 卸载程序          ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    
    read -p "警告：将停止服务并删除配置。确定继续吗？[y/N]: " confirm < /dev/tty
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    
    log_info "正在停止服务..."
    systemctl stop "qbittorrent-nox@root" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@root" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox
    systemctl daemon-reload
    
    if command -v docker >/dev/null; then 
        log_info "正在删除容器..."
        docker rm -f vertex filebrowser 2>/dev/null || true
    fi
    rm -f /etc/sysctl.d/99-ptbox.conf
    sysctl --system >/dev/null 2>&1

    if [[ "${1:-}" == "--purge" ]]; then
        log_warn "正在执行深度清理 (配置与数据库)..."
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/fb.db"
        
        echo -e "${RED}是否删除下载目录 (/root/Downloads)? 数据无价，请慎重！${NC}"
        read -p "确认删除吗？[y/N]: " del_dl < /dev/tty
        
        if [[ "$del_dl" =~ ^[Yy]$ ]]; then
            rm -rf "/root/Downloads"
            log_warn "下载目录已删除。"
        else
            log_info "保留下载目录。"
        fi
    fi
    log_info "卸载完成。"
    exit 0
}

install_docker_env() {
    if command -v docker >/dev/null; then return 0; fi
    print_banner "安装 Docker 环境"
    local retries=3; local count=0
    until [ $count -ge $retries ]; do
        wait_for_lock
        if curl -fsSL https://get.docker.com | bash; then return 0; fi
        count=$((count+1)); log_warn "安装失败，重试中 ($count/$retries)..."; sleep 5
    done
    log_err "Docker 安装失败，请检查网络。"
}

install_qbit() {
    print_banner "安装 qBittorrent"
    local hb="/root"; local url=""; local arch=$(uname -m)
    
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        log_info "版本策略: 锁定 4.3.9 (Special Optimized)"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        INSTALLED_MAJOR_VER="4"
    else
        log_info "版本策略: 搜索 [$QB_VER_REQ] ..."
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL "${api}/latest" | jq -r .tag_name)
        else
            tag=$(curl -sL "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
        fi
        
        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_warn "未找到版本 [$QB_VER_REQ]，回退至默认 4.3.9"
            [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
            INSTALLED_MAJOR_VER="4"
        else
            log_info "已定位版本: $tag"
            local fname="${arch}-qbittorrent-nox"
            [[ "$arch" == "x86_64" ]] && fname="x86_64-qbittorrent-nox"
            [[ "$arch" == "aarch64" ]] && fname="aarch64-qbittorrent-nox"
            url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
            if [[ "$tag" =~ release-5 ]]; then INSTALLED_MAJOR_VER="5"; else INSTALLED_MAJOR_VER="4"; fi
        fi
    fi

    log_info "下载二进制文件: $url"
    wget -q --show-progress -O /usr/bin/qbittorrent-nox "$url"
    chmod +x /usr/bin/qbittorrent-nox
    mkdir -p "$hb/.config/qBittorrent" "$hb/Downloads"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")

    # 线程与缓存优化
    local threads_val="4"; local cache_val="$QB_CACHE"
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "应用 v5 优化: 禁用应用层缓存 (DiskWriteCacheSize=-1)"
        cache_val="-1"; threads_val="0"
    else
        log_info "应用 v4 优化: 设置缓存 $QB_CACHE MiB"
        local root_disk=$(df /root | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//;s/\/dev\///')
        local rot_path="/sys/block/$root_disk/queue/rotational"
        if [ ! -f "$rot_path" ]; then root_disk=$(lsblk -nd -o NAME | head -1); rot_path="/sys/block/$root_disk/queue/rotational"; fi
        if [[ -f "$rot_path" && "$(cat $rot_path)" == "0" ]]; then 
            log_info "检测到 SSD 硬盘，启用高性能 I/O (16线程)"
            threads_val="16"
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
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12
WebUI\AuthSubnetWhitelistEnabled=true
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
    install_docker_env
    local hb="/root"

    if [[ "$DO_VX" == "true" ]]; then
        print_banner "正在部署 Vertex (Host模式)"
        
        # 1. 预先创建所有必要的目录结构 (确保 Vertex 启动时不报错)
        log_info "预创建数据目录结构..."
        mkdir -p "$hb/vertex/data/"{client,douban,irc,push,race,rss,rule,script,server,site,watch}
        mkdir -p "$hb/vertex/data/rule/"{rss,link,race}
        chmod -R 777 "$hb/vertex/data"
        
        # 2. 清理旧环境
        docker rm -f vertex &>/dev/null || true
        
        # 3. 预先生成 setting.json (Host模式下唯一可靠的改端口方法)
        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$hb/vertex/data/setting.json"
        
        log_info "注入 Vertex 配置 (监听端口: $VX_PORT)..."
        cat > "$set_file" << EOF
{
  "username": "$APP_USER",
  "password": "$vx_pass_md5",
  "port": $VX_PORT
}
EOF

        # 4. 如果有备份，恢复备份
        if [[ -n "$VX_RESTORE_URL" ]]; then
            log_info "恢复备份数据..."
            wget -q -O "$TEMP_DIR/bk.zip" "$VX_RESTORE_URL"
            if [[ -f "$TEMP_DIR/bk.zip" ]]; then
                local unzip_cmd="unzip -o"
                [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P $VX_ZIP_PASS"
                $unzip_cmd "$TEMP_DIR/bk.zip" -d "$hb/vertex/" >/dev/null || log_warn "备份解压失败"
                
                # 恢复后再次强制修改端口 (因为备份里包含的是旧端口配置)
                log_info "修正备份中的端口设置..."
                if [ -f "$set_file" ]; then
                    jq --arg u "$APP_USER" --arg p "$vx_pass_md5" --argjson pt "$VX_PORT" \
                       '.username = $u | .password = $p | .port = $pt' \
                       "$set_file" > "${set_file}.tmp" && mv "${set_file}.tmp" "$set_file"
                fi
            fi
        fi

        # 5. 启动容器 (Vertex 会读取我们预设好的文件，直接监听新端口)
        log_info "启动 Vertex..."
        docker run -d --name vertex --network host \
            -v "$hb/vertex":/vertex \
            -e TZ=Asia/Shanghai \
            lswl/vertex:stable >/dev/null
            
        # 6. 放行端口
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        print_banner "正在部署 FileBrowser"
        rm -rf "$hb/.config/filebrowser" "$hb/fb.db"
        
        # 创建数据库文件并赋予写权限
        mkdir -p "$hb/.config/filebrowser" 
        touch "$hb/fb.db"
        chmod 666 "$hb/fb.db"
        
        docker rm -f filebrowser &>/dev/null || true
        log_info "初始化数据库..."
        
        # 强制 Root 运行初始化
        docker run --rm --user 0:0 -v "$hb/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest config init >/dev/null
        docker run --rm --user 0:0 -v "$hb/fb.db":/database/filebrowser.db filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin >/dev/null
        
        log_info "启动服务..."
        # 强制 Root 运行主进程 (解决 Permission Denied 的终极方案)
        docker run -d --name filebrowser --restart unless-stopped \
            --user 0:0 \
            -v "$hb":/srv \
            -v "$hb/fb.db":/database/filebrowser.db \
            -v "$hb/.config/filebrowser":/config \
            -p $FB_PORT:80 \
            filebrowser/filebrowser:latest >/dev/null
            
        open_port "$FB_PORT"
    fi
}

sys_tune() {
    print_banner "应用系统优化 (BBR+FQ)"
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak
    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max=1048576
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.somaxconn=65535
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_window_scaling=1
EOF
    sysctl --system >/dev/null 2>&1
    local eth=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    [[ -n "$eth" ]] && ifconfig "$eth" txqueuelen 10000 2>/dev/null || true
    log_info "内核参数与网卡队列优化已应用。"
}

# ================= 3. 主流程 =================

if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

while getopts "u:p:c:q:vftod:k:" opt; do
    case $opt in 
        u) APP_USER=$OPTARG ;; p) APP_PASS=$OPTARG ;; c) QB_CACHE=$OPTARG ;; q) QB_VER_REQ=$OPTARG ;;
        v) DO_VX=true ;; f) DO_FB=true ;; t) DO_TUNE=true ;; o) CUSTOM_PORT=true ;;
        d) VX_RESTORE_URL=$OPTARG ;; k) VX_ZIP_PASS=$OPTARG ;;
    esac
done

check_root
print_banner "环境检查与依赖安装"
wait_for_lock
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool >/dev/null

if [[ -z "$APP_PASS" ]]; then
    # 强制从终端读取密码
    echo -n "请输入 Web 面板密码 (至少12位): "
    read -s APP_PASS < /dev/tty
    echo ""
fi

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}       进入端口自定义模式       ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBit BT监听" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && sys_tune

PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")

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
    echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC} (Host模式)"
    echo -e "   └─ 提示: 下载器地址请填 ${YELLOW}127.0.0.1:$QB_WEB_PORT${NC}"
    if [[ -n "$VX_RESTORE_URL" ]]; then echo -e "   └─ 状态: ${GREEN}数据已恢复${NC}"; fi
fi
if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
    echo -e "   └─ 下载目录: ${YELLOW}Downloads${NC}"
fi
echo -e "${BLUE}========================================================${NC}"
if [[ "$DO_TUNE" == "true" ]]; then echo -e "${YELLOW}提示: 深度内核优化已应用，建议重启服务器生效。${NC}"; fi
echo -e "${RED}[注意] 如果无法访问端口，请检查云服务商网页端的防火墙/安全组设置！${NC}"
