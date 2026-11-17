# AI Tunnel

原生 macOS 界面管理自建 frp 隧道，将本机 HTTP 服务通过 Caddy 提供给公网。支持 HTTPS / HTTP/2、断线重连和登录启动。

```text
公网调用方 → HTTPS / HTTP/2 → Caddy :443
          → HTTP/1.1 或 h2c → 服务器 127.0.0.1:18080
          → frp TLS 隧道 → Mac frpc → 本机 127.0.0.1:8080
```

## 下载公开版

前往 [GitHub Releases](https://github.com/yaooort/ai-tunnel/releases/latest) 下载 **AI Tunnel Public 1.1.0** 的 M1 / Apple Silicon DMG（macOS 13+），将 App 拖入“应用程序”。也提供 ZIP 和 SHA256 校验清单。

公开版不带任何预置服务器、Token 或 CA 配置。首次打开点击“配置服务器”，可以填写自己的服务器信息，也可以导入安装脚本生成的连接 JSON。保存后配置进入当前 macOS 用户的钥匙串；公开版使用独立的 App ID 和钥匙串空间。

程序使用 ad-hoc 本地签名，**未进行 Developer ID 签名或 Apple 公证**。首次打开如被系统阻止，请在“系统设置 → 隐私与安全性”中允许本应用打开。

## 一键安装 Linux 服务端

先准备自己的域名，将 A/AAAA 记录解析到服务器（Cloudflare 使用“仅 DNS”）。允许入站 TCP **80、443、7000**；18080 仅监听服务器回环。

将下面的 `tunnel.example.com` 换成自己的域名，在**全新的 Linux 服务器**上执行：

```bash
curl -fsSL https://github.com/yaooort/ai-tunnel/releases/download/v1.1.0/install.sh \
  | sudo sh -s -- --domain tunnel.example.com
```

已经是 root 时去掉 `sudo`。服务器需预装 `curl`；其余依赖由安装器自动安装。该命令安装固定版本，不会随主分支变动。

安装器会自动：

- 识别 Linux 架构及包管理器，校验官方 frp / Caddy 压缩包的 SHA256。
- 安装 frps、Caddy，生成随机隧道 Token、私有 CA 和 TLS 证书。
- 配置 HTTPS / HTTP/2、开机启动、进程恢复和证书续期。
- 将权限为 `600` 的客户端连接文件写入 `/root/ai-tunnel.connection.json`，不会把 Token 打印到终端。

支持 **x86_64、ARM64、ARMv7**。自动服务管理支持 **systemd / OpenRC**；依赖安装支持 **apt、dnf、yum、apk、zypper、pacman**，覆盖 Debian/Ubuntu、Rocky/AlmaLinux/RHEL/Fedora、Alpine、openSUSE、Arch 等常见发行版。要求 OpenSSL 1.1.1+、Python 3 和可访问 GitHub 的网络。无法承诺所有 Linux 发行版、旧系统和所有 CPU；不支持的环境会报错退出。无 init 的容器可用 `--no-start` 安装文件后自行管理进程。

已有中转或 Caddy 配置、二进制的服务器会被拒绝覆盖。安装器不会修改云平台安全组或全局防火墙，请自行放行对应端口。

默认后端是 **HTTP/1.1**。本机服务若确实使用明文 HTTP/2，追加 `--backend h2c`：

```bash
curl -fsSL https://github.com/yaooort/ai-tunnel/releases/download/v1.1.0/install.sh \
  | sudo sh -s -- --domain tunnel.example.com --backend h2c
```

其他选项：`--server-address 公网IP或域名`（默认使用域名）、`--frp-port 7000`、`--remote-port 18080`。两端配置需要一致。只检测环境而不安装，可运行 `sh install.sh --check`。

## 连接 Mac

1. 通过 SSH/SCP 私下把服务器 `/root/ai-tunnel.connection.json` 传到 Mac，随后删除服务器上的临时导出文件。
2. 打开 **AI Tunnel Public → 配置服务器 → 导入连接文件**，确认后保存。也可以手动填写服务器地址、7000 端口、TLS 域名、公网 HTTPS 地址、Token、CA 的 PEM 文本；高级设置中的映射端口默认为 18080。
3. 启动本机业务服务，确认它监听 `127.0.0.1:8080`，协议与服务端的 `--backend` 一致。
4. 点击“连接”，需要登录后自动恢复时，同时打开两个启动开关。

关闭窗口会继续运行；退出应用会断开隧道。连接状态表示代理注册结果，业务接口还需单独验证。程序不会启动本机业务或阻止电脑睡眠。同一服务器映射端口只供一个客户端连接。

例如 OpenAI 兼容服务的 Base URL 填 `https://你的域名/v1`。业务 API Key 由本机服务管理，独立于隧道 Token；模型列表为 `/v1/models`。`/v1` 本身返回 404 不表示隧道失败。

## 服务端维护

systemd：

```bash
systemctl status ai-tunnel-frps ai-tunnel-caddy
journalctl -u ai-tunnel-frps -u ai-tunnel-caddy -n 100 --no-pager
systemctl list-timers ai-tunnel-cert-renew.timer
```

OpenRC：

```bash
rc-service ai-tunnel-frps status
rc-service ai-tunnel-caddy status
tail -n 100 /var/log/ai-tunnel/frps.log /var/log/ai-tunnel/caddy.log
```

再次导出连接文件（不会覆盖已存在的目标）：

```bash
sudo python3 /opt/ai-tunnel/export-connection \
  --output /root/ai-tunnel-new.connection.json
```

域名、端口和后端协议记录在 `/etc/ai-tunnel/relay.json`；运行配置为 `/etc/ai-tunnel/frps.toml` 与 `/etc/caddy/Caddyfile`。证书和私钥保存在 `/var/lib/ai-tunnel/pki`，需私下备份。续期保留 CA，正常续期无需修改 Mac 配置。systemd 每日检查，OpenRC 由受监管的续期进程每日检查；公网证书由 Caddy 自动续期。

## 从源码构建

公开 M1 版需要 macOS、Xcode Command Line Tools（Swift 6 工具链）和官方 frp 发行包下载网络：

```bash
bash scripts/build-public-m1.sh
```

产物位于 `dist/public`，包括 DMG、ZIP、校验清单和验证报告。此脚本从源码新建 App，不读取 `private/` 或自用 App；公开版 Bundle ID 为 `vip.k-line.aitunnel.public`。

原有免导入自用构建仍保留：

```bash
# 先准备自己的 private/ai-tunnel.connection.json
bash scripts/build-macos.sh
bash scripts/package-m1.sh
```

**自用脚本生成的 App、ZIP、DMG 含有预置凭据，只能私下分发。** 不要把它们放入公开 Release。公开发布仅使用 `build-public-m1.sh` 的 `dist/public` 产物。

本地部署源码可直接运行 `sudo sh deploy/install.sh --source-dir "$(pwd)/deploy" --domain 自己的域名`，无需先下载 Release 的服务端载荷。

## 验证与许可说明

```bash
./tests/build-harness.sh
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness'
```

隔离测试使用假的 frpc 子进程、临时目录和独立钥匙串项，不连接生产中转。详见 [测试说明](tests/README.md)。可选 h2c fixture 需要 Go 1.24+，普通 App 构建不需要 Go。

[frp](https://github.com/fatedier/frp) 使用 Apache License 2.0；App 构建脚本校验官方压缩包并提取完整许可随程序分发，详见 [第三方说明](resources/ThirdPartyNotices.txt)。服务端从 [Caddy 官方发行包](https://github.com/caddyserver/caddy/releases) 安装 Caddy。
