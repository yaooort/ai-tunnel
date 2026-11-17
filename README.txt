AI Tunnel 使用与维护说明
更新日期：2026-11-17
版本：1.0.1（自用免导入版源码）
公开仓库中的域名和 IP 均为示例值，部署前请按 README.md 替换为自己的服务器信息。

一、用途和运行要求

AI Tunnel 将本机 127.0.0.1:8080 的 HTTP 服务，通过自建 frp 加密隧道提供给公网调用。默认后端协议为 HTTP/1.1；公网入口仍支持 HTTPS 和 HTTP/2。

公网入口示例：https://tunnel.example.com
中转服务器示例：203.0.113.10
客户端：macOS 13 或更高版本，支持 Apple M 系列和 Intel 处理器。
应用和内嵌 frpc 均为 ARM64 + x86_64 通用二进制，frp 版本为 0.71.0。

完整链路：
公网调用方 -- HTTPS / HTTP/2 --> Caddy :443
  -- HTTP/1.1 --> 服务器 127.0.0.1:18080
  -- frp TLS 加密隧道 --> Mac 上的 frpc
  -- 原始 TCP 转发 --> 本机 127.0.0.1:8080

本机主动连接服务器，不需要本机公网 IP 或路由器端口映射。
AI Tunnel 只负责隧道，不负责启动你的 8080 业务程序；业务请求鉴权由该程序处理。

二、安装应用和首次打开

1. 解压 AI-Tunnel-macOS.zip（包含 App、说明和可选后台服务脚本；universal.zip 是仅 App 的包）。
2. 将 AI Tunnel.app 拖入“应用程序”，最终路径应为：
   /Applications/AI Tunnel.app
3. 首次运行可在 Finder 中右键应用，选择“打开”。如果当前 macOS 仍阻止打开，前往“系统设置 → 隐私与安全性”，针对 AI Tunnel 选择允许打开，再按系统提示确认。

本版本使用本地 ad-hoc 签名，未进行 Developer ID 签名和 Apple 公证。
不需要关闭 Gatekeeper，也不需要调整系统的全局安全策略。

dist/build-verification.txt 记录了构建架构、frpc 版本和本地签名检查结果。
ZIP 的 SHA256 校验记录位于 AI-Tunnel-macOS-universal.zip.sha256。

三、直接连接

1. 先启动本机业务程序，确认它监听 127.0.0.1:8080。当前服务器按 HTTP/1.1 后端配置。
2. 打开 AI Tunnel。这个自用版本已内置服务器连接配置，无需导入文件。
3. 保持本机端口为 8080；如果业务程序使用其他端口，先断开，再修改端口。
4. 点击“连接”，等待状态变为“已连接”。
5. 公网调用 https://tunnel.example.com 加上原有业务路径，方法、请求体等均沿用业务接口。

OpenAI 兼容客户端的 API Base URL 填写：https://tunnel.example.com/v1
模型列表接口为 /v1/models，需要业务程序自己的 API Key。/v1 是接口基础地址，不是网页；例如业务程序对 /v1 返回 404、对未鉴权的 /v1/models 返回 401，均不表示隧道故障。

自用安装包内含访问隧道所需的凭据和 CA 证书。请保管 App、ZIP 和源码中的 private 目录，仅供自己使用。
请勿将这个自用安装包、内置连接配置或 private 目录公开上传、提交到 Git 或发送到公开群组。
内置配置位于 AI Tunnel.app/Contents/Resources/preset-connection.json，首次启动时应用会自动读取。

“已连接”表示隧道已建立；业务程序是否就绪、具体接口是否成功，需要用实际业务请求确认。

四、日常使用、登录启动和自动重连

应用中有两个独立开关：

“登录时启动应用”：登录 macOS 账户后自动启动 AI Tunnel。
“打开应用后自动连接”：应用启动后，如果已有连接配置，自动启动隧道。

需要登录后自动恢复隧道时，同时打开这两个开关。
如果系统要求批准登录项，前往“系统设置 → 通用 → 登录项”允许 AI Tunnel。

关闭窗口：应用和隧道继续运行，可以从菜单栏恢复窗口。
点击“断开连接”：停止当前隧道。
选择“退出 AI Tunnel”或 Command-Q：退出应用并断开隧道。

网络暂时断开、服务器重启后，frpc 会继续重连；frpc 进程意外退出时，应用也会自动重新启动它。
断线期间已经进行的 HTTP 请求或 gRPC 流可能中断，调用方需要自行重新连接；写请求按业务幂等策略重试。

电脑睡眠、断电或业务程序停止时，公网业务不可用。
应用不会自动保持电脑唤醒，也不会替你启动 8080 的业务服务。
需要长期运行时，请在 Mac 接电状态下配置合适的睡眠策略，并让业务程序独立自动启动。

五、可选：安装系统级开机后台服务

默认使用图形界面即可。若需要在 macOS 用户登录前启动隧道，可安装独立的 LaunchDaemon。
系统服务与图形界面不能同时管理隧道，安装后 GUI 会拒绝连接，避免重复占用服务器转发端口。

安装前：
1. 在图形界面取消“打开应用后自动连接”和“登录时启动应用”。
2. 点击“断开连接”，然后退出 AI Tunnel。
3. 确认应用已经放到 /Applications/AI Tunnel.app。

打开终端，替换下面脚本的占位路径，使用当前普通用户执行。安装脚本仍需要 JSON 文件参数，可以直接使用 App 内置配置：

sudo bash "/绝对路径/ai-tunnel/scripts/install-system-service.sh" \
  "/Applications/AI Tunnel.app" \
  "/Applications/AI Tunnel.app/Contents/Resources/preset-connection.json" \
  "$(id -un)" 8080

sudo 提示输入的是本机管理员密码。最后一个参数是本机业务端口，默认 8080。
安装脚本会检查 GUI frpc 是否仍在运行，并在有冲突时停止安装；不会终止无关的 frpc 进程。

系统服务名称：vip.k-line.aitunnel.frpc
LaunchDaemon 文件：/Library/LaunchDaemons/vip.k-line.aitunnel.frpc.plist
独立程序和配置：/Library/Application Support/AITunnelService
日志目录：/Library/Logs/AITunnelService

此服务使用指定普通用户运行，凭据文件权限为 600，验证服务器 TLS 身份，失败后自动恢复。
frpc 日志按日期轮转，保留 7 天。
安装后服务立即启动；此模式下，退出图形界面不会控制或停止系统服务。

查看状态：
sudo launchctl print system/vip.k-line.aitunnel.frpc

查看日志：
tail -n 100 /Library/Logs/AITunnelService/frpc.log

重新启动：
sudo launchctl kickstart -k system/vip.k-line.aitunnel.frpc

卸载系统服务并恢复使用图形界面：
sudo bash "/绝对路径/ai-tunnel/scripts/uninstall-system-service.sh"

卸载会停止服务并删除 LaunchDaemon 文件，保留配置、凭据和日志。
卸载完成后可重新打开 GUI，连接隧道，按需要恢复两个启动开关。

系统服务只负责 frpc，不负责本机业务程序。启用 FileVault 时，冷启动仍需先解锁系统磁盘。

六、连接验证

先运行 curl -V，确认 Features 中有 HTTP2。下面的 /实际业务路径 请换成你现有的接口路径。

在 Mac 检查当前本机 HTTP/1.1 服务：
curl --http1.1 -sS -o /dev/null \
  -w 'HTTP/%{http_version} status=%{http_code}\n' \
  http://127.0.0.1:8080/实际业务路径

在公网客户端检查入口：
curl --http2 -sS -o /dev/null \
  -w 'HTTP/%{http_version} status=%{http_code}\n' \
  https://tunnel.example.com/实际业务路径

本机检查期望协议为 HTTP/1.1，公网检查期望协议为 HTTP/2；状态码和响应内容应符合业务接口预期。
404 可能只是所请求的路径不存在；不要仅根据根路径 / 的结果判断业务是否成功。
公网 HTTP/2 只验证客户端到 Caddy；Caddy 到本机业务服务可以使用 HTTP/1.1。
如果以后更换为真正的 h2c 后端，需将 /etc/caddy/Caddyfile 中的上游改为 h2c://127.0.0.1:18080、transport http 的 versions 改为 h2c，校验并重载 Caddy。frp 是 TCP 转发，无需修改或重装 Mac 程序。

七、服务器配置和维护

将自己的域名指向服务器 IP；使用 Cloudflare 时选择“仅 DNS”（灰云）。

公网开放的 TCP 端口：
80：Caddy 证书签发和 HTTP 跳转。
443：公网 HTTPS / HTTP/2 入口。
7000：frp TLS 隧道连接。

18080 只绑定 127.0.0.1，供同机 Caddy 访问，不应对公网开放。
服务器保留原有 SSH 22 端口供维护。

主要文件：
/etc/caddy/Caddyfile
/etc/ai-tunnel/frps.toml
/etc/ai-tunnel/token
/etc/ai-tunnel/tls/server.crt
/etc/ai-tunnel/tls/server.key
/var/lib/ai-tunnel/pki
/opt/ai-tunnel/frps

systemd 单位：
ai-tunnel-frps.service：frp 中转，开机启动、失败自动恢复。
caddy.service：公网 HTTPS 和反向代理。
ai-tunnel-loopback.service：启动时恢复回环接口和 127.0.0.1 地址。
ai-tunnel-cert-renew.timer：每日检查私有隧道证书是否需要续期。
ai-tunnel-cert-renew.service：执行私有隧道证书续期。

在服务器以 root 或具有 sudo 权限的账户执行：

systemctl status ai-tunnel-frps caddy ai-tunnel-loopback --no-pager
systemctl list-timers ai-tunnel-cert-renew.timer --no-pager
journalctl -u ai-tunnel-frps -u caddy -n 100 --no-pager
journalctl -u ai-tunnel-cert-renew.service -n 50 --no-pager

修改 frps 配置后先校验，再重启：
runuser -u ai-tunnel -- /opt/ai-tunnel/frps verify -c /etc/ai-tunnel/frps.toml
systemctl restart ai-tunnel-frps

修改 Caddy 配置后先校验，再重载：
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy

重新导出当前 Mac 连接配置（文件含凭据，不会打印内容；目标文件已存在时会拒绝覆盖）：
python3 /opt/ai-tunnel/export-connection --output /root/ai-tunnel-new.connection.json

通过 SSH/SCP 私下传到 Mac，替换构建时的 private/ai-tunnel.connection.json，重新构建自用 App；随后删除服务器上的这份临时导出副本。

重启中转后，保持 Mac 的连接程序运行，等待其自动重连，再检查实际业务请求。

在服务器检查隧道回环监听：
ss -lntp | grep ':18080'

在服务器检查转发后的 HTTP/1.1：
curl --http1.1 -sS -o /dev/null \
  -w 'HTTP/%{http_version} status=%{http_code}\n' \
  http://127.0.0.1:18080/实际业务路径

只有本机客户端成功建立代理后，frps 才会提供 18080 监听。

八、证书续期和备份

公网 HTTPS 证书：由 Caddy 自动申请和续期，需要域名继续指向服务器、80/443 可达。

frp 私有隧道证书：服务端证书有效期 365 天，私有 CA 有效期 3650 天。
续期定时器每日检查一次，并随机延迟最多 1 小时；剩余有效期不足 30 天时重新签发服务端证书。
续期保留原有 CA，正常续期不需要更换 App 的内置连接配置。
证书更新后会重启 frps，客户端随后自动重连，现有请求可能短暂中断。

手动触发检查：
systemctl start ai-tunnel-cert-renew.service
journalctl -u ai-tunnel-cert-renew.service -n 50 --no-pager

查看证书有效期：
openssl x509 -in /etc/ai-tunnel/tls/server.crt -noout -dates
openssl x509 -in /var/lib/ai-tunnel/pki/ca.crt -noout -dates

请备份 /var/lib/ai-tunnel/pki、/etc/ai-tunnel 和 Caddy 配置，妥善保护 CA 私钥、服务器私钥及认证凭据。
不要删除或重新生成现有 CA；如 CA 更换，需重新导出连接配置并重新构建自用 App。
CA 十年有效期并非自动永久续期，需要在到期前安排 CA 更换和客户端配置更新。

九、常见问题

公网返回 502：先检查本机业务服务是否运行、GUI 是否已连接、服务器 18080 是否监听，以及 Caddy 上游协议是否与本机服务一致，再查看两端日志。若日志出现 HTTP/1.1 header 或 frame too large，检查是否将 HTTP/1.1 服务错误配置成 h2c。

GUI 一直显示重连：检查 Mac 能否访问服务器 TCP 7000，确认服务器 frps 在运行、连接文件有效，以及 Mac 系统时间正确。

服务器重启后业务没有恢复：检查 Mac 是否唤醒、frpc 是否运行，以及本机 8080 的业务程序是否自动启动。

GUI 提示已安装系统后台服务：先用卸载脚本移除系统服务，再使用 GUI；不要手工启动第二个 frpc 争用同一转发端口。

登录启动没有生效：确认应用位于“应用程序”，检查“系统设置 → 通用 → 登录项”的批准状态，并同时启用“打开应用后自动连接”。

内置连接配置读取失败：确认使用本次完整解压得到的 App，且当前用户可读取其内置配置；必要时重新构建自用版本。不要把凭据复制到日志或截图中。

GUI 日志默认路径：~/Library/Logs/AITunnel/frpc.log
GUI 运行配置目录：~/Library/Application Support/AITunnel/runtime
可以在界面展开“连接日志”，或使用显示日志文件的操作在 Finder 中定位。

十、源码与重新构建

应用源码：Sources/AITunnelApp
macOS 打包脚本：scripts/build-macos.sh
服务器安装及配置模板：deploy
可选系统服务安装/卸载脚本：scripts/install-system-service.sh、scripts/uninstall-system-service.sh

开发者在安装 Xcode Command Line Tools 的 Mac 上，可运行：
bash scripts/build-macos.sh

构建时默认必须存在 private/ai-tunnel.connection.json；文件缺失或字段校验失败会停止，不会生成缺少连接配置的 App。
如使用其他连接配置路径，可运行：
AI_TUNNEL_CONNECTION_FILE="/绝对路径/连接配置.json" bash scripts/build-macos.sh

构建会将配置以 600 权限写入 App 内的 Contents/Resources/preset-connection.json，应用默认读取它，普通使用者无需导入。
请使用自己的普通账户构建和运行，让配置始终可由当前用户读取；生成的 App 和 ZIP 都包含私密隧道凭据，请妥善保存。
构建脚本校验两个架构的官方 frp 0.71.0 压缩包 SHA256，编译通用 App，执行本地 ad-hoc 签名并生成 ZIP。
普通使用者运行已提供的 App 不需要安装 Xcode，也不需要自行构建。

十一、第三方许可

应用内嵌 frp 0.71.0（frpc），使用 Apache License, Version 2.0。
项目地址：https://github.com/fatedier/frp
应用内完整许可文本：Contents/Resources/Licenses/frp-LICENSE.txt
第三方说明：Contents/Resources/ThirdPartyNotices.txt
源码项目的 resources/ThirdPartyNotices.txt 亦保留版本和许可说明。

十二、在全新服务器上重新部署

deploy/install-relay.sh 针对 Debian 12、x86_64；公开模板使用示例域名/IP。
部署前请按 README.md 修改 Caddyfile、install-relay.sh、renew-tunnel-cert.sh 和 export-connection.py 中的示例值。
已有服务器请勿再次运行安装脚本覆盖服务。
将自己的域名 A 记录指向服务器 IP，并保持仅 DNS。下面命令中的 203.0.113.10 也应替换。
把源码包中的 deploy 文件夹传到全新服务器，在 Mac 的源码目录中执行：

ssh -p 22 root@203.0.113.10 'mkdir -p /root/ai-tunnel-source'
scp -P 22 -r deploy root@203.0.113.10:/root/ai-tunnel-source/
ssh -p 22 root@203.0.113.10

然后在服务器上执行：
bash /root/ai-tunnel-source/deploy/install-relay.sh
python3 /opt/ai-tunnel/export-connection --output /root/ai-tunnel-new.connection.json

安装脚本下载并校验 frp，安装 Caddy，生成独立 CA、TLS 证书和随机 token，安装 systemd 服务及续期定时器。
如果发现已有 frp/Caddy 配置，它会停止，避免覆盖现有部署。
云平台如另有安全组，请允许 TCP 22、80、443、7000；18080 保持仅回环监听。
重装会生成新的 CA/token，需要重新导出、传回 Mac 并重新构建含新内置配置的自用 App。
