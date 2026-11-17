#!/bin/bash
# Derive a native Apple Silicon installer from the verified universal app.
set +x
set -euo pipefail
umask 077

script_dir=$(cd "$(dirname "$0")" && pwd -P)
project_dir=$(cd "$script_dir/.." && pwd -P)
dist_dir="$project_dir/dist"
source_app="$dist_dir/AI Tunnel.app"
build_dir="$project_dir/.build/m1"

for command_name in codesign lipo ditto hdiutil plutil shasum; do
  command -v "$command_name" >/dev/null || { echo "Missing tool: $command_name" >&2; exit 1; }
done
test -d "$source_app" || { echo 'Build the universal self-use app first.' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
test -r "$source_app/Contents/Resources/preset-connection.json" || {
  echo 'The self-use preset is missing from the application.' >&2; exit 1;
}
mkdir -p "$build_dir" "$dist_dir"
chmod 700 "$dist_dir"
stage_dir=$(mktemp -d "$build_dir/stage.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
payload_dir="$stage_dir/payload"
app_dir="$payload_dir/AI Tunnel.app"
mkdir -p "$payload_dir"
ditto "$source_app" "$app_dir"

# Thin both executables; the UI and tunnel must both run natively on M1.
for relative_path in 'Contents/MacOS/AI Tunnel' 'Contents/Resources/bin/frpc'; do
  executable="$app_dir/$relative_path"
  lipo "$executable" -verify_arch arm64
  if [ "$(lipo -archs "$executable")" != arm64 ]; then
    lipo "$executable" -thin arm64 -output "$stage_dir/arm64-executable"
    install -m 755 "$stage_dir/arm64-executable" "$executable"
  fi
  test "$(lipo -archs "$executable")" = arm64
done
chmod 600 "$app_dir/Contents/Resources/preset-connection.json"
codesign --force --sign - --timestamp=none --options runtime \
  "$app_dir/Contents/Resources/bin/frpc"
codesign --force --sign - --timestamp=none --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"

cat > "$payload_dir/安装说明.txt" <<'GUIDE'
AI Tunnel — M1 / Apple Silicon 原生版本
版本：1.0.1；要求 macOS 13 或更高版本。

将 AI Tunnel.app 拖入“应用程序”后打开。
服务器配置已内置，本机服务默认 127.0.0.1:8080，直接点击“连接”即可。
需要登录后自动连接时，同时打开两个启动开关。

应用仅作本地 ad-hoc 签名，未进行 Apple 公证。首次打开如被阻止，
请在“系统设置 → 隐私与安全性”中针对 AI Tunnel 允许打开。

自用程序内含隧道连接凭据，请保管此安装包。
详细说明见“使用说明.txt”；可选系统开机服务脚本位于 scripts。
GUIDE
cp "$project_dir/README.txt" "$payload_dir/使用说明.txt"
mkdir -p "$payload_dir/scripts"
cp "$script_dir/install-system-service.sh" "$script_dir/uninstall-system-service.sh" "$payload_dir/scripts/"
ln -s /Applications "$payload_dir/Applications"

output_zip="$dist_dir/AI-Tunnel-macOS-M1-arm64.zip"
output_dmg="$dist_dir/AI-Tunnel-macOS-M1-arm64.dmg"
ditto -c -k --sequesterRsrc "$payload_dir" "$output_zip"
hdiutil create -srcfolder "$payload_dir" -volname 'AI Tunnel M1' \
  -format UDZO -fs HFS+ -ov "$output_dmg"
hdiutil verify "$output_dmg"
chmod 600 "$output_zip" "$output_dmg"
shasum -a 256 "$output_zip" "$output_dmg" > "$dist_dir/M1-SHA256.txt"

{
  printf 'Package time (UTC): '; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'Version: '; plutil -extract CFBundleShortVersionString raw -o - "$app_dir/Contents/Info.plist"
  printf 'Minimum macOS: '; plutil -extract LSMinimumSystemVersion raw -o - "$app_dir/Contents/Info.plist"
  printf 'GUI architecture: '; lipo -archs "$app_dir/Contents/MacOS/AI Tunnel"
  printf 'frpc architecture: '; lipo -archs "$app_dir/Contents/Resources/bin/frpc"
  codesign --verify --deep --strict --verbose=2 "$app_dir" 2>&1
  printf 'Private connection preset: included, permissions 600.\n'
  printf 'Signing: ad-hoc. Not notarized.\n'
  printf 'Build host: %s. No physical M1 execution test performed.\n' "$(uname -m)"
  cat "$dist_dir/M1-SHA256.txt"
} > "$dist_dir/M1-verification.txt"
printf 'M1 installers created:\n%s\n%s\n' "$output_dmg" "$output_zip"
