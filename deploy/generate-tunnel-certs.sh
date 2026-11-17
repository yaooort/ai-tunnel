#!/bin/bash
# Run on the Linux relay with OpenSSL >= 1.1.1.
# Reuses an existing CA when renewing the server certificate.
set -euo pipefail
cert_name=${1:?Usage: bash generate-tunnel-certs.sh TUNNEL_DNS_NAME OUTPUT_DIRECTORY}
pki_dir=${2:?Usage: bash generate-tunnel-certs.sh TUNNEL_DNS_NAME OUTPUT_DIRECTORY}
case "$cert_name" in
  ''|*[!a-zA-Z0-9.-]*) echo 'Expected a DNS hostname, without scheme or port' >&2; exit 1 ;;
esac
umask 077
mkdir -p "$pki_dir"
pki_dir=$(cd "$pki_dir" && pwd -P)
if [ ! -e "$pki_dir/ca.key" ] && [ ! -e "$pki_dir/ca.crt" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj '/CN=Private frp Tunnel CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$pki_dir/ca.key" -out "$pki_dir/ca.crt" 2>/dev/null
fi
test -s "$pki_dir/ca.key" && test -s "$pki_dir/ca.crt"
openssl x509 -in "$pki_dir/ca.crt" -noout -checkend 31536000
work_dir=$(mktemp -d "$pki_dir/issue.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
openssl req -new -newkey rsa:3072 -nodes -sha256 \
  -subj "/CN=$cert_name" \
  -keyout "$work_dir/server.key" -out "$work_dir/server.csr" 2>/dev/null
cat > "$work_dir/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$cert_name
EOF
serial_hex=$(openssl rand -hex 16)
openssl x509 -req -sha256 -days 365 \
  -in "$work_dir/server.csr" \
  -CA "$pki_dir/ca.crt" -CAkey "$pki_dir/ca.key" -set_serial "0x$serial_hex" \
  -extfile "$work_dir/server.ext" -out "$work_dir/server.crt" 2>/dev/null
openssl verify -CAfile "$pki_dir/ca.crt" -verify_hostname "$cert_name" "$work_dir/server.crt"
install -m 600 "$work_dir/server.key" "$pki_dir/server.key"
install -m 644 "$work_dir/server.crt" "$pki_dir/server.crt"
chmod 600 "$pki_dir/ca.key"
chmod 644 "$pki_dir/ca.crt"
echo "Issued server certificate for $cert_name (365 days); existing CA preserved."
