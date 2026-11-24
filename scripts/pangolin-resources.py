#!/usr/bin/env python3
"""Создать HTTP-ресурсы Pangolin и цели с полным HC-набором без дубликатов.

--spec имя:сайт:ip:порт:метод:hc-порт:hc-путь (например komodo:b:127.0.0.1:9120:http:9120:/)
Для домашней Remnawave указывайте домашний сайт и адрес внутри домашней сети.
"""
import argparse
import importlib.util
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location(
    "pangolin_bootstrap", Path(__file__).with_name("pangolin-bootstrap.py")
)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def items(api, path, key):
    data = api.request("GET", path)
    values = data.get(key, []) if isinstance(data, dict) else data
    if not isinstance(values, list):
        raise bootstrap.ApiError(f"Pangolin {path}: неверный формат списка")
    return values


def parse_spec(text):
    parts = text.split(":", 6)
    if len(parts) != 7:
        raise ValueError("ожидается имя:сайт:ip:порт:метод:hc-порт:hc-путь")
    sub, site, ip, port, method, hc_port, hc_path = parts
    if not all(re.fullmatch(r"[a-z][a-z0-9-]{0,30}", value) for value in (sub, site)):
        raise ValueError("неверное имя ресурса или сайта")
    ipaddress.IPv4Address(ip)
    if not 1 <= int(port) <= 65535 or not 1 <= int(hc_port) <= 65535:
        raise ValueError("неверный номер порта")
    if method not in ("http", "https") or not hc_path.startswith("/"):
        raise ValueError("неверный метод или HC-путь")
    return sub, site, ip, int(port), method, int(hc_port), hc_path


def ensure_resources(api, org, domain, specs):
    sites = items(api, f"/org/{org}/sites", "sites")
    domains = items(api, f"/org/{org}/domains", "domains")
    available = [d for d in domains if d.get("baseDomain") == domain and d.get("verified")]
    if not available:
        raise bootstrap.ApiError(f"домен {domain} ещё не подтверждён в Pangolin")
    domain_id = available[0]["domainId"]
    resources = items(api, f"/org/{org}/resources", "resources")
    for text in specs:
        sub, alias, ip, port, method, hc_port, hc_path = parse_spec(text)
        site = next((s for s in sites if s.get("niceId") == f"cluster-{alias}"), None)
        if not site or not site.get("online"):
            raise bootstrap.ApiError(f"cluster-{alias} отсутствует или offline — ресурс {sub} не создаю")
        host = f"{sub}.{domain}"
        resource = next((r for r in resources if r.get("fullDomain") == host), None)
        if resource is None:
            resource = api.request("PUT", f"/org/{org}/resource", {
                "name": sub, "mode": "http", "domainId": domain_id, "subdomain": sub,
            })
            resources.append(resource)
            print(f"Pangolin: ресурс {host} создан")
        rid = resource["resourceId"]
        targets = items(api, f"/resource/{rid}/targets", "targets")
        if any(t.get("siteId") == site["siteId"] and t.get("ip") == ip
               and t.get("port") == port and t.get("method") == method for t in targets):
            print(f"Pangolin: цель {host} уже существует, не меняю")
            continue
        api.request("PUT", f"/resource/{rid}/target", {
            "siteId": site["siteId"], "mode": "http", "method": method,
            "ip": ip, "port": port, "hcEnabled": True, "hcPath": hc_path,
            "hcScheme": method, "hcMode": "http", "hcHostname": ip,
            "hcPort": hc_port, "hcInterval": 5, "hcUnhealthyInterval": 30,
            "hcTimeout": 5, "hcMethod": "GET", "hcFollowRedirects": True,
        })
        print(f"Pangolin: цель {host} создана с HC")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", required=True)
    p.add_argument("--org-id", default="cluster")
    p.add_argument("--domain", required=True)
    p.add_argument("--admin-file", default="/etc/db/secrets/pangolin-admin.json")
    p.add_argument("--spec", action="append", required=True)
    p.add_argument("--repair-ip", help="IP одной A-записи домена для штатного wildcard-repair")
    args = p.parse_args()
    try:
        creds = json.loads(Path(args.admin_file).read_text(encoding="utf-8"))
        api = bootstrap.PangolinApi(args.url)
        api.request("POST", "/auth/login", creds)
        ensure_resources(api, args.org_id, args.domain, args.spec)
        if args.repair_ip:
            ipaddress.IPv4Address(args.repair_ip)
            subprocess.run(
                ["/usr/local/bin/pangolin-wildcard-repair.sh", args.repair_ip],
                stdout=subprocess.DEVNULL, check=True, timeout=60,
            )
            print("Pangolin: wildcard-repair после создания ресурсов выполнен")
    except (bootstrap.ApiError, OSError, ValueError, KeyError) as exc:
        print(f"Pangolin-ресурсы: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
