AI Tunnel Public 1.1.0 使用与维护说明
更新日期：2026-11-17

完整图文/命令说明见同目录 README.md 或 https://github.com/yaooort/ai-tunnel。

公开版本：
1. 从 GitHub Release 下载 M1 / ARM64 的 Public DMG 或 ZIP。
2. 将 AI Tunnel Public.app 放到“应用程序”；要求 macOS 13+。
3. 点击“配置服务器”，手动填写自己的信息或导入服务端生成的 .connection.json，确认保存到钥匙串。
4. 先运行本机 127.0.0.1:8080 业务服务，再连接隧道。
5. 需要登录后自动恢复时同时打开“登录时启动应用”和“打开应用后自动连接”。

公开版不含服务器地址、Token、CA 或其他预置连接凭据。
仅作 ad-hoc 签名，未做 Developer ID 签名和 Apple 公证；如被阻止，请在系统设置的隐私与安全性中允许打开。
关闭窗口继续运行，退出应用停止隧道。电脑睡眠、断电或业务程序停止时业务不可用。
公网 HTTP/2 与本机协议独立：服务端 --backend http1 对应 HTTP/1.1，--backend h2c 对应明文 HTTP/2。
“已连接”只表示 frp 代理已注册，请使用实际业务路径验证。业务 API Key 独立于隧道 Token。

Linux 服务端：
请按 README.md 的一键安装命令在全新服务器安装，使用自己的域名，并允许 TCP 80/443/7000。
默认远端映射为 127.0.0.1:18080，不对公网开放。
支持 Linux x86_64/ARM64/ARMv7、systemd/OpenRC 和常见包管理器；无 init 的容器需使用 --no-start 并自行管理进程。
生成的 /root/ai-tunnel.connection.json 含私密 Token，权限 600，私下传到 Mac 后删除临时副本。
已有配置不覆盖；不能直接在现有生产服务器重跑安装器作为升级。

维护：
systemd 服务：ai-tunnel-frps / ai-tunnel-caddy / ai-tunnel-cert-renew.timer。
OpenRC 服务：ai-tunnel-frps / ai-tunnel-caddy / ai-tunnel-cert-renew；续期进程每日检查。
服务器参数：/etc/ai-tunnel/relay.json。
业务转发配置：/etc/caddy/Caddyfile；修改后先 validate 再 reload。
私有 PKI：/var/lib/ai-tunnel/pki；私下备份，不要重建 CA。
重新导出：sudo python3 /opt/ai-tunnel/export-connection --output /root/ai-tunnel-new.connection.json。

Mac 日志：~/Library/Logs/AITunnel/frpc.log。
运行配置：~/Library/Application Support/AITunnel/runtime；退出时清理临时凭据。
公开版与自用版不应同时连接同一服务器映射端口。

原自用构建：
scripts/build-macos.sh 默认读取 private/ai-tunnel.connection.json，产物内含私密配置；scripts/package-m1.sh 也只供私下分发。
公开发布请使用 scripts/build-public-m1.sh，且仅发布 dist/public 中的产物。
可选登录前 LaunchDaemon 脚本仍可配合原自用 App 和服务端导出的连接 JSON 使用；不能与 GUI 同时管理同一隧道。
frp 0.71.0 使用 Apache License 2.0，完整许可随 App 分发。
