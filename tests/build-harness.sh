#!/bin/bash
# Default builds a fully isolated model test with a fake child process.
# --frpc PATH embeds a real frpc for the --connection observation interface.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd -P)
project_dir=$(cd "$test_dir/.." && pwd -P)
frpc_path="$test_dir/fake-frpc.sh"
if [ "$#" -gt 0 ]; then
  if [ "$#" != 2 ] || [ "$1" != --frpc ]; then
    echo 'Usage: build-harness.sh [--frpc PATH]' >&2
    exit 1
  fi
  frpc_path=$2
fi
if [ ! -f "$frpc_path" ]; then
  echo 'The selected frpc executable does not exist.' >&2
  exit 1
fi
app_dir="$test_dir/.build/AppModel Harness.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/bin"
install -m 755 "$frpc_path" "$app_dir/Contents/Resources/bin/frpc"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>vip.k-line.aitunnel.harness</string>
<key>CFBundleExecutable</key><string>AppModelHarness</string>
<key>CFBundleName</key><string>AppModel Harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  -target "$(uname -m)-apple-macos13.0" -module-name AITunnelHarness \
  "$project_dir/Sources/AITunnelApp/AppModel.swift" "$test_dir/AppModelHarness.swift" \
  -o "$app_dir/Contents/MacOS/AppModelHarness"
codesign --force --sign - --timestamp=none "$app_dir" >/dev/null
printf '%s\n' "$app_dir/Contents/MacOS/AppModelHarness"
