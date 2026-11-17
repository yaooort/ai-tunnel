#!/bin/bash
# Stop/remove only the AI Tunnel system LaunchDaemon. Keep credentials and logs.
set +x
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" -ne 0 ]; then
  echo 'Usage: sudo bash uninstall-system-service.sh' >&2
  exit 1
fi
label=vip.k-line.aitunnel.frpc
plist_path="/Library/LaunchDaemons/$label.plist"
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$label"
fi
if [ -f "$plist_path" ]; then rm "$plist_path"; fi
echo 'AI Tunnel system service removed. The GUI can now manage the tunnel.'
echo 'Credentials and configuration are preserved in /Library/Application Support/AITunnelService.'
echo 'Logs are preserved in /Library/Logs/AITunnelService.'
