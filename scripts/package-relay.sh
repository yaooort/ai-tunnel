#!/bin/sh
# Package only reviewed, credential-free relay sources for a public release.
set -eu
umask 022
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_dir=$(cd "$script_dir/.." && pwd -P)
version=1.1.0
output_dir="$project_dir/dist/public"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/relay" "$output_dir"
for name in install.sh configure-relay.py Caddyfile frps.toml generate-tunnel-certs.sh \
  renew-tunnel-cert.sh export-connection.py ai-tunnel-frps.service ai-tunnel-caddy.service \
  ai-tunnel-cert-renew.service ai-tunnel-cert-renew.timer; do
  test -f "$project_dir/deploy/$name"
  test ! -L "$project_dir/deploy/$name"
  cp "$project_dir/deploy/$name" "$stage/relay/$name"
  chmod 644 "$stage/relay/$name"
done
COPYFILE_DISABLE=1 tar -czf "$output_dir/AI-Tunnel-Relay-$version.tar.gz" -C "$stage" relay
cp "$project_dir/deploy/install.sh" "$output_dir/install.sh"
chmod 644 "$output_dir/install.sh" "$output_dir/AI-Tunnel-Relay-$version.tar.gz"
(
  cd "$output_dir"
  set -- "AI-Tunnel-Relay-$version.tar.gz" install.sh
  for name in "AI-Tunnel-Public-$version-macOS-arm64.dmg" \
    "AI-Tunnel-Public-$version-macOS-arm64.zip" PUBLIC-VERIFICATION.txt SERVER-VERIFICATION.txt; do
    if [ -f "$name" ]; then set -- "$@" "$name"; fi
  done
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" > SHA256SUMS
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 "$@" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
  fi
)
printf 'Credential-free relay assets: %s\n' "$output_dir"
