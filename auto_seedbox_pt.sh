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

# 4.3.9 黄金版本硬编码源 (Userdocs)
URL_V4_AMD64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
URL_V4_ARM64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/aarch64-qbittorrent-nox"

# ================= 1. 基础工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

check_root() { [[ $EUID -ne 0 ]] && log_err "必须使用 root 权限运行 (sudo bash ...)"; }

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_err "本脚本仅支持 Debian 或 Ubuntu 系统。"
        fi
    else
        log_err "无法检测操作系统类型。"
    fi
}

# 端口占用检测
is_port_free() {
    local port=$1
    if command -v ss >/dev/null; then
        ss -tuln | grep -q ":$port " && return 1
    else
        netstat -tuln 2>/dev/null | grep -q ":$port " && return 1
    fi
    return 0
}

# 交互式获取可用端口
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

# 环境依赖准备
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

    if [ "$install_needed" = true ]; then
        log_info "正在安装必要组件 (jq, curl, unzip, python3)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -qq update && apt-get -qq install -y "${deps[@]}" net-tools >/dev/null
    fi
}

# ================= 2. qBittorrent 模块 =================

install_qbit() {
    local home="/home/$QB_USER"
    local url=""

    # --- 版本解析与下载 ---
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        log_info "锁定经典版本: 4.3.9 (Static)"
        if [[ "$ARCH" == "x86_64" ]]; then url="$URL_V4_AMD64"; else url="$URL_V4_ARM64"; fi
        INSTALLED_MAJOR_VER="4"
    else
        log_info "正在搜索请求的版本: $QB_VER_REQ ..."
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -s "${api}/latest" | jq -r .tag_name)
        else
            tag=$(curl -s "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
        fi

        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_err "未找到匹配 '$QB_VER_REQ' 的版本。"
        fi

        log_info "已找到版本: $tag"
        local fname="x86_64-qbittorrent-nox"
        [[ "$ARCH" == "aarch64" ]] && fname="aarch64-qbittorrent-nox"
        url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        
        [[ "$tag" =~ release-5 ]] && INSTALLED_MAJOR_VER="5" || INSTALLED_MAJOR_VER="4"
    fi

    wget -q --show-progress -t 3 -O /usr/bin/qbittorrent-nox "$url"
    [[ ! -s /usr/bin/qbittorrent-nox ]] && log_err "下载失败，文件无效。"
    chmod +x /usr/bin/qbittorrent-nox

    # --- 用户与配置 ---
    if ! id "$QB_USER" &>/dev/null; then useradd -m -s /bin/bash "$QB_USER"; fi
    mkdir -p "$home/.config/qBittorrent" "$home/Downloads"
    chown -R "$QB_USER:$QB_USER" "$home"

    # 生成安全哈希
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), os.urandom(16), 100000); print(f'@ByteArray({base64.b64encode(os.urandom(16)).decode()}:{base64.b64encode(dk).decode()})')" "$QB_PASS")

    # 磁盘检测
    local is_ssd=0
    local dev_source=$(df --output=source "$home" | tail -1)
    if [[ "$dev_source" == "/dev/"* ]]; then
        local disk_pname=$(lsblk -nd -o PKNAME "$dev_source" 2>/dev/null || echo "${dev_source##*/}" | sed 's/[0-9]*$//')
        [[ -f "/sys/block/$disk_pname/queue/rotational" && "$(cat /sys/block/$disk_pname/queue/rotational)" == "0" ]] && is_ssd=1
    fi

    # 写入双模式配置
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "应用 v5 (MMap) 优化参数..."
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
        log_info "应用 v4 (UserCache) 优化参数 (SSD: $is_ssd)..."
        local aio=4; local buf=10240
        [[ "$is_ssd" -eq 1 ]] && { aio=12; buf=20480; }
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

    # Systemd 托管
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

# ================= 3. Docker 模块 (Vertex/FileBrowser) =================

install_apps() {
    if ! command -v docker >/dev/null; then
        log_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
        systemctl enable docker; systemctl start docker
    fi
    
    local uid=$(id -u "$QB_USER")
    local gid=$(id -g "$QB_USER")
    local home="/home/$QB_USER"

    # Vertex 安装
    if [ "$DO_VX" = true ]; then
        log_info "部署 Vertex..."
        mkdir -p "$home/vertex"
        if [ -n "$VX_RESTORE_URL" ]; then
            log_warn "从备份 URL 恢复数据..."
            wget -q -O "$TEMP_DIR/v.zip" "$VX_RESTORE_URL" || log_err "备份文件下载失败"
            local u_cmd="unzip -o"
            [[ -n "$VX_ZIP_PASS" ]] && u_cmd="unzip -o -P $VX_ZIP_PASS"
            if $u_cmd "$TEMP_DIR/v.zip" -d "$home/vertex/" >/dev/null; then
                log_info "数据恢复成功，尝试自动修复配置端口..."
                find "$home/vertex/data/client" -name "*.json" -print0 2>/dev/null | xargs -0 sed -i "s/\"port\": [0-9]*/\"port\": $QB_WEB_PORT/g" 2>/dev/null || true
            else
                log_err "解压失败，请检查密码。"
            fi
        fi
        chown -R "$uid:$gid" "$home/vertex"
        docker rm -f vertex &>/dev/null || true
        docker run -d --name vertex --restart unless-stopped \
            -p $VX_PORT:3000 -v "$home/vertex":/vertex \
            -e TZ=Asia/Shanghai -e PUID=$uid -e PGID=$gid lswl/vertex:stable >/dev/null
    fi

    # FileBrowser 安装
    if [ "$DO_FB" = true ]; then
        log_info "部署 FileBrowser..."
        touch "$home/fb.db" && chown "$uid:$gid" "$home/fb.db"
        docker rm -f filebrowser &>/dev/null || true
        docker run -d --name filebrowser --restart unless-stopped \
            -v "$home":/srv -v "$home/fb.db":/database/filebrowser.db \
            -p $FB_PORT:80 -u $uid:$gid filebrowser/filebrowser:latest >/dev/null
    fi
}

# ================= 4. 系统优化模块 =================

sys_tune() {
    log_info "正在应用内核优化 (BBR + Sysctl)..."
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 通用网络栈优化
    cat > /etc/sysctl.d/99-ptbox-base.conf << EOF
fs.file-max = 2097152
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
EOF

    # 针对 v4/v5 应用差异化内存策略
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "执行 v5 (MMap) 专用内核优化..."
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 1
vm.dirty_ratio = 80
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 50
EOF
    else
        log_info "执行 v4 (UserCache) 专用内核优化..."
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
EOF
    fi

    sysctl --system >/dev/null 2>&1
    log_info "优化参数应用成功。"
}

# ================= 5. 卸载模块 =================

uninstall() {
    log_warn "=== 卸载模式 ==="
    read -p "请输入要卸载的用户名: " u
    [[ -z "$u" ]] && exit 1
    systemctl stop "qbittorrent-nox@$u" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@$u" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service /usr/bin/qbittorrent-nox
    if command -v docker >/dev/null; then docker rm -f vertex filebrowser 2>/dev/null || true; fi
    rm -f /etc/sysctl.d/99-ptbox-*.conf
    sysctl --system >/dev/null 2>&1
    if [[ "$1" == "--purge" ]]; then
        log_warn "正在彻底删除用户数据 ($u)..."
        userdel -r "$u" 2>/dev/null || rm -rf "/home/$u"
    fi
    log_info "卸载完成。"
    exit 0
}

# ================= 6. 主程序入口 =================

if [[ "${1:-}" == "--uninstall" ]]; then uninstall ""; fi
if [[ "${1:-}" == "--purge" ]]; then uninstall "--purge"; fi

# 参数解析
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
        h) echo "请查阅 README"; exit 0 ;;
    esac
done

check_root; check_os; prepare_env

# 参数交互补充
if [[ -z "$QB_USER" ]]; then read -p "请输入用户名: " QB_USER; fi
if [[ -z "$QB_PASS" ]]; then 
    echo -n "请输入密码 (无回显): "
    read -s QB_PASS
    echo ""
fi
while [ ${#QB_PASS} -lt 12 ]; do
    log_warn "密码过短，请设置至少 12 位:"
    read -s QB_PASS; echo ""
done

# 端口逻辑处理
if [ "$CUSTOM_PORT" = true ]; then
    log_info "--- 进入交互式端口配置 ---"
    QB_WEB_PORT=$(get_input_port "qBittorrent WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBittorrent BT监听" 20000)
    [ "$DO_VX" = true ] && VX_PORT=$(get_input_port "Vertex" 3000)
    [ "$DO_FB" = true ] && FB_PORT=$(get_input_port "FileBrowser" 8081)
else
    # 非交互模式下的核心逻辑：检查并报错
    if ! is_port_free "$QB_WEB_PORT"; then log_err "默认端口 $QB_WEB_PORT (qBitWeb) 被占用，请使用 -o 运行!"; fi
    if ! is_port_free "$QB_BT_PORT"; then log_err "默认端口 $QB_BT_PORT (qBitBT) 被占用，请使用 -o 运行!"; fi
    if [ "$DO_VX" = true ] && ! is_port_free "$VX_PORT"; then log_err "默认端口 $VX_PORT (Vertex) 被占用，请使用 -o 运行!"; fi
    if [ "$DO_FB" = true ] && ! is_port_free "$FB_PORT"; then log_err "默认端口 $FB_PORT (FileBrowser) 被占用，请使用 -o 运行!"; fi
fi

# 执行安装流程
install_qbit
if [ "$DO_VX" = true ] || [ "$DO_FB" = true ]; then install_apps; fi
if [ "$DO_TUNE" = true ]; then sys_tune; fi

# 输出完成信息
PUB_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")
echo ""
echo "========================================================"
echo -e "${GREEN}   Auto-Seedbox-PT 安装成功! (v${INSTALLED_MAJOR_VER} 内核)${NC}"
echo "========================================================"
echo -e "用户: ${YELLOW}$QB_USER${NC} / 密码: (已加密)"
echo "--------------------------------------------------------"
echo -e "🧩 qBittorrent: http://$PUB_IP:$QB_WEB_PORT"
[[ "$DO_VX" == true ]] && echo -e "🌐 Vertex:      http://$PUB_IP:$VX_PORT"
[[ "$DO_FB" == true ]] && echo -e "📁 FileBrowser: http://$PUB_IP:$FB_PORT"
echo "========================================================"
if [ "$DO_TUNE" = true ]; then echo -e "${YELLOW}提示: 已应用内核深度优化，建议重启服务器 (reboot)${NC}"; fi
