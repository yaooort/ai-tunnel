#!/bin/sh
# Portable Linux bootstrap. No embedded credentials; download hashes are pinned.
set -eu
umask 077
version=1.1.0
release="https://github.com/yaooort/ai-tunnel/releases/download/v$version"
domain= server_address= backend=http1 frp_port=7000 remote_port=18080 source_dir= no_start=0 check_only=0
usage() {
  cat <<'HELP'
AI Tunnel relay installer (run as root)
sh install.sh --domain tunnel.example.com [--server-address PUBLIC_IP]
  [--backend http1|h2c] [--frp-port 7000] [--remote-port 18080]
  [--source-dir /path/to/deploy] [--no-start] [--check]
Linux x86_64/ARM64/ARMv7. Auto start needs systemd or OpenRC.
Package managers: apt, dnf, yum, apk, zypper, pacman.
Existing relay/Caddy configuration will not be overwritten.
--no-start installs/validates files without starting services (manual/containers).
--check detects the platform without installing anything.
HELP
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain|--server-address|--backend|--frp-port|--remote-port|--source-dir)
      [ "$#" -ge 2 ] || die "Missing value for $1"
      case "$1" in
        --domain) domain=$2 ;; --server-address) server_address=$2 ;;
        --backend) backend=$2 ;; --frp-port) frp_port=$2 ;;
        --remote-port) remote_port=$2 ;; --source-dir) source_dir=$2 ;;
      esac
      shift 2 ;;
    --no-start) no_start=1; shift ;; --check) check_only=1; shift ;;
    --help|-h) usage; exit 0 ;; *) die "Unknown option: $1" ;;
  esac
done
[ "$(uname -s)" = Linux ] || die 'This installer requires Linux.'
case "$(uname -m)" in
  x86_64|amd64) frp_arch=amd64; caddy_arch=amd64
    frp_sha=84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716
    caddy_sha=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b ;;
  aarch64|arm64) frp_arch=arm64; caddy_arch=arm64
    frp_sha=f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266
    caddy_sha=d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42 ;;
  armv7l|armv7) frp_arch=arm; caddy_arch=armv7
    frp_sha=f40a984f83e8d34a9241b0be4a9d5fbcfe513a4a5c022b84a02637ff6d36833b
    caddy_sha=492c730b1b992e0d3e4346d1652128ae6ad99208834d3d78c27b3b6c9541c841 ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
init_system=none
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then init_system=systemd
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then init_system=openrc; fi
package_manager=none
for candidate in apt-get dnf yum apk zypper pacman; do
  if command -v "$candidate" >/dev/null 2>&1; then package_manager=$candidate; break; fi
done
printf 'Linux %s; init=%s; package manager=%s\n' "$frp_arch" "$init_system" "$package_manager"
if [ "$check_only" = 1 ]; then exit 0; fi
[ "$(id -u)" = 0 ] || die 'Run as root (or use sudo sh).'
case "$domain" in ''|*[!A-Za-z0-9.-]*|.*|*.) die 'Provide --domain with a DNS hostname, without scheme/port.' ;; esac
case "$domain" in *.*) ;; *) die 'The domain must be a fully qualified DNS hostname.' ;; esac
case "$domain" in example.com|*.example.com|example.net|*.example.net|*.invalid) die 'Replace the example domain with your own domain.' ;; esac
[ -n "$server_address" ] || server_address=$domain
case "$server_address" in ''|*[!A-Za-z0-9.:-]*) die 'Invalid server address.' ;; esac
case "$backend" in http1|h2c) ;; *) die '--backend must be http1 or h2c.' ;; esac
for port in "$frp_port" "$remote_port"; do
  case "$port" in ''|*[!0-9]*|0*) die 'Invalid TCP port.' ;; esac
  [ "${#port}" -le 5 ] || die 'Invalid TCP port.'
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die 'Ports must be between 1024 and 65535.'
done
[ "$frp_port" != "$remote_port" ] || die 'frp and remote ports must differ.'
if [ "$init_system" = none ] && [ "$no_start" = 0 ]; then die 'No systemd/OpenRC found; use --no-start only for manual/test installation.'; fi
for existing in /etc/ai-tunnel/frps.toml /etc/ai-tunnel/relay.json /etc/caddy/Caddyfile /opt/ai-tunnel/frps /opt/ai-tunnel/caddy; do
  [ ! -e "$existing" ] || die "Existing installation at $existing; refusing to overwrite."
done
if command -v ss >/dev/null 2>&1; then
  for port in 80 443 "$frp_port" "$remote_port"; do
    if ss -H -lnt "sport = :$port" | grep -q .; then die "TCP port $port is already in use."; fi
  done
fi
missing=0
for tool in bash curl tar openssl python3 install; do command -v "$tool" >/dev/null 2>&1 || missing=1; done
if [ "$missing" = 1 ] || { [ ! -s /etc/ssl/certs/ca-certificates.crt ] && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ]; }; then
  case "$package_manager" in
    apt-get) export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y bash curl ca-certificates tar openssl python3 coreutils ;;
    dnf|yum) "$package_manager" install -y bash curl ca-certificates tar openssl python3 coreutils ;;
    apk) apk add --no-cache bash curl ca-certificates tar openssl python3 coreutils ;;
    zypper) zypper --non-interactive install bash curl ca-certificates tar openssl python3 coreutils ;;
    pacman) pacman -Sy --needed --noconfirm bash curl ca-certificates tar openssl python coreutils ;;
    *) die 'Install bash, curl, CA certificates, tar, OpenSSL, Python 3 and coreutils first.' ;;
  esac
fi
for tool in bash curl tar openssl python3 install; do command -v "$tool" >/dev/null 2>&1 || die "Missing tool: $tool"; done
if ! openssl req -help 2>&1 | grep -q addext; then die 'OpenSSL 1.1.1 or newer is required.'; fi
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
download() { curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 600 "$1" -o "$2"; }
verify() {
  actual=$(openssl dgst -sha256 "$2" | awk '{print $NF}')
  [ "$actual" = "$1" ] || die "SHA256 mismatch for $(basename "$2")."
}
if [ -z "$source_dir" ]; then
  bundle="AI-Tunnel-Relay-$version.tar.gz"
  download "$release/$bundle" "$work_dir/$bundle"
  download "$release/SHA256SUMS" "$work_dir/SHA256SUMS"
  bundle_sha=$(awk -v name="$bundle" '$2 == name {print $1}' "$work_dir/SHA256SUMS")
  [ "${#bundle_sha}" = 64 ] || die 'Missing relay bundle checksum.'
  verify "$bundle_sha" "$work_dir/$bundle"
  tar -xzf "$work_dir/$bundle" -C "$work_dir"
  source_dir="$work_dir/relay"
fi
for file in configure-relay.py Caddyfile frps.toml generate-tunnel-certs.sh renew-tunnel-cert.sh export-connection.py ai-tunnel-frps.service ai-tunnel-caddy.service ai-tunnel-cert-renew.service ai-tunnel-cert-renew.timer; do
  [ -f "$source_dir/$file" ] || die "Missing relay payload: $file"
done
python3 "$source_dir/configure-relay.py" --validate-only --domain "$domain" --server-address "$server_address" --frp-port "$frp_port" --remote-port "$remote_port" --backend "$backend" --init "$init_system" --source-dir "$source_dir"
download "https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_linux_$frp_arch.tar.gz" "$work_dir/frp.tar.gz"
verify "$frp_sha" "$work_dir/frp.tar.gz"
download "https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_linux_$caddy_arch.tar.gz" "$work_dir/caddy.tar.gz"
verify "$caddy_sha" "$work_dir/caddy.tar.gz"
tar -xzf "$work_dir/frp.tar.gz" -C "$work_dir"
mkdir "$work_dir/caddy"
tar -xzf "$work_dir/caddy.tar.gz" -C "$work_dir/caddy"
if ! id ai-tunnel >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then useradd --system --user-group --home-dir /var/lib/ai-tunnel --shell /bin/false ai-tunnel
  else addgroup -S ai-tunnel; adduser -S -D -H -h /var/lib/ai-tunnel -s /bin/false -G ai-tunnel ai-tunnel; fi
fi
install -d -m 755 /opt/ai-tunnel /etc/caddy
install -d -o root -g ai-tunnel -m 750 /var/lib/ai-tunnel
install -d -o root -g ai-tunnel -m 750 /etc/ai-tunnel /etc/ai-tunnel/tls
install -d -o root -g root -m 700 /var/lib/ai-tunnel/pki
install -d -o ai-tunnel -g ai-tunnel -m 750 /var/lib/ai-tunnel/caddy /var/log/ai-tunnel
install -m 755 "$work_dir/frp_0.71.0_linux_$frp_arch/frps" /opt/ai-tunnel/frps
install -m 755 "$work_dir/caddy/caddy" /opt/ai-tunnel/caddy
install -m 644 "$work_dir/frp_0.71.0_linux_$frp_arch/LICENSE" /opt/ai-tunnel/frp-LICENSE
if [ -f "$work_dir/caddy/LICENSE" ]; then install -m 644 "$work_dir/caddy/LICENSE" /opt/ai-tunnel/caddy-LICENSE; fi
bash "$source_dir/generate-tunnel-certs.sh" "$domain" /var/lib/ai-tunnel/pki
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.crt /etc/ai-tunnel/tls/server.crt
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.key /etc/ai-tunnel/tls/server.key
openssl rand -hex 32 > /etc/ai-tunnel/token
chown root:ai-tunnel /etc/ai-tunnel/token
chmod 640 /etc/ai-tunnel/token
python3 "$source_dir/configure-relay.py" --domain "$domain" --server-address "$server_address" --frp-port "$frp_port" --remote-port "$remote_port" --backend "$backend" --init "$init_system" --source-dir "$source_dir"
chown root:ai-tunnel /etc/ai-tunnel/frps.toml
chmod 640 /etc/ai-tunnel/frps.toml
install -m 755 "$source_dir/generate-tunnel-certs.sh" /opt/ai-tunnel/generate-tunnel-certs
install -m 755 "$source_dir/renew-tunnel-cert.sh" /opt/ai-tunnel/renew-tunnel-cert
install -m 755 "$source_dir/export-connection.py" /opt/ai-tunnel/export-connection
/opt/ai-tunnel/frps verify -c /etc/ai-tunnel/frps.toml
HOME=/var/lib/ai-tunnel/caddy /opt/ai-tunnel/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
chown -R ai-tunnel:ai-tunnel /var/lib/ai-tunnel/caddy
if [ "$init_system" = systemd ]; then
  systemctl daemon-reload
  systemctl enable ai-tunnel-frps ai-tunnel-caddy ai-tunnel-cert-renew.timer
  if [ "$no_start" = 0 ]; then
    systemctl start ai-tunnel-frps ai-tunnel-caddy ai-tunnel-cert-renew.timer
    systemctl is-active ai-tunnel-frps ai-tunnel-caddy ai-tunnel-cert-renew.timer
  fi
elif [ "$init_system" = openrc ]; then
  rc-update add ai-tunnel-frps default; rc-update add ai-tunnel-caddy default; rc-update add ai-tunnel-cert-renew default
  if [ "$no_start" = 0 ]; then rc-service ai-tunnel-frps start; rc-service ai-tunnel-caddy start; rc-service ai-tunnel-cert-renew start; fi
fi
python3 /opt/ai-tunnel/export-connection --output /root/ai-tunnel.connection.json
printf '\nRelay installed. HTTPS: https://%s\n' "$domain"
printf 'Allow inbound TCP 80, 443, %s in your firewall/security group. Keep %s loopback-only.\n' "$frp_port" "$remote_port"
printf 'Private client config: /root/ai-tunnel.connection.json (600). Transfer privately to Mac and import in AI Tunnel Public.\n'
if [ "$no_start" = 1 ]; then printf 'Services were NOT started (--no-start). Start manually or use systemd/OpenRC.\n'; fi
