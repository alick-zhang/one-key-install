# one-key-install

Linux 一键安装脚本模板。仿 `bash <(curl -Ls URL)` 的远程一键执行方式，脚本不落地、直接下载即运行。

## 脚本总览

| 脚本 | 适用场景 | 一句话说明 |
|------|----------|-----------|
| [install.sh](#用法) | 通用 VPS（Debian/Ubuntu/CentOS 系） | 常用工具菜单式安装：Docker、Tailscale、BBR、fail2ban、反代等 15 项 |
| [sing-box.sh](#sing-box-四合一节点管理独立脚本-sing-boxsh) | 想跑代理节点的 VPS | 自研 sing-box 四合一（Reality/Argo/TUIC/Hy2）一键部署 + `sb` 管理菜单 |
| [install-proxy.sh](#小鸡代理节点独立脚本-install-proxysh仅-alpine) | Alpine 迷你 NAT 小鸡（128M 级） | 双链路轻量节点（Reality + Hy2），零必填项全自动 |

## 用法

```bash
# 进入交互菜单
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh)

# 或带参数直接指定安装项
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) docker
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) docker nginx tailscale
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/install.sh) all
```

### sing-box 四合一节点管理（独立脚本 sing-box.sh）

自研的 sing-box 节点一键安装 + 常驻管理脚本，功能形态复刻 `eooce/sing-box`，
但**二进制全部走官方渠道**（SagerNet / Cloudflare 官方 GitHub Releases），订阅文件本地生成，
不依赖任何第三方 CDN 或订阅转换站——上游删库不影响本脚本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/alick-zhang/one-key-install/main/sing-box.sh)
# 静默安装（可带环境变量）：... sing-box.sh -i
# 静默卸载：... sing-box.sh -u
```

- 四协议一次部署，共用一个 UUID：VLESS-Reality（TCP 主链路）/ VMess-WS（Argo 隧道入口）/ TUIC v5 / Hysteria2
- 多发行版：apt / dnf / yum / apk，systemd / OpenRC 双支持（含 Alpine 小鸡）
- 装完输 `sb` 随时唤出菜单：启停 / 日志 / 更新二进制、Argo 临时↔固定隧道切换、改 UUID/端口/密钥、
  IPv4/IPv6 切换、WARP 分流（AI 站点预设走 WARP）、http 订阅入口（nginx，base64 订阅）
- 端口自动编排：Reality 用主端口 P，nginx 订阅 P+1，TUIC P+2（UDP），Hy2 P+3（UDP）；vmess-ws 只听 127.0.0.1 供隧道回源
- 可选裁剪（环境变量）：`NO_ARGO=1`（不装隧道）/ `NO_HY2=1` `NO_TUIC=1`（商家没给 UDP）/
  `NO_NGINX=1`（不要订阅入口）/ `ARGO_TOKEN=xxx`（固定隧道，域名长期稳定）/ `PORT=` / `REALITY_SNI=` / `NODENAME=`
- Alpine 需先 `apk add bash curl`

#### 从老王版（eooce/sing-box）迁移

老王版与本脚本**共用同一个目录 `/etc/sing-box`**，但配置布局不同（他是 `conf/` 拆分文件，
本脚本是单文件 `config.json`），直接覆盖安装会端口打架、两边都跑不正常。迁移正确姿势：

1. **不要用老王脚本菜单里的卸载**——他会把 nginx 本体整个卸掉，机器上其他走反代的应用会断
2. 手动只清 sing-box 部分（nginx 一根手指都不碰）：
   ```bash
   systemctl stop sing-box argo 2>/dev/null
   systemctl disable sing-box argo 2>/dev/null
   rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
   systemctl daemon-reload
   rm -rf /etc/sing-box
   rm -f /usr/bin/sb
   ```
3. 再跑本脚本安装。nginx 已存在会被检测到并跳过安装，已有反代配置和 HTTPS 证书原样保留；
   本脚本对 nginx 只新增一个自己的订阅配置 `sing-box-sub.conf`，不碰其他配置

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
| gost | gost HTTP/SOCKS5 代理（GitHub 最新版二进制，systemd Restart=always 保活；随机账号/密码存 `/etc/gost/auth.env` 600 权限，HTTP/SOCKS5 同端口自动识别；默认 8443 被占自动换高位端口，自动放行防火墙） |
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
