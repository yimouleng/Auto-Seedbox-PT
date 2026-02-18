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

非常敏锐！您的判断完全正确。

TCP/UDP 端口的有效范围是 1 到 65535。
您输入的 547127 远远超出了这个范围。脚本之前的版本虽然检查了“是否为数字”和“是否被占用”，但漏掉了“是否超过 65535”的范围检查。

当脚本尝试执行 ufw allow 547127 时，防火墙直接报错 ERROR: Bad port 并终止了运行。

🚀 Auto-Seedbox-PT (ASP) v3.0 - 最终稳健版
V3.0 更新内容：

输入逻辑修复：重写了 get_input_port 函数，增加了 1-65535 的范围强制校验。如果输入超限，会提示重输，不会让脚本崩在半路。

继承所有特性：保留了您刚才指定的特殊优化版源、ARM/x86 自动识别、以及全参数同步功能。

请使用此版本覆盖，这下就算手滑多输了一位数，脚本也能拦得住：

Bash
#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v3.0 - 最终稳健版
# 
# [V3.0 修复]
# 1. 输入校验增强：增加端口范围检测 (1-65535)，防止输入非法端口导致 UFW 报错。
# 2. 核心保持：继续使用用户指定的 4.3.9 特殊优化版二进制源。
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; NC='\033[0m'

# 默认端口
QB_WEB_PORT=8080; QB_BT_PORT=20000; VX_PORT=3000; FB_PORT=8081

# 参数变量初始化
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

# 特殊优化版源
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

check_root() { if [[ $EUID -ne 0 ]]; then log_err "请使用 sudo -i 切换到 root 后运行！"; fi; }

wait_for_lock() {
    local max_wait=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -eq 0 ]; then log_warn "检测到系统后台正在更新，等待锁释放..."; fi
        sleep 2; waited=$((waited + 2))
        if [ $waited -ge $max_wait ]; then rm -f /var/lib/dpkg/lock*; break; fi
    done
}

open_port() {
    local port=$1; local proto=${2:-tcp}
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "$port"; then ufw allow "$port/$proto" >/dev/null; log_info "防火墙已放行: $port/$proto"; fi
    fi
}

# [关键修复] 增加范围校验的端口输入函数
get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "$prompt [默认 $default]: " port; port=${port:-$default}
        
        # 1. 检查是否为数字
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then 
            log_warn "输入错误：请输入纯数字端口号。"
            continue
        fi

        # 2. 检查范围 (1-65535)
        if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
            log_warn "范围错误：端口必须在 1 到 65535 之间 (您输入了 $port)。"
            continue
        fi

        # 3. 检查占用
        if ss -tuln | grep -q ":$port "; then 
            log_warn "占用错误：端口 $port 已被系统占用，请更换。"
            continue
        fi

        echo "$port"; return 0;
    done
}

# ================= 2. 安装与卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}      Auto-Seedbox-PT 卸载程序          ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    read -p "警告：将停止服务并删除配置。确定继续吗？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    
    log_info "正在清理服务..."
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
        log_warn "正在深度清除数据..."
        rm -rf "/root/.config/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/fb.db"
        read -p "是否删除下载目录 (/root/Downloads)? [y/N]: " del_dl
        [[ "$del_dl" =~ ^[Yy]$ ]] && rm -rf "/root/Downloads"
    fi
    log_info "卸载完成。"
    exit 0
}

install_qbit() {
    print_banner "正在安装 qBittorrent"
    local hb="/root"; local url=""; local arch=$(uname -m)
    
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        log_info "版本策略: 锁定 4.3.9 (Special Optimized)"
        if [[ "$arch" == "x86_64" ]]; then
            url="$URL_V4_AMD64"
            log_info "检测到 x86_64 架构，使用专用优化版。"
        elif [[ "$arch" == "aarch64" ]]; then
            url="$URL_V4_ARM64"
            log_info "检测到 ARM64 架构，使用专用优化版。"
        else
            log_err "不支持的架构: $arch"
        fi
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
            log_warn "未找到版本 [$QB_VER_REQ]，回退至默认 4.3.9 (优化版)"
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

    log_info "下载地址: $url"
    wget -q --show-progress -O /usr/bin/qbittorrent-nox "$url"
    chmod +x /usr/bin/qbittorrent-nox
    mkdir -p "$hb/.config/qBittorrent" "$hb/Downloads"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")

    # 磁盘检测与线程优化
    local threads_val="4"
    local cache_val="$QB_CACHE"
    
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "应用 v5 优化: 禁用应用层缓存 (DiskWriteCacheSize=-1)"
        cache_val="-1"; threads_val="0"
    else
        log_info "应用 v4 优化: 缓存 $QB_CACHE MiB"
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
    
    open_port "$QB_WEB_PORT"
    open_port "$QB_BT_PORT" "tcp"
    open_port "$QB_BT_PORT" "udp"
}

install_docker_retry() {
    if command -v docker >/dev/null; then return 0; fi
    print_banner "正在安装 Docker"
    local retries=3; local count=0
    until [ $count -ge $retries ]; do
        wait_for_lock
        if curl -fsSL https://get.docker.com | bash; then return 0; fi
        count=$((count+1)); log_warn "安装失败，重试中 ($count/$retries)..."; sleep 5
    done
    log_err "Docker 安装失败，请检查网络。"
}

install_apps() {
    install_docker_retry
    local hb="/root"

    if [[ "$DO_VX" == "true" ]]; then
        print_banner "正在部署 Vertex"
        mkdir -p "$hb/vertex/data"
        
        if [[ -n "$VX_RESTORE_URL" ]]; then
            log_info "正在下载备份: $VX_RESTORE_URL"
            wget -q -O "$TEMP_DIR/vertex_backup.zip" "$VX_RESTORE_URL" || log_warn "备份下载失败，将安装纯净版"
            if [[ -f "$TEMP_DIR/vertex_backup.zip" ]]; then
                log_info "正在解压备份..."
                local unzip_cmd="unzip -o"
                [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P $VX_ZIP_PASS"
                if $unzip_cmd "$TEMP_DIR/vertex_backup.zip" -d "$hb/vertex/"; then
                    log_info "✅ 备份恢复成功"
                else
                    log_err "❌ 解压失败，请检查密码 (-k) 是否正确"
                fi
            fi
        fi

        log_info "同步 Web 账号密码..."
        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        cat > "$hb/vertex/data/setting.json" << EOF
{
  "username": "$APP_USER",
  "password": "$vx_pass_md5",
  "port": 3000,
  "configPath": "/vertex/data"
}
EOF
        docker rm -f vertex &>/dev/null || true
        docker run -d --name vertex --restart unless-stopped -p $VX_PORT:3000 -v "$hb/vertex":/vertex -e TZ=Asia/Shanghai -e PUID=0 -e PGID=0 lswl/vertex:stable >/dev/null
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        print_banner "正在部署 FileBrowser"
        log_info "初始化数据库并创建用户..."
        rm -rf "$hb/.config/filebrowser" "$hb/fb.db"
        mkdir -p "$hb/.config/filebrowser" && touch "$hb/fb.db"
        docker rm -f filebrowser &>/dev/null || true
        docker run --rm -v "$hb/fb.db":/database/filebrowser.db --user 0:0 filebrowser/filebrowser:latest config init >/dev/null
        docker run --rm -v "$hb/fb.db":/database/filebrowser.db --user 0:0 filebrowser/filebrowser:latest users add "$APP_USER" "$APP_PASS" --perm.admin >/dev/null
        docker run -d --name filebrowser --restart unless-stopped -v "$hb":/srv -v "$hb/fb.db":/database/filebrowser.db -v "$hb/.config/filebrowser":/config -p $FB_PORT:80 --user 0:0 filebrowser/filebrowser:latest >/dev/null
        open_port "$FB_PORT"
    fi
}

sys_tune() {
    print_banner "应用系统优化"
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
    log_info "内核参数与网卡队列优化已完成。"
}

# ================= 3. 主流程 =================

if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

while getopts "u:p:c:q:vftod:k:" opt; do
    case $opt in 
        u) APP_USER=$OPTARG ;; 
        p) APP_PASS=$OPTARG ;; 
        c) QB_CACHE=$OPTARG ;; 
        q) QB_VER_REQ=$OPTARG ;;
        v) DO_VX=true ;; 
        f) DO_FB=true ;; 
        t) DO_TUNE=true ;; 
        o) CUSTOM_PORT=true ;;
        d) VX_RESTORE_URL=$OPTARG ;;
        k) VX_ZIP_PASS=$OPTARG ;;
    esac
done

check_root
print_banner "环境检查与依赖安装"
wait_for_lock
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y curl wget jq unzip python3 net-tools ethtool >/dev/null

if [[ -z "$APP_PASS" ]]; then
    echo -n "请输入 Web 面板密码 (至少12位): "
    read -s APP_PASS; echo ""
fi

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}       进入端口自定义模式       ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBit BT监听 (Incoming Port)" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && sys_tune

PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")

echo ""
echo -e "${BLUE}########################################################${NC}"
echo -e "${GREEN}          Auto-Seedbox-PT 安装成功! (V3.0)             ${NC}"
echo -e "${BLUE}########################################################${NC}"
echo -e "Web 账号: ${YELLOW}$APP_USER${NC}"
echo -e "Web 密码: ${YELLOW}(您刚才输入的密码)${NC}"
echo -e "BT 端口 : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP 已放行)"
echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🧩 qBittorrent: ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC} (核心: v$INSTALLED_MAJOR_VER)"
if [[ "$DO_VX" == "true" ]]; then
    echo -e "🌐 Vertex:      ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
    echo -e "   └─ 初始账号: ${YELLOW}$APP_USER${NC} / ${YELLOW}(同上)${NC}"
    if [[ -n "$VX_RESTORE_URL" ]]; then echo -e "   └─ 状态: ${GREEN}数据已恢复${NC}"; fi
fi
if [[ "$DO_FB" == "true" ]]; then
    echo -e "📁 FileBrowser: ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
    echo -e "   └─ 初始账号: ${YELLOW}$APP_USER${NC} / ${YELLOW}(同上)${NC}"
fi
echo -e "${BLUE}========================================================${NC}"
if [[ "$DO_TUNE" == "true" ]]; then echo -e "${YELLOW}提示: 深度内核优化已应用，建议重启服务器生效。${NC}"; fi
