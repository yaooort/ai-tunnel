#!/bin/bash
set -euo pipefail
if openssl x509 -in /etc/ai-tunnel/tls/server.crt -noout -checkend 2592000; then exit 0; fi
domain=$(python3 -c 'import json; print(json.load(open("/etc/ai-tunnel/relay.json"))["domain"])')
bash /opt/ai-tunnel/generate-tunnel-certs "$domain" /var/lib/ai-tunnel/pki
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.crt /etc/ai-tunnel/tls/server.crt
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.key /etc/ai-tunnel/tls/server.key
/opt/ai-tunnel/frps verify -c /etc/ai-tunnel/frps.toml
if [ -d /run/systemd/system ]; then
  systemctl restart ai-tunnel-frps
else
  rc-service ai-tunnel-frps restart
fi
