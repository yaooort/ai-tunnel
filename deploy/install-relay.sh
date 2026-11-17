#!/bin/bash
set -euo pipefail
test "$(id -u)" = 0
domain=tunnel.example.com
source_dir=$(cd "$(dirname "$0")" && pwd)
test ! -e /etc/ai-tunnel/frps.toml || { echo 'Relay already installed; refusing to overwrite its configuration.' >&2; exit 1; }
test ! -e /etc/caddy/Caddyfile || { echo 'Existing Caddy configuration requires a manual merge.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl gnupg python3 debian-keyring debian-archive-keyring apt-transport-https
install -d -m 755 /opt/ai-tunnel
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 \
  https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_linux_amd64.tar.gz \
  -o "$work_dir/frp.tar.gz"
echo '84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716  frp.tar.gz' > "$work_dir/checksum"
(cd "$work_dir" && sha256sum -c checksum)
tar -xzf "$work_dir/frp.tar.gz" -C "$work_dir"
install -m 755 "$work_dir/frp_0.71.0_linux_amd64/frps" /opt/ai-tunnel/frps
id -u ai-tunnel >/dev/null 2>&1 || useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin ai-tunnel
install -d -o root -g ai-tunnel -m 750 /etc/ai-tunnel /etc/ai-tunnel/tls
install -d -o root -g root -m 700 /var/lib/ai-tunnel/pki
bash "$source_dir/generate-tunnel-certs.sh" "$domain" /var/lib/ai-tunnel/pki
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.crt /etc/ai-tunnel/tls/server.crt
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.key /etc/ai-tunnel/tls/server.key
(umask 077; openssl rand -hex 32 > /etc/ai-tunnel/token)
chown root:ai-tunnel /etc/ai-tunnel/token
chmod 640 /etc/ai-tunnel/token
install -o root -g ai-tunnel -m 640 "$source_dir/frps.toml" /etc/ai-tunnel/frps.toml
install -m 644 "$source_dir/ai-tunnel-frps.service" /etc/systemd/system/ai-tunnel-frps.service
runuser -u ai-tunnel -- /opt/ai-tunnel/frps verify -c /etc/ai-tunnel/frps.toml

curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
  gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update -qq
apt-get install -y -qq caddy
cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.package-default
install -m 644 "$source_dir/Caddyfile" /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

install -m 755 "$source_dir/generate-tunnel-certs.sh" /opt/ai-tunnel/generate-tunnel-certs
install -m 755 "$source_dir/renew-tunnel-cert.sh" /opt/ai-tunnel/renew-tunnel-cert
install -m 755 "$source_dir/export-connection.py" /opt/ai-tunnel/export-connection
install -m 644 "$source_dir/ai-tunnel-cert-renew.service" /etc/systemd/system/ai-tunnel-cert-renew.service
install -m 644 "$source_dir/ai-tunnel-cert-renew.timer" /etc/systemd/system/ai-tunnel-cert-renew.timer
install -d -m 755 /etc/systemd/system/caddy.service.d
printf '[Service]\nRestart=on-failure\nRestartSec=5s\n' > /etc/systemd/system/caddy.service.d/restart.conf
if ! ip -4 address show dev lo | grep -q 'inet 127.0.0.1/'; then
  install -m 644 "$source_dir/ai-tunnel-loopback.service" /etc/systemd/system/ai-tunnel-loopback.service
  for service in caddy ai-tunnel-frps; do
    install -d -m 755 "/etc/systemd/system/$service.service.d"
    printf '[Unit]\nRequires=ai-tunnel-loopback.service\nAfter=ai-tunnel-loopback.service\n' > "/etc/systemd/system/$service.service.d/loopback.conf"
  done
  systemctl daemon-reload
  systemctl enable --now ai-tunnel-loopback
fi
systemctl daemon-reload
systemctl enable ai-tunnel-frps caddy ai-tunnel-cert-renew.timer
systemctl restart ai-tunnel-frps caddy
systemctl start ai-tunnel-cert-renew.timer
systemctl is-active ai-tunnel-frps caddy
echo 'Relay installation finished.'
