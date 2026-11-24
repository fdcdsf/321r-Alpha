#!/usr/bin/env python3
"""Поднять красивую страницу подписки Remnawave на control VPS (install mode).

API-токен хранится только на первом сервере и в закрытом .env control-ноды.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location("rw", Path(__file__).with_name("remnawave-bootstrap.py"))
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)


def run(args, *, input=None):
    try:
        return subprocess.run(args, input=input, capture_output=True, check=True, timeout=180)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise rw.Failure("не удалось установить страницу подписки на control-ноду") from None


def provision(api, node_ip, ssh_key, compose, token_file):
    path = Path(token_file)
    if path.is_file():
        token = rw.secure(path)
    else:
        known = api.call("/tokens", browser=True)["tokens"]
        if any(t.get("name") == "321r-subpage" for t in known):
            raise rw.Failure("API-токен subpage есть в панели, но локальная копия потеряна; повторно не создаю")
        token = api.call("/tokens", "POST", {"name": "321r-subpage", "expiresInDays": 365, "scopes": ["*"]}, browser=True)["token"]
        rw.save(path, token + "\n")
        print("Remnawave: токен страницы подписки создан")
    ssh = ["ssh", "-i", ssh_key, "-p", "2222", "-o", "BatchMode=yes", "root@" + node_ip]
    run(ssh + ["install -d -m 700 /opt/remnawave/subscription"])
    run(["scp", "-q", "-i", ssh_key, "-P", "2222", compose,
         f"root@{node_ip}:/opt/remnawave/subscription/docker-compose.yml"])
    data = ("APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://remnawave:3000\n"
            "REMNAWAVE_API_TOKEN=" + token + "\nTRUST_PROXY=1\n").encode()
    run(ssh + ["umask 077; cat > /opt/remnawave/subscription/.env && chmod 600 /opt/remnawave/subscription/.env"], input=data)
    run(ssh + ["cd /opt/remnawave/subscription && docker compose up -d >/dev/null 2>&1"])
    run(ssh + ["docker ps --format '{{.Names}}' | grep -qx remnawave-subscription-page"])
    print("Remnawave: красивая страница запущена на control-ноде")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--panel-url", required=True)
    p.add_argument("--control-ip", required=True)
    p.add_argument("--compose", required=True)
    p.add_argument("--ssh-key", default="/root/.ssh/id_cluster")
    p.add_argument("--admin-file", default="/etc/db/secrets/remnawave-admin.json")
    p.add_argument("--token-file", default="/etc/db/secrets/remnawave-subpage.token")
    a = p.parse_args()
    try:
        import ipaddress
        ipaddress.IPv4Address(a.control_ip)
        api = rw.Api(a.panel_url)
        rw.admin(api, "install", a.admin_file, None)
        provision(api, a.control_ip, a.ssh_key, a.compose, a.token_file)
    except (rw.Failure, ValueError, KeyError, OSError, TypeError) as exc:
        print(f"Remnawave subpage: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
