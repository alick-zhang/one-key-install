#!/usr/bin/env bash
#
# one-key-install —— Linux 一键安装脚本
# 用法：
#   bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh)
#   或带参数直接指定: install.sh docker pi  /  install.sh all
#
# 设计：
#   - 每个安装项 = 一个函数，往里加东西就加函数 + 菜单加一行
#   - 幂等：已装的项自动跳过，脚本重复跑、中断后续跑都安全
#   - 兼容 apt / yum / dnf 三系包管理器

set -e

# ================= 颜色与日志 =================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ================= 前置检查 =================
[[ $EUID -eq 0 ]] || { log_error "请用 root 运行（sudo 或 root 用户）"; exit 1; }

# 识别包管理器并定义 PKG 函数
if   command -v apt-get >/dev/null 2>&1; then PKG() { apt-get update -y && apt-get install -y "$@"; }
elif command -v dnf     >/dev/null 2>&1; then PKG() { dnf install -y "$@"; }
elif command -v yum     >/dev/null 2>&1; then PKG() { yum install -y "$@"; }
else log_error "不支持的包管理器（仅支持 apt / dnf / yum）"; exit 1; fi

# 依赖 curl / wget（很多安装流程要用）
command -v curl >/dev/null 2>&1 || PKG curl

# ================= 安装项（每个一个函数） =================

install_unzip() {
  command -v unzip >/dev/null 2>&1 && { log_info "unzip 已安装，跳过"; return; }
  log_info "安装 unzip ..."
  PKG unzip
  command -v unzip >/dev/null 2>&1 && log_info "unzip 安装完成" || { log_error "unzip 安装失败"; exit 1; }
}

install_docker() {
  command -v docker >/dev/null 2>&1 && { log_info "Docker 已安装，跳过"; return; }
  log_info "安装 Docker + Docker Compose ..."
  # 官方一键脚本：https://get.docker.com
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
  # 安装独立 docker compose 插件（新版本 docker 自带 compose v2，此处兜底）
  if ! docker compose version >/dev/null 2>&1; then
    log_warn "未检测到 docker compose 插件，尝试安装 compose standalone ..."
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  docker --version && docker compose version
  log_info "Docker 安装完成"
}

install_tailscale() {
  command -v tailscale >/dev/null 2>&1 && { log_info "Tailscale 已安装，跳过"; return; }
  log_info "安装 Tailscale ..."
  # 官方安装脚本
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  command -v tailscale >/dev/null 2>&1 && log_info "Tailscale 安装完成，运行 'tailscale up' 登录" || { log_error "Tailscale 安装失败"; exit 1; }
}

install_nginx() {
  command -v nginx >/dev/null 2>&1 && { log_info "Nginx 已安装，跳过"; return; }
  log_info "安装 Nginx ..."
  PKG nginx
  systemctl enable --now nginx
  command -v nginx >/dev/null 2>&1 && log_info "Nginx 安装完成" || { log_error "Nginx 安装失败"; exit 1; }
}

install_pi() {
  command -v pi >/dev/null 2>&1 && { log_info "Pi 已安装，跳过"; return; }
  log_info "安装 Pi（终端 AI 编程助手）..."
  # 官方安装器自动处理 Node.js 22.19+ 依赖（缺失时交互式补装）
  curl -fsSL https://pi.dev/install.sh | sh
  command -v pi >/dev/null 2>&1 && log_info "Pi 安装完成，运行 'pi' 启动" || { log_error "Pi 安装失败"; exit 1; }
}

install_nano() {
  command -v nano >/dev/null 2>&1 && { log_info "nano 已安装，跳过"; return; }
  log_info "安装 nano ..."
  PKG nano
  command -v nano >/dev/null 2>&1 && log_info "nano 安装完成" || { log_error "nano 安装失败"; exit 1; }
}

install_cron() {
  command -v crontab >/dev/null 2>&1 && { log_info "cron 已安装，跳过"; return; }
  log_info "安装 cron（定时任务）..."
  # Debian/Ubuntu 装 cron（服务名 cron）；CentOS/RHEL 装 cronie（服务名 crond）
  if command -v apt-get >/dev/null 2>&1; then
    PKG cron
    systemctl enable --now cron
  else
    PKG cronie
    systemctl enable --now crond
  fi
  command -v crontab >/dev/null 2>&1 && log_info "cron 安装完成，运行 'crontab -e' 添加定时任务" || { log_error "cron 安装失败"; exit 1; }
}

setup_swap() {
  local SWAP_SIZE=500   # MB

  if swapon --show | tail -n +2 | grep -q .; then
    log_info "系统已有启用的 swap，跳过创建"
  else
    log_info "创建 ${SWAP_SIZE}M swapfile ..."
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_info "swapfile 创建完成（已写入 /etc/fstab 持久化）"
  fi

  if [ "$(cat /proc/sys/vm/swappiness)" = "10" ]; then
    log_info "swappiness 已是 10，跳过"
  else
    sysctl -w vm.swappiness=10 >/dev/null
    echo 'vm.swappiness = 10' > /etc/sysctl.d/99-swappiness.conf
    log_info "swappiness 已设为 10（写入 /etc/sysctl.d/99-swappiness.conf 持久化）"
  fi
}

setup_bbr() {
  # 幂等：已启用则跳过
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    log_info "BBR 已启用，跳过"
    return
  fi

  # BBR 需要内核 >= 4.9
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)
  if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
    log_warn "内核 $(uname -r) 低于 4.9，不支持 BBR，跳过"
    return
  fi

  log_info "开启 BBR ..."
  # 尝试加载模块（内核内置时会失败，属正常，忽略）
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    log_warn "内核未提供 BBR 算法（可用: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)），跳过"
    return
  fi

  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true   # 容器内可能报权限错，以最终校验为准

  if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ]; then
    log_info "BBR 开启完成（写入 /etc/sysctl.d/99-bbr.conf 持久化）"
  else
    log_error "BBR 开启失败（容器环境可能不允许修改 sysctl）"
    exit 1
  fi
}

install_fail2ban() {
  command -v fail2ban-client >/dev/null 2>&1 && { log_info "fail2ban 已安装，跳过"; return; }
  log_info "安装 fail2ban（SSH 防爆破）..."
  PKG fail2ban
  # sshd jail：10 分钟内密码错 5 次 → 封禁 1 小时（参数借鉴 kejilion 默认值）
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban   # 重启确保读到新 jail 配置
  if fail2ban-client status sshd >/dev/null 2>&1; then
    log_info "fail2ban 安装完成（10 分钟内错 5 次 → 封 1 小时），查看: fail2ban-client status sshd"
  else
    log_error "fail2ban 服务异常，查日志: journalctl -u fail2ban -n 20"
    exit 1
  fi
}

setup_ports() {
  local ports=(80 443)   # HTTP / HTTPS

  log_info "放行端口 80/443 ..."
  # 注意：云厂商安全组（阿里云/腾讯云/AWS 控制台）脚本改不了，需手动放行
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q '^Status: active'; then
    # Ubuntu/Debian 系：ufw 在管
    local p
    for p in "${ports[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    log_info "ufw 已放行 80/443"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    # CentOS/RHEL 系：firewalld 在管（--permanent 持久化 + reload 生效）
    local p args=()
    for p in "${ports[@]}"; do args+=(--add-port="$p/tcp"); done
    firewall-cmd --permanent "${args[@]}" >/dev/null && firewall-cmd --reload >/dev/null
    log_info "firewalld 已放行 80/443（持久化）"
  elif command -v iptables >/dev/null 2>&1 && iptables -L INPUT -n 2>/dev/null | grep -qE 'REJECT|DROP'; then
    # 裸 iptables 挂了拦截规则（甲骨文等镜像常见）：插到最前放行，能持久化就持久化
    local p
    for p in "${ports[@]}"; do iptables -I INPUT -p tcp --dport "$p" -j ACCEPT; done
    if [ -d /etc/iptables ]; then
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      log_info "iptables 已放行 80/443，并写入 /etc/iptables/rules.v4 持久化"
    else
      log_warn "iptables 已放行 80/443，但未找到持久化目录，重启后需重跑本项"
    fi
  else
    # 没有防火墙在拦截（多数 VPS 的默认状态），端口本来就是通的
    log_info "无防火墙拦截，80/443 本来就通，无需操作"
  fi
  log_warn "云厂商安全组需在控制台手动放行 80/443（脚本管不到机房那道门）"
}

setup_clean() {
  log_info "系统清理 ..."
  # 清无用的依赖包 + 包管理器缓存
  if command -v apt-get >/dev/null 2>&1; then
    apt-get autoremove --purge -y || log_warn "apt autoremove 有报错，跳过继续"
    apt-get clean
  elif command -v dnf >/dev/null 2>&1; then
    dnf autoremove -y || true
    dnf clean all
  else
    yum autoremove -y || true
    yum clean all
  fi
  # journal 系统日志：只留 7 天、总量压到 200M 以内（无 systemd 的容器里自动跳过）
  journalctl --rotate 2>/dev/null || true
  journalctl --vacuum-time=7d 2>/dev/null | tail -n 1
  journalctl --vacuum-size=200M 2>/dev/null | tail -n 1
  log_info "系统清理完成"
}

# ================= 菜单 =================
menu() {
  echo
  echo "================ 一键安装菜单 ================"
  echo " 1) unzip"
  echo " 2) Docker + Docker Compose"
  echo " 3) Tailscale"
  echo " 4) Nginx"
  echo " 5) Pi（终端 AI 编程助手）"
  echo " 6) nano"
  echo " 7) Swap（500M + swappiness 10）"
  echo " 8) BBR（TCP 拥塞控制，内核 >= 4.9）"
  echo " 9) cron（定时任务）"
  echo "10) 防火墙放行 80/443"
  echo "11) fail2ban（SSH 防爆破）"
  echo "12) 系统清理（包缓存 + 日志压缩）"
  echo "13) 全部安装"
  echo " 0) 退出"
  echo "=============================================="
}

interactive() {
  while true; do
    menu
    read -rp "请选择 [0-13]: " n
    case $n in
      1) install_unzip ;;
      2) install_docker ;;
      3) install_tailscale ;;
      4) install_nginx ;;
      5) install_pi ;;
      6) install_nano ;;
      7) setup_swap ;;
      8) setup_bbr ;;
      9) install_cron ;;
      10) setup_ports ;;
      11) install_fail2ban ;;
      12) setup_clean ;;
      13) install_unzip; install_docker; install_tailscale; install_nginx; install_pi; install_nano; setup_swap; setup_bbr; install_cron; setup_ports; install_fail2ban ;;
      0) log_info "再见"; exit 0 ;;
      *) log_warn "无效选项: $n" ;;
    esac
  done
}

# ================= 入口：支持参数直接指定，无参数进菜单 =================
case "$1" in
  unzip)    install_unzip ;;
  docker)   install_docker ;;
  tailscale) install_tailscale ;;
  nginx)    install_nginx ;;
  pi)       install_pi ;;
  nano)     install_nano ;;
  swap)     setup_swap ;;
  bbr)      setup_bbr ;;
  cron)     install_cron ;;
  ports)    setup_ports ;;
  fail2ban) install_fail2ban ;;
  clean)    setup_clean ;;
  all)      install_unzip; install_docker; install_tailscale; install_nginx; install_pi; install_nano; setup_swap; setup_bbr; install_cron; setup_ports; install_fail2ban ;;
  "")       interactive ;;
  *)        log_warn "未知参数: $1（可用: unzip / docker / tailscale / nginx / pi / nano / swap / bbr / cron / ports / fail2ban / clean / all）"; exit 1 ;;
esac
