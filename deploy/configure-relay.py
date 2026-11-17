#!/usr/bin/env python3
"""Generate relay configuration from validated installer arguments, never secrets."""
import argparse
import json
import ipaddress
import errno
import os
from pathlib import Path
import re
import socket


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--domain', required=True)
    parser.add_argument('--server-address', required=True)
    parser.add_argument('--frp-port', type=int, default=7000)
    parser.add_argument('--remote-port', type=int, default=18080)
    parser.add_argument('--backend', choices=['http1', 'h2c'], default='http1')
    parser.add_argument('--init', choices=['systemd', 'openrc', 'none'], required=True)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run as root.')
    if len(args.domain) > 253 or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in args.domain.split('.')):
        parser.error('Invalid DNS domain.')
    if not re.fullmatch(r'[A-Za-z0-9.:-]{1,253}', args.server_address):
        parser.error('Invalid server address.')
    if ':' in args.server_address or re.fullmatch(r'[0-9.]+', args.server_address):
        try:
            ipaddress.ip_address(args.server_address)
        except ValueError:
            parser.error('Invalid IP address.')
    elif any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in args.server_address.split('.')):
        parser.error('Invalid server hostname.')
    if any(not 1024 <= p <= 65535 for p in [args.frp_port, args.remote_port]) or args.frp_port == args.remote_port:
        parser.error('Invalid ports.')
    if args.validate_only:
        for port in [80, 443, args.frp_port, args.remote_port]:
            for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
                try:
                    with socket.socket(family, socket.SOCK_STREAM) as probe:
                        probe.bind((address, port))
                except OSError as error:
                    if family == socket.AF_INET6 and error.errno in [errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPROTONOSUPPORT]:
                        continue
                    parser.error(f'TCP port {port} is unavailable.')
        print('Domain, server address and port preflight passed.')
        return
    os.umask(0o077)
    metadata = dict(domain=args.domain, serverAddress=args.server_address,
                    serverPort=args.frp_port, remotePort=args.remote_port, backend=args.backend)
    Path('/etc/ai-tunnel/relay.json').write_text(json.dumps(metadata, indent=2) + '\n')
    frps = (args.source_dir / 'frps.toml').read_text()
    frps = frps.replace('bindPort = 7000', f'bindPort = {args.frp_port}')
    frps = frps.replace('single = 18080', f'single = {args.remote_port}')
    Path('/etc/ai-tunnel/frps.toml').write_text(frps)
    caddy = (args.source_dir / 'Caddyfile').read_text()
    caddy = caddy.replace('tunnel.example.com', args.domain).replace(':18080', f':{args.remote_port}')
    if args.backend == 'h2c':
        caddy = caddy.replace('http://', 'h2c://').replace('versions 1.1', 'versions h2c')
    Path('/etc/caddy/Caddyfile').write_text(caddy)
    Path('/etc/caddy/Caddyfile').chmod(0o644)
    if args.init == 'systemd':
        for name in ['ai-tunnel-frps.service', 'ai-tunnel-caddy.service',
                     'ai-tunnel-cert-renew.service', 'ai-tunnel-cert-renew.timer']:
            p = Path('/etc/systemd/system') / name
            p.write_text((args.source_dir / name).read_text())
            p.chmod(0o644)
    elif args.init == 'openrc':
        for service in ['frps', 'caddy', 'cert-renew']:
            arguments = {'frps': '-c /etc/ai-tunnel/frps.toml', 'caddy': 'run --config /etc/caddy/Caddyfile --adapter caddyfile', 'cert-renew': ''}[service]
            command = 'cert-renew-loop' if service == 'cert-renew' else service
            # OpenRC uses root for Caddy's low ports; systemd grants only bind capability.
            user = 'ai-tunnel:ai-tunnel' if service == 'frps' else 'root'
            p = Path('/etc/init.d') / f'ai-tunnel-{service}'
            p.write_text(f'''#!/sbin/openrc-run
description="AI Tunnel {service}"
supervisor=supervise-daemon
command="/opt/ai-tunnel/{command}"
command_args="{arguments}"
command_user="{user}"
pidfile="/run/ai-tunnel-{service}.pid"
respawn_delay=5
respawn_max=0
output_log="/var/log/ai-tunnel/{service}.log"
error_log="/var/log/ai-tunnel/{service}.log"
export HOME=/var/lib/ai-tunnel/caddy
depend() {{ need net; }}
''')
            p.chmod(0o755)
        p = Path('/opt/ai-tunnel/cert-renew-loop')
        p.write_text('''#!/bin/sh
while :; do
  interval=86400
  /opt/ai-tunnel/renew-tunnel-cert || interval=3600
  sleep "$interval"
done
''')
        p.chmod(0o755)


if __name__ == '__main__':
    main()
