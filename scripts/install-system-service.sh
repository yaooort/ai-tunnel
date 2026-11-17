#!/bin/bash
# Install an independent frpc LaunchDaemon. The GUI does not control this daemon.
# Run only after disconnecting the GUI tunnel. Credentials are never printed.
set +x
set -euo pipefail
umask 077

usage() {
  echo 'Usage: sudo bash install-system-service.sh "/Applications/AI Tunnel.app" CONNECTION_JSON LOCAL_USER [LOCAL_PORT]' >&2
  echo 'Disconnect the GUI tunnel first. This installs a separate service that runs before user login.' >&2
}
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then usage; exit 2; fi
if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" -ne 0 ]; then
  echo 'Run this installer on macOS with sudo.' >&2
  exit 1
fi
app_path=$1
connection_json=$2
local_user=$3
local_port=${4:-8080}
label=vip.k-line.aitunnel.frpc
plist_path="/Library/LaunchDaemons/$label.plist"
service_root='/Library/Application Support/AITunnelService'
log_dir='/Library/Logs/AITunnelService'

if ! [[ "$local_user" =~ ^[A-Za-z0-9_.-]+$ ]] || \
   ! id "$local_user" >/dev/null 2>&1 || [ "$(id -u "$local_user")" -eq 0 ]; then
  echo 'LOCAL_USER must be an existing non-root macOS account.' >&2
  exit 1
fi
if ! [[ "$local_port" =~ ^[0-9]{1,5}$ ]] || \
   [ "$((10#$local_port))" -lt 1 ] || [ "$((10#$local_port))" -gt 65535 ]; then
  echo 'LOCAL_PORT must be between 1 and 65535.' >&2
  exit 1
fi
local_port=$((10#$local_port))
local_group=$(id -gn "$local_user")
local_home=$(/usr/bin/dscl . -read "/Users/$local_user" NFSHomeDirectory | \
  /usr/bin/sed 's/^NFSHomeDirectory: //')
if [ ! -d "$local_home" ] || [[ "$local_home" != /* ]]; then
  echo 'Unable to resolve the local user home directory.' >&2
  exit 1
fi
gui_pid_path="$local_home/Library/Application Support/AITunnel/runtime/frpc.pid"
if [ -f "$gui_pid_path" ]; then
  gui_pid=$(cat "$gui_pid_path")
  if [[ "$gui_pid" =~ ^[0-9]+$ ]]; then
    gui_command=$(/bin/ps -p "$gui_pid" -o command= 2>/dev/null || true)
    case "$gui_command" in
      *AITunnel*frpc*|*"AI Tunnel"*frpc*)
        echo 'The GUI frpc process is running. Disconnect it in AI Tunnel and retry.' >&2
        exit 1 ;;
    esac
  fi
fi
# A stale PID file is insufficient evidence. Also check real frpc command paths.
for candidate_pid in $(/usr/bin/pgrep -x frpc || true); do
  candidate_command=$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)
  case "$candidate_command" in
    *"/AITunnel/runtime/"*|*"AI Tunnel.app/Contents/Resources/bin/frpc"*)
      echo 'A GUI-managed frpc process is running. Disconnect it before installing.' >&2
      exit 1 ;;
    *)
      if [[ "$candidate_command" != *"$service_root/bin/frpc"* ]]; then
        echo "Notice: another frpc process exists (PID $candidate_pid); it will not be stopped." >&2
      fi ;;
  esac
done

frpc_source="$app_path/Contents/Resources/bin/frpc"
if [ ! -f "$frpc_source" ] || [ ! -f "$connection_json" ]; then
  echo 'The application frpc binary or connection JSON was not found.' >&2
  exit 1
fi
codesign --verify --strict "$frpc_source"
stage_dir=$(mktemp -d /private/tmp/aitunnel-install.XXXXXX)
trap 'rm -rf "$stage_dir"' EXIT
first_character=$(awk 'match($0,/[^ \t\r\n]/) { print substr($0,RSTART,1); exit }' "$connection_json")
if [ "$(wc -c < "$connection_json" | tr -d ' ')" -gt 131072 ] || \
   [ "$first_character" != '{' ] || \
   ! /usr/bin/plutil -convert json -o "$stage_dir/validated.json" "$connection_json" >/dev/null 2>&1; then
  echo 'Connection file is not a valid JSON object or exceeds the size limit.' >&2
  exit 1
fi
extract_string() {
  if ! /usr/bin/plutil -extract "$1" raw -expect string -o - "$connection_json" 2>/dev/null; then
    echo "Missing or invalid string field: $1" >&2
    return 1
  fi
}
extract_integer() {
  if ! /usr/bin/plutil -extract "$1" raw -expect integer -o - "$connection_json" 2>/dev/null; then
    echo "Missing or invalid integer field: $1" >&2
    return 1
  fi
}
schema_version=$(extract_integer schemaVersion)
server_address=$(extract_string serverAddress)
tls_server_name=$(extract_string tlsServerName)
server_port=$(extract_integer serverPort)
remote_port=$(extract_integer remotePort)
if [ "$schema_version" != 1 ]; then echo 'Unsupported connection schema.' >&2; exit 1; fi
if ! [[ "$server_address" =~ ^[A-Za-z0-9.-]+$ ]] || \
   ! [[ "$tls_server_name" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo 'The server address and TLS name must be valid DNS names or IPv4 addresses.' >&2
  exit 1
fi
for connection_port in "$server_port" "$remote_port"; do
  if ! [[ "$connection_port" =~ ^[0-9]{1,5}$ ]] || \
     [ "$((10#$connection_port))" -lt 1 ] || [ "$((10#$connection_port))" -gt 65535 ]; then
    echo 'Connection JSON contains an invalid port.' >&2
    exit 1
  fi
done
server_port=$((10#$server_port))
remote_port=$((10#$remote_port))
token_value=$(extract_string token)
if [ "${#token_value}" -lt 32 ] || [ "${#token_value}" -gt 256 ] || \
   ! [[ "$token_value" =~ ^[-A-Za-z0-9._~]+$ ]]; then
  echo 'Connection token has an invalid format.' >&2
  exit 1
fi
unset token_value
/usr/bin/plutil -extract token raw -expect string -o "$stage_dir/token" "$connection_json" >/dev/null 2>&1
if ! /usr/bin/plutil -extract caCertificatePEM raw -expect string \
     -o "$stage_dir/ca.crt" "$connection_json" >/dev/null 2>&1 || \
   ! /usr/bin/openssl x509 -in "$stage_dir/ca.crt" -noout -checkend 0 >/dev/null 2>&1; then
  echo 'Connection CA certificate is invalid or expired.' >&2
  exit 1
fi

install -d -o root -g wheel -m 755 "$service_root" "$service_root/bin"
install -d -o "$local_user" -g "$local_group" -m 700 "$log_dir"
install -o root -g wheel -m 755 "$frpc_source" "$service_root/bin/frpc"
install -o "$local_user" -g "$local_group" -m 600 "$stage_dir/token" "$service_root/token"
install -o "$local_user" -g "$local_group" -m 600 "$stage_dir/ca.crt" "$service_root/ca.crt"
cat > "$stage_dir/frpc.toml" <<EOF
serverAddr = "$server_address"
serverPort = $server_port
loginFailExit = false
auth.method = "token"
auth.additionalScopes = ["NewWorkConns"]
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$service_root/token"
transport.protocol = "tcp"
transport.dialServerTimeout = 10
transport.tls.enable = true
transport.tls.trustedCaFile = "$service_root/ca.crt"
transport.tls.serverName = "$tls_server_name"
transport.dialServerKeepalive = 30
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.heartbeatInterval = -1
transport.heartbeatTimeout = -1
log.to = "$log_dir/frpc.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true

[[proxies]]
name = "ai-local-8080"
type = "tcp"
localIP = "127.0.0.1"
localPort = $local_port
remotePort = $remote_port
EOF
install -o "$local_user" -g "$local_group" -m 600 \
  "$stage_dir/frpc.toml" "$service_root/frpc.toml"
/usr/bin/sudo -u "$local_user" "$service_root/bin/frpc" verify \
  -c "$service_root/frpc.toml"

# plutil supplies XML escaping for all paths and values.
/usr/bin/plutil -create xml1 "$stage_dir/service.plist"
/usr/bin/plutil -insert Label -string "$label" "$stage_dir/service.plist"
/usr/bin/plutil -insert UserName -string "$local_user" "$stage_dir/service.plist"
/usr/bin/plutil -insert ProgramArguments -array "$stage_dir/service.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$service_root/bin/frpc" "$stage_dir/service.plist"
/usr/bin/plutil -insert ProgramArguments.1 -string -c "$stage_dir/service.plist"
/usr/bin/plutil -insert ProgramArguments.2 -string "$service_root/frpc.toml" "$stage_dir/service.plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$stage_dir/service.plist"
/usr/bin/plutil -insert KeepAlive -bool YES "$stage_dir/service.plist"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$stage_dir/service.plist"
/usr/bin/plutil -insert Umask -integer 63 "$stage_dir/service.plist"
/usr/bin/plutil -insert EnvironmentVariables -dictionary "$stage_dir/service.plist"
for variable in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
  /usr/bin/plutil -insert "EnvironmentVariables.$variable" -string '' "$stage_dir/service.plist"
done
/usr/bin/plutil -insert StandardOutPath -string /dev/null "$stage_dir/service.plist"
/usr/bin/plutil -insert StandardErrorPath -string /dev/null "$stage_dir/service.plist"
/usr/bin/plutil -lint "$stage_dir/service.plist"
/bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
install -o root -g wheel -m 644 "$stage_dir/service.plist" "$plist_path"
/bin/launchctl enable "system/$label"
/bin/launchctl bootstrap system "$plist_path"
/bin/launchctl print "system/$label"
echo "Installed independent boot service for $local_user on local port $local_port."
echo "Log (rotated by frpc, retained 7 days): $log_dir/frpc.log"
echo 'The GUI cannot connect while this service is installed. Use uninstall-system-service.sh to return to GUI mode.'
echo 'The local application on the configured port must also start independently. FileVault requires disk unlock after a cold boot.'
