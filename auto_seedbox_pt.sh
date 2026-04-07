#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP)
# qBittorrent + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
#
# 参数说明:
#   -u : 用户名 (用于运行服务和登录WebUI)
#   -p : 密码（必须 ≥ 12 位）
#   -c : 显式指定 qB 缓存/工作集大小 (MiB)
#        - 4.x: 作为 disk_cache 使用
#        - 5.x: 作为 memory_working_set_limit 使用
#        不传则走默认保守策略
#   -q : qBittorrent 版本 (4, 4.3.9, 5, 5.0.4, latest, 或精确小版本如 5.1.2)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser (含 MediaInfo 扩展)
#   -t : 启用系统内核优化（强烈推荐）
#   -m : 调优模式 (1: 极限抢种 / 2: 均衡保种) [默认 1]
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP/tar.gz 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
#   -a : 启用 M1 动态自适应控制器（仅 Mode 1 生效，默认关闭）
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

QB_WEB_PORT=8080
QB_BT_PORT=47878
VX_PORT=3000
FB_PORT=8081
MI_PORT=8082
SS_PORT=8083

APP_USER="admin"
APP_PASS=""
QB_CACHE=1024
QB_VER_REQ="5.0.4"

DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false
CACHE_SET_BY_USER=false
QB_EXPLICIT_CACHE_MODE=false
TUNE_MODE="1"
AUTOTUNE_ENABLE=false

FIREWALL_AUTO=true
FIREWALL_RULES=()

VX_RESTORE_URL=""
VX_ZIP_PASS=""
INSTALLED_MAJOR_VER="5"
ACTION="install"

HB="/root"
ASP_ENV_FILE="/etc/asp_env.sh"

TEMP_DIR=$(mktemp -d -t asp-XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 固化直链库 (兜底与默认版本)
URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V5_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"
URL_V5_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"

# 动态控制器路径
AUTOTUNE_BIN="/usr/local/bin/asp-qb-autotune.sh"
AUTOTUNE_SVC="/etc/systemd/system/asp-qb-autotune.service"
AUTOTUNE_TMR="/etc/systemd/system/asp-qb-autotune.timer"
AUTOTUNE_ENV="/etc/asp_autotune_env.sh"
AUTOTUNE_STATE="/run/asp-qb-autotune.state"
AUTOTUNE_COOKIE="/run/asp-qb_cookie.txt"
AUTOTUNE_LOCK="/run/asp-qb-autotune.lock"
AUTOTUNE_PSI_WARN="/run/asp-qb-autotune.psi_warned"

# Autotune opt-in flag (requires -a)
AUTOTUNE_OPTIN_FLAG="/etc/asp_autotune_optin"

# ================= PSI 自动探测/自动启用 (Boot-time) =================
# PSI 为内核能力。此处“启用”含义：若 PSI 可用，则开机自动启用 M1 动态控制器 timer。
PSI_FLAG_FILE="/etc/asp_psi_supported"
PSI_ENV_FILE="/etc/asp_psi_env.sh"
PSI_DETECT_BIN="/usr/local/bin/asp-psi-detect.sh"
PSI_DETECT_SVC="/etc/systemd/system/asp-psi-detect.service"

# ================= 1. 工具函数 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

execute_with_spinner() {
    local msg="$1"
    shift
    local log="/tmp/asp_install.log"
    "$@" >> "$log" 2>&1 &
    local pid=$!
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    printf "\e[?25l"
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r\033[K ${CYAN}[%c]${NC} %s..." "$spinstr" "$msg"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    local ret=0
    wait $pid || ret=$?
    printf "\e[?25h"
    if [ $ret -eq 0 ]; then
        printf "\r\033[K ${GREEN}[√]${NC} %s... 完成!\n" "$msg"
    else
        printf "\r\033[K ${RED}[X]${NC} %s... 失败! (请查看 /tmp/asp_install.log)\n" "$msg"
    fi
    return $ret
}

download_file() {
    local url=$1
    local output=$2

    if [[ "$output" == "/usr/bin/qbittorrent-nox" ]]; then
        systemctl stop "qbittorrent-nox@$APP_USER" 2>/dev/null || true
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f "$output" 2>/dev/null || true
    fi

    if ! execute_with_spinner "正在获取资源 $(basename "$output")" wget -q --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "下载失败，请检查网络或 URL: $url"
    fi
}

validate_pass() {
    [[ ${#1} -ge 12 ]] || log_err "安全性不足：密码长度必须 ≥ 12 位！"
}

wait_for_lock() {
    local max_wait=300
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        log_warn "等待系统包管理器锁释放..."
        sleep 2
        waited=$((waited + 2))
        [[ $waited -ge $max_wait ]] && break
    done
}

register_firewall_rule() {
    local port=$1
    local proto=${2:-tcp}
    local rule="${port}/${proto}"
    local existing
    for existing in "${FIREWALL_RULES[@]:-}"; do
        [[ "$existing" == "$rule" ]] && return 0
    done
    FIREWALL_RULES+=("$rule")
}

is_interactive_mode() {
    [[ -t 0 && -t 1 && -r /dev/tty ]]
}

configure_firewall_policy() {
    FIREWALL_RULES=()
    register_firewall_rule "$QB_WEB_PORT" tcp
    register_firewall_rule "$QB_BT_PORT" tcp
    register_firewall_rule "$QB_BT_PORT" udp
    [[ "$DO_VX" == "true" ]] && register_firewall_rule "$VX_PORT" tcp
    [[ "$DO_FB" == "true" ]] && register_firewall_rule "$FB_PORT" tcp

    if is_interactive_mode; then
        echo -e "${YELLOW}=================================================${NC}"
        echo -e "${YELLOW} 提示: 脚本可自动放行以下防火墙端口 ${NC}"
        local rule
        for rule in "${FIREWALL_RULES[@]}"; do
            echo -e "  - ${CYAN}${rule}${NC}"
        done
        echo -e "${YELLOW}=================================================${NC}"

        local fw_answer
        read -r -p "是否自动开放这些端口？ [Y/n]: " fw_answer < /dev/tty || true
        fw_answer=${fw_answer:-Y}
        if [[ "$fw_answer" =~ ^[Yy]$ ]]; then
            FIREWALL_AUTO=true
            log_info "已选择自动配置防火墙规则。"
        else
            FIREWALL_AUTO=false
            log_warn "已跳过自动配置防火墙，请按上面的端口列表手动放行。"
        fi
    else
        FIREWALL_AUTO=true
        log_warn "当前为非交互模式：脚本将自动开放以下防火墙端口。"
        local rule
        for rule in "${FIREWALL_RULES[@]}"; do
            log_warn "  - ${rule}"
        done
    fi
}

open_port() {
    local port=$1
    local proto=${2:-tcp}
    register_firewall_rule "$port" "$proto"

    if [[ "$FIREWALL_AUTO" != "true" ]]; then
        return 0
    fi

    if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
        ufw allow "$port/$proto" >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null; then
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT || true
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif command -v iptables-save >/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
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
    local prompt=$1
    local default=$2
    local port
    while true; do
        read -p "  ▶ $prompt [默认 $default]: " port < /dev/tty
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

# ================= 1.1 硬件判定 =================

is_g95_preset() {
    local mem_kb mem_gb cpus
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_gb=$((mem_kb / 1024 / 1024))
    cpus=$(nproc 2>/dev/null || echo 1)

    [[ $cpus -ge 4 && $cpus -le 6 && $mem_gb -ge 7 && $mem_gb -le 10 ]]
}

detect_download_disk_class() {
    local path="${1:-$HB/Downloads}"
    [[ -d "$path" ]] || { echo "ssd"; return 0; }

    local dev pk rota
    dev=$(df -P "$path" 2>/dev/null | awk 'NR==2{print $1}' || true)
    [[ -n "${dev:-}" ]] || { echo "ssd"; return 0; }

    dev=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
    dev=$(basename "$dev")

    pk=$(lsblk -no PKNAME "/dev/$dev" 2>/dev/null | head -n 1 || true)
    [[ -n "${pk:-}" ]] && dev="$pk"

    rota=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo "0")
    [[ "$rota" == "1" ]] && echo "hdd" || echo "ssd"
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
        log_info "创建隔离系统用户: $APP_USER"
        if getent group "$APP_USER" >/dev/null 2>&1; then
            log_warn "检测到同名用户组已存在，正在将其指定为主要组..."
            useradd -m -s /bin/bash -g "$APP_USER" "$APP_USER"
        else
            useradd -m -s /bin/bash "$APP_USER"
        fi
    fi

    HB=$(eval echo ~$APP_USER)
}

# ================= 3. 卸载 =================

uninstall() {
    if [ -f "$ASP_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$ASP_ENV_FILE"
    fi

    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}        执行深度卸载流程 (含系统回滚)            ${NC}"
    echo -e "${CYAN}=================================================${NC}"

    log_info "正在扫描已安装的用户..."
    local detected_users
    detected_users=$(systemctl list-units --full -all --no-legend 'qbittorrent-nox@*' | sed -n 's/.*qbittorrent-nox@\([^.]*\)\.service.*/\1/p' | sort -u | tr '\n' ' ')
    [[ -z "$detected_users" ]] && detected_users="未检测到活跃服务 (可能是 admin)"

    echo -e "${YELLOW}=================================================${NC}"
    echo -e "${YELLOW} 提示: 系统中检测到以下可能的安装用户: ${NC}"
    echo -e "${GREEN} -> [ ${detected_users} ] ${NC}"
    echo -e "${YELLOW}=================================================${NC}"

    local default_u=${APP_USER:-admin}
    read -p "请输入要卸载的用户名 [默认: $default_u]: " input_user < /dev/tty
    local target_user=${input_user:-$default_u}
    local target_home
    target_home=$(eval echo ~$target_user 2>/dev/null || echo "/home/$target_user")

    log_warn "将清理用户数据并【彻底回滚内核与系统状态】。"
    read -p "确认要卸载核心组件吗？此操作不可逆！ [Y/n]: " confirm < /dev/tty
    confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0


    # 二次确认：FileBrowser 可能包含大量文件/数据库（仅在检测到相关迹象时提示）
    local fb_detected="false"
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "filebrowser" && fb_detected="true"
    fi
    if [[ -d "$target_home/filebrowser_data" || -d "$target_home/.config/filebrowser" || -f "$target_home/fb.db" ]]; then
        fb_detected="true"
    fi
    local FB_PURGE="Y"
    if [[ "$fb_detected" == "true" ]]; then
        echo -e "${YELLOW}=================================================${NC}"
        log_warn "检测到 FileBrowser 容器/数据痕迹，卸载将删除相关数据库与配置。"
        read -p "是否一并删除 FileBrowser（含数据库）？此操作不可逆！ [Y/n]: " FB_PURGE < /dev/tty
        FB_PURGE=${FB_PURGE:-Y}
        echo -e "${YELLOW}=================================================${NC}"
    fi

    # 二次确认：Vertex 删除由用户确认
    # Vertex purge confirmation
    local vx_detected="false"
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "vertex" && vx_detected="true"
    fi
    if [[ -d "$target_home/vertex" || -d "/root/vertex" ]]; then
        vx_detected="true"
    fi

    local VX_PURGE="Y"
    echo -e "${YELLOW}=================================================${NC}"
    if [[ "$vx_detected" == "true" ]]; then
        log_warn "检测到 Vertex 容器或数据痕迹，删除后不可恢复。"
    else
        log_warn "未检测到明显 Vertex 痕迹，但你仍可手动选择执行 Vertex 清理。"
    fi
    read -p "是否删除 Vertex（容器/镜像/数据）？[Y/n]: " VX_PURGE < /dev/tty
    VX_PURGE=${VX_PURGE:-Y}
    echo -e "${YELLOW}=================================================${NC}"

    execute_with_spinner "停止并移除服务守护进程" sh -c "
        systemctl stop qbittorrent-nox@${target_user} 2>/dev/null || true
        systemctl disable qbittorrent-nox@${target_user} 2>/dev/null || true

        for svc in \$(systemctl list-units --full -all | grep 'qbittorrent-nox@' | awk '{print \$1}'); do
            systemctl stop \"\$svc\" 2>/dev/null || true
            systemctl disable \"\$svc\" 2>/dev/null || true
        done

        systemctl stop asp-qb-autotune.timer 2>/dev/null || true
        systemctl stop asp-qb-autotune.service 2>/dev/null || true
        systemctl disable asp-qb-autotune.timer 2>/dev/null || true
        systemctl disable asp-qb-autotune.service 2>/dev/null || true

        # PSI detector (boot-time)
        systemctl stop asp-psi-detect.service 2>/dev/null || true
        systemctl disable asp-psi-detect.service 2>/dev/null || true


        # 彻底清理 systemd 残留（wants 链接/失败状态）
        rm -f /etc/systemd/system/timers.target.wants/asp-qb-autotune.timer 2>/dev/null || true
        rm -f /etc/systemd/system/multi-user.target.wants/asp-psi-detect.service 2>/dev/null || true
        rm -f /etc/systemd/system/multi-user.target.wants/asp-qb-autotune.service 2>/dev/null || true
        systemctl reset-failed asp-qb-autotune.timer asp-qb-autotune.service asp-psi-detect.service 2>/dev/null || true

        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f /usr/bin/qbittorrent-nox

        rm -f /etc/systemd/system/qbittorrent-nox@.service
        rm -f /etc/systemd/system/multi-user.target.wants/qbittorrent-nox@*.service 2>/dev/null || true

        rm -f \"$AUTOTUNE_BIN\" \"$AUTOTUNE_SVC\" \"$AUTOTUNE_TMR\" \"$AUTOTUNE_ENV\"
        rm -f \"$AUTOTUNE_STATE\" \"$AUTOTUNE_COOKIE\" \"$AUTOTUNE_LOCK\" \"$AUTOTUNE_PSI_WARN\"

        rm -f \"$PSI_DETECT_BIN\" \"$PSI_DETECT_SVC\" \"$PSI_FLAG_FILE\" \"$PSI_ENV_FILE\"

    "

    if command -v docker >/dev/null 2>&1; then
      execute_with_spinner "清理 Docker 镜像与容器残留" sh -c '
        VX_PURGE="$1"
        FB_PURGE="$2"
    
        case "${VX_PURGE:-Y}" in
          [Yy])
            docker rm -f vertex 2>/dev/null || true
            docker rmi lswl/vertex:stable 2>/dev/null || true
            ;;
        esac
    
        case "${FB_PURGE:-Y}" in
          [Yy])
            docker rm -f filebrowser 2>/dev/null || true
            docker rmi filebrowser/filebrowser:latest 2>/dev/null || true
            ;;
        esac
    
        docker network prune -f >/dev/null 2>&1 || true
      ' sh "${VX_PURGE:-Y}" "${FB_PURGE:-Y}"
    fi

    execute_with_spinner "移除系统优化与内核回滚 (含服务扩展)" sh -c "
        systemctl stop asp-tune.service 2>/dev/null || true
        systemctl stop asp-mediainfo.service 2>/dev/null || true
        systemctl disable asp-tune.service 2>/dev/null || true
        systemctl disable asp-mediainfo.service 2>/dev/null || true

        rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
        rm -f /etc/systemd/system/asp-mediainfo.service /usr/local/bin/asp-mediainfo.py
        rm -f /usr/local/bin/asp-mediainfo.js /usr/local/bin/sweetalert2.all.min.js

        [ -f /etc/nginx/conf.d/asp-filebrowser.conf ] && rm -f /etc/nginx/conf.d/asp-filebrowser.conf && systemctl reload nginx 2>/dev/null || true

        if [ -f /etc/security/limits.conf ]; then
            sed -i '/# Auto-Seedbox-PT Limits BEGIN/,/# Auto-Seedbox-PT Limits END/d' /etc/security/limits.conf 2>/dev/null || true
            sed -i '/# Auto-Seedbox-PT Limits/{N;N;N;N;d;}' /etc/security/limits.conf 2>/dev/null || true
        fi
    "

    log_warn "执行底层状态回滚..."
    if [ -f /etc/asp_original_governor ]; then
        local orig_gov
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

    local ETH DEF_ROUTE
    ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    [[ -n "$ETH" ]] && ifconfig "$ETH" txqueuelen 1000 2>/dev/null || true
    DEF_ROUTE=$(ip -o -4 route show to default | head -n1)
    [[ -n "$DEF_ROUTE" ]] && ip route change $DEF_ROUTE initcwnd 10 initrwnd 10 2>/dev/null || true

    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true

    execute_with_spinner "清理防火墙规则遗留" sh -c "
        if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
            ufw delete allow $QB_WEB_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/udp >/dev/null 2>&1 || true
            ufw delete allow $VX_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $FB_PORT/tcp >/dev/null 2>&1 || true
        fi
        if command -v firewalld >/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --remove-port=\"$QB_WEB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/udp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$VX_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$FB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
        if command -v iptables >/dev/null; then
            iptables -D INPUT -p tcp --dport $QB_WEB_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $VX_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $FB_PORT -j ACCEPT 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif command -v iptables-save >/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    "

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true

    log_warn "清理配置文件..."
    if [[ -d "$target_home" ]]; then
        rm -rf "$target_home/.config/qBittorrent" "$target_home/.local/share/qBittorrent" "$target_home/.cache/qBittorrent"
        if [[ "${VX_PURGE:-Y}" =~ ^[Yy]$ ]]; then
            rm -rf "$target_home/vertex"
        fi
if [[ "${FB_PURGE:-Y}" =~ ^[Yy]$ ]]; then
    rm -rf "$target_home/.config/filebrowser" "$target_home/filebrowser_data" "$target_home/fb.db"
fi
log_info "已清理 $target_home 下的配置文件。"

        if [[ -d "$target_home/Downloads" ]]; then
            echo -e "${YELLOW}=================================================${NC}"
            log_warn "检测到可能包含大量数据的目录: $target_home/Downloads"
            read -p "是否连同已下载的种子数据一并彻底删除？此操作不可逆！ [Y/n]: " del_data < /dev/tty
            del_data=${del_data:-Y}
            if [[ "$del_data" =~ ^[Yy]$ ]]; then
                rm -rf "$target_home/Downloads"
                log_info "💣 已彻底删除 $target_home/Downloads 数据目录。"
            else
                log_info "🛡️ 已为您安全保留 $target_home/Downloads 数据目录。"
            fi
            echo -e "${YELLOW}=================================================${NC}"
        fi
    fi

    rm -f "$AUTOTUNE_OPTIN_FLAG" 2>/dev/null || true

    rm -rf "/root/.config/qBittorrent" "/root/.local/share/qBittorrent" "/root/.cache/qBittorrent" "$ASP_ENV_FILE"
    if [[ "${VX_PURGE:-Y}" =~ ^[Yy]$ ]]; then
        rm -rf "/root/vertex"
    fi
    if [[ "${FB_PURGE:-Y}" =~ ^[Yy]$ ]]; then
        rm -rf "/root/.config/filebrowser" "/root/filebrowser_data" "/root/fb.db"
    fi

    log_warn "建议重启服务器 (reboot) 以彻底清理内核内存驻留。"
    log_info "卸载完成。"
    exit 0
}

# ================= 4. 系统优化 =================

optimize_system() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 系统内核优化 (ASP-Tuned Elite) ══════════════════╗${NC}"
    echo ""

    # ====== 【新增】容器环境侦测与阻断机制 ======
    local VIRT_TYPE
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    [[ -d "/proc/vz" ]] && VIRT_TYPE="openvz"
    # Fallback: some minimal/container images may miss systemd-detect-virt
    if [[ "$VIRT_TYPE" == "unknown" || "$VIRT_TYPE" == "none" ]]; then
        [[ -f "/run/systemd/container" ]] && grep -q "^lxc$" /run/systemd/container 2>/dev/null && VIRT_TYPE="lxc"
        [[ "$VIRT_TYPE" != "lxc" ]] && grep -qaE "(^|/)lxc(/|$)" /proc/1/cgroup 2>/dev/null && VIRT_TYPE="lxc"
    fi

    if [[ "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "openvz" ]]; then
        echo -e "  ${YELLOW}[!] 检测到当前环境为 $VIRT_TYPE 容器。${NC}"
        echo -e "  ${YELLOW}[!] 容器共享宿主机内核，无法越权修改底层 TCP 拥塞控制与调度策略。${NC}"
        echo -e "  ${YELLOW}[!] 已智能跳过内核级优化，防止安装报错中断。${NC}"
        echo -e "  ${GREEN}  ↳ 注: qBittorrent 应用层优化(连接数/内存/线程等)已通过API注入，不受影响！${NC}"

        # 尽力而为：在容器中依然尝试提升文件描述符限制 (这通常是被允许的)
        if ! grep -q "# Auto-Seedbox-PT Limits BEGIN" /etc/security/limits.conf 2>/dev/null; then
            if [[ -w /etc/security/limits.conf ]]; then
                cat >> /etc/security/limits.conf << EOF || log_warn "容器内写入 limits.conf 失败，已继续执行。"

# Auto-Seedbox-PT Limits BEGIN
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
# Auto-Seedbox-PT Limits END
EOF
            else
                log_warn "容器内无法写入 /etc/security/limits.conf，已跳过 nofile 提升。"
            fi
        fi
        echo ""
        return 0 # 提前退出函数，阻止后续 sysctl 和底层脚本的执行
    fi
    # ============================================

    echo -e "  ${CYAN}▶ 正在深度接管系统调度与网络协议栈...${NC}"

    local mem_kb mem_gb_sys disk_class
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_gb_sys=$((mem_kb / 1024 / 1024))
    disk_class=$(detect_download_disk_class "$HB/Downloads")

    local rmem_max=16777216
    local dirty_ratio=15
    local dirty_bg_ratio=5
    local backlog=30000
    local syn_backlog=65535

    if [[ "$disk_class" == "hdd" ]]; then
        dirty_ratio=12
        dirty_bg_ratio=4
    fi

    if [[ "$TUNE_MODE" == "1" ]]; then
        if [[ $mem_gb_sys -ge 30 ]]; then
            rmem_max=67108864
            dirty_ratio=20
            dirty_bg_ratio=5
            backlog=100000
            syn_backlog=100000
            echo -e "  ${PURPLE}↳ 检测到纯血级算力 (>=32GB)，已解锁高位内核权限 (64MB Buffer)！${NC}"
        elif [[ $mem_gb_sys -ge 15 ]]; then
            rmem_max=33554432
            dirty_ratio=15
            dirty_bg_ratio=5
            backlog=50000
            syn_backlog=100000
            echo -e "  ${PURPLE}↳ 检测到中大型算力 (>=16GB)，已挂载进阶内核权限 (32MB Buffer)。${NC}"
        else
            rmem_max=16777216
            echo -e "  ${PURPLE}↳ 检测到常规级算力 (<16GB)，已挂载防 OOM 并发矩阵 (16MB Buffer)。${NC}"
        fi
    fi

    local tcp_wmem="4096 65536 $rmem_max"
    local tcp_rmem="4096 87380 $rmem_max"
    local tcp_mem_min=$((mem_kb / 16))
    local tcp_mem_def=$((mem_kb / 8))
    local tcp_mem_max=$((mem_kb / 4))

    local avail_cc kernel_name target_cc ui_cc
    avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "bbr cubic reno")
    kernel_name=$(uname -r | tr '[:upper:]' '[:lower:]')
    target_cc="bbr"
    ui_cc="bbr"

    if [[ "$TUNE_MODE" == "1" ]]; then
        if echo "$avail_cc" | grep -qw "bbrx" || echo "$kernel_name" | grep -q "bbrx"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbrx" && echo "bbrx" || echo "bbr")
            ui_cc="bbrx"
        elif echo "$avail_cc" | grep -qw "bbr3" || echo "$kernel_name" | grep -qE "bbr3|bbrv3"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbr3" && echo "bbr3" || echo "bbr")
            ui_cc="bbrv3"
        fi

        if [ ! -f /etc/asp_original_governor ]; then
            cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null > /etc/asp_original_governor || echo "ondemand" > /etc/asp_original_governor
        fi
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
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
EOF

    if ! grep -q "# Auto-Seedbox-PT Limits BEGIN" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF

# Auto-Seedbox-PT Limits BEGIN
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
# Auto-Seedbox-PT Limits END
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
            avail=\$(cat "\$queue_path/scheduler")
            if [ "\$rot" == "0" ]; then
                if echo "\$avail" | grep -qw "mq-deadline"; then echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null; fi
            else
                if echo "\$avail" | grep -qw "bfq"; then
                    echo "bfq" > "\$queue_path/scheduler" 2>/dev/null
                elif echo "\$avail" | grep -qw "mq-deadline"; then
                    echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null
                fi
            fi
        fi
    fi
done

ETH=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
if [ -n "\$ETH" ]; then
    ifconfig "\$ETH" txqueuelen 10000 2>/dev/null
    ethtool -G "\$ETH" rx 4096 tx 4096 2>/dev/null || ethtool -G "\$ETH" rx 2048 tx 2048 2>/dev/null || true

    if [[ "$TUNE_MODE" == "1" ]]; then
        CPUS=\$(nproc 2>/dev/null || echo 1)
        if [[ \$CPUS -gt 1 ]]; then
            MASK=\$(printf "%x" \$(( (1 << CPUS) - 1 )))
            for rxq in /sys/class/net/\$ETH/queues/rx-*; do
                [ -w "\$rxq/rps_cpus" ] && echo "\$MASK" > "\$rxq/rps_cpus" 2>/dev/null
            done
            [ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
            for rxq in /sys/class/net/\$ETH/queues/rx-*; do
                [ -w "\$rxq/rps_flow_cnt" ] && echo 4096 > "\$rxq/rps_flow_cnt" 2>/dev/null
            done
        fi
    fi
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

    execute_with_spinner "注入高吞吐网络参数" sh -c "sysctl --system || true"
    execute_with_spinner "重载网卡队列与 CPU 调度" systemctl start asp-tune.service || true

    local rmem_mb=$((rmem_max / 1024 / 1024))
    echo ""
    echo -e "  ${PURPLE}[⚡ ASP-Tuned Elite 核心调优已挂载]${NC}"
    echo -e "  ${CYAN}├─${NC} 拥塞控制算法 : ${GREEN}${ui_cc}${NC}"
    echo -e "  ${CYAN}├─${NC} TCP 缓冲上限 : ${YELLOW}${rmem_mb} MB${NC}"
    echo -e "  ${CYAN}└─${NC} 脏页回写策略 : ${YELLOW}ratio=${dirty_ratio}, bg_ratio=${dirty_bg_ratio}${NC}"
    echo ""
}

# ================= 4.0 PSI 自动探测与开机自动启用 =================
# 目标:
#  1) 开机后检测 PSI 是否可用（/proc/pressure/memory 可读）
#  2) 若可用，则写入 PSI_FLAG_FILE 与 PSI_ENV_FILE（排障/状态展示）
#  3) 若 PSI 可用且已部署 autotune 单元，则自动 enable+start timer（已启用/运行则跳过）
install_psi_autodetect() {
    cat > "$PSI_DETECT_BIN" << 'EOF_PSI_DETECT'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PSI_FLAG_FILE="/etc/asp_psi_supported"
PSI_ENV_FILE="/etc/asp_psi_env.sh"

AUTOTUNE_TMR_UNIT="asp-qb-autotune.timer"
AUTOTUNE_TMR="/etc/systemd/system/asp-qb-autotune.timer"
AUTOTUNE_ENV="/etc/asp_autotune_env.sh"

psi_ok="0"
if [[ -r /proc/pressure/memory ]]; then
  if head -n 1 /proc/pressure/memory >/dev/null 2>&1; then
    psi_ok="1"
  fi
fi

if [[ "$psi_ok" == "1" ]]; then
  echo "1" > "$PSI_FLAG_FILE"
  cat > "$PSI_ENV_FILE" << EOF
# Auto-Seedbox-PT PSI capability marker (generated at boot)
export ASP_PSI_SUPPORTED=1
EOF
else
  echo "0" > "$PSI_FLAG_FILE"
  cat > "$PSI_ENV_FILE" << EOF
# Auto-Seedbox-PT PSI capability marker (generated at boot)
export ASP_PSI_SUPPORTED=0
EOF
fi
chmod 600 "$PSI_FLAG_FILE" "$PSI_ENV_FILE" 2>/dev/null || true

# 若 PSI 可用，则尝试自动启用 M1 动态控制器 timer（仅当 unit 存在）
if [[ "$psi_ok" == "1" ]]; then
  # 仅当用户已 opt-in（传过 -a）时，才自动启用动态控制器 timer
  if [[ -f "/etc/asp_autotune_optin" ]]; then
    if [[ -f "$AUTOTUNE_TMR" && -f "$AUTOTUNE_ENV" ]]; then
      systemctl daemon-reload >/dev/null 2>&1 || true

      if ! systemctl is-enabled --quiet "$AUTOTUNE_TMR_UNIT" 2>/dev/null; then
        systemctl enable "$AUTOTUNE_TMR_UNIT" >/dev/null 2>&1 || true
      fi
      if ! systemctl is-active --quiet "$AUTOTUNE_TMR_UNIT" 2>/dev/null; then
        systemctl start "$AUTOTUNE_TMR_UNIT" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

exit 0
EOF_PSI_DETECT
    chmod +x "$PSI_DETECT_BIN"

    cat > "$PSI_DETECT_SVC" << EOF
[Unit]
Description=ASP PSI Detect & Auto-Enable (Boot-time)
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$PSI_DETECT_BIN

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable asp-psi-detect.service >/dev/null 2>&1 || true
    systemctl start asp-psi-detect.service >/dev/null 2>&1 || true

    log_info "已部署 PSI 开机自动探测：asp-psi-detect.service"
}

# ================= 4.1 动态控制器（仅 Mode 1，需 -a） =================

install_autotune_m1() {
    # 说明：为解决“PSI 后开导致 timer/unit 不存在”的鸡与蛋问题，
    #      这里在 Mode 1 下始终生成 M1 控制器相关文件（脚本/service/timer/env），
    #      但仅在用户显式开启(-a)或当前已检测到 PSI 可用时才立即启用 timer。
    [[ "$TUNE_MODE" == "1" ]] || return 0

    local disk_class
    disk_class=$(detect_download_disk_class "$HB/Downloads")

    local is_g95="false"
    if is_g95_preset; then
        is_g95="true"
    fi

    cat > "$AUTOTUNE_ENV" << EOF
QB_WEB_PORT=$QB_WEB_PORT
APP_USER=$APP_USER
APP_PASS=$APP_PASS
DISK_CLASS=$disk_class
IS_G95=$is_g95
INSTALLED_MAJOR_VER=$INSTALLED_MAJOR_VER

AUTOTUNE_MEM_LOW_PCT=12
AUTOTUNE_MEM_HIGH_PCT=20
AUTOTUNE_MEM_LOW_FLOOR_MB=768
AUTOTUNE_MEM_HIGH_FLOOR_MB=1024

AUTOTUNE_PSI_GUARD=0.02
AUTOTUNE_PSI_BOOST=0.005

AUTOTUNE_LOGGER_TAG=asp-qb-autotune
EOF
    chmod 600 "$AUTOTUNE_ENV"

    cat > "$AUTOTUNE_BIN" << 'EOF_AUTOTUNE'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ENV_FILE="/etc/asp_autotune_env.sh"
STATE_FILE="/run/asp-qb-autotune.state"
COOKIE_FILE="/run/asp-qb_cookie.txt"
LOCK_FILE="/run/asp-qb-autotune.lock"
PSI_WARN_ONCE="/run/asp-qb-autotune.psi_warned"

[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "$ENV_FILE"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

TAG="${AUTOTUNE_LOGGER_TAG:-asp-qb-autotune}"
QBIT_URL="http://127.0.0.1:${QB_WEB_PORT}"

# API 存活
if ! curl -fsS --max-time 2 "${QBIT_URL}/api/v2/app/version" >/dev/null 2>&1; then
  exit 0
fi

mem_total_kb=$(grep -m1 '^MemTotal:' /proc/meminfo | awk '{print $2}')
mem_avail_kb=$(grep -m1 '^MemAvailable:' /proc/meminfo | awk '{print $2}')
mem_total_mb=$((mem_total_kb / 1024))
mem_avail_mb=$((mem_avail_kb / 1024))

psi_full_avg10="0.00"
psi_available=0
if [[ -r /proc/pressure/memory ]]; then
  psi_full_avg10=$(awk '/^full /{for(i=1;i<=NF;i++){if($i ~ /^avg10=/){split($i,a,"="); print a[2]; found=1; exit}}} END{if(!found) print "0.00"}' /proc/pressure/memory)
  psi_available=1
else
  if [[ ! -f "$PSI_WARN_ONCE" ]]; then
    logger -t "$TAG" "PSI not available; falling back to MemAvailable-only control."
    touch "$PSI_WARN_ONCE" || true
  fi
fi

mem_low_pct=${AUTOTUNE_MEM_LOW_PCT:-12}
mem_high_pct=${AUTOTUNE_MEM_HIGH_PCT:-20}
mem_low_floor=${AUTOTUNE_MEM_LOW_FLOOR_MB:-768}
mem_high_floor=${AUTOTUNE_MEM_HIGH_FLOOR_MB:-1024}

low_mb=$(( mem_total_mb * mem_low_pct / 100 ))
high_mb=$(( mem_total_mb * mem_high_pct / 100 ))
(( low_mb < mem_low_floor )) && low_mb=$mem_low_floor
(( high_mb < mem_high_floor )) && high_mb=$mem_high_floor

psi_guard=${AUTOTUNE_PSI_GUARD:-0.02}
psi_boost=${AUTOTUNE_PSI_BOOST:-0.005}

psi_full_int=$(python3 - <<PY
v=float("$psi_full_avg10")
print(int(v*1000))
PY
)

psi_guard_int=$(python3 - <<PY
v=float("$psi_guard")
print(int(v*1000))
PY
)

psi_boost_int=$(python3 - <<PY
v=float("$psi_boost")
print(int(v*1000))
PY
)

prev="normal"
if [[ -f "$STATE_FILE" ]]; then
  prev=$(cat "$STATE_FILE" 2>/dev/null || echo "normal")
fi

want="$prev"
if (( mem_avail_mb <= low_mb )) || (( psi_available == 1 && psi_full_int >= psi_guard_int )); then
  want="guard"
elif (( mem_avail_mb >= high_mb )) && (( psi_available == 0 || psi_full_int <= psi_boost_int )); then
  want="boost"
else
  if [[ "$prev" == "guard" ]]; then
    want="guard"
  elif [[ "$prev" == "boost" ]]; then
    want="boost"
  else
    want="normal"
  fi
fi

# 基线/爆发/护栏：仅调关键旋钮
if [[ "${DISK_CLASS:-ssd}" == "hdd" ]]; then
  NORMAL_CS=1200; BOOST_CS=1600; GUARD_CS=500
  NORMAL_HO=180;  BOOST_HO=240;  GUARD_HO=80
  NORMAL_PTT=180; BOOST_PTT=220; GUARD_PTT=80
  NORMAL_SB=10240; BOOST_SB=15360; GUARD_SB=5120
  NORMAL_SBF=150; BOOST_SBF=180; GUARD_SBF=120
else
  NORMAL_CS=1500; BOOST_CS=2000; GUARD_CS=600
  NORMAL_HO=240;  BOOST_HO=320;  GUARD_HO=120
  NORMAL_PTT=250; BOOST_PTT=320; GUARD_PTT=120
  NORMAL_SB=20480; BOOST_SB=30720; GUARD_SB=10240
  NORMAL_SBF=250; BOOST_SBF=300; GUARD_SBF=150
fi

if (( mem_total_mb < 6144 )); then
  NORMAL_CS=900; BOOST_CS=1200; GUARD_CS=450
  NORMAL_HO=120; BOOST_HO=160; GUARD_HO=60
  NORMAL_PTT=120; BOOST_PTT=160; GUARD_PTT=60
  NORMAL_SB=10240; BOOST_SB=15360; GUARD_SB=5120
  NORMAL_SBF=150; BOOST_SBF=180; GUARD_SBF=120
fi

if [[ "${IS_G95:-false}" == "true" ]]; then
  if [[ "${DISK_CLASS:-ssd}" != "hdd" ]]; then
    NORMAL_CS=1700; BOOST_CS=2200; GUARD_CS=650
    NORMAL_HO=260;  BOOST_HO=340;  GUARD_HO=130
    NORMAL_PTT=280; BOOST_PTT=360; GUARD_PTT=130
    NORMAL_SB=20480; BOOST_SB=32768; GUARD_SB=10240
    NORMAL_SBF=250; BOOST_SBF=320; GUARD_SBF=150
  else
    NORMAL_CS=1300; BOOST_CS=1700; GUARD_CS=550
  fi
fi

case "$want" in
  boost) CS=$BOOST_CS; HO=$BOOST_HO; PTT=$BOOST_PTT; SB=$BOOST_SB; SBF=$BOOST_SBF ;;
  guard) CS=$GUARD_CS; HO=$GUARD_HO; PTT=$GUARD_PTT; SB=$GUARD_SB; SBF=$GUARD_SBF ;;
  *)     CS=$NORMAL_CS; HO=$NORMAL_HO; PTT=$NORMAL_PTT; SB=$NORMAL_SB; SBF=$NORMAL_SBF ;;
esac

[[ "$want" == "$prev" ]] && exit 0

rm -f "$COOKIE_FILE" 2>/dev/null || true
curl -fsS -c "$COOKIE_FILE" --max-time 5 \
  --data-urlencode "username=${APP_USER}" \
  --data-urlencode "password=${APP_PASS}" \
  "${QBIT_URL}/api/v2/auth/login" >/dev/null 2>&1 || exit 0

PATCH=$(python3 - <<PY
import json
patch = {
  "connection_speed": int(${CS}),
  "max_half_open_connections": int(${HO}),
  "max_connec_per_torrent": int(${PTT}),
  "send_buffer_watermark": int(${SB}),
  "send_buffer_watermark_factor": int(${SBF}),
}
print(json.dumps(patch, separators=(",",":")))
PY
)

http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -b "$COOKIE_FILE" \
  -X POST --data-urlencode "json=$PATCH" "${QBIT_URL}/api/v2/app/setPreferences" || echo "000")

if [[ "$http_code" == "200" ]]; then
  echo "$want" > "$STATE_FILE"
  logger -t "$TAG" "state=${want} prev=${prev} memAvailMB=${mem_avail_mb} psiFullAvg10=${psi_full_avg10} cs=${CS} ho=${HO} ptt=${PTT} sb=${SB} sbf=${SBF}"
fi
EOF_AUTOTUNE
    chmod +x "$AUTOTUNE_BIN"

    cat > "$AUTOTUNE_SVC" << EOF
[Unit]
Description=ASP qBittorrent AutoTune (M1)
After=network.target qbittorrent-nox@${APP_USER}.service

[Service]
Type=oneshot
ExecStart=$AUTOTUNE_BIN
EOF

    cat > "$AUTOTUNE_TMR" << EOF
[Unit]
Description=ASP qBittorrent AutoTune Timer (M1)

[Timer]
OnBootSec=30
OnUnitActiveSec=120
AccuracySec=1
Unit=asp-qb-autotune.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

# 仅在用户显式开启(-a)或当前系统已支持 PSI 时，立即启用/启动 timer。
# 否则只生成文件，等待 asp-psi-detect.service 在后续 PSI 可用的开机阶段自动启用。
local psi_now="false"
if [[ -r /proc/pressure/memory ]] && head -n 1 /proc/pressure/memory >/dev/null 2>&1; then
    psi_now="true"
fi

# 仅在用户显式开启(-a)（opt-in）时允许启用；PSI 仅作为“可启用”的必要条件之一
local optin="false"
if [[ "$AUTOTUNE_ENABLE" == "true" ]] || [[ -f "$AUTOTUNE_OPTIN_FLAG" ]]; then
    optin="true"
fi

if [[ "$optin" == "true" && "$psi_now" == "true" ]]; then
    systemctl enable asp-qb-autotune.timer >/dev/null 2>&1 || true
    systemctl restart asp-qb-autotune.timer >/dev/null 2>&1 || true
    log_info "已启用 M1 动态控制器：asp-qb-autotune.timer"
else
    log_info "已生成 M1 动态控制器文件（未启用）。需 -a 且系统支持 PSI 时才会启用；若后续开启 PSI，可重跑脚本或由开机探测在 opt-in 后自动启用。"
fi
}

# ================= 5. 应用部署 =================

install_qbit() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 部署 qBittorrent 引擎 ══════════════════╗${NC}"
    echo ""

    local arch url api
    arch=$(uname -m)
    url=""
    api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"

    local hash_threads
    hash_threads=$(nproc 2>/dev/null || echo 2)

    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        INSTALLED_MAJOR_VER="4"
        log_info "锁定版本: 4.x -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
    elif [[ "$QB_VER_REQ" == "5" || "$QB_VER_REQ" == "5.0.4" ]]; then
        INSTALLED_MAJOR_VER="5"
        log_info "锁定版本: 5.x -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
    else
        INSTALLED_MAJOR_VER="5"
        log_info "请求动态版本: $QB_VER_REQ -> GitHub API"

        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL --max-time 10 "$api" | jq -r '.[0].tag_name' 2>/dev/null || echo "null")
        else
            tag=$(curl -sL --max-time 10 "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' 2>/dev/null | head -n 1 || echo "null")
        fi

        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_warn "GitHub API 获取失败，降级为内置版本 5.0.4"
            [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
        else
            log_info "获取上游版本: $tag"
            local fname="${arch}-qbittorrent-nox"
            url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        fi
    fi

    download_file "$url" "/usr/bin/qbittorrent-nox"
    chmod +x /usr/bin/qbittorrent-nox

    mkdir -p "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local/share/qBittorrent/BT_backup"
    chown -R "$APP_USER:$APP_USER" "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local"

    rm -f "$HB/.config/qBittorrent/qBittorrent.conf.lock"
    rm -f "$HB/.local/share/qBittorrent/BT_backup/.lock"

    local pass_hash
    pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")

    local disk_class
    disk_class=$(detect_download_disk_class "$HB/Downloads")

    if [[ "${CACHE_SET_BY_USER:-false}" == "false" ]]; then
        local total_mem_mb
        total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')

        if [[ "$TUNE_MODE" == "1" ]]; then
            if [[ "$INSTALLED_MAJOR_VER" == "4" ]]; then
                QB_CACHE=$(( total_mem_mb / 8 ))
            else
                QB_CACHE=$(( total_mem_mb / 4 ))
            fi
        else
            if [[ "$INSTALLED_MAJOR_VER" == "4" ]]; then
                QB_CACHE=$(( total_mem_mb / 12 ))
            else
                QB_CACHE=$(( total_mem_mb / 6 ))
            fi
        fi

        [[ $QB_CACHE -lt 256 ]] && QB_CACHE=256
        [[ "$TUNE_MODE" == "2" && $QB_CACHE -gt 2048 ]] && QB_CACHE=2048
    fi

    local cache_val="$QB_CACHE"
    local config_file="$HB/.config/qBittorrent/qBittorrent.conf"

    cat > "$config_file" << EOF
[LegalNotice]
Accepted=true

[Preferences]
General\Locale=zh_CN
WebUI\Locale=zh_CN
WebUI\Language=zh_CN
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

    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        local io_mode=1
        local total_mem_mb
        total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')

        if [[ "$disk_class" == "ssd" && "$TUNE_MODE" == "1" ]]; then
            io_mode=0
        fi

        if [[ "${QB_EXPLICIT_CACHE_MODE:-false}" == "true" && "$disk_class" == "ssd" && $total_mem_mb -ge 8192 ]]; then
            io_mode=0
        fi

        cat >> "$config_file" << EOF
Session\DiskIOType=2
Session\DiskIOReadMode=$io_mode
Session\DiskIOWriteMode=$io_mode
Session\MemoryWorkingSetLimit=$cache_val
Session\HashingThreads=$hash_threads
EOF
    fi

    chown "$APP_USER:$APP_USER" "$config_file"

    local total_mem_mb reserve_mb mem_limit_mb mem_high_mb
    total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    reserve_mb=1024
    [[ $total_mem_mb -le 4096 ]] && reserve_mb=768
    mem_limit_mb=$((total_mem_mb - reserve_mb))
    [[ $mem_limit_mb -lt 1024 ]] && mem_limit_mb=$((total_mem_mb * 80 / 100))
    mem_high_mb=$((mem_limit_mb * 90 / 100))

    cat > /etc/systemd/system/qbittorrent-nox@.service << EOF
[Unit]
Description=qBittorrent Service (User: %i)
After=network.target

[Service]
Type=simple
User=%i
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QB_WEB_PORT
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

OOMScoreAdjust=0
MemoryAccounting=true
MemoryHigh=${mem_high_mb}M
MemoryMax=${mem_limit_mb}M
MemoryLimit=${mem_limit_mb}M

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable "qbittorrent-nox@$APP_USER" >/dev/null 2>&1
    systemctl start "qbittorrent-nox@$APP_USER"
    open_port "$QB_WEB_PORT"
    open_port "$QB_BT_PORT" "tcp"
    open_port "$QB_BT_PORT" "udp"

    local api_ready=false
    printf "\e[?25l"
    for i in {1..20}; do
        printf "\r\033[K ${CYAN}[⠧]${NC} 轮询探测 API 接口引擎存活状态... ($i/20)"
        if curl -s -f --max-time 2 "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/version" >/dev/null; then
            api_ready=true
            break
        fi
        sleep 1
    done
    printf "\e[?25h"

    if [[ "$api_ready" == "true" ]]; then
        printf "\r\033[K ${GREEN}[√]${NC} API 引擎握手成功！开始下发高级底层配置... \n"

        curl -s -c "$TEMP_DIR/qb_cookie.txt" --max-time 5 \
            --data-urlencode "username=$APP_USER" \
            --data-urlencode "password=$APP_PASS" \
            "http://127.0.0.1:$QB_WEB_PORT/api/v2/auth/login" >/dev/null

        curl -s -b "$TEMP_DIR/qb_cookie.txt" --max-time 5 \
            "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/preferences" > "$TEMP_DIR/current_pref.json"

        local patch_json
        patch_json="{\"locale\":\"zh_CN\",\"web_ui_language\":\"zh_CN\",\"bittorrent_protocol\":1,\"dht\":false,\"pex\":false,\"lsd\":false,\"announce_to_all_trackers\":true,\"announce_to_all_tiers\":true,\"queueing_enabled\":false,\"bdecode_depth_limit\":10000,\"bdecode_token_limit\":10000000,\"strict_super_seeding\":false,\"max_ratio_action\":0,\"max_ratio\":-1,\"max_seeding_time\":-1,\"file_pool_size\":5000,\"peer_tos\":2"

        local mem_kb_qbit mem_gb_qbit sb_low sb_buf sb_factor
        mem_kb_qbit=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_gb_qbit=$((mem_kb_qbit / 1024 / 1024))

        sb_low=3072
        sb_buf=15360
        sb_factor=200

        if [[ "$disk_class" == "ssd" ]]; then
            sb_low=3072
            sb_buf=15360
            sb_factor=300
        else
            sb_low=3072
            sb_buf=10240
            sb_factor=150
        fi

        if [[ $mem_gb_qbit -lt 6 ]]; then
            sb_low=3072
            sb_buf=10240
            sb_factor=150
        fi

        if is_g95_preset && [[ "$disk_class" == "ssd" ]]; then
            sb_low=3072
            sb_buf=15360
            sb_factor=300
        fi

        if [[ "$TUNE_MODE" == "1" ]]; then
            local dyn_async_io dyn_max_connec dyn_max_connec_tor dyn_max_up dyn_max_up_tor dyn_half_open

            dyn_async_io=$([[ "$disk_class" == "ssd" ]] && echo 8 || echo 4)

            if [[ $mem_gb_qbit -ge 30 ]]; then
                dyn_async_io=12
                dyn_max_connec=30000
                dyn_max_connec_tor=1000
                dyn_max_up=10000
                dyn_max_up_tor=300
                dyn_half_open=1000
                sb_buf=65536
                sb_factor=320
            elif [[ $mem_gb_qbit -ge 15 ]]; then
                dyn_async_io=8
                dyn_max_connec=10000
                dyn_max_connec_tor=500
                dyn_max_up=5000
                dyn_max_up_tor=200
                dyn_half_open=500
            elif [[ $mem_gb_qbit -lt 6 ]]; then
                dyn_async_io=4
                dyn_max_connec=2000
                dyn_max_connec_tor=100
                dyn_max_up=500
                dyn_max_up_tor=50
                dyn_half_open=100
            else
                dyn_max_connec=4000
                dyn_max_connec_tor=200
                dyn_max_up=2000
                dyn_max_up_tor=100
                dyn_half_open=200

                if is_g95_preset; then
                    dyn_max_connec=6000
                    dyn_max_up=2500
                    dyn_half_open=250
                fi
            fi

            patch_json="${patch_json},\"max_connec\":${dyn_max_connec},\"max_connec_per_torrent\":${dyn_max_connec_tor},\"max_uploads\":${dyn_max_up},\"max_uploads_per_torrent\":${dyn_max_up_tor},\"max_half_open_connections\":${dyn_half_open},\"send_buffer_watermark\":${sb_buf},\"send_buffer_low_watermark\":${sb_low},\"send_buffer_watermark_factor\":${sb_factor},\"connection_speed\":2000,\"peer_timeout\":45,\"upload_choking_algorithm\":1,\"seed_choking_algorithm\":1,\"async_io_threads\":${dyn_async_io},\"max_active_downloads\":-1,\"max_active_uploads\":-1,\"max_active_torrents\":-1"
        else
            local m2_async
            m2_async=4
            [[ "$disk_class" == "ssd" ]] && m2_async=8

            patch_json="${patch_json},\"max_connec\":1500,\"max_connec_per_torrent\":100,\"max_uploads\":400,\"max_uploads_per_torrent\":40,\"max_half_open_connections\":80,\"send_buffer_watermark\":${sb_buf},\"send_buffer_low_watermark\":${sb_low},\"send_buffer_watermark_factor\":${sb_factor},\"connection_speed\":600,\"peer_timeout\":120,\"upload_choking_algorithm\":0,\"seed_choking_algorithm\":0,\"async_io_threads\":${m2_async}"
        fi

        if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
            local io_mode=1
            if [[ "$disk_class" == "ssd" && "$TUNE_MODE" == "1" ]]; then
                io_mode=0
            fi
            if [[ "${QB_EXPLICIT_CACHE_MODE:-false}" == "true" && "$disk_class" == "ssd" && $mem_gb_qbit -ge 8 ]]; then
                io_mode=0
            fi
            patch_json="${patch_json},\"memory_working_set_limit\":$cache_val,\"disk_io_type\":2,\"disk_io_read_mode\":$io_mode,\"disk_io_write_mode\":$io_mode,\"hashing_threads\":$hash_threads"
        else
            if [[ "$TUNE_MODE" == "1" ]]; then
                patch_json="${patch_json},\"disk_cache\":$cache_val,\"disk_cache_ttl\":600"
            else
                patch_json="${patch_json},\"disk_cache\":$cache_val,\"disk_cache_ttl\":1200"
            fi
        fi

        patch_json="${patch_json}}"
        echo "$patch_json" > "$TEMP_DIR/patch_pref.json"

        local final_payload="$patch_json"
        if command -v jq >/dev/null && grep -q "{" "$TEMP_DIR/current_pref.json"; then
            if jq -s '.[0] * .[1]' "$TEMP_DIR/current_pref.json" "$TEMP_DIR/patch_pref.json" > "$TEMP_DIR/final_pref.json" 2>/dev/null; then
                if [[ -s "$TEMP_DIR/final_pref.json" && $(cat "$TEMP_DIR/final_pref.json") != "null" ]]; then
                    final_payload=$(cat "$TEMP_DIR/final_pref.json")
                fi
            fi
        fi

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -b "$TEMP_DIR/qb_cookie.txt" \
            -X POST --data-urlencode "json=$final_payload" "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/setPreferences")

        if [[ "$http_code" == "200" ]]; then
            echo -e " ${GREEN}[√]${NC} 引擎配置下发完成。"
            systemctl restart "qbittorrent-nox@$APP_USER"
        else
            echo -e " ${RED}[X]${NC} API 注入失败 (Code: $http_code)，请手动配置。"
        fi

        rm -f "$TEMP_DIR/qb_cookie.txt" "$TEMP_DIR/"*pref.json
    else
        echo -e "\n ${RED}[X]${NC} qBittorrent WebUI 未能在 20 秒内响应！"
    fi
}

install_apps() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 部署容器化应用 (Docker) ══════════════════╗${NC}"
    echo ""
    wait_for_lock

    if ! command -v docker >/dev/null; then
        execute_with_spinner "自动安装 Docker 环境" sh -c "curl -fsSL https://get.docker.com | sh || (apt-get update && apt-get install -y docker.io)"
    fi

    if [[ "$DO_VX" == "true" ]]; then
        echo -e "  ${CYAN}▶ 正在处理 Vertex...${NC}"

        docker rm -f vertex &>/dev/null || true

        mkdir -p "$HB/vertex/data/"{client,douban,irc,push,race,rss,rule,script,server,site,watch}
        mkdir -p "$HB/vertex/data/douban/set" "$HB/vertex/data/watch/set"
        mkdir -p "$HB/vertex/data/rule/"{delete,link,rss,race,raceSet}

        local vx_pass_md5
        vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$HB/vertex/data/setting.json"
        local need_init=true

        if [[ -n "$VX_RESTORE_URL" ]]; then
            local extract_tmp
            extract_tmp=$(mktemp -d)
            local extract_failed=false

            if [[ "$VX_RESTORE_URL" == *.tar.gz* || "$VX_RESTORE_URL" == *.tgz* ]]; then
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.tar.gz"
                if ! execute_with_spinner "解压 tar.gz 备份数据" tar -xzf "$TEMP_DIR/bk.tar.gz" -C "$extract_tmp"; then
                    log_warn "tar.gz 解压失败，降级为全新安装。"
                    extract_failed=true
                fi
            else
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.zip"

                local extract_success=false
                while [[ "$extract_success" == "false" ]]; do
                    local current_pass="${VX_ZIP_PASS:-ASP_DUMMY_PASS_NO_INPUT}"
                    if execute_with_spinner "解压 ZIP 备份数据" unzip -q -o -P "$current_pass" "$TEMP_DIR/bk.zip" -d "$extract_tmp"; then
                        extract_success=true
                    else
                        echo -e "\n${YELLOW}=================================================${NC}"
                        log_warn "ZIP 解压失败：密码错误或文件损坏。"
                        echo -e "  ${CYAN}▶ 1.${NC} 输入新密码重试"
                        echo -e "  ${CYAN}▶ 2.${NC} 输入 ${YELLOW}skip${NC} 跳过恢复"
                        echo -e "  ${CYAN}▶ 3.${NC} 输入 ${RED}exit${NC} 退出脚本"
                        echo -e "${YELLOW}=================================================${NC}"
                        read -p "  请输入指令或新密码: " user_choice < /dev/tty

                        if [[ "$user_choice" == "skip" ]]; then
                            log_info "跳过备份恢复，执行全新安装。"
                            extract_failed=true
                            break
                        elif [[ "$user_choice" == "exit" ]]; then
                            log_err "用户终止部署流程。"
                        elif [[ -n "$user_choice" ]]; then
                            VX_ZIP_PASS="$user_choice"
                            log_info "已更新 ZIP 密码，准备重试解压..."
                        else
                            log_warn "输入为空，请重试。"
                        fi
                    fi
                done
            fi

            if [[ "$extract_failed" == "false" ]]; then
                local real_set
                real_set=$(find "$extract_tmp" -name "setting.json" | head -n 1)
                if [[ -n "$real_set" ]]; then
                    local real_dir
                    real_dir=$(dirname "$real_set")
                    cp -a "$real_dir"/. "$HB/vertex/data/" 2>/dev/null || true
                    need_init=false
                else
                    log_warn "备份包结构异常（未找到 setting.json），降级为全新安装。"
                fi
            fi

            rm -rf "$extract_tmp"
        elif [[ -f "$set_file" ]]; then
            log_info "检测到本地已有配置，执行原地接管..."
            need_init=false
        fi

        local gw
        gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
        [[ -z "$gw" ]] && gw="172.17.0.1"

        if [[ "$need_init" == "false" ]]; then
            cat << 'EOF_PYTHON' > "$TEMP_DIR/vx_fix.py"
import json, os, codecs, sys
from urllib.parse import urlparse, urlunparse

vx_dir = sys.argv[1]
app_user = sys.argv[2]
md5_pass = sys.argv[3]
gw_ip = sys.argv[4]
qb_port = sys.argv[5]
app_pass = sys.argv[6]
log_file = "/tmp/asp_vx_error.log"

def log_err(msg):
    with open(log_file, "a") as f:
        f.write(msg + "\n")

def update_json(path, modifier_func):
    if not os.path.exists(path) or not path.endswith('.json'):
        return
    try:
        with codecs.open(path, "r", "utf-8-sig") as f:
            data = json.load(f)
        changed = modifier_func(data)
        if changed:
            with codecs.open(path, "w", "utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
    except Exception as e:
        log_err(f"Failed to process {path}: {str(e)}")

def normalize_client_url(url: str) -> str:
    """Vertex 容器内访问 qB 的 URL 修复策略：
    - 如果备份里是 localhost/127.0.0.1/0.0.0.0/容器网关等“本地指向”，则改为 http://{gw_ip}:{qb_port}
    - 如果备份里是远程 IP/域名（多下载器场景），保留 host；若未写端口则补 qb_port
    """
    if not url or not isinstance(url, str):
        return f"http://{gw_ip}:{qb_port}"

    try:
        p = urlparse(url)
    except Exception:
        return f"http://{gw_ip}:{qb_port}"

    scheme = p.scheme or "http"
    host = p.hostname or ""
    port = p.port

    local_hosts = {"127.0.0.1", "localhost", "0.0.0.0", "172.17.0.1", gw_ip}

    if host in local_hosts or host == "":
        # 强制容器网关直连
        new_host = gw_ip
        new_port = int(qb_port)
        scheme = "http"
    else:
        # 多下载器：保留原 host/域名
        new_host = host
        new_port = port if port else int(qb_port)

    # IPv6 处理
    if ":" in new_host and not new_host.startswith("["):
        netloc = f"[{new_host}]:{new_port}"
    else:
        netloc = f"{new_host}:{new_port}"

    return urlunparse((scheme, netloc, p.path or "", p.params or "", p.query or "", p.fragment or ""))

def fix_setting(d):
    d["username"] = app_user
    d["password"] = md5_pass
    return True

update_json(os.path.join(vx_dir, "setting.json"), fix_setting)

client_dir = os.path.join(vx_dir, "client")
if os.path.exists(client_dir):
    for fname in os.listdir(client_dir):
        def fix_client(d):
            if not isinstance(d, dict):
                return False
            c_type = d.get("client", "") or d.get("type", "")
            if "qbittorrent" in (c_type or "").lower():
                old_url = d.get("clientUrl") or d.get("clientURL") or d.get("url") or ""
                new_url = normalize_client_url(old_url)

                changed = False
                if d.get("clientUrl") != new_url:
                    d["clientUrl"] = new_url
                    changed = True

                # 统一账号密码（与脚本参数一致）
                if d.get("username") != app_user:
                    d["username"] = app_user
                    changed = True
                if d.get("password") != app_pass:
                    d["password"] = app_pass
                    changed = True

                return changed
            return False

        update_json(os.path.join(client_dir, fname), fix_client)
EOF_PYTHON
            python3 "$TEMP_DIR/vx_fix.py" "$HB/vertex/data" "$APP_USER" "$vx_pass_md5" "$gw" "$QB_WEB_PORT" "$APP_PASS"
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
        find "$HB/vertex/data" -type d -exec chmod 775 {} \; 2>/dev/null || true
find "$HB/vertex/data" -type f -exec chmod 664 {} \; 2>/dev/null || true
find "$HB/vertex/data/script" -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod 775 {} \; 2>/dev/null || true

        execute_with_spinner "拉取 Vertex 镜像" docker pull lswl/vertex:stable
        execute_with_spinner "启动 Vertex 容器" docker run -d --name vertex --restart unless-stopped -p $VX_PORT:3000 -v "$HB/vertex":/vertex -e TZ=Asia/Shanghai lswl/vertex:stable
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        echo -e "  ${CYAN}▶ 正在处理 FileBrowser...${NC}"

        docker rm -f filebrowser &>/dev/null || true

        rm -rf "$HB/.config/filebrowser" "$HB/fb.db" "$HB/filebrowser_data"
        mkdir -p "$HB/.config/filebrowser" "$HB/filebrowser_data"
        chown -R "$APP_USER:$APP_USER" "$HB/.config/filebrowser" "$HB/filebrowser_data"

        if ! command -v nginx >/dev/null; then
            execute_with_spinner "安装 Nginx" sh -c "apt-get update -qq && apt-get install -y nginx"
        fi

        local JS_REMOTE_URL="https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/refs/heads/main/asp-mediainfo.js"
        execute_with_spinner "拉取 MediaInfo 前端扩展" sh -c "wget -qO /usr/local/bin/asp-mediainfo.js \"${JS_REMOTE_URL}?v=$(date +%s%N)\""
        execute_with_spinner "拉取 SweetAlert2" wget -qO /usr/local/bin/sweetalert2.all.min.js "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js"
# Screenshot 前端扩展（从 GitHub 拉取，带 cache-buster 防止中间缓存）
local SS_JS_URL="https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/refs/heads/main/asp-screenshot.js"
execute_with_spinner "拉取 Screenshot 截图扩展" sh -c "wget -qO /usr/local/bin/asp-screenshot.js \"${SS_JS_URL}?v=$(date +%s%N)\""
chmod 644 /usr/local/bin/asp-screenshot.js /usr/local/bin/asp-mediainfo.js /usr/local/bin/sweetalert2.all.min.js

        cat > /usr/local/bin/asp-mediainfo.py << 'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys
PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/mi':
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get('file', [''])[0].lstrip('/')
            full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()

            if not full_path.startswith(os.path.abspath(BASE_DIR)) or not os.path.isfile(full_path):
                self.wfile.write(json.dumps({"error": "非法路径或文件不存在"}).encode('utf-8'))
                return

            try:
                res_text = subprocess.run(['mediainfo', full_path], capture_output=True, text=True)
                raw_text = res_text.stdout

                res_json = subprocess.run(['mediainfo', '--Output=JSON', full_path], capture_output=True, text=True)
                media = None
                try:
                    media = json.loads(res_json.stdout)
                except Exception:
                    pass

                if media is None:
                    lines = raw_text.split('\n')
                    tracks = []
                    current_track = {}
                    for line in lines:
                        line = line.strip()
                        if not line:
                            if current_track:
                                tracks.append(current_track)
                                current_track = {}
                            continue
                        if ':' not in line and '@type' not in current_track:
                            current_track['@type'] = line
                        elif ':' in line:
                            k, v = line.split(':', 1)
                            current_track[k.strip()] = v.strip()
                    if current_track:
                        tracks.append(current_track)
                    media = {"media": {"track": tracks}}

                payload = {"raw_text": raw_text, **media}
                self.wfile.write(json.dumps(payload).encode('utf-8'))

            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY
        chmod +x /usr/local/bin/asp-mediainfo.py

        # ================= 截图功能（FileBrowser 内一键截图） =================
        # 前端注入脚本：asp-screenshot.js（依赖 SweetAlert2，已在本脚本中拉取）

        # 后端截图服务：asp-screenshot.py（调用 ffmpeg 抽帧，输出到 /tmp）
        cat > /usr/local/bin/asp-screenshot.py << 'EOF_PY_SS'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys, time, shutil, uuid, zipfile

PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]
OUT_ROOT = "/tmp/asp_screens"

def safe_join(base, rel):
    rel = (rel or "").lstrip("/")
    full = os.path.abspath(os.path.join(base, rel))
    base_abs = os.path.abspath(base)
    if not full.startswith(base_abs + os.sep) and full != base_abs:
        return None
    return full

def cleanup_old(max_age_sec=48*3600, max_dirs=200):
    try:
        if not os.path.isdir(OUT_ROOT):
            return
        now = time.time()
        items = []
        for name in os.listdir(OUT_ROOT):
            p = os.path.join(OUT_ROOT, name)
            if os.path.isdir(p):
                try:
                    st = os.stat(p)
                    items.append((st.st_mtime, p))
                except Exception:
                    pass
        items.sort()  # oldest first
        removed = 0
        for mtime, p in items:
            if removed >= 40:
                break
            if (now - mtime) > max_age_sec:
                shutil.rmtree(p, ignore_errors=True)
                removed += 1
        if len(items) > max_dirs:
            for _, p in items[: max(0, len(items) - max_dirs)]:
                shutil.rmtree(p, ignore_errors=True)
    except Exception:
        pass

def ffprobe_meta(path):
    """Return dict: width,height,duration (may be None)"""
    meta = {"width": None, "height": None, "duration": None}
    # duration
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=12
        )
        s = (r.stdout or "").strip()
        if s:
            meta["duration"] = float(s)
    except Exception:
        pass
    # width/height from first video stream
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height",
             "-of", "json", path],
            capture_output=True, text=True, timeout=12
        )
        j = json.loads(r.stdout or "{}")
        streams = j.get("streams") or []
        if streams:
            meta["width"] = int(streams[0].get("width")) if streams[0].get("width") else None
            meta["height"] = int(streams[0].get("height")) if streams[0].get("height") else None
    except Exception:
        pass
    return meta

def make_timestamps(dur, n, head_pct, tail_pct):
    if not dur or dur <= 0 or n <= 0:
        return [1.0] * n
    if n == 1:
        return [max(0.0, dur * 0.5)]
    head = max(0.0, min(head_pct, 49.0)) / 100.0
    tail = max(0.0, min(tail_pct, 49.0)) / 100.0
    start = dur * head
    end = dur * (1.0 - tail)
    if end <= start + 1.0:
        start = 0.0
        end = max(1.0, dur * 0.9)
    step = (end - start) / (n - 1)
    return [max(0.0, start + i * step) for i in range(n)]

def make_zip(out_dir, files, zip_name="screenshots.zip"):
    zip_path = os.path.join(out_dir, zip_name)
    try:
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for f in files:
                fp = os.path.join(out_dir, f)
                if os.path.isfile(fp):
                    z.write(fp, arcname=f)
        if os.path.isfile(zip_path) and os.path.getsize(zip_path) > 0:
            return zip_name
    except Exception:
        pass
    return None

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, payload):
        b = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/ss":
            self._send(404, {"error": "not found"})
            return

        qs = urllib.parse.parse_qs(parsed.query)
        rel = qs.get("file", [""])[0]

        def geti(key, default):
            try:
                return int(qs.get(key, [str(default)])[0] or default)
            except Exception:
                return default

        probe = (qs.get("probe", ["0"])[0] or "0").strip()  # 1 => probe only

        full = safe_join(BASE_DIR, rel)
        if not full or not os.path.isfile(full):
            self._send(400, {"error": "非法路径或文件不存在"})
            return

        if probe in ("1", "true", "yes"):
            meta = ffprobe_meta(full)
            self._send(200, {"meta": meta})
            return

        n = geti("n", 6)
        width = geti("width", 1280)
        head = geti("head", 5)
        tail = geti("tail", 5)
        fmt = (qs.get("fmt", ["jpg"])[0] or "jpg").lower()
        zip_on = (qs.get("zip", ["1"])[0] or "1").strip()

        n = max(1, min(n, 20))
        width = max(320, min(width, 3840))
        head = max(0, min(head, 49))
        tail = max(0, min(tail, 49))
        if fmt not in ("jpg", "jpeg", "png"):
            fmt = "jpg"
        make_zip_on = zip_on not in ("0", "false", "no")

        os.makedirs(OUT_ROOT, exist_ok=True)
        cleanup_old()

        token = uuid.uuid4().hex
        out_dir = os.path.join(OUT_ROOT, token)
        os.makedirs(out_dir, exist_ok=True)

        meta = ffprobe_meta(full)
        dur = meta.get("duration")
        ts = make_timestamps(dur, n, head, tail)

        files = []
        for i, t in enumerate(ts, start=1):
            out_name = f"{i}.{fmt}"
            out_path = os.path.join(out_dir, out_name)
            vf = f"scale={width}:-2"
            cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error",
                   "-ss", f"{t:.3f}", "-i", full,
                   "-frames:v", "1", "-an",
                   "-vf", vf]
            if fmt in ("jpg", "jpeg"):
                cmd += ["-q:v", "2"]
            cmd += ["-y", out_path]
            try:
                subprocess.run(cmd, timeout=35, check=True)
                if os.path.isfile(out_path) and os.path.getsize(out_path) > 0:
                    files.append(out_name)
            except Exception:
                pass

        if not files:
            try:
                shutil.rmtree(out_dir, ignore_errors=True)
            except Exception:
                pass
            self._send(500, {"error": "截图失败：ffmpeg 执行失败或文件不支持"})
            return

        zip_file = make_zip(out_dir, files) if make_zip_on else None

        payload = {
            "base": f"/__asp_ss__/{token}/",
            "files": files,
            "zip": zip_file,
            "params": {"n": n, "width": width, "head": head, "tail": tail, "fmt": fmt},
            "meta": meta
        }
        self._send(200, payload)

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY_SS
        chmod +x /usr/local/bin/asp-screenshot.py

        cat > /etc/systemd/system/asp-screenshot.service << EOF
[Unit]
Description=ASP Screenshot API Service (ffmpeg)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/asp-screenshot.py "$HB" $SS_PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable asp-screenshot.service >/dev/null 2>&1
        systemctl restart asp-screenshot.service

        
# Download asp-screenshot.js from GitHub to local server
if [ ! -s "/usr/local/bin/asp-screenshot.js" ]; then
  wget -q --tries=3 --timeout=20 -O /usr/local/bin/asp-screenshot.js \
    "https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/asp-screenshot.js?x=$(date +%s%N)" || true
fi
chmod 644 /usr/local/bin/asp-screenshot.js


cat > /etc/systemd/system/asp-mediainfo.service << EOF
[Unit]
Description=ASP MediaInfo API Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/asp-mediainfo.py "$HB" $MI_PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable asp-mediainfo.service >/dev/null 2>&1
        systemctl restart asp-mediainfo.service

        cat > /etc/nginx/conf.d/asp-filebrowser.conf << EOF_NGINX
server {
    listen $FB_PORT;
    server_name _;
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:18081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Accept-Encoding "";
        sub_filter '</body>' '<script src="/asp-mediainfo.js"></script><script src="/asp-screenshot.js"></script></body>';
        sub_filter_once on;
    }

    location = /asp-mediainfo.js {
        alias /usr/local/bin/asp-mediainfo.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }

    location = /sweetalert2.all.min.js {
        alias /usr/local/bin/sweetalert2.all.min.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }

location = /asp-screenshot.js {
    alias /usr/local/bin/asp-screenshot.js;
    add_header Content-Type "application/javascript; charset=utf-8";
        add_header Cache-Control "no-store";
}

location /api/ss {
    proxy_pass http://127.0.0.1:$SS_PORT;
}

location /__asp_ss__/ {
    alias /tmp/asp_screens/;
    autoindex off;
    add_header Cache-Control "no-store";
}

    location /api/mi {
        proxy_pass http://127.0.0.1:$MI_PORT;
    }
}
EOF_NGINX
        systemctl restart nginx

        execute_with_spinner "拉取 FileBrowser 镜像" docker pull filebrowser/filebrowser:latest
        execute_with_spinner "初始化 FileBrowser 数据库" sh -c "docker run --rm --user 0:0 -v \"$HB/filebrowser_data\":/database filebrowser/filebrowser:latest -d /database/filebrowser.db config init >/dev/null 2>&1 || true"
        execute_with_spinner "创建 FileBrowser 管理员" sh -c "docker run --rm --user 0:0 -v \"$HB/filebrowser_data\":/database filebrowser/filebrowser:latest -d /database/filebrowser.db users add \"$APP_USER\" \"$APP_PASS\" --perm.admin >/dev/null 2>&1 || true"
        execute_with_spinner "启动 FileBrowser 容器" docker run -d --name filebrowser --restart unless-stopped --user 0:0 \
            -v "$HB":/srv -v "$HB/filebrowser_data":/database -v "$HB/.config/filebrowser":/config \
            -p 127.0.0.1:18081:80 filebrowser/filebrowser:latest -d /database/filebrowser.db

        open_port "$FB_PORT"
    fi
}

# ================= 6. 参数解析 =================

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --uninstall) ACTION="uninstall"; shift ;;
        -u|--user) APP_USER="$2"; shift 2 ;;
        -p|--pass) APP_PASS="$2"; shift 2 ;;
        -c|--cache)
            QB_CACHE="$2"
            [[ "$QB_CACHE" =~ ^[0-9]+$ ]] || log_err "参数 -c/--cache 必须是数字 (MiB)。"
            CACHE_SET_BY_USER=true
            QB_EXPLICIT_CACHE_MODE=true
            shift 2
            ;;
        -q|--qbit) QB_VER_REQ="$2"; shift 2 ;;
        -m|--mode) TUNE_MODE="$2"; shift 2 ;;
        -v|--vertex) DO_VX=true; shift ;;
        -f|--filebrowser) DO_FB=true; shift ;;
        -t|--tune) DO_TUNE=true; shift ;;
        -o|--custom-port) CUSTOM_PORT=true; shift ;;
        -d|--data) VX_RESTORE_URL="$2"; shift 2 ;;
        -k|--key) VX_ZIP_PASS="$2"; shift 2 ;;
        -a|--autotune) AUTOTUNE_ENABLE=true; shift ;;
        *) shift ;;
    esac
done

if [[ "$TUNE_MODE" != "1" && "$TUNE_MODE" != "2" ]]; then
    TUNE_MODE="1"
fi

if [[ "$ACTION" == "uninstall" ]]; then
    uninstall
fi

# ================= UI =================

clear

echo -e "${CYAN}        ___   _____   ___  ${NC}"
echo -e "${CYAN}       / _ | / __/ |/ _ \\ ${NC}"
echo -e "${CYAN}      / __ |_\\ \\  / ___/ ${NC}"
echo -e "${CYAN}     /_/ |_/___/ /_/     ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "${PURPLE}     ✦ Auto-Seedbox-PT (ASP) 极限部署引擎 v3.6.0 ✦${NC}"
echo -e "${PURPLE}     ✦               作者：Supcutie              ✦${NC}"
echo -e "${GREEN}    🚀 一键部署 qBittorrent + Vertex + FileBrowser 刷流引擎${NC}"
echo -e "${YELLOW}   💡 GitHub：https://github.com/yimouleng/Auto-Seedbox-PT ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 环境预检 ══════════════════╗${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "  检查 Root 权限...... [${RED}X${NC}] 拒绝通行"
    log_err "权限不足：请使用 root 用户运行本脚本！"
else
    echo -e "  检查 Root 权限...... [${GREEN}√${NC}] 通行"
fi

mem_kb_chk=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_gb_chk=$((mem_kb_chk / 1024 / 1024))
tune_downgraded=false
if [[ "$TUNE_MODE" == "1" && $mem_gb_chk -lt 4 ]]; then
    TUNE_MODE="2"
    tune_downgraded=true
    echo -e "  检测 物理内存....... [${RED}!${NC}] ${mem_gb_chk} GB ${RED}(不足4G,触发降级保护)${NC}"
else
    echo -e "  检测 物理内存....... [${GREEN}√${NC}] ${mem_gb_chk} GB"
fi

arch_chk=$(uname -m)
echo -e "  检测 系统架构....... [${GREEN}√${NC}] ${arch_chk}"
kernel_chk=$(uname -r)
echo -e "  检测 内核版本....... [${GREEN}√${NC}] ${kernel_chk}"

if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "  检测 网络连通性..... [${GREEN}🌐${NC}] 正常"
else
    echo -e "  检测 网络连通性..... [${YELLOW}!${NC}] 异常 (后续拉取依赖可能失败)"
fi

echo -n -e "  检查 DPKG 锁状态.... "
wait_for_lock_silent() {
    local max_wait=60
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -n "."
        sleep 1
        waited=$((waited + 1))
        [[ $waited -ge $max_wait ]] && break
    done
}
wait_for_lock_silent
echo -e "[${GREEN}√${NC}] 就绪"

echo ""
echo -e " ${GREEN}√ 环境预检通过${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 模式配置 ══════════════════╗${NC}"
echo ""

if [[ "$DO_TUNE" == "true" ]]; then
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "  当前选定模式: ${RED}极限抢种 (Mode 1)${NC}"
        echo -e "  运行策略:     静态基线 +（可选）动态护栏"
        [[ "$AUTOTUNE_ENABLE" == "true" ]] && echo -e "  动态控制器:   ${GREEN}启用 (-a)${NC}" || echo -e "  动态控制器:   ${YELLOW}未启用${NC}"
        echo ""
        echo -e "  ${YELLOW}3 秒后开始部署...${NC}"
        sleep 3
    else
        echo -e "  当前选定模式: ${GREEN}均衡保种 (Mode 2)${NC}"
        echo -e "  运行策略:     静态参数 + systemd 护栏"
        if [[ "$tune_downgraded" == "true" ]]; then
            echo -e "  ${YELLOW}※ 内存不足，已强制降级 Mode 2${NC}"
        fi
        echo ""
    fi
else
    echo -e "  当前选定模式: ${GREEN}默认 (未开启系统内核调优)${NC}"
    echo ""
fi

if [[ -z "$APP_USER" ]]; then APP_USER="admin"; fi
if [[ -n "$APP_PASS" ]]; then validate_pass "$APP_PASS"; fi

if [[ -z "$APP_PASS" ]]; then
    while true; do
        echo -n -e "  ▶ 请输入 Web 面板统一密码 (必须 ≥ 12 位): "
        read -s APP_PASS < /dev/tty; echo ""
        if [[ ${#APP_PASS} -ge 12 ]]; then break; fi
        log_warn "密码过短，请重新输入！"
    done
    echo ""
fi

export DEBIAN_FRONTEND=noninteractive
execute_with_spinner "修复系统包状态" sh -c "dpkg --configure -a && apt-get --fix-broken install -y >/dev/null 2>&1 || true"
execute_with_spinner "安装依赖 (curl/jq/python3...)" sh -c "apt-get -qq update && apt-get -qq install -y curl wget jq unzip tar python3 net-tools ethtool iptables mediainfo ffmpeg locales"

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e " ${CYAN}╔══════════════════ 自定义端口 ════════════════╗${NC}"
    echo ""
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080)
    QB_BT_PORT=$(get_input_port "qBit BT监听" 47878)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
fi

while check_port_occupied "$MI_PORT"; do
    MI_PORT=$((MI_PORT + 1))
done
while check_port_occupied "$SS_PORT"; do
    SS_PORT=$((SS_PORT + 1))
done


cat > "$ASP_ENV_FILE" << EOF
export QB_WEB_PORT=$QB_WEB_PORT
export QB_BT_PORT=$QB_BT_PORT
export VX_PORT=${VX_PORT:-3000}
export FB_PORT=${FB_PORT:-8081}
export MI_PORT=${MI_PORT:-8082}
export SS_PORT=${SS_PORT:-8083}
EOF
chmod 600 "$ASP_ENV_FILE"

configure_firewall_policy

# 若用户显式传入 -a，则写入 opt-in 标记（用于开机 PSI 探测后自动启用 timer）
if [[ "$AUTOTUNE_ENABLE" == "true" ]]; then
    echo "1" > "$AUTOTUNE_OPTIN_FLAG"
    chmod 600 "$AUTOTUNE_OPTIN_FLAG" 2>/dev/null || true
fi

setup_user
install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && optimize_system

# PSI 自动启用逻辑：若未显式传 -a，但系统支持 PSI 且处于 Mode 1，则自动开启 M1 控制器部署。
# 说明：M1 控制器本身仍包含 PSI/非 PSI 的运行时自适应回退逻辑；这里只决定是否安装/启用该控制器。
# 动态控制器不再在 PSI 可用时自动等价启用；需要用户显式 -a。
install_autotune_m1
install_psi_autodetect

PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "ServerIP")

tune_str=""
if [[ "$TUNE_MODE" == "1" ]]; then
    tune_str="${RED}Mode 1 (极限抢种)${NC}"
else
    tune_str="${GREEN}Mode 2 (均衡保种)${NC}"
fi

echo ""
echo ""

VX_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
[[ -z "$VX_GW" ]] && VX_GW="172.17.0.1"

cat << EOF
========================================================================
                    ✨ AUTO-SEEDBOX-PT 部署完成 ✨
========================================================================
  [系统状态]
EOF
echo -e "  ▶ 调优模式 : $tune_str"
echo -e "  ▶ 运行用户 : ${YELLOW}$APP_USER${NC}"

# 安全提示：Mode 1 下为支持“PSI 后期开启自动启用 M1 控制器”，会生成 root-only 的 env（含 WebUI 密码）
if [[ "$TUNE_MODE" == "1" && -f "$AUTOTUNE_ENV" ]]; then
    echo -e "  🔐 安全提示 : ${YELLOW}已生成 root-only 控制器凭据 (${AUTOTUNE_ENV})${NC}"
fi

# PSI 状态展示（内核能力探测 + boot detector + M1 timer）
psi_support="不可用"
if [[ -r /proc/pressure/memory ]] && head -n 1 /proc/pressure/memory >/dev/null 2>&1; then
    psi_support="可用"
fi

# 若存在标记文件，则以标记文件为准（便于排障：是否为开机探测结果）
if [[ -f "$PSI_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PSI_ENV_FILE" 2>/dev/null || true
    if [[ "${ASP_PSI_SUPPORTED:-0}" == "1" ]]; then
        psi_support="可用"
    else
        psi_support="不可用"
    fi
fi

psi_detect_state="未启用"
if systemctl is-enabled --quiet asp-psi-detect.service 2>/dev/null; then
    psi_detect_state="已启用"
fi

autotune_state="未启用"
if [[ -f "$AUTOTUNE_TMR" ]]; then
    if systemctl is-enabled --quiet asp-qb-autotune.timer 2>/dev/null; then
        autotune_state="已启用"
    fi
    if systemctl is-active --quiet asp-qb-autotune.timer 2>/dev/null; then
        autotune_state="${autotune_state}/运行中"
    fi
fi

echo -e "  ▶ PSI 支持 : ${YELLOW}${psi_support}${NC}  (Detector: ${YELLOW}${psi_detect_state}${NC})"
if [[ -f "$AUTOTUNE_TMR" ]]; then
    echo -e "  ▶ M1 动态控制器 : ${YELLOW}${autotune_state}${NC}"
fi
echo ""
echo -e " ------------------------ ${CYAN}🌐 访问地址${NC} ------------------------"
echo -e "  ${YELLOW}⚠️ 安全提示: WebUI 为兼容部分环境已关闭 Host/CSRF 校验且默认 HTTP 明文，可手动在qb中关闭。${NC}"
if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
    echo -e "  ${YELLOW}提示: 若首次看到种子为 0，可 Ctrl+F5 强制刷新${NC}"
fi
echo -e "  🧩 qBittorrent WebUI : ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC}"
if [[ "$DO_VX" == "true" ]]; then
echo -e "  🌐 Vertex 面板      : ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
echo -e "     └─ 内部直连 qBit : ${YELLOW}$VX_GW:$QB_WEB_PORT${NC}"
fi
if [[ "$DO_FB" == "true" ]]; then
echo -e "  📁 FileBrowser      : ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
echo -e "     ├─ MediaInfo     : ${YELLOW}由本机 Nginx 代理分发${NC}"
echo -e "     └─ Screenshot    : ${YELLOW}由本机 Nginx 代理分发${NC}"
fi

echo ""
echo -e " ------------------------ ${CYAN}🔐 登录信息${NC} ------------------------"
echo -e "  👤 账号 : ${YELLOW}$APP_USER${NC}"
echo -e "  🔑 密码 : ${YELLOW}$APP_PASS${NC}"
echo -e "  📡 BT 端口 : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP)"

echo ""
echo -e " ------------------------ ${CYAN}📂 数据目录${NC} ------------------------"
echo -e "  ⬇️ Downloads : $HB/Downloads"
echo -e "  ⚙️ qB 配置   : $HB/.config/qBittorrent"
[[ "$DO_VX" == "true" ]] && echo -e "  📦 Vertex 数据: $HB/vertex/data"

echo ""
echo -e " ------------------------ ${CYAN}🛠️ 维护指令${NC} ------------------------"
echo -e "  重启 qB : ${YELLOW}systemctl restart qbittorrent-nox@$APP_USER${NC}"
echo -e "  动态控制器说明: 需要 ${YELLOW}-a${NC} opt-in 且系统支持 ${YELLOW}PSI${NC} 才会启用（开机自动检测）。"
if [[ "$TUNE_MODE" == "1" && "$AUTOTUNE_ENABLE" == "true" ]]; then
echo -e "  动态控制器 : ${YELLOW}systemctl status asp-qb-autotune.timer${NC}"
echo -e "  动态日志   : ${YELLOW}journalctl -t asp-qb-autotune -n 50${NC}"
fi
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && echo -e "  重启容器 : ${YELLOW}docker restart vertex filebrowser${NC}"
echo -e "  卸载脚本 : ${YELLOW}bash ./asp.sh --uninstall${NC}"

echo -e "========================================================================"
if [[ "$DO_TUNE" == "true" ]]; then
echo -e " ⚠️ ${YELLOW}建议 reboot 以完全应用内核参数${NC}"
echo -e "========================================================================"
fi
echo ""
