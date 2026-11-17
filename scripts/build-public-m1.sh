#!/bin/bash
# Build a clean Apple Silicon public release, without any personal preset.
# Does not read or modify private/, the personal app, or personal installers.
set +x
set -euo pipefail
umask 022

script_dir=$(cd "$(dirname "$0")" && pwd -P)
project_dir=$(cd "$script_dir/.." && pwd -P)
build_dir="$project_dir/.build/public-m1"
output_dir="$project_dir/dist/public"
version=1.1.0
build_number=3
app_name='AI Tunnel Public'
bundle_id=vip.k-line.aitunnel.public
frp_version=0.71.0
frp_archive="frp_${frp_version}_darwin_arm64.tar.gz"
frp_sha256=45be02b186860d375ed49a8941ae9569628a54bf14e67fc36b29c98c99dabcc6
artifact_name="AI-Tunnel-Public-${version}-macOS-arm64"

if [ "$(uname -s)" != Darwin ]; then
  echo 'Run this public release build on macOS with Xcode tools installed.' >&2
  exit 1
fi
if [ "${AI_TUNNEL_CONNECTION_FILE+x}" = x ]; then
  echo 'Public builds do not accept AI_TUNNEL_CONNECTION_FILE. Unset it and run again.' >&2
  exit 1
fi
for command_name in xcrun codesign lipo iconutil ditto hdiutil shasum curl tar plutil; do
  command -v "$command_name" >/dev/null || { echo "Missing build tool: $command_name" >&2; exit 1; }
done
sources=("$project_dir"/Sources/AITunnelApp/*.swift)
test -f "${sources[0]}" || { echo 'No application Swift sources found.' >&2; exit 1; }

mkdir -p "$build_dir/downloads"
stage_dir=$(mktemp -d "$build_dir/stage.XXXXXX")
mounted=0
mount_dir="$stage_dir/mounted-dmg"
cleanup() {
  if [ "$mounted" -eq 1 ]; then
    if ! hdiutil detach "$mount_dir" >/dev/null 2>&1; then
      echo "Could not detach verification image; staging directory retained: $stage_dir" >&2
      return
    fi
  fi
  rm -rf "$stage_dir"
}
trap cleanup EXIT

payload_dir="$stage_dir/payload"
app_dir="$payload_dir/$app_name.app"
release_dir="$stage_dir/release"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/bin" \
  "$app_dir/Contents/Resources/Licenses" "$release_dir"

# Reuse only the pinned official archive, never an existing app or preset.
cached_archive="$project_dir/.build/macos/downloads/$frp_archive"
if [ -f "$cached_archive" ]; then
  archive_path="$cached_archive"
else
  archive_path="$build_dir/downloads/$frp_archive"
  if [ ! -f "$archive_path" ]; then
    echo "Downloading official frp $frp_version (darwin_arm64)…"
    curl --fail --location --silent --show-error --retry 3 \
      --connect-timeout 15 --max-time 600 \
      "https://github.com/fatedier/frp/releases/download/v${frp_version}/${frp_archive}" \
      -o "$archive_path.partial"
    mv "$archive_path.partial" "$archive_path"
  fi
fi
actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
test "$actual_sha256" = "$frp_sha256" || { echo 'Official frp archive SHA256 mismatch.' >&2; exit 1; }
tar -xzf "$archive_path" -C "$stage_dir" \
  "frp_${frp_version}_darwin_arm64/frpc" "frp_${frp_version}_darwin_arm64/LICENSE"
install -m 755 "$stage_dir/frp_${frp_version}_darwin_arm64/frpc" "$app_dir/Contents/Resources/bin/frpc"
install -m 644 "$stage_dir/frp_${frp_version}_darwin_arm64/LICENSE" \
  "$app_dir/Contents/Resources/Licenses/frp-LICENSE.txt"
install -m 644 "$project_dir/resources/ThirdPartyNotices.txt" \
  "$app_dir/Contents/Resources/ThirdPartyNotices.txt"
echo 'Official ARM64 frpc archive SHA256 verified.'

install -m 644 "$project_dir/resources/Info.plist" "$app_dir/Contents/Info.plist"
plist="$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
plutil -replace CFBundleName -string "$app_name" "$plist"
plutil -replace CFBundleDisplayName -string "$app_name" "$plist"
plutil -replace CFBundleExecutable -string "$app_name" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build_number" "$plist"
plutil -replace LSMinimumSystemVersion -string 13.0 "$plist"
plutil -lint "$plist"

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
echo 'Compiling public ARM64 application (macOS 13+)…'
xcrun swiftc -parse-as-library -O -whole-module-optimization -D AI_TUNNEL_PUBLIC \
  -target arm64-apple-macosx13.0 -sdk "$sdk_path" -module-name AITunnelPublic \
  -file-prefix-map "$project_dir=." \
  -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement \
  "${sources[@]}" -o "$app_dir/Contents/MacOS/$app_name"
xcrun swift "$script_dir/generate-icon.swift" "$stage_dir/AppIcon.iconset"
iconutil -c icns "$stage_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$app_dir/Contents/MacOS/$app_name"

verify_clean_app() {
  local app=$1 unexpected
  unexpected=$(find "$app" \( -iname '*preset*' -o -iname '*.json' -o -iname '*.crt' \
    -o -iname '*.key' -o -iname '*.token' -o -iname '*.pem' -o -iname '*.p12' \
    -o -iname '*.pfx' -o -iname '*.log' -o -iname 'runtime' -o -iname 'logs' \
    -o -iname 'token' -o -iname 'key' -o -iname 'private' \) -print)
  if [ -n "$unexpected" ]; then
    echo 'Public application contains a prohibited configuration or credential path:' >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
  test "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = "$bundle_id"
  test "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version"
  test "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = "$build_number"
  test "$(lipo -archs "$app/Contents/MacOS/$app_name")" = arm64
  test "$(lipo -archs "$app/Contents/Resources/bin/frpc")" = arm64
  codesign --verify --deep --strict "$app"
}

# Ad-hoc hardened signing only; no developer identity or notarization is used.
codesign --force --sign - --timestamp=none --options runtime "$app_dir/Contents/Resources/bin/frpc"
codesign --force --sign - --timestamp=none --options runtime "$app_dir"
verify_clean_app "$app_dir"

cat > "$payload_dir/安装说明.txt" <<'GUIDE'
AI Tunnel Public 1.1.0 — Apple Silicon / M1 原生版本
要求 macOS 13 或更高版本。

将 AI Tunnel Public.app 拖入“应用程序”后打开。
首次使用请配置自己的中转服务器、本机服务端口和公网 HTTPS 地址。
提供自己服务器的认证信息与 CA 证书，或导入自己导出的连接 JSON。
应用会将连接凭据保存在当前用户的 macOS 钥匙串中。
本公开包不包含服务器地址、CA、认证凭据或预置连接文件。

关闭窗口后隧道继续运行；退出应用会断开隧道。
电脑睡眠或本机业务服务停止时，公网业务不可用。

此版本采用本地 ad-hoc 签名，未进行 Apple 公证。
首次打开如被系统阻止，请在“系统设置 → 隐私与安全性”中针对本应用允许打开。
无需关闭系统的全局安全策略。
GUIDE
ln -s /Applications "$payload_dir/Applications"

output_zip="$release_dir/$artifact_name.zip"
output_dmg="$release_dir/$artifact_name.dmg"
ditto -c -k --sequesterRsrc "$payload_dir" "$output_zip"
mkdir -p "$stage_dir/zip-check"
ditto -x -k "$output_zip" "$stage_dir/zip-check"
verify_clean_app "$stage_dir/zip-check/$app_name.app"
test -L "$stage_dir/zip-check/Applications"

hdiutil create -srcfolder "$payload_dir" -volname "$app_name" -format UDZO -fs HFS+ -ov "$output_dmg"
hdiutil verify "$output_dmg"
mkdir -p "$mount_dir"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" "$output_dmg" >/dev/null
mounted=1
verify_clean_app "$mount_dir/$app_name.app"
test -L "$mount_dir/Applications"
test -r "$mount_dir/安装说明.txt"
hdiutil detach "$mount_dir" >/dev/null
mounted=0

(cd "$release_dir" && shasum -a 256 "$artifact_name.zip" "$artifact_name.dmg" > SHA256SUMS)
(cd "$release_dir" && shasum -a 256 -c SHA256SUMS)
{
  printf 'Public build time (UTC): '; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'App: %s\nBundle ID: %s\nVersion: %s (%s)\nMinimum macOS: 13.0\n' \
    "$app_name" "$bundle_id" "$version" "$build_number"
  printf 'Compiler condition: AI_TUNNEL_PUBLIC\nfrp: %s, official darwin_arm64 archive SHA256 %s\n' "$frp_version" "$frp_sha256"
  xcrun swiftc --version 2>&1
  (
    cd "$payload_dir"
    printf '\nMain executable platform:\n'
    xcrun vtool -show-build "$app_name.app/Contents/MacOS/$app_name"
    printf '\nfrpc platform:\n'
    xcrun vtool -show-build "$app_name.app/Contents/Resources/bin/frpc"
    codesign --display --verbose=2 "$app_name.app" 2>&1 | sed '/^Executable=/d'
    codesign --verify --deep --strict --verbose=2 "$app_name.app" 2>&1
  )
  printf '\nVerification: App, extracted ZIP, and read-only mounted DMG passed signature, ARM64, ID and credential-path checks; SHA256SUMS verified.\n'
  printf 'No preset, runtime, log, token or private-key files included.\n'
  printf 'Personal configuration and personal artifacts were not used.\n'
  printf 'Signing: ad-hoc hardened runtime. Not notarized.\n'
  printf 'Build host: %s. Physical Apple Silicon runtime execution was not tested by this script.\n' "$(uname -m)"
  printf '\nPayload file manifest:\n'
  (cd "$payload_dir" && find . -print | LC_ALL=C sort)
  printf '\nChecksums:\n'
  cat "$release_dir/SHA256SUMS"
} > "$release_dir/PUBLIC-VERIFICATION.txt"

mkdir -p "$output_dir"
chmod 755 "$output_dir"
for filename in "$artifact_name.zip" "$artifact_name.dmg" SHA256SUMS PUBLIC-VERIFICATION.txt; do
  install -m 644 "$release_dir/$filename" "$output_dir/$filename"
done
(cd "$output_dir" && shasum -a 256 -c SHA256SUMS)
public_app="$output_dir/$app_name.app"
if [ -e "$public_app" ]; then rm -rf "$public_app"; fi
ditto "$app_dir" "$public_app"
echo "Public ZIP: $output_dir/$artifact_name.zip"
echo "Public DMG: $output_dir/$artifact_name.dmg"
echo "Checksums: $output_dir/SHA256SUMS"
echo "Report: $output_dir/PUBLIC-VERIFICATION.txt"
