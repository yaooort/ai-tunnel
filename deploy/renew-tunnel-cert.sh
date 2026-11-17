#!/bin/bash
set -euo pipefail
if openssl x509 -in /etc/ai-tunnel/tls/server.crt -noout -checkend 2592000; then exit 0; fi
bash /opt/ai-tunnel/generate-tunnel-certs tunnel.example.com /var/lib/ai-tunnel/pki
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.crt /etc/ai-tunnel/tls/server.crt
install -o root -g ai-tunnel -m 640 /var/lib/ai-tunnel/pki/server.key /etc/ai-tunnel/tls/server.key
runuser -u ai-tunnel -- /opt/ai-tunnel/frps verify -c /etc/ai-tunnel/frps.toml
systemctl restart ai-tunnel-frps
