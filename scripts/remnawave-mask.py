#!/usr/bin/env python3
"""Минимальный VPN: по одному маскированному хосту на ноду, squad и пробная подписка."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import re
import sys
import urllib.request

spec = importlib.util.spec_from_file_location("rw", Path(__file__).with_name("remnawave-bootstrap.py"))
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)


def ensure(api, domain, aliases):
    profiles = api.call("/config-profiles", browser=True)["configProfiles"]
    profile = next((x for x in profiles if x.get("name") == "321r-mask"), None)
    if not profile:
        raise rw.Failure("нет профиля 321r-mask")
    puid = profile["uuid"]
    inbounds = api.call(f"/config-profiles/{puid}/inbounds", browser=True)["inbounds"]
    inbound = next((x for x in inbounds if x.get("tag") == "masked-vless"), None)
    if not inbound:
        raise rw.Failure("нет inbound masked-vless")
    nodes = {x["name"]: x for x in api.call("/nodes", browser=True)}
    hosts = api.call("/hosts", browser=True)
    for alias in aliases:
        node = nodes.get("node-" + alias)
        if not node:
            raise rw.Failure(f"node-{alias} ещё не зарегистрирована")
        address = f"vpn-{alias}.{domain}"
        if any(x.get("address") == address for x in hosts):
            print(f"Remnawave: хост {address} уже есть")
            continue
        api.call("/hosts", "POST", {
            "inbound": {"configProfileUuid": puid, "configProfileInboundUuid": inbound["uuid"]},
            "remark": "321r-" + alias, "address": address, "port": 443,
            "sni": address, "fingerprint": "chrome", "securityLayer": "DEFAULT",
            "nodes": [node["uuid"]],
        }, browser=True)
        print(f"Remnawave: хост {address} создан")
    squads = api.call("/internal-squads", browser=True)["internalSquads"]
    squad = next((x for x in squads if x.get("name") == "321r"), None)
    if not squad:
        squad = api.call("/internal-squads", "POST", {"name": "321r", "inbounds": [inbound["uuid"]]}, browser=True)
        print("Remnawave: squad 321r создан")
    users_result = api.call("/users", browser=True)
    users = users_result.get("users", []) if isinstance(users_result, dict) else users_result
    if not isinstance(users, list):
        raise rw.Failure("неожиданный ответ GET /users")
    if not any(u.get("username") == "hc-probe" for u in users):
        expire = (datetime.now(timezone.utc) + timedelta(days=365)).isoformat().replace("+00:00", "Z")
        u = api.call("/users", "POST", {"username": "hc-probe", "expireAt": expire,
                    "activeInternalSquads": [squad["uuid"]]}, browser=True)
        print("Remnawave: пробный пользователь создан (ссылка только в защищённом файле)")
        return u.get("shortUuid")
    print("Remnawave: пробный пользователь уже есть")
    return next(u.get("shortUuid") for u in users if u.get("username") == "hc-probe")


def check(api, domain, aliases, subscription_file):
    nodes = {n["name"]: n for n in api.call("/nodes", browser=True)}
    hosts = api.call("/hosts", browser=True)
    for alias in aliases:
        node = nodes.get("node-" + alias)
        if not node or not node.get("isConnected"):
            raise rw.Failure(f"node-{alias} не подключена к панели")
        address = f"vpn-{alias}.{domain}"
        if not any(h.get("address") == address and h.get("nodes") == [node.get("uuid")] for h in hosts):
            raise rw.Failure(f"{address} не закреплён только за node-{alias}")
        print(f"Remnawave: node-{alias} connected, собственный host есть")
    url = rw.secure(subscription_file)
    try:
        data = urllib.request.urlopen(url, timeout=20).read()
        text = base64.b64decode(b"".join(data.split()), validate=True).decode("utf-8")
    except (ValueError, UnicodeError, OSError) as exc:
        raise rw.Failure("подписка не вернула список VLESS") from None
    for alias in aliases:
        if f"vpn-{alias}.{domain}" not in text:
            raise rw.Failure(f"подписка не содержит vpn-{alias}.{domain}")
    print(f"Remnawave: подписка содержит {len(aliases)} адреса VPN")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=["install", "connect"], required=True)
    p.add_argument("--panel-url", required=True)
    p.add_argument("--domain", required=True)
    p.add_argument("--node", action="append", required=True)
    p.add_argument("--admin-file", default="/etc/db/secrets/remnawave-admin.json")
    p.add_argument("--token-file", default="/etc/db/secrets/remnawave-api.token")
    p.add_argument("--subscription-file", default="/etc/db/secrets/remnawave-probe-url")
    p.add_argument("--check-only", action="store_true", help="приёмка без изменения панели")
    args = p.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9.-]+", args.domain):
            raise rw.Failure("неверный домен")
        if any(not re.fullmatch(r"[a-z][a-z0-9-]{0,20}", n) for n in args.node):
            raise rw.Failure("неверное имя ноды")
        api = rw.Api(args.panel_url)
        rw.admin(api, args.mode, args.admin_file, args.token_file)
        if args.check_only:
            check(api, args.domain, args.node, args.subscription_file)
            return 0
        short = ensure(api, args.domain, args.node)
        if not short:
            raise rw.Failure("не получен shortUuid пробного пользователя")
        url = args.panel_url + "/api/sub/" + short
        if Path(args.subscription_file).exists():
            if rw.secure(args.subscription_file) != url:
                raise rw.Failure("пробная подписка изменилась; не перезаписываю")
        else:
            rw.save(args.subscription_file, url + "\n")
        print("Remnawave: подписка готова (URL в защищённом файле)")
        return 0
    except (rw.Failure, OSError, KeyError, TypeError, ValueError) as e:
        print(f"Remnawave: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
