#!/usr/bin/env python3
"""Export client credentials on the relay. Never print credential contents."""
import argparse
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="/root/ai-tunnel.connection.json")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run this export on the relay as root.")
    destination = Path(args.output).absolute()
    token = Path("/etc/ai-tunnel/token").read_text().strip()
    certificate = Path("/var/lib/ai-tunnel/pki/ca.crt").read_text()
    if not token or "-----BEGIN CERTIFICATE-----" not in certificate:
        raise SystemExit("Relay credentials are incomplete.")
    payload = {
        "schemaVersion": 1,
        "serverAddress": "203.0.113.10",
        "serverPort": 7000,
        "tlsServerName": "tunnel.example.com",
        "publicURL": "https://tunnel.example.com",
        "remotePort": 18080,
        "caCertificatePEM": certificate,
        "token": token,
    }
    # Refuse to overwrite an existing file or follow a symlink.
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(payload, output, indent=2)
            output.write("\n")
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    print(f"Private client connection file written to {destination}")


if __name__ == "__main__":
    main()
