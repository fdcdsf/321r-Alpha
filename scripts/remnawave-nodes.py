#!/usr/bin/env python3
"""Ноды Remnawave: создаёт ключи, запускает Xray и регистрирует в выбранной панели.

Панель install или connect — один и тот же API, никакого Docker на домашнем сервере
этот скрипт не разворачивает. Повторный запуск не меняет существующие ноды/секреты.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location("rw", Path(__file__).with_name("remnawave-bootstrap.py"))
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)


def run(args, timeout=300, **kwargs):
    try:
        return subprocess.run(args, capture_output=True, timeout=timeout, check=True, **kwargs)
    except subprocess.CalledProcessError as e:
        tail = (e.stderr or e.stdout or b"").decode(errors="replace").strip().splitlines()[-3:]
        raise rw.Failure(
            "команда на ноде не прошла: " + str(args[-1])[:90]
            + (" | " + " / ".join(tail) if tail else "")
        ) from e
    except subprocess.TimeoutExpired:
        raise rw.Failure(f"команда на ноде зависла (>{timeout} с): {str(args[-1])[:90]}") from None


def provision(api, nodes, ssh_key, compose):
    profiles = api.call("/config-profiles", browser=True)["configProfiles"]
    profile = next((p for p in profiles if p.get("name") == "321r-mask"), None)
    if not profile:
        raise rw.Failure("нет профиля 321r-mask (сначала remnawave-bootstrap.py)")
    uuid = profile["uuid"]
    inbounds = api.call(f"/config-profiles/{uuid}/inbounds", browser=True)["inbounds"]
    active = [i["uuid"] for i in inbounds if i.get("tag") == "masked-vless"]
    if len(active) != 1:
        raise rw.Failure("в профиле отсутствует единственный masked-vless inbound")
    known = {n["name"]: n for n in api.call("/nodes", browser=True)}
    for alias, ip in nodes:
        name = "node-" + alias
        ssh = ["ssh", "-n", "-i", ssh_key, "-p", "2222", "-o", "BatchMode=yes", "root@" + ip]
        env_file = f"/etc/db/secrets/remnanode-{alias}.env"
        if not Path(env_file).exists():
            generated = api.call("/keygen", browser=True)["secretKey"]
            if not re.fullmatch(r"[A-Za-z0-9_+./=-]+", generated):
                raise rw.Failure("панель вернула неожиданный формат SECRET_KEY")
            rw.save(env_file, "SECRET_KEY=" + generated + "\n")
        run(ssh + ["install -d -m 700 /opt/remnanode"])
        run(["scp", "-q", "-i", ssh_key, "-P", "2222", compose,
             f"root@{ip}:/opt/remnanode/docker-compose.yml"])
        # Секрет только через stdin; не подставлять его в командную строку SSH.
        put = ["ssh", "-i", ssh_key, "-p", "2222", "-o", "BatchMode=yes",
               "root@" + ip, "umask 077; cat > /opt/remnanode/.env && chmod 600 /opt/remnanode/.env"]
        run(put, input=Path(env_file).read_bytes())
        run(ssh + ["cd /opt/remnanode && for img in $(docker compose config --images); do docker image inspect $img >/dev/null 2>&1 || docker pull $img; done"], timeout=900)
        run(ssh + ["cd /opt/remnanode && (docker compose up -d || { docker rm -f remnanode >/dev/null 2>&1; docker compose up -d; })"], timeout=180)
        run(ssh + ["docker ps --format '{{.Names}}' | grep -qx remnanode"])
        print(f"Remnawave: {name} запущена на {alias}")
        if name not in known:
            api.call("/nodes", "POST", {"name": name, "address": ip, "port": 2099,
                     "configProfile": {"activeConfigProfileUuid": uuid, "activeInbounds": active}}, browser=True)
            print(f"Remnawave: {name} зарегистрирована в панели")
        else:
            print(f"Remnawave: {name} уже зарегистрирована, не меняю")
    names = {n["name"] for n in api.call("/nodes", browser=True)}
    if any("node-" + a not in names for a, _ in nodes):
        raise rw.Failure("не все VPN-ноды появились в панели")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=["install", "connect"], required=True)
    p.add_argument("--panel-url", required=True)
    p.add_argument("--admin-file", default="/etc/db/secrets/remnawave-admin.json")
    p.add_argument("--token-file", default="/etc/db/secrets/remnawave-api.token")
    p.add_argument("--ssh-key", default="/root/.ssh/id_cluster")
    p.add_argument("--compose", required=True)
    p.add_argument("--node", action="append", required=True, help="alias:mesh-IP")
    a = p.parse_args()
    try:
        api = rw.Api(a.panel_url)
        rw.admin(api, a.mode, a.admin_file, a.token_file)
        nodes = []
        for item in a.node:
            alias, ip = item.split(":", 1)
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,20}", alias):
                raise ValueError("неверное имя ноды")
            import ipaddress
            ipaddress.IPv4Address(ip)
            nodes.append((alias, ip))
        provision(api, nodes, a.ssh_key, a.compose)
    except (rw.Failure, ValueError, KeyError, OSError) as e:
        print(f"Remnawave: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
