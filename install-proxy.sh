#!/usr/bin/env bash
#
# install-proxy.sh —— Alpine 小鸡一键代理节点（sing-box: VLESS-Reality + Hysteria2）
# 适用：128M 内存 / 1G 硬盘级别的迷你 VPS（如 NAT 小鸡），宿主机裸跑，不用容器
#
# 用法（root）：
#   bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install-proxy.sh)
#   可选参数：
#     --port N        监听端口（默认 8443，TCP 给 Reality，UDP 给 Hysteria2，同号不同协议）
#     --ext-port N    NAT 小鸡商家映射的外部端口（默认同 --port；独立 IP 机器不用管）
#     --host H        链接里用的 IP/域名（默认自动探测公网 IP）
#     --no-hy2        不装 Hysteria2（商家没给 UDP 映射时用）
#     --sni S         Reality 伪装目标站（默认 www.microsoft.com）
#     --uninstall     卸载：停服务、删配置、卸包
#
# 全自动生成：Reality 密钥对 / UUID / short_id / Hy2 密码 / 自签证书，零必填项。

set -e

# ================= 颜色与日志 =================
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_hint()  { echo -e "${BLUE}[HINT]${NC} $*"; }

# ================= 默认参数 =================
PORT=8443
EXT_PORT=""
HOST=""
WITH_HY2=1
SNI="www.microsoft.com"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     PORT="$2"; shift 2 ;;
    --ext-port) EXT_PORT="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --no-hy2)   WITH_HY2=0; shift ;;
    --sni)      SNI="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h)
      sed -n '3,16p' "$0"; exit 0 ;;
    *) log_error "未知参数: $1（--help 看用法）"; exit 1 ;;
  esac
done
[[ "$EXT_PORT" ]] || EXT_PORT="$PORT"

# ================= 前置检查 =================
stage() { echo; log_hint "======== $1 ========"; }

stage "阶段 0/5：环境检查"
[[ $EUID -eq 0 ]] || { log_error "请用 root 运行"; exit 1; }
[[ -f /etc/alpine-release && $(command -v apk) ]] || { log_error "本脚本仅支持 Alpine Linux（宿主机裸跑方案）"; exit 1; }
log_info "Alpine $(cat /etc/alpine-release) 确认"

# 内存/磁盘体检（128M 级小鸡给提示，不阻断）
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
DISK_MB=$(df -Pm / | awk 'NR==2{print $4}')
log_info "内存 ${MEM_MB}M / 磁盘剩余 ${DISK_MB}M"
[[ $MEM_MB -lt 256 ]] && log_warn "内存 <256M，属于小内存机型，脚本会按轻量方案配置"
[[ $DISK_MB -lt 150 ]] && log_warn "磁盘剩余 <150M，安装可能吃紧"

# ================= 卸载模式 =================
if [[ $UNINSTALL -eq 1 ]]; then
  stage "卸载 sing-box 代理节点"
  rc-service sing-box stop 2>/dev/null || true
  rc-update del sing-box default 2>/dev/null || true
  rm -f /etc/init.d/sing-box
  [[ -d /etc/sing-box ]] && { cp /etc/sing-box/config.json "/root/sing-box-config.bak.$(date +%s)" 2>/dev/null || true; rm -rf /etc/sing-box; }
  apk del sing-box 2>/dev/null || true
  rm -f /var/log/sing-box.log
  log_info "卸载完成（原配置已备份到 /root/ 下，端口放行规则如需回收请手动处理）"
  exit 0
fi

# ================= 阶段 1：安装 sing-box =================
stage "阶段 1/5：安装 sing-box"
apk update -q
if apk add -q sing-box openssl curl 2>/dev/null; then
  log_info "已从 Alpine 官方源安装 sing-box $(sing-box version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '')"
else
  # 兜底通道：GitHub releases 静态二进制（Go 静态编译，musl 直跑）
  log_warn "apk 源无 sing-box，改用 GitHub releases 兜底 ..."
  [[ "$(uname -m)" == "x86_64" ]] && SB_ARCH="amd64" || SB_ARCH="arm64"
  SB_VER="1.12.9"
  cd /tmp
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz" -o sb.tgz
  tar xzf sb.tgz
  install -m 755 "sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
  rm -rf sb.tgz "sing-box-${SB_VER}-linux-${SB_ARCH}"
  cd /
  SB_BIN=/usr/local/bin/sing-box
  log_info "已安装 sing-box $(v=$($SB_BIN version | head -1); echo $v)"
fi
command -v sing-box >/dev/null 2>&1 && SB_BIN="$(command -v sing-box)" || SB_BIN=/usr/local/bin/sing-box
"$SB_BIN" version >/dev/null 2>&1 || { log_error "sing-box 不可执行"; exit 1; }

# 小内存兜底：无 swap 且磁盘允许 → 128M swapfile
if [[ $(awk '/SwapTotal/{print $2}' /proc/meminfo) -eq 0 && $DISK_MB -gt 300 ]]; then
  log_info "小内存机无 swap，创建 128M swapfile ..."
  dd if=/dev/zero of=/swapfile bs=1M count=128 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ================= 阶段 2：生成配置 =================
stage "阶段 2/5：生成配置（密钥全自动）"
CONF_DIR=/etc/sing-box
mkdir -p "$CONF_DIR"

# 幂等保护：已有配置先备份
[[ -f $CONF_DIR/config.json ]] && { cp "$CONF_DIR/config.json" "$CONF_DIR/config.json.bak.$(date +%s)"; log_warn "检测到旧配置，已备份"; }

# 端口占用检查
if netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${PORT}$"; then
  log_error "端口 ${PORT}/TCP 已被占用，换一个: --port N"; exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
HY2_PASS=$(openssl rand -hex 12)

KEYPAIR=$("$SB_BIN" generate reality-keypair)
PRIV_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
PUB_KEY=$(echo "$KEYPAIR"  | awk '/PublicKey/{print $2}')
[[ "$PRIV_KEY" && "$PUB_KEY" ]] || { log_error "Reality 密钥对生成失败"; exit 1; }

# Hy2 自签证书（客户端 insecure=1，不依赖域名）
HY2_BLOCK=""
if [[ $WITH_HY2 -eq 1 ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$CONF_DIR/hy2.key" -out "$CONF_DIR/hy2.crt" \
    -subj "/CN=${SNI}" -days 3650 2>/dev/null
  HY2_BLOCK=$(cat <<EOF
,
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{ "password": "${HY2_PASS}" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CONF_DIR}/hy2.crt",
        "key_path": "${CONF_DIR}/hy2.key"
      }
    }
EOF
)
fi

cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
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
    }${HY2_BLOCK}
  ]
}
EOF
chmod 600 "$CONF_DIR/config.json" "$CONF_DIR"/hy2.key 2>/dev/null || true
"$SB_BIN" check -c "$CONF_DIR/config.json" && log_info "配置校验通过" || { log_error "配置校验失败"; exit 1; }

# ================= 阶段 3：OpenRC 服务 =================
stage "阶段 3/5：注册并启动服务"
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy node"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
EOF
chmod 755 /etc/init.d/sing-box
# apk 版二进制在 /usr/bin；GitHub 兜底版在 /usr/local/bin —— init 脚本指对路径
[[ -x /usr/local/bin/sing-box && ! -x /usr/bin/sing-box ]] && sed -i 's#/usr/bin/sing-box#/usr/local/bin/sing-box#' /etc/init.d/sing-box

rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart
sleep 2
rc-service sing-box status >/dev/null 2>&1 || { log_error "服务启动失败，日志:"; tail -20 /var/log/sing-box.log; exit 1; }
log_info "sing-box 已启动并设为开机自启"

# ================= 阶段 4：防火墙 =================
stage "阶段 4/5：防火墙放行"
if command -v iptables >/dev/null 2>&1 && iptables -L INPUT -n 2>/dev/null | grep -qE 'REJECT|DROP'; then
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  [[ $WITH_HY2 -eq 1 ]] && iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
  log_info "iptables 已放行 ${PORT} TCP+UDP"
elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'reject|drop'; then
  nft add rule inet filter input tcp dport "$PORT" accept 2>/dev/null || nft add rule filter input tcp dport "$PORT" accept 2>/dev/null || true
  [[ $WITH_HY2 -eq 1 ]] && { nft add rule inet filter input udp dport "$PORT" accept 2>/dev/null || true; }
  log_info "nftables 已放行 ${PORT} TCP+UDP"
else
  log_info "无防火墙拦截，端口默认全通"
fi
log_warn "云厂商安全组 / NAT 商家映射面板需要自行确认放行 ${PORT}"

# ================= 阶段 5：输出连接信息 =================
stage "阶段 5/5：部署完成"
[[ "$HOST" ]] || HOST=$(curl -fs4 --max-time 8 https://api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
[[ "$HOST" ]] || { read -rp "自动探测公网 IP 失败，手动输入 IP/域名: " HOST; }

NODE_NAME="alpine-$(hostname)"

VLESS_LINK="vless://${UUID}@${HOST}:${EXT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"

echo
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}          代理节点已部署完成（sing-box）${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo
echo "── 主链路 VLESS-Reality（TCP，抗探测最强）──"
echo "  地址:      ${HOST}:${EXT_PORT}"
echo "  UUID:      ${UUID}"
echo "  公钥 pbk:  ${PUB_KEY}"
echo "  short id:  ${SHORT_ID}"
echo "  SNI/Flow:  ${SNI} / xtls-rprx-vision"
echo
echo "  导入链接（v2rayN / Clash Meta 直接粘贴）:"
echo -e "  ${BLUE}${VLESS_LINK}${NC}"
if [[ $WITH_HY2 -eq 1 ]]; then
  HY2_LINK="hysteria2://${HY2_PASS}@${HOST}:${EXT_PORT}/?insecure=1&sni=${SNI}#${NODE_NAME}-hy2"
  echo
  echo "── 备链路 Hysteria2（UDP/QUIC，拥堵时段切它冲速）──"
  echo "  导入链接:"
  echo -e "  ${BLUE}${HY2_LINK}${NC}"
  echo "  （若商家没给 UDP 端口映射，此链路不可用，用上面 Reality 即可）"
fi
echo
echo "── 管理命令 ──"
echo "  状态: rc-service sing-box status"
echo "  重启: rc-service sing-box restart"
echo "  日志: tail -f /var/log/sing-box.log"
echo "  卸载: 本脚本 --uninstall"
echo
echo -e "${YELLOW}最后确认：商家 NAT 映射 / 云安全组已放行 外部端口 ${EXT_PORT}${NC}"
[[ "$EXT_PORT" != "$PORT" ]] && echo -e "${YELLOW}（NAT 小鸡：内部监听 ${PORT}，对外是 ${EXT_PORT}，两条链接已按外部端口生成）${NC}"
