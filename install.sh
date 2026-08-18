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
  echo " 8) 全部安装"
  echo " 0) 退出"
  echo "=============================================="
}

interactive() {
  while true; do
    menu
    read -rp "请选择 [0-8]: " n
    case $n in
      1) install_unzip ;;
      2) install_docker ;;
      3) install_tailscale ;;
      4) install_nginx ;;
      5) install_pi ;;
      6) install_nano ;;
      7) setup_swap ;;
      8) install_unzip; install_docker; install_tailscale; install_nginx; install_pi; install_nano; setup_swap ;;
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
  all)      install_unzip; install_docker; install_tailscale; install_nginx; install_pi; install_nano; setup_swap ;;
  "")       interactive ;;
  *)        log_warn "未知参数: $1（可用: unzip / docker / tailscale / nginx / pi / nano / swap / all）"; exit 1 ;;
esac
