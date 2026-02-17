#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) v1.0
# 
# 描述: 
#   专为 PT 玩家打造的全自动化 Seedbox 部署工具。
#   集成 qBittorrent (v4/v5 双核引擎)、Vertex、FileBrowser 及底层系统优化。
# 
# 核心特性:
#   [Auto] 自动识别硬件(SSD/HDD)与内核版本，动态应用最佳参数
#   [Safe] 零黑盒代码，Python3 原生生成密码，Docker 最小权限运行
#   [Flex] 支持 -q latest 尝鲜 v5 版本，或锁定 4.3.9 养老
#   [Easy] 支持 -o 交互式端口配置，支持 Vertex 备份一键恢复
# 
# 项目地址: [你的GitHub地址]
# 基于: vivibudong/PT-Seedbox (MIT License)
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局配置 =================

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 默认参数
QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081

QB_USER=""
QB_PASS=""
QB_CACHE=1024
QB_VER_REQ="4.3.9" # 默认版本

DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false 
VX_RESTORE_URL=""
VX_ZIP_PASS=""

# 内部变量
INSTALLED_MAJOR_VER="4"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 4.3.9 硬编码源 (Userdocs)
URL_V4_AMD64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
URL_V4_ARM64="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/aarch64-qbittorrent-nox"

# ================= 1. 基础检查 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

check_root() { [[ $EUID -ne 0 ]] && log_err "请使用 root 权限运行 (sudo bash ...)"; }

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_err "本脚本仅支持 Debian 或 Ubuntu 系统。"
        fi
    else
        log_err "无法检测操作系统。"
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

# 交互式获取端口
get_input_port() {
    local prompt=$1
    local default=$2
    local port
    while true; do
        read -p "$prompt [默认 $default]: " port
        port=${port:-$default}
        
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_warn "端口必须是 1-65535 之间的数字"
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

    if [ "$install_needed" = true ]; then
        log_info "安装基础依赖..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -qq update
        apt-get -qq install -y "${deps[@]}" net-tools >/dev/null
    fi
}

# ================= 2. qBittorrent 安装 =================

install_qbit() {
    local home="/home/$QB_USER"
    local url=""

    # --- 版本解析逻辑 ---
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        # 路径 A: 默认 4.3.9 (硬编码)
        log_info "选中版本: qBittorrent 4.3.9 (Static)"
        if [[ "$ARCH" == "x86_64" ]]; then url="$URL_V4_AMD64"; else url="$URL_V4_ARM64"; fi
        INSTALLED_MAJOR_VER="4"
    else
        # 路径 B: API 搜索
        log_info "正在搜索版本: $QB_VER_REQ ..."
        local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
        local tag=""
        
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -s "${api}/latest" | jq -r .tag_name)
        else
            tag=$(curl -s "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' | head -n 1)
        fi

        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_err "未找到包含 '$QB_VER_REQ' 的版本。"
        fi

        log_info "已锁定 Release: $tag"
        local fname="x86_64-qbittorrent-nox"
        [[ "$ARCH" == "aarch64" ]] && fname="aarch64-qbittorrent-nox"
        url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        
        if [[ "$tag" =~ release-5 ]]; then INSTALLED_MAJOR_VER="5"; else INSTALLED_MAJOR_VER="4"; fi
    fi

    log_info "正在下载..."
    wget -q --show-progress -t 3 -O /usr/bin/qbittorrent-nox "$url"
    if [ ! -s /usr/bin/qbittorrent-nox ]; then log_err "下载失败"; fi
    chmod +x /usr/bin/qbittorrent-nox

    # --- 配置 ---
    if ! id "$QB_USER" &>/dev/null; then useradd -m -s /bin/bash "$QB_USER"; fi
    mkdir -p "$home/.config/qBittorrent" "$home/Downloads"
    chown -R "$QB_USER:$QB_USER" "$home"

    # 生成密码
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), os.urandom(16), 100000); print(f'@ByteArray({base64.b64encode(os.urandom(16)).decode()}:{base64.b64encode(dk).decode()})')" "$QB_PASS")

    # 磁盘检测
    local is_ssd=0
    local dev_name=$(df --output=source "$home" | tail -1)
    if [[ "$dev_name" == "/dev/"* ]]; then
        local disk_name=$(lsblk -nd -o PKNAME "$dev_name" 2>/dev/null || echo "${dev_name##*/}" | sed 's/[0-9]*$//')
        if [ -f "/sys/block/$disk_name/queue/rotational" ]; then
            [[ "$(cat /sys/block/$disk_name/queue/rotational)" == "0" ]] && is_ssd=1
        fi
    fi

    # 写入配置 (双核优化策略)
    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "应用 v5 策略 (MMap/OS Cache)..."
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
Downloads\DiskWriteCacheTTL=60
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$QB_USER
EOF
    else
        log_info "应用 v4 策略 (UserCache, SSD: $([ $is_ssd -eq 1 ] && echo "是" || echo "否"))..."
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

    # Systemd
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
TimeoutStopSec=20
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "qbittorrent-nox@$QB_USER" >/dev/null 2>&1
    systemctl restart "qbittorrent-nox@$QB_USER"
}

# ================= 3. Docker 应用 =================

install_apps() {
    if ! command -v docker >/dev/null; then
        log_info "安装 Docker..."
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
        systemctl enable docker; systemctl start docker
    fi
    
    local uid=$(id -u "$QB_USER")
    local gid=$(id -g "$QB_USER")
    local home="/home/$QB_USER"

    # --- Vertex ---
    if [ "$DO_VX" = true ]; then
        log_info "部署 Vertex..."
        mkdir -p "$home/vertex"
        
        if [ -n "$VX_RESTORE_URL" ]; then
            log_warn "从备份恢复 Vertex..."
            wget -q -O "$TEMP_DIR/vx.zip" "$VX_RESTORE_URL" || log_err "备份下载失败"
            local unzip_cmd="unzip -o"
            [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -o -P $VX_ZIP_PASS"
            
            if $unzip_cmd "$TEMP_DIR/vx.zip" -d "$home/vertex/" >/dev/null; then
                log_info "数据恢复成功!"
                find "$home/vertex/data/client" -name "*.json" -print0 2>/dev/null | xargs -0 sed -i "s/\"port\": [0-9]*/\"port\": $QB_WEB_PORT/g" 2>/dev/null || true
            else
                log_err "解压失败。"
            fi
        fi

        chown -R "$uid:$gid" "$home/vertex"
        docker rm -f vertex &>/dev/null || true
        docker run -d --name vertex --restart unless-stopped \
            -p $VX_PORT:3000 \
            -v "$home/vertex":/vertex \
            -e TZ=Asia/Shanghai \
            -e PUID=$uid -e PGID=$gid \
            lswl/vertex:stable >/dev/null
    fi

    # --- FileBrowser ---
    if [ "$DO_FB" = true ]; then
        log_info "部署 FileBrowser..."
        touch "$home/fb.db" && chown "$uid:$gid" "$home/fb.db"
        docker rm -f filebrowser &>/dev/null || true
        docker run -d --name filebrowser --restart unless-stopped \
            -v "$home":/srv \
            -v "$home/fb.db":/database/filebrowser.db \
            -p $FB_PORT:80 \
            -u $uid:$gid \
            filebrowser/filebrowser:latest >/dev/null
    fi
}

# ================= 4. 系统调优 =================

sys_tune() {
    log_info "应用内核优化 (BBR + Sysctl)..."
    
    cat > /etc/sysctl.d/99-ptbox-base.conf << EOF
fs.file-max = 2097152
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
vm.min_free_kbytes = 65536
EOF

    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        log_info "针对 v5 (MMap) 调整内核参数..."
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 1
vm.dirty_ratio = 80
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 50
EOF
    else
        log_info "针对 v4 (UserCache) 调整内核参数..."
        cat > /etc/sysctl.d/99-ptbox-mem.conf << EOF
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
EOF
    fi

    sysctl --system >/dev/null 2>&1
}

# ================= 5. 卸载 =================

uninstall() {
    log_warn "=== 卸载模式 ==="
    read -p "输入要卸载的用户名: " u
    [[ -z "$u" ]] && exit 1

    systemctl stop "qbittorrent-nox@$u" 2>/dev/null || true
    systemctl disable "qbittorrent-nox@$u" 2>/dev/null || true
    rm -f /etc/systemd/system/qbittorrent-nox@.service
    
    if command -v docker >/dev/null; then
        docker rm -f vertex filebrowser 2>/dev/null || true
    fi
    
    rm -f /usr/bin/qbittorrent-nox
    rm -f /etc/sysctl.d/99-ptbox-*.conf
    sysctl --system >/dev/null 2>&1
    
    if [[ "$1" == "--purge" ]]; then
        log_warn "删除用户数据 ($u)..."
        userdel -r "$u" 2>/dev/null || rm -rf "/home/$u"
    fi
    log_info "卸载完成。"
    exit 0
}

# ================= 6. 主程序 =================

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
        h) echo "请查看 README 文档"; exit 0 ;;
    esac
done

check_root
check_os
prepare_env

# 交互式检查
if [ -z "$QB_USER" ]; then read -p "请输入用户名: " QB_USER; fi
if [ -z "$QB_PASS" ]; then 
    echo -n "请输入密码 (无回显): "
    read -s QB_PASS
    echo ""
fi
while [ ${#QB_PASS} -lt 12 ]; do
    log_warn "密码太短，请至少 12 位:"
    read -s QB_PASS
    echo ""
done
if [ -z "$QB_CACHE" ]; then QB_CACHE=1024; fi

# === 交互式端口设置 ===
if [ "$CUSTOM_PORT" = true ]; then
    log_info "--- 端口自定义 ---"
    QB_WEB_PORT=$(get_input_port "qBittorrent WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBittorrent BT监听" 20000)
    if [ "$DO_VX" = true ]; then
        VX_PORT=$(get_input_port "Vertex" 3000)
    fi
    if [ "$DO_FB" = true ]; then
        FB_PORT=$(get_input_port "FileBrowser" 8081)
    fi
else
    check_port $QB_WEB_PORT "qBitWeb"
    check_port $QB_BT_PORT "qBitBT"
fi

# 执行安装
install_qbit
if [ "$DO_VX" = true ] || [ "$DO_FB" = true ]; then install_apps; fi
if [ "$DO_TUNE" = true ]; then sys_tune; fi

# 完成
IP=$(curl -s --max-time 3 https://api.ipify.org || echo "ServerIP")
echo ""
echo "========================================================"
echo -e "${GREEN}   安装成功! (v${INSTALLED_MAJOR_VER} Core)${NC}"
echo "========================================================"
echo -e "用户: ${YELLOW}$QB_USER${NC}"
echo -e "密码: ${YELLOW}(已隐藏)${NC}"
echo "--------------------------------------------------------"
echo -e "🧩 qBittorrent: http://$IP:$QB_WEB_PORT"
[[ "$DO_VX" == true ]] && echo -e "🌐 Vertex:      http://$IP:$VX_PORT"
[[ "$DO_FB" == true ]] && echo -e "📁 FileBrowser: http://$IP:$FB_PORT"
echo "========================================================"
if [ "$DO_TUNE" = true ]; then echo -e "${YELLOW}提示: 已应用内核优化，建议 reboot${NC}"; fi
