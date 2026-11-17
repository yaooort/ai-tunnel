#!/bin/bash
# Build a universal macOS application. Requires Xcode Command Line Tools.
# The result is locally ad-hoc signed, not Developer ID signed or notarized.
set +x
set -euo pipefail
umask 077

script_dir=$(cd "$(dirname "$0")" && pwd -P)
project_dir=$(cd "$script_dir/.." && pwd -P)
build_dir="$project_dir/.build/macos"
dist_dir="$project_dir/dist"
frp_version=0.71.0
connection_file=${AI_TUNNEL_CONNECTION_FILE:-"$project_dir/private/ai-tunnel.connection.json"}

if [ "$(uname -s)" != Darwin ]; then
  echo 'Run this script on macOS with Xcode Command Line Tools installed.' >&2
  exit 1
fi
for command_name in xcrun codesign lipo iconutil ditto shasum curl tar plutil openssl; do
  command -v "$command_name" >/dev/null || {
    echo "Missing build tool: $command_name" >&2
    exit 1
  }
done
if [ ! -f "$connection_file" ] || [ ! -r "$connection_file" ]; then
  echo "Missing or unreadable preset connection file: $connection_file" >&2
  echo 'Provide private/ai-tunnel.connection.json or set AI_TUNNEL_CONNECTION_FILE to its path.' >&2
  exit 1
fi
mkdir -p "$build_dir/downloads" "$build_dir/arm64" "$build_dir/x86_64" "$dist_dir"
chmod 700 "$dist_dir"
stage_dir=$(mktemp -d "$build_dir/stage.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
app_dir="$stage_dir/AI Tunnel.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/bin" \
  "$app_dir/Contents/Resources/Licenses"

# Validate the private preset without printing JSON, certificates, or tokens.
validate_connection_preset() {
  local file=$1 check_dir=$2 schema address tls_name port public_url token_value field first_character
  first_character=$(awk 'match($0,/[^ \t\r\n]/) { print substr($0,RSTART,1); exit }' "$file")
  if [ "$(wc -c < "$file" | tr -d ' ')" -gt 131072 ] || \
     [ "$first_character" != '{' ] || \
     ! plutil -convert json -o "$check_dir/preset-validation.json" "$file" >/dev/null 2>&1; then
    echo 'Preset connection validation failed: invalid or oversized JSON.' >&2
    return 1
  fi
  schema=$(plutil -extract schemaVersion raw -expect integer -o - "$file" 2>/dev/null) || return 1
  address=$(plutil -extract serverAddress raw -expect string -o - "$file" 2>/dev/null) || return 1
  tls_name=$(plutil -extract tlsServerName raw -expect string -o - "$file" 2>/dev/null) || return 1
  public_url=$(plutil -extract publicURL raw -expect string -o - "$file" 2>/dev/null) || return 1
  token_value=$(plutil -extract token raw -expect string -o - "$file" 2>/dev/null) || return 1
  if [ "$schema" != 1 ] || ! [[ "$address" =~ ^[A-Za-z0-9.-]+$ ]] || \
     ! [[ "$tls_name" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$public_url" != https://* ]] || \
     [ "${#token_value}" -lt 32 ] || [ "${#token_value}" -gt 256 ] || \
     ! [[ "$token_value" =~ ^[-A-Za-z0-9._~]+$ ]]; then
    echo 'Preset connection validation failed: invalid schema or connection fields.' >&2
    return 1
  fi
  unset token_value
  for field in serverPort remotePort; do
    port=$(plutil -extract "$field" raw -expect integer -o - "$file" 2>/dev/null) || return 1
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || \
       [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
      echo 'Preset connection validation failed: invalid port field.' >&2
      return 1
    fi
  done
  if ! plutil -extract caCertificatePEM raw -expect string \
       -o "$check_dir/preset-ca-check.crt" "$file" >/dev/null 2>&1 || \
     ! openssl x509 -in "$check_dir/preset-ca-check.crt" -noout -checkend 0 >/dev/null 2>&1; then
    echo 'Preset connection validation failed: invalid or expired CA certificate.' >&2
    return 1
  fi
}
if ! validate_connection_preset "$connection_file" "$stage_dir"; then
  echo 'Preset connection fields could not be validated. No application was packaged.' >&2
  exit 1
fi
install -m 600 "$connection_file" "$app_dir/Contents/Resources/preset-connection.json"
echo "Preset connection file: $connection_file"
echo 'Preset fields validated; private preset embedded with permissions 600.'

download_frpc() {
  local platform=$1 expected=$2 architecture=$3
  local archive="frp_${frp_version}_${platform}.tar.gz"
  local archive_path="$build_dir/downloads/$archive"
  if [ ! -f "$archive_path" ]; then
    echo "Downloading official frp $frp_version ($platform)…"
    curl --fail --location --silent --show-error --retry 3 \
      --connect-timeout 15 --max-time 600 \
      "https://github.com/fatedier/frp/releases/download/v${frp_version}/${archive}" \
      -o "$archive_path.partial"
    mv "$archive_path.partial" "$archive_path"
  fi
  local actual
  actual=$(shasum -a 256 "$archive_path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "SHA256 mismatch for $archive. Remove the cached archive and retry." >&2
    exit 1
  fi
  tar -xzf "$archive_path" -C "$stage_dir" \
    "frp_${frp_version}_${platform}/frpc" \
    "frp_${frp_version}_${platform}/LICENSE"
  install -m 755 "$stage_dir/frp_${frp_version}_${platform}/frpc" \
    "$build_dir/$architecture/frpc"
  lipo "$build_dir/$architecture/frpc" -verify_arch "$architecture"
  echo "Verified official archive SHA256: $archive ($actual)"
}

# Published checksums for the pinned official v0.71.0 release archives.
download_frpc darwin_arm64 \
  45be02b186860d375ed49a8941ae9569628a54bf14e67fc36b29c98c99dabcc6 arm64
download_frpc darwin_amd64 \
  1b1b4e2f1836e21e8733f1dddaacd4ed9ae67d7dbee39046b9d7b7eda6253637 x86_64
cmp "$stage_dir/frp_${frp_version}_darwin_arm64/LICENSE" \
  "$stage_dir/frp_${frp_version}_darwin_amd64/LICENSE"
install -m 644 "$stage_dir/frp_${frp_version}_darwin_amd64/LICENSE" \
  "$app_dir/Contents/Resources/Licenses/frp-LICENSE.txt"
install -m 644 "$project_dir/resources/ThirdPartyNotices.txt" \
  "$app_dir/Contents/Resources/ThirdPartyNotices.txt"

sources=("$project_dir"/Sources/AITunnelApp/*.swift)
if [ ! -f "${sources[0]}" ]; then
  echo 'No Swift application sources found under Sources/AITunnelApp.' >&2
  exit 1
fi
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
for architecture in arm64 x86_64; do
  echo "Compiling AI Tunnel for $architecture (macOS 13+)…"
  xcrun swiftc -parse-as-library -O -whole-module-optimization \
    -target "$architecture-apple-macosx13.0" -sdk "$sdk_path" \
    -module-name AITunnel -framework SwiftUI -framework AppKit \
    -framework Security -framework ServiceManagement \
    "${sources[@]}" -o "$build_dir/$architecture/AI Tunnel"
done
lipo -create "$build_dir/arm64/AI Tunnel" "$build_dir/x86_64/AI Tunnel" \
  -output "$app_dir/Contents/MacOS/AI Tunnel"
lipo -create "$build_dir/arm64/frpc" "$build_dir/x86_64/frpc" \
  -output "$app_dir/Contents/Resources/bin/frpc"

install -m 644 "$project_dir/resources/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swift "$script_dir/generate-icon.swift" "$stage_dir/AppIcon.iconset"
iconutil -c icns "$stage_dir/AppIcon.iconset" \
  -o "$app_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$app_dir/Contents/MacOS/AI Tunnel" "$app_dir/Contents/Resources/bin/frpc"
plutil -lint "$app_dir/Contents/Info.plist"

# Sign embedded executables first. No developer identity or private key is used.
codesign --force --sign - --timestamp=none --options runtime \
  "$app_dir/Contents/Resources/bin/frpc"
codesign --force --sign - --timestamp=none --options runtime "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
lipo "$app_dir/Contents/MacOS/AI Tunnel" -verify_arch arm64 x86_64
lipo "$app_dir/Contents/Resources/bin/frpc" -verify_arch arm64 x86_64

output_app="$dist_dir/AI Tunnel.app"
output_zip="$dist_dir/AI-Tunnel-macOS-universal.zip"
if [ -e "$output_app" ]; then rm -rf "$output_app"; fi
mv "$app_dir" "$output_app"
ditto -c -k --sequesterRsrc --keepParent "$output_app" "$output_zip"
shasum -a 256 "$output_zip" > "$output_zip.sha256"
chmod 600 "$output_zip" "$output_zip.sha256"

{
  printf 'Build time (UTC): '; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'macOS minimum: 13.0\nfrp version: %s\n' "$frp_version"
  printf 'Private preset: embedded and validated; file permissions 600.\n'
  xcrun swiftc --version 2>&1
  lipo -archs "$output_app/Contents/MacOS/AI Tunnel"
  lipo -archs "$output_app/Contents/Resources/bin/frpc"
  "$output_app/Contents/Resources/bin/frpc" --version
  codesign --display --verbose=2 "$output_app" 2>&1
  codesign --verify --deep --strict --verbose=2 "$output_app" 2>&1
  shasum -a 256 "$output_app/Contents/Resources/Licenses/frp-LICENSE.txt"
  printf '\nSigning: ad-hoc only. Not notarized.\n'
  shasum -a 256 "$output_zip"
} > "$dist_dir/build-verification.txt"

echo "Application: $output_app"
echo "ZIP: $output_zip"
echo "Verification: $dist_dir/build-verification.txt"
echo 'Ad-hoc signed locally. Developer ID signing and Apple notarization were not performed.'
