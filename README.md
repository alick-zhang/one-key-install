# one-key-install

Linux 一键安装脚本模板。仿 `bash <(curl -Ls URL)` 的远程一键执行方式，脚本不落地、直接下载即运行。

## 用法

```bash
# 进入交互菜单
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh)

# 或带参数直接指定安装项
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) docker
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) docker nginx tailscale
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) all
```

## 支持安装项

| 选项 | 内容 |
|------|------|
| unzip | unzip 解压工具 |
| docker | Docker + Docker Compose（官方 get.docker.com 脚本） |
| tailscale | Tailscale 组网（官方 install.sh） |
| nginx | Nginx 反向代理 |
| pi | Pi 终端 AI 编程助手（官方 pi.dev 安装器，自动处理 Node.js 22.19+ 依赖） |
| nano | nano 文本编辑器（精简系统不自带） |
| cron | cron 定时任务（apt 装 cron / yum·dnf 装 cronie 并自启，`crontab -e` 添加任务） |
| swap | 创建 500M swapfile（fstab 持久化）+ swappiness=10（内存优化） |
| bbr | 开启 BBR TCP 拥塞控制 + fq 队列（sysctl.d 持久化，需内核 >= 4.9） |
| ports | 防火墙放行 80/443（自动识别 ufw / firewalld / iptables；无防火墙则确认已通。云厂商安全组需控制台手动放行） |
| fail2ban | SSH 防爆破：10 分钟内密码错 5 次封禁 1 小时（jail.d 持久化，`fail2ban-client status sshd` 查看） |
| rclone | rclone 云存储同步/备份（官方 install.sh 装最新版，支持 S3/R2/OneDrive/WebDAV/SFTP 等 70+ 后端，`rclone config` 配置） |
| openlist | OpenList 网盘聚合/文件列表（Docker Compose 部署到 `/opt/openlist`，端口 5244，自动补装 Docker；初始密码看 `docker logs openlist`，重置: `docker exec openlist ./openlist admin random`） |
| clean | 系统清理：autoremove 清无用包 + 包缓存 + journal 日志压到 7 天/200M（可反复跑） |

## 特性

- **函数化**：每个安装项一个函数，往里加东西 = 加函数 + 菜单加一行
- **幂等**：已安装的项自动跳过，重复跑 / 中断后续跑都安全
- **多发行版**：兼容 apt（Debian/Ubuntu）、dnf/yum（CentOS/RHEL）
- **参数式调用**：支持 `install.sh <item>` 或组合多个，不传参数进交互菜单

## 添加新安装项

在 `install.sh` 里照葫芦画瓢：

```bash
install_xxx() {
  command -v xxx >/dev/null 2>&1 && { log_info "xxx 已安装，跳过"; return; }
  log_info "安装 xxx ..."
  PKG xxx                                  # 或官方脚本 curl ... | bash
  systemctl enable --now xxx               # 若需要开机自启
  command -v xxx >/dev/null 2>&1 && log_info "完成" || { log_error "失败"; exit 1; }
}
```

然后在 `case "$1"` 和 `interactive()` 菜单里各加一行。
