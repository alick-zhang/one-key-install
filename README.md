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

### 小鸡代理节点（独立脚本 install-proxy.sh，仅 Alpine）

给 128M/1G 级迷你 VPS（含 NAT 小鸡）跑代理节点用，与 install.sh 主体无关（Alpine 无 apt/dnf/yum）。
sing-box 宿主机裸跑，双协议同进程，零必填项全自动生成密钥：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install-proxy.sh)
# NAT 小鸡指定商家映射的外部端口：... install-proxy.sh --port 8443 --ext-port 51234
# 商家不给 UDP 映射就砍掉 Hy2：... install-proxy.sh --no-hy2
# 卸载：... install-proxy.sh --uninstall
```

- 主链路：VLESS-Reality（TCP，伪装成访问大站 TLS，不需域名/证书，抗探测最强）
- 备链路：Hysteria2（UDP/QUIC，拥堵时段切速），自签证书 + insecure=1
- 输出 v2rayN/Clash Meta 可直接粘贴的导入链接；NAT 场景自动用「共享IP:外部端口」生成
- 小内存兑底：无 swap 且磁盘充裕时自动加 128M swapfile；apk 源失败自动改 GitHub releases 装二进制

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
| proxy | 通用 Nginx 反向代理：交互输入域名 → 自动生成 conf（含大文件上传支持）→ 可选 certbot 签 HTTPS（Let's Encrypt 自动续期）。公网只暴露 80/443，后端端口收口到 127.0.0.1 |
| clean | 系统清理：autoremove 清无用包 + 包缓存 + journal 日志压到 7 天/200M（可反复跑） |

## 特性

- **函数化**：每个安装项一个函数，往里加东西 = 加函数 + 菜单加一行
- **幂等**：已安装的项自动跳过，重复跑 / 中断后续跑都安全
- **多发行版**：兼容 apt（Debian/Ubuntu）、dnf/yum（CentOS/RHEL）
- **参数式调用**：支持 `install.sh <item>` 或组合多个，不传参数进交互菜单
- **端口收口**：套反向代理的应用只绑 127.0.0.1，公网只露 80/443（Docker 端口映射会绕过 ufw，靠回环绑定收口比防火墙可靠）

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
