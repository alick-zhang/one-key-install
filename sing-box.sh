#!/usr/bin/env bash
#
# sing-box.sh —— 自研 sing-box 四合一节点一键安装 / 管理脚本
# 功能形态复刻 eooce/sing-box（VLESS-Reality + VMess-WS(Argo隧道) + Hysteria2 + TUIC5），
# 但二进制全部来自官方渠道（SagerNet / Cloudflare 官方 GitHub Releases），
# 订阅文件本地生成，不依赖任何第三方 CDN 或订阅转换站——上游删库不影响本脚本。
#
# 用法（root）：
#   bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/sing-box.sh)
#   无参数进交互菜单；Alpine 请先 apk add bash curl
#
# 参数：
#   -i  静默安装（可配下方环境变量，全默认则零交互）
#   -u  静默卸载
#   -r  重启服务
#   -v  查看已安装版本
#   -h  帮助
#
# 安装时可用环境变量（bash <(curl...) PORT=12345 形式传入）：
#   PORT=        Reality 主端口（TUIC/Hy2/nginx 订阅自动用 +2/+3/+1 排开）
#   ARGO_PORT=   本机 vmess-ws 回环端口（默认 8001，仅 127.0.0.1 监听，不暴露公网）
#   REALITY_SNI= Reality 伪装目标站（默认 www.microsoft.com）
#   CFIP=        vmess-argo 链接里的优选入口 IP/域名（默认直接用隧道域名）
#   CFPORT=      同上端口（默认 443）
#   ARGO_TOKEN=  Cloudflare 固定隧道 Token（传入则走固定隧道，域名长期稳定）
#   NODENAME=    节点显示名（默认 国家-运营商 自动识别）
#   NO_ARGO=1    不装 Argo 隧道（纯 Reality+Hy2+TUIC，小内存机省资源）
#   NO_HY2=1     不装 Hysteria2（商家没给 UDP 时用）
#   NO_TUIC=1    不装 TUIC
#   NO_NGINX=1   不装 nginx（不提供 http 订阅入口，链接手动复制）
#
# 目录：/etc/sing-box（二进制 + config.json + 证书 + sb.env 元数据 + url.txt/sub.txt 订阅）
# 装完输入 sb 随时唤出管理菜单。

# ================= 颜色与日志 =================
re="\033[0m"
r()     { echo -e "\e[1;91m$1\033[0m"; }
g()     { echo -e "\e[1;32m$1\033[0m"; }
y()     { echo -e "\e[1;33m$1\033[0m"; }
b()     { echo -e "\e[1;36m$1\033[0m"; }
p()     { echo -e "\e[1;35m$1\033[0m"; }
log_info()  { echo -e "${green}[INFO]${re} $*"; }
log_warn()  { echo -e "${yellow}[WARN]${re} $*"; }
log_error() { echo -e "${red}[ERROR]${re} $*"; }
ask()       { local __v; read -rp "$(b "$1")" __v && eval "$2=\"\$__v\""; }
pause()     { read -n 1 -s -r -p "$(r "按任意键返回...")"; echo; }

# ================= 常量 =================
WORK_DIR="${SB_WORK_DIR:-/etc/sing-box}"
CONF="$WORK_DIR/config.json"
ENV_FILE="$WORK_DIR/sb.env"
URL_FILE="$WORK_DIR/url.txt"
SUB_FILE="$WORK_DIR/sub.txt"
WARP_FILE="$WORK_DIR/warp_domains.txt"
RAW_URL="https://raw.githubusercontent.com/alick-zhang/one-key-install/main/sing-box.sh"
SB_REPO="SagerNet/sing-box"
SB_VER_FALLBACK="1.14.0"

# 环境变量覆盖（安装时读取，装完持久化到 sb.env）
BASE_PORT="${PORT:-}"
VMESS_PORT="${ARGO_PORT:-8001}"
SNI="${REALITY_SNI:-www.microsoft.com}"
CFIP="${CFIP:-}"
CFPORT="${CFPORT:-443}"
ARGO_TOKEN="${ARGO_TOKEN:-}"
NODENAME="${NODENAME:-}"
NO_ARGO="${NO_ARGO:-0}"
NO_HY2="${NO_HY2:-0}"
NO_TUIC="${NO_TUIC:-0}"
NO_NGINX="${NO_NGINX:-0}"
IP_MODE="${IP_MODE:-auto}"   # auto | 4 | 6

# ================= 通用小函数 =================
command_exists() { command -v "$1" >/dev/null 2>&1; }

github_latest() {  # $1=owner/repo → 去掉 v 前缀的版本号，失败输出空
    curl -sm 10 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name": *"v?[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
}

detect_sys() {
    if command_exists systemctl; then INIT="systemd"
    elif command_exists rc-update; then INIT="openrc"
    else INIT="unknown"; fi

    if command_exists apt-get; then
        PKG() { apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
        NGINX_CONF_DIR="/etc/nginx/conf.d"
    elif command_exists dnf; then
        PKG() { dnf install -y "$@"; }
        NGINX_CONF_DIR="/etc/nginx/conf.d"
    elif command_exists yum; then
        PKG() { yum install -y "$@"; }
        NGINX_CONF_DIR="/etc/nginx/conf.d"
    elif command_exists apk; then
        PKG() { apk add "$@"; }
        NGINX_CONF_DIR="/etc/nginx/http.d"   # Alpine 的 nginx 只有 http.d
    else
        PKG() { return 1; }
        NGINX_CONF_DIR=""
    fi
}

check_root() {
    [[ $EUID -eq 0 ]] || { r "请用 root 运行：sudo -i 切换后再执行"; exit 1; }
}

fmt_host() { case "$1" in *:*) echo "[$1]" ;; *) echo "$1" ;; esac; }

port_busy() {  # $1=port 尽力检查占用；查不到工具时视为不占用
    if command_exists ss; then ss -tlnu 2>/dev/null | awk '{print $5}' | grep -qE ":$1$"
    elif command_exists netstat; then netstat -tlnu 2>/dev/null | awk '{print $4}' | grep -qE ":$1$"
    else return 1; fi
}

pick_base_port() {
    if [[ -n "$BASE_PORT" ]]; then VLESS_PORT="$BASE_PORT"; return; fi
    while :; do
        VLESS_PORT=$(( RANDOM % 50000 + 10001 ))
        [[ $((VLESS_PORT + 3)) -gt 65535 ]] && continue
        port_busy "$VLESS_PORT" && continue
        break
    done
}

svc() {  # svc <name> <start|stop|restart|status>
    if [[ $INIT == systemd ]]; then systemctl "$2" "$1" >/dev/null 2>&1
    else rc-service "$1" "$2" >/dev/null 2>&1; fi
}
svc_enable() {
    if [[ $INIT == systemd ]]; then systemctl enable "$1" >/dev/null 2>&1
    else rc-update add "$1" default >/dev/null 2>&1; fi
}
svc_active() {
    if [[ $INIT == systemd ]]; then systemctl is-active --quiet "$1" >/dev/null 2>&1
    else rc-service "$1" status 2>/dev/null | grep -q started; fi
}

# ================= 依赖安装 =================
install_deps() {
    local deps=(curl openssl jq tar)
    [[ $NO_NGINX == 1 ]] || deps+=(nginx)
    local missing=()
    local d
    for d in "${deps[@]}"; do
        # nginx 单独判断；busybox 自带 tar 不强求
        if [[ $d == nginx ]]; then command_exists nginx || missing+=("$d")
        elif [[ $d == tar ]]; then command_exists tar || missing+=("$d")
        else command_exists "$d" || missing+=("$d"); fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        y "补装依赖: ${missing[*]} ..."
        PKG "${missing[@]}" || { r "依赖安装失败，请手动安装: ${missing[*]}"; exit 1; }
    fi
    command_exists jq || { r "jq 不可用，配置编辑功能无法工作"; exit 1; }
}

# ================= 二进制下载（全部官方渠道） =================
map_arch() {
    case "$(uname -m)" in
        x86_64|amd64)        SB_ARCH="amd64";  CF_ARCH="amd64" ;;
        i386|i686|x86)       SB_ARCH="386";    CF_ARCH="" ;;
        aarch64|arm64)       SB_ARCH="arm64";  CF_ARCH="arm64" ;;
        armv7l|armv8l|armhf) SB_ARCH="armv7";  CF_ARCH="" ;;
        s390x)               SB_ARCH="s390x";  CF_ARCH="" ;;
        *) r "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

install_singbox_bin() {
    local ver url_try url_fb tmpd
    ver="$(github_latest "$SB_REPO")"
    [[ -n "$ver" ]] || ver="$SB_VER_FALLBACK"
    url_try="https://github.com/$SB_REPO/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"
    url_fb="https://github.com/$SB_REPO/releases/download/v${SB_VER_FALLBACK}/sing-box-${SB_VER_FALLBACK}-linux-${SB_ARCH}.tar.gz"
    tmpd=$(mktemp -d)
    if ! curl -fsSL -o "$tmpd/sb.tgz" "$url_try"; then
        y "v${ver} 下载失败，回退固定版本 v${SB_VER_FALLBACK}"
        curl -fsSL -o "$tmpd/sb.tgz" "$url_fb" || { r "sing-box 二进制下载失败"; rm -rf "$tmpd"; exit 1; }
        ver="$SB_VER_FALLBACK"
    fi
    tar xzf "$tmpd/sb.tgz" -C "$tmpd"
    install -m 755 "$tmpd/sing-box-${ver}-linux-${SB_ARCH}/sing-box" "$WORK_DIR/sing-box"
    rm -rf "$tmpd"
    "$WORK_DIR/sing-box" version >/dev/null 2>&1 || { r "sing-box 不可执行"; exit 1; }
    echo "$ver" > "$WORK_DIR/version"
    log_info "sing-box v${ver} 就绪"
}

install_argo_bin() {
    [[ $NO_ARGO == 1 ]] && return 0
    if [[ -z "$CF_ARCH" ]]; then
        log_warn "当前架构无官方 cloudflared，跳过 Argo（链接只保留直连协议）"
        NO_ARGO=1; return 0
    fi
    curl -fsSL -o "$WORK_DIR/argo" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
        || { r "cloudflared 下载失败，本次部署不含 Argo（Reality/Hy2/TUIC 不受影响）"; NO_ARGO=1; return 1; }
    chmod +x "$WORK_DIR/argo"
    log_info "cloudflared 就绪"
}

# ================= 元数据持久化 =================
write_env() {
    cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIV_KEY="$PRIV_KEY"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
SNI="$SNI"
VLESS_PORT="$VLESS_PORT"
TUIC_PORT="$TUIC_PORT"
HY2_PORT="$HY2_PORT"
VMESS_PORT="$VMESS_PORT"
NGINX_PORT="$NGINX_PORT"
SUB_TOKEN="$SUB_TOKEN"
NODENAME="$NODENAME"
CFIP="$CFIP"
CFPORT="$CFPORT"
IP_MODE="$IP_MODE"
ARGO_MODE="$ARGO_MODE"
ARGO_TOKEN="$ARGO_TOKEN"
ARGO_DOMAIN="$ARGO_DOMAIN"
NO_ARGO="$NO_ARGO"
NO_HY2="$NO_HY2"
NO_TUIC="$NO_TUIC"
NO_NGINX="$NO_NGINX"
EOF
    chmod 600 "$ENV_FILE"
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    return 0
}

gen_meta() {  # 缺什么补什么（重装时已有值则保留）
    [[ -n "${UUID:-}" ]]     || UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -e 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
    [[ -n "${SHORT_ID:-}" ]] || SHORT_ID=$(openssl rand -hex 8)
    if [[ -z "${PRIV_KEY:-}" || -z "${PUB_KEY:-}" ]]; then
        local kp
        kp=$("$WORK_DIR/sing-box" generate reality-keypair)
        PRIV_KEY=$(echo "$kp" | awk '/PrivateKey/{print $2}')
        PUB_KEY=$(echo "$kp" | awk '/PublicKey/{print $2}')
        [[ -n "$PRIV_KEY" && -n "$PUB_KEY" ]] || { r "Reality 密钥对生成失败"; exit 1; }
    fi
    [[ -n "${VLESS_PORT:-}" ]] || pick_base_port
    [[ -n "${TUIC_PORT:-}" ]]  || TUIC_PORT=$((VLESS_PORT + 2))
    [[ -n "${HY2_PORT:-}" ]]   || HY2_PORT=$((VLESS_PORT + 3))
    [[ -n "${NGINX_PORT:-}" ]] || NGINX_PORT=$((VLESS_PORT + 1))
    [[ -n "${SUB_TOKEN:-}" ]]  || SUB_TOKEN=$(openssl rand -hex 12)
    [[ -n "${ARGO_MODE:-}" ]]  || { [[ -n "$ARGO_TOKEN" ]] && ARGO_MODE="token" || ARGO_MODE="quick"; }
    # 节点名清洗：只留字母数字-_，其余替换为下划线（名字要进 URL）
    [[ -n "${NODENAME:-}" ]] && NODENAME=$(printf '%s' "$NODENAME" | tr -c 'A-Za-z0-9_-' '_')
    return 0
}

# ================= 自签证书（Hy2/TUIC 共用） =================
gen_certs() {
    if [[ -s "$WORK_DIR/cert.pem" && -s "$WORK_DIR/private.key" ]]; then return 0; fi
    openssl ecparam -genkey -name prime256v1 -out "$WORK_DIR/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$WORK_DIR/private.key" -out "$WORK_DIR/cert.pem" \
        -subj "/CN=${SNI}" 2>/dev/null
    [[ -s "$WORK_DIR/cert.pem" ]] || { r "自签证书生成失败"; exit 1; }
}

cert_fingerprint() {  # URL 编码过的 SHA256 指纹（放链接 pinSHA256 参数）
    [[ -s "$WORK_DIR/cert.pem" ]] || { echo ""; return; }
    openssl x509 -noout -fingerprint -sha256 -in "$WORK_DIR/cert.pem" 2>/dev/null \
        | cut -d'=' -f2 | tr -d '\n' | sed 's/:/%3A/g'
}

# ================= 配置生成 =================
gen_config() {
    local hy2_block="" tuic_block="" vmess_block=""
    local cert="$WORK_DIR/cert.pem" key="$WORK_DIR/private.key"

    if [[ $NO_TUIC != 1 ]]; then
        tuic_block=$(cat <<EOF
,
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [{ "uuid": "${UUID}", "password": "${UUID}" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert}",
        "key_path": "${key}"
      }
    }
EOF
)
    fi
    if [[ $NO_HY2 != 1 ]]; then
        hy2_block=$(cat <<EOF
,
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${UUID}" }],
      "ignore_client_bandwidth": false,
      "masquerade": "https://${SNI}",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert}",
        "key_path": "${key}"
      }
    }
EOF
)
    fi
    if [[ $NO_ARGO != 1 ]]; then
        vmess_block=$(cat <<EOF
,
    {
      "type": "vmess",
      "tag": "vmess-ws-in",
      "listen": "127.0.0.1",
      "listen_port": ${VMESS_PORT},
      "users": [{ "uuid": "${UUID}" }],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF
)
    fi

    cat > "$CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true, "output": "${WORK_DIR}/sb.log" },
  "ntp": { "enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "60m" },
  "dns": {
    "servers": [{ "tag": "local", "type": "local" }],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }${vmess_block}${tuic_block}${hy2_block}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "mtu": 1280,
      "address": ["172.16.0.2/32", "2606:4700:110:8dfe:d141:69bb:6b80:925/128"],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ],
  "route": {
    "rules": [],
    "final": "direct"
  }
}
EOF
    chmod 600 "$CONF"
    "$WORK_DIR/sing-box" check -c "$CONF" || { r "配置校验失败，内容如下排查："; cat "$CONF"; exit 1; }
}

# 配置校验失败自动回滚的保护壳：safe_edit "<jq表达式>"
safe_edit() {  # safe_edit [--arg k v ...] "<jq表达式>" —— 改配置带校验，失败自动放弃
    [[ -f "$CONF" ]] || { r "未找到配置，请先安装"; return 1; }
    cp "$CONF" "$CONF.bak.$$"
    if jq "$@" "$CONF" > "$CONF.new" 2>/dev/null; then
        "$WORK_DIR/sing-box" check -c "$CONF.new" >/dev/null 2>&1 || { rm -f "$CONF.new"; r "改后的配置校验失败，已放弃修改"; return 1; }
        mv "$CONF.new" "$CONF"
        rm -f "$CONF.bak.$$"
        svc restart sing-box
        sleep 1
        if svc_active sing-box; then
            log_info "sing-box 已重载配置"
        else
            log_warn "服务未起来，日志尾部:"
            tail -5 "$WORK_DIR/sb.log" 2>/dev/null
        fi
        return 0
    else
        rm -f "$CONF.new" "$CONF.bak.$$"
        r "jq 编辑失败，已放弃修改"
        return 1
    fi
}

# ================= 防火墙放行 =================
open_ports() {
    local spec p proto opened=0
    for spec in "$@"; do
        p="${spec%%/*}"; proto="${spec##*/}"
        if command_exists ufw && ufw status 2>/dev/null | head -1 | grep -q '^Status: active'; then
            ufw allow "$p/$proto" >/dev/null; opened=1
        elif command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q running; then
            firewall-cmd --permanent --add-port="${p}/${proto}" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; opened=1
        elif command_exists iptables && iptables -L INPUT -n 2>/dev/null | grep -qE 'REJECT|DROP'; then
            iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT
            [[ -d /etc/iptables ]] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
            opened=1
        fi
    done
    [[ $opened -eq 1 ]] && log_info "防火墙已放行 $*" || log_info "无防火墙拦截，端口默认全通"
    y "提醒：云厂商安全组 / NAT 商家映射面板需自行放行这些端口"
}

# ================= 服务注册 =================
setup_systemd_services() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box proxy node (one-key)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${WORK_DIR}
LimitNOFILE=infinity
ExecStart=${WORK_DIR}/sing-box run -c ${CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    if [[ $NO_ARGO != 1 ]]; then
        local argo_cmd
        if [[ $ARGO_MODE == token ]]; then
            argo_cmd="${WORK_DIR}/argo tunnel --no-autoupdate run --token '${ARGO_TOKEN}'"
        else
            argo_cmd="${WORK_DIR}/argo tunnel --url http://127.0.0.1:${VMESS_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
        fi
        cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Cloudflare Tunnel (argo)
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "${argo_cmd} >> ${WORK_DIR}/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    [[ $NO_ARGO != 1 ]] && { systemctl enable argo >/dev/null 2>&1; systemctl restart argo; }
}

setup_openrc_services() {
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box proxy node (one-key)"
command="${WORK_DIR}/sing-box"
command_args="run -c ${CONF}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="${WORK_DIR}/sb.log"
error_log="${WORK_DIR}/sb.log"
EOF
    chmod 755 /etc/init.d/sing-box
    if [[ $NO_ARGO != 1 ]]; then
        local argo_cmd
        if [[ $ARGO_MODE == token ]]; then
            argo_cmd="${WORK_DIR}/argo tunnel --no-autoupdate run --token ${ARGO_TOKEN}"
        else
            argo_cmd="${WORK_DIR}/argo tunnel --url http://127.0.0.1:${VMESS_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
        fi
        cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel (argo)"
command="/bin/sh"
command_args="-c ${argo_cmd} >> ${WORK_DIR}/argo.log 2>&1"
command_background="yes"
pidfile="/run/argo.pid"
EOF
        chmod 755 /etc/init.d/argo
    fi
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box restart
    [[ $NO_ARGO != 1 ]] && { rc-update add argo default >/dev/null 2>&1; rc-service argo restart; }
}

setup_services() {
    if [[ $INIT == systemd ]]; then setup_systemd_services
    elif [[ $INIT == openrc ]]; then setup_openrc_services
    else r "不支持的 init 系统（既无 systemd 也无 openrc）"; exit 1; fi
    sleep 3
    svc_active sing-box || { r "sing-box 启动失败，日志尾部:"; tail -20 "$WORK_DIR/sb.log" 2>/dev/null; exit 1; }
    log_info "sing-box 已启动并设为开机自启"
    if [[ $NO_ARGO != 1 ]]; then
        svc_active argo && log_info "Argo 隧道已启动" || log_warn "Argo 未起来，稍后可在菜单 4 里查看日志"
    fi
}

# ================= Argo 隧道域名 =================
argo_domain() {
    if [[ $ARGO_MODE == token ]]; then echo "${ARGO_DOMAIN:-}"; return; fi
    [[ -f "$WORK_DIR/argo.log" ]] || return 0
    sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "$WORK_DIR/argo.log" 2>/dev/null | tail -1
}

wait_argo_domain() {
    local dom="" i
    for i in 1 2 3 4 5; do
        dom=$(argo_domain)
        [[ -n "$dom" ]] && { echo "$dom"; return 0; }
        sleep 2
    done
    echo ""
}

# ================= 节点链接生成 =================
get_realip() {
    local flag="" ip
    [[ $IP_MODE == 4 ]] && flag="-4"
    [[ $IP_MODE == 6 ]] && flag="-6"
    local u
    for u in https://api.ip.sb/ip https://ipinfo.io/ip https://ifconfig.me; do
        ip=$(curl $flag -sm 6 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    echo ""
}

auto_nodename() {
    local geo
    geo=$(curl -sm 5 https://api.ip.sb/geoip 2>/dev/null | jq -r '.country_code + "-" + (.isp // .org // "")' 2>/dev/null)
    case "$geo" in ""|null|null-*) geo="SB-$(hostname 2>/dev/null || echo node)" ;; esac
    echo "$geo" | grep -oq . || geo="SB-$(hostname 2>/dev/null || echo node)"
    printf '%s' "$geo" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40
}

build_links() {
    load_env || { r "未安装或元数据丢失，请先安装（菜单 1 / -i）"; return 1; }
    local server_ip dom name add fp
    server_ip=$(get_realip)
    [[ -n "$server_ip" ]] || { r "公网 IP 探测失败"; ask server_ip "手动输入服务器 IP/域名: "; }
    [[ -n "$server_ip" ]] || return 1
    local host; host=$(fmt_host "$server_ip")
    name="${NODENAME:-$(auto_nodename)}"
    fp=$(cert_fingerprint)

    # Argo 域名：quick 模式现取，token 模式用存的
    dom=$(argo_domain)
    [[ -z "$dom" && $NO_ARGO != 1 ]] && dom=$(wait_argo_domain)

    local links=()
    links+=("vless://${UUID}@${host}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${name}")

    if [[ $NO_ARGO != 1 && -n "$dom" ]]; then
        add="${CFIP:-$dom}"
        local vjson
        vjson=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess-argo?ed=2560","tls":"tls","sni":"%s","fp":"chrome","allowInsecure":"false"}' \
            "Argo-${name}" "$add" "$CFPORT" "$UUID" "$dom" "$dom")
        links+=("vmess://$(printf %s "$vjson" | base64 | tr -d '\n')")
    fi

    if [[ $NO_TUIC != 1 ]]; then
        links+=("tuic://${UUID}:${UUID}@${host}:${TUIC_PORT}?sni=${SNI}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUIC-${name}")
    fi
    if [[ $NO_HY2 != 1 ]]; then
        links+=("hysteria2://${UUID}@${host}:${HY2_PORT}/?sni=${SNI}&insecure=1&pinSHA256=${fp}&alpn=h3&obfs=none#Hy2-${name}")
    fi

    : > "$URL_FILE"
    local l
    for l in "${links[@]}"; do echo "$l" >> "$URL_FILE"; done
    base64 < "$URL_FILE" | tr -d '\n' > "$SUB_FILE"

    echo ""
    g "================ 节点信息（${name}）================"
    for l in "${links[@]}"; do echo -e "${purple}${l}${re}"; echo; done
    if [[ $NO_NGINX != 1 ]] && command_exists nginx; then
        g "订阅链接（v2rayN/Shadowrocket/NekoBox 等，base64）:"
        echo -e "${purple}http://${host}:${NGINX_PORT}/${SUB_TOKEN}/sub.txt${re}"
        g "原始链接文件: http://${host}:${NGINX_PORT}/${SUB_TOKEN}/url.txt"
    fi
    g "本机文件: ${URL_FILE} / ${SUB_FILE}"
    [[ $NO_ARGO != 1 && $ARGO_MODE == quick ]] && y "提示：临时隧道域名重启会变，节点链接需重新查看（菜单5）；要域名稳定用菜单4切固定隧道"
    [[ $NO_ARGO != 1 && -z "$dom" ]] && r "Argo 域名还没拿到，vmess 链接已跳过——稍后菜单4看日志"
    return 0
}

# ================= nginx 订阅入口 =================
setup_nginx_sub() {
    [[ $NO_NGINX == 1 ]] && return 0
    command_exists nginx || { log_warn "未装 nginx，跳过订阅入口（可设 NO_NGINX=1 消除此提示）"; return 0; }
    local conf="$NGINX_CONF_DIR/sing-box-sub.conf"
    [[ -n "$NGINX_CONF_DIR" ]] || { log_warn "未识别 nginx 配置目录，跳过订阅入口"; return 0; }
    cat > "$conf" <<EOF
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name _;

    location /${SUB_TOKEN}/ {
        alias ${WORK_DIR}/;
        default_type text/plain;
    }
}
EOF
    if nginx -t >/dev/null 2>&1; then
        svc restart nginx
        svc_enable nginx
        log_info "订阅入口就绪: http://<IP>:${NGINX_PORT}/${SUB_TOKEN}/sub.txt"
    else
        rm -f "$conf"
        log_warn "nginx 配置校验失败（已回滚），订阅入口未启用：手动排查 nginx -t"
    fi
}

remove_nginx_sub() {
    [[ $NO_NGINX == 1 ]] && return 0
    local conf="$NGINX_CONF_DIR/sing-box-sub.conf"
    if [[ -f "$conf" ]]; then
        rm -f "$conf"
        nginx -t >/dev/null 2>&1 && svc restart nginx
    fi
}

# ================= 快捷命令 =================
create_shortcut() {
    curl -fsSL "$RAW_URL" -o "$WORK_DIR/sing-box.sh" 2>/dev/null \
        || { log_warn "脚本落盘失败，sb 命令不可用（不影响节点运行）"; return 1; }
    chmod +x "$WORK_DIR/sing-box.sh"
    ln -sf "$WORK_DIR/sing-box.sh" /usr/local/bin/sb
    command_exists sb && log_info "快捷命令 sb 就绪（随时输 sb 唤出管理菜单）" || { ln -sf "$WORK_DIR/sing-box.sh" /usr/bin/sb; }
}

# ================= 安装 / 卸载主流程 =================
install_flow() {
    check_root
    detect_sys
    map_arch
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    if svc_active sing-box || [[ -f "$CONF" ]]; then
        if [[ "${1:-}" == "silent" ]]; then y "已安装，跳过（重装请先 -u 卸载）"; exit 0; fi
        y "检测到已安装。继续会保留 UUID/密钥/端口重写配置（升级二进制+配置），卸载请用菜单 2。"
        ask yn "继续? (y/N): "
        [[ "$yn" =~ ^[Yy]$ ]] || return 0
        load_env || true
    fi

    y "==> 1/7 安装依赖"
    install_deps
    y "==> 2/7 下载官方二进制"
    install_singbox_bin
    install_argo_bin
    y "==> 3/7 生成密钥与配置"
    gen_meta
    [[ -n "$NODENAME" ]] || NODENAME=$(auto_nodename)
    gen_certs
    gen_config
    write_env
    y "==> 4/7 注册服务并启动"
    setup_services
    y "==> 5/7 防火墙放行"
    local specs=("${VLESS_PORT}/tcp" "${NGINX_PORT}/tcp")
    [[ $NO_TUIC != 1 ]] && specs+=("${TUIC_PORT}/udp")
    [[ $NO_HY2 != 1 ]] && specs+=("${HY2_PORT}/udp")
    open_ports "${specs[@]}"
    y "==> 6/7 创建 sb 快捷命令"
    create_shortcut
    y "==> 7/7 订阅入口"
    setup_nginx_sub

    build_links
    echo ""
    g "=========================================="
    g "   四合一节点部署完成（Reality/Argo/TUIC/Hy2）"
    g "=========================================="
    g "以后随时输 sb 进管理菜单；订阅/链接在菜单 5 查看。"
}

uninstall_flow() {
    check_root
    detect_sys
    load_env || true
    y "==> 停止并移除服务"
    svc stop sing-box; svc stop argo
    if [[ $INIT == systemd ]]; then
        systemctl disable sing-box >/dev/null 2>&1
        systemctl disable argo >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
    else
        rc-update del sing-box default >/dev/null 2>&1
        rc-update del argo default >/dev/null 2>&1
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    fi
    y "==> 移除订阅入口（nginx 本体保留）"
    remove_nginx_sub
    y "==> 备份并删除 /etc/sing-box"
    [[ -f "$CONF" ]] && cp "$CONF" "/root/sing-box-config.bak.$(date +%s)" 2>/dev/null
    rm -rf "$WORK_DIR"
    rm -f /usr/local/bin/sb /usr/bin/sb
    g "卸载完成（原配置备份在 /root/ 下；nginx 未卸载，如需卸载请手动处理）"
}

# ================= 菜单 3：sing-box 管理 =================
manage_singbox() {
    load_env || { r "未安装"; return 1; }
    echo
    g "sing-box 状态: $(svc_active sing-box && g "运行中" || r "未运行")"
    echo " 1) 启动        2) 停止       3) 重启"
    echo " 4) 运行日志    5) 更新二进制（sing-box + cloudflared）"
    echo " 0) 返回"
    ask n "选择: "
    case $n in
        1) svc start sing-box && g "已启动" ;;
        2) svc stop sing-box && g "已停止" ;;
        3) svc restart sing-box && g "已重启" ;;
        4) tail -n 40 "$WORK_DIR/sb.log" 2>/dev/null || r "暂无日志" ;;
        5)
            map_arch
            y "更新 sing-box ..."
            install_singbox_bin && log_info "sing-box 更新完成"
            if [[ $NO_ARGO != 1 ]]; then
                y "更新 cloudflared ..."
                install_argo_bin && log_info "cloudflared 更新完成"
            fi
            svc restart sing-box
            [[ $NO_ARGO != 1 ]] && svc restart argo
            g "更新完成: $(cat "$WORK_DIR/version" 2>/dev/null)"
            ;;
        0) return 0 ;;
        *) r "无效选项" ;;
    esac
}

# ================= 菜单 4：Argo 隧道管理 =================
manage_argo() {
    load_env || { r "未安装"; return 1; }
    [[ $NO_ARGO == 1 ]] && { r "安装时未启用 Argo（NO_ARGO=1），重装可开启"; return 1; }
    echo
    local cur_dom
    cur_dom=$(argo_domain)
    [[ -z "$cur_dom" ]] && cur_dom="(获取中或未就绪，选项 1 看日志)"
    g "当前模式: $( [[ $ARGO_MODE == token ]] && echo "固定隧道(token)" || echo "临时隧道(trycloudflare)")"
    g "当前域名: $(p "$cur_dom")"
    echo " 1) 查看隧道日志      2) 重启隧道（临时隧道=换新域名）"
    echo " 3) 切换为固定隧道    4) 切换为临时隧道"
    echo " 0) 返回"
    ask n "选择: "
    case $n in
        1) tail -n 40 "$WORK_DIR/argo.log" 2>/dev/null || r "暂无日志" ;;
        2) svc restart argo && sleep 4 && g "已重启，域名: $(argo_domain)" ;;
        3)
            ask tok "输入 Cloudflare 隧道 Token（Zero Trust → Networks → Tunnels 里创建）: "
            [[ -n "$tok" ]] || { r "Token 不能为空"; return 1; }
            ask dom "输入绑定到该隧道的域名（如 sb.example.com）: "
            [[ -n "$dom" ]] || { r "域名不能为空"; return 1; }
            ARGO_MODE="token"; ARGO_TOKEN="$tok"; ARGO_DOMAIN="$dom"
            write_env
            setup_services
            g "已切换固定隧道，节点信息请在菜单 5 重新查看"
            ;;
        4)
            ARGO_MODE="quick"; ARGO_TOKEN=""; ARGO_DOMAIN=""
            write_env
            setup_services
            sleep 4
            g "已切换临时隧道，域名: $(argo_domain)"
            ;;
        0) return 0 ;;
        *) r "无效选项" ;;
    esac
}

# ================= 菜单 6：修改节点配置 =================
change_config() {
    load_env || { r "未安装"; return 1; }
    echo
    echo " 1) 更换 UUID（全部协议同步换）"
    echo " 2) 更换 Reality 密钥对 + short_id"
    echo " 3) 更换主端口（TUIC/Hy2/订阅端口跟随 +2/+3/+1）"
    echo " 4) 更换伪装站 SNI"
    echo " 5) 节点链接 IPv4/IPv6 切换（当前: $IP_MODE）"
    echo " 6) 全部重生成（新 UUID + 新密钥 + 新证书）"
    echo " 0) 返回"
    ask n "选择: "
    case $n in
        1)
            local nu; nu=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -e 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
            safe_edit --arg u "$nu" '.inbounds |= map(
                if .type == "hysteria2" then .users[0].password = $u
                elif .type == "tuic" then .users[0].uuid = $u | .users[0].password = $u
                else .users[0].uuid = $u end)' || return 1
            UUID="$nu"; write_env
            g "新 UUID: $nu（菜单 5 重新生成链接）"
            ;;
        2)
            local kp np nsid
            kp=$("$WORK_DIR/sing-box" generate reality-keypair)
            np=$(echo "$kp" | awk '/PrivateKey/{print $2}')
            nsid=$(openssl rand -hex 8)
            local npub; npub=$(echo "$kp" | awk '/PublicKey/{print $2}')
            safe_edit --arg k "$np" --arg s "$nsid" \
                '.inbounds |= map(if .type == "vless" then .tls.reality.private_key = $k | .tls.reality.short_id = [$s] else . end)' || return 1
            PRIV_KEY="$np"; PUB_KEY="$npub"; SHORT_ID="$nsid"; write_env
            g "Reality 密钥已更换（菜单 5 重新生成链接）"
            ;;
        3)
            local np2
            ask np2 "输入新的 Reality 主端口（10001-65000）: "
            [[ "$np2" =~ ^[0-9]+$ ]] && [[ $np2 -ge 10001 && $np2 -le 65000 ]] || { r "端口不合法"; return 1; }
            port_busy "$np2" && { r "端口被占用"; return 1; }
            VLESS_PORT="$np2"; TUIC_PORT=$((np2+2)); HY2_PORT=$((np2+3)); NGINX_PORT=$((np2+1))
            gen_config
            write_env
            setup_services
            setup_nginx_sub
            open_ports "${VLESS_PORT}/tcp" "${NGINX_PORT}/tcp" "${TUIC_PORT}/udp" "${HY2_PORT}/udp"
            g "端口已更换（菜单 5 重新生成链接）"
            ;;
        4)
            local ns
            ask ns "输入新的伪装站（如 www.cloudflare.com）: "
            [[ -n "$ns" ]] || return 1
            SNI="$ns"
            gen_certs 2>/dev/null   # 证书 CN 已存在则跳过；换 SNI 后建议全部重生成（选项6）才彻底
            safe_edit --arg s "$ns" \
                '.inbounds |= map(if .type == "vless" then .tls.server_name = $s | .tls.reality.handshake.server = $s else . end)' || return 1
            write_env
            g "SNI 已更换（注意：Hy2/TUIC 证书 CN 未变，彻底换请用选项 6）"
            ;;
        5)
            case $IP_MODE in
                auto) IP_MODE="4" ;;
                4)    IP_MODE="6" ;;
                *)    IP_MODE="auto" ;;
            esac
            write_env
            g "已切换为: $IP_MODE（菜单 5 重新生成链接）"
            ;;
        6)
            UUID=""; PRIV_KEY=""; PUB_KEY=""; SHORT_ID=""
            rm -f "$WORK_DIR/cert.pem" "$WORK_DIR/private.key"
            gen_meta
            gen_certs
            gen_config
            write_env
            svc restart sing-box
            g "全部密钥已重生成（菜单 5 重新生成链接）"
            ;;
        0) return 0 ;;
        *) r "无效选项" ;;
    esac
}

# ================= 菜单 7：订阅管理 =================
manage_sub() {
    load_env || { r "未安装"; return 1; }
    echo
    g "订阅文件: ${URL_FILE}（原始） / ${SUB_FILE}（base64）"
    if [[ $NO_NGINX == 1 ]]; then
        y "当前未启用 http 订阅入口（NO_NGINX=1），链接请在菜单 5 手动复制"
        return 0
    fi
    command_exists nginx || { y "未安装 nginx，无 http 订阅入口；链接在菜单 5 手动复制"; return 0; }
    local host; host=$(fmt_host "$(get_realip)")
    g "订阅地址: $(p "http://${host}:${NGINX_PORT}/${SUB_TOKEN}/sub.txt")"
    echo " 1) 关闭 http 订阅入口（删 nginx 配置）"
    echo " 2) 更换订阅路径 Token"
    echo " 0) 返回"
    ask n "选择: "
    case $n in
        1)
            remove_nginx_sub
            NO_NGINX=1; write_env
            g "已关闭（重开：卸载重装或手动恢复 nginx 配置）"
            ;;
        2)
            SUB_TOKEN=$(openssl rand -hex 12)
            write_env
            setup_nginx_sub
            g "新订阅地址: http://${host}:${NGINX_PORT}/${SUB_TOKEN}/sub.txt"
            ;;
        0) return 0 ;;
        *) r "无效选项" ;;
    esac
}

# ================= 菜单 8：WARP 分流 =================
WARP_PRESET="openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
claude.ai
anthropic.com
gemini.google.com
generativelanguage.googleapis.com
grok.com
x.ai
perplexity.ai
poe.com"

warp_apply() {  # $1=on|off
    if [[ "$1" == "on" ]]; then
        [[ -s "$WARP_FILE" ]] || echo "$WARP_PRESET" > "$WARP_FILE"
        local domains_json
        domains_json=$(jq -Rn '[inputs]' < "$WARP_FILE")
        safe_edit --argjson d "$domains_json" \
            '.route.rules = [{ "domain_suffix": $d, "outbound": "warp" }]' || return 1
        g "分流已开启：以下域名走 WARP 出口"
    else
        safe_edit '.route.rules = []' || return 1
        g "分流已关闭，全部直连"
    fi
}

manage_warp() {
    load_env || { r "未安装"; return 1; }
    echo
    local rule_cnt
    rule_cnt=$(jq -r '.route.rules | length' "$CONF" 2>/dev/null || echo 0)
    g "当前状态: $( [[ "$rule_cnt" -gt 0 ]] && echo "分流开启（${rule_cnt} 条规则）" || echo "全直连" )"
    [[ -s "$WARP_FILE" ]] && g "分流域名数: $(grep -c . "$WARP_FILE")"
    echo " 1) 开启分流（AI 站点预设走 WARP）"
    echo " 2) 添加自定义域名（domain_suffix）"
    echo " 3) 查看分流域名列表"
    echo " 4) 关闭分流（恢复全直连）"
    echo " 0) 返回"
    ask n "选择: "
    case $n in
        1) warp_apply on ;;
        2)
            [[ -s "$WARP_FILE" ]] || echo "$WARP_PRESET" > "$WARP_FILE"
            ask dom "输入域名后缀（如 myai.com，一行一个效果相同，可多次添加）: "
            [[ -n "$dom" ]] || return 0
            grep -qxF "$dom" "$WARP_FILE" || echo "$dom" >> "$WARP_FILE"
            warp_apply on
            ;;
        3) [[ -s "$WARP_FILE" ]] && cat "$WARP_FILE" || y "列表为空（未开启过分流）" ;;
        4) warp_apply off ;;
        0) return 0 ;;
        *) r "无效选项" ;;
    esac
}

# ================= 主菜单 =================
menu() {
    local sb_st="未安装" argo_st="-"
    if [[ -f "$CONF" ]]; then
        svc_active sing-box && sb_st="运行中" || sb_st="已停止"
        [[ $NO_ARGO != 1 ]] && { svc_active argo && argo_st="运行中" || argo_st="已停止"; }
    fi
    clear
    echo ""
    g "GitHub: ${purple}https://github.com/alick-zhang/one-key-install${re}"
    echo ""
    p "======== 自研 sing-box 四合一管理脚本 ========"
    echo ""
    p "Argo    状态: ${argo_st}"
    p "singbox 状态: ${sb_st}   版本: v$(cat "$WORK_DIR/version" 2>/dev/null || echo '?')"
    echo ""
    g " 1. 安装 sing-box（Reality/Argo/TUIC/Hy2 一键部署）"
    r   " 2. 卸载 sing-box"
    echo "==============="
    g " 3. sing-box 管理（启停/日志/更新）"
    g " 4. Argo 隧道管理（临时/固定隧道切换）"
    echo "==============="
    g " 5. 查看节点信息（分享链接 + 订阅）"
    g " 6. 修改节点配置（UUID/端口/密钥/IPv6）"
    g " 7. 订阅管理（http 订阅入口开关）"
    g " 8. WARP 分流管理（AI 站点走 WARP）"
    echo "==============="
    p " 9. 服务器工具箱（本仓库 install.sh：BBR/swap/防火墙/fail2ban 等）"
    echo "==============="
    r " 0. 退出脚本"
    echo "==========="
}

main_menu() {
    check_root
    detect_sys
    while :; do
        menu
        ask n "请选择 [0-9]: "
        case $n in
            1) install_flow;        pause ;;
            2) ask yn "确认卸载? (y/N): "; [[ "$yn" =~ ^[Yy]$ ]] && uninstall_flow; pause ;;
            3) manage_singbox;      pause ;;
            4) manage_argo;         pause ;;
            5) build_links;         pause ;;
            6) change_config;       pause ;;
            7) manage_sub;          pause ;;
            8) manage_warp;         pause ;;
            9) bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh); pause ;;
            0) g "再见"; exit 0 ;;
            *) r "无效选项，请输入 0-9"; sleep 1 ;;
        esac
    done
}

# ================= 自测钩子（仅本地开发校验配置用，线上无感） =================
if [[ "${SB_SELFTEST:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ================= 用法与入口 =================
usage() { sed -n '2,32p' "/etc/sing-box/sing-box.sh" 2>/dev/null || sed -n '2,32p' "$0" 2>/dev/null || true; }

restart_all() {
    check_root
    detect_sys
    load_env || { r "未安装"; exit 1; }
    svc restart sing-box
    [[ $NO_ARGO != 1 ]] && svc restart argo
    g "已重启"
}

case "${1:-}" in
    -i|--install)   install_flow silent ;;
    -u|--uninstall) uninstall_flow ;;
    -r|--restart)   restart_all ;;
    -v|--version)   echo "sing-box: v$(cat "$WORK_DIR/version" 2>/dev/null || echo '未安装')"; [[ -x "$WORK_DIR/sing-box" ]] && "$WORK_DIR/sing-box" version | head -1 ;;
    -h|--help)      usage ;;
    "")             main_menu ;;
    *)              r "未知参数: $1（可用: -i / -u / -r / -v / -h，无参数进菜单）"; exit 1 ;;
esac
