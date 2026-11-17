# AI Tunnel

用原生 macOS 界面管理 frp 隧道，将本机 HTTP 服务通过自建服务器提供给公网调用。Caddy 提供 HTTPS 和 HTTP/2，frp 负责加密传输与断线重连。

```text
公网调用方 → HTTPS / HTTP/2 → Caddy :443
          → HTTP/1.1 → 服务器 127.0.0.1:18080
          → frp TLS 隧道 → Mac frpc → 本机 127.0.0.1:8080
```

## 功能与要求

- SwiftUI 窗口、菜单栏入口、连接状态、日志、端口设置。
- 登录启动、应用启动后自动连接、隧道重连与子进程恢复。
- 可选 LaunchDaemon，在 macOS 用户登录前运行隧道。
- macOS 13+；支持 Apple Silicon 和 Intel，可单独打包 M1/ARM64 版本。
- 构建需要 macOS、Xcode Command Line Tools，以及能下载官方 frp 发行包的网络。
- 服务器安装脚本面向全新的 Debian 12 x86_64 主机，使用 systemd 和 Caddy。

仓库提供源码和部署模板，**不包含连接凭据、私钥和预配置安装包**。构建需要提供自己的服务器连接配置。应用版本为 1.0.1，固定使用 frp 0.71.0，并校验官方压缩包的 SHA256。

## 部署自己的中转服务器

模板中的 `tunnel.example.com` 和 `203.0.113.10` 是示例值，请先替换：

| 文件 | 需要设置的内容 |
| --- | --- |
| `deploy/Caddyfile` | 公网域名、后端协议 |
| `deploy/install-relay.sh` | `domain` |
| `deploy/renew-tunnel-cert.sh` | 证书续期使用的同一域名 |
| `deploy/export-connection.py` | `serverAddress`、`tlsServerName`、`publicURL` |

1. 将域名 A 记录解析到服务器。使用 Cloudflare 时设为“仅 DNS”。
2. 允许 TCP 22、80、443、7000；18080 仅供服务器回环访问。
3. 将 `deploy` 目录传到服务器，在该目录以 root 执行：

   ```bash
   bash install-relay.sh
   python3 /opt/ai-tunnel/export-connection \
     --output /root/ai-tunnel.connection.json
   ```

安装脚本会生成随机认证 token 和私有 CA，安装 frps、Caddy、开机启动服务及证书续期定时器。它会拒绝覆盖已有 frps/Caddy 配置；已有服务器应手动合并配置。

将导出的 JSON 通过 SSH/SCP 私下传到 Mac 项目的 `private/ai-tunnel.connection.json`，随后删除服务器上的临时导出文件。这个 JSON 包含认证 token，请勿提交到 Git。它已被 `.gitignore` 排除。

默认上游为 HTTP/1.1，公网入口仍支持 HTTP/2。如果本机服务确实使用明文 HTTP/2（h2c），把 Caddy 上游改为 `h2c://127.0.0.1:18080`，并将 `transport http` 中的 `versions` 改为 `h2c`。协议必须与本机业务服务一致。

## 构建 Mac 程序

在源码根目录运行：

```bash
chmod 700 private
chmod 600 private/ai-tunnel.connection.json
bash scripts/build-macos.sh
```

也可以通过 `AI_TUNNEL_CONNECTION_FILE` 指定自己的配置路径：

```bash
AI_TUNNEL_CONNECTION_FILE="/absolute/path/to/connection.json" \
  bash scripts/build-macos.sh
```

输出为 `dist/AI Tunnel.app` 和通用版 ZIP，支持 ARM64 与 x86_64。生成 Apple Silicon 专用 DMG 和 ZIP：

```bash
bash scripts/package-m1.sh
```

构建会把连接 JSON 嵌入 App，实现免导入连接。**生成的 App、ZIP 和 DMG 均含有自己的隧道凭据，应私下分发，不能上传到公开 GitHub Release。** `dist/`、`private/`、构建缓存和安装包均已忽略。

应用仅使用本地 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。安装和开机服务操作见 [使用与维护说明](README.txt)。

## 使用

先启动本机 8080 业务服务，再打开 AI Tunnel 并连接。需要登录后自动恢复时，同时开启“登录时启动应用”和“打开应用后自动连接”。关闭窗口会继续运行，退出应用会停止隧道。

“已连接”表示 frp 代理注册成功；业务是否就绪仍需请求实际接口验证。本程序不会启动业务服务，也不会阻止电脑睡眠。同一组连接配置仅供一个客户端占用转发端口。

对于 OpenAI 兼容服务，客户端的 Base URL 通常为 `https://你的域名/v1`，模型列表使用 `/v1/models`。业务 API Key 由本机服务管理，独立于 frp 隧道 token。`/v1` 本身返回 404 不代表隧道失败。

## 验证

隔离测试需要 Swift 6 工具链，使用假的 frpc 子进程、临时目录和独立钥匙串项，不连接生产中转：

```bash
./tests/build-harness.sh
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness'
```

测试范围和真实连接观察方式见 [tests/README.md](tests/README.md)。完整运维步骤见 [README.txt](README.txt)。

可选的 `tests/H2CFixture.go` 使用 Go 1.24+；普通 App 构建及 Swift 隔离测试不需要 Go。

## 第三方软件

[frp](https://github.com/fatedier/frp) 使用 Apache License 2.0。构建脚本从经过校验的官方发行包提取完整许可并随 App 分发，详情见 [第三方说明](resources/ThirdPartyNotices.txt)。
