#!/usr/bin/env python3
"""Идемпотентно создать сайты Newt в Pangolin и сохранить одноразовые секреты.

Запускать на первой VPS после scripts/pangolin-bootstrap.py. Секрет существующего
сайта Pangolin повторно НЕ показывает: без локального файла не перезаписываем сайт.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location(
    "pangolin_bootstrap", Path(__file__).with_name("pangolin-bootstrap.py")
)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def save_site(path, data, endpoint):
    newt_id, secret = data.get("newtId"), data.get("secret")
    if not newt_id or not secret or not all(
        re.fullmatch(r"[a-zA-Z0-9_-]+", value) for value in (newt_id, secret)
    ):
        raise bootstrap.ApiError("Pangolin не вернул корректные Newt ID/secret")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(f"PANGOLIN_ENDPOINT={endpoint}\nNEWT_ID={newt_id}\nNEWT_SECRET={secret}\n")


def ensure_sites(api, org, endpoint, aliases, secret_dir):
    result = api.request("GET", f"/org/{org}/sites")
    existing = result.get("sites", []) if isinstance(result, dict) else result
    if not isinstance(existing, list):
        raise bootstrap.ApiError("Pangolin вернул неожиданный список сайтов")
    by_name = {site["niceId"]: site for site in existing}
    for alias in aliases:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,20}", alias):
            raise bootstrap.ApiError("недопустимое имя ноды")
        name = f"cluster-{alias}"
        path = Path(secret_dir) / f"newt-{alias}.env"
        if name in by_name:
            if not path.is_file():
                raise bootstrap.ApiError(f"сайт {name} уже есть, но его секрет не сохранён — не пересоздаю")
            if os.name == "posix" and path.stat().st_mode & 0o077:
                raise bootstrap.ApiError(f"права секрета сайта {name} слишком широкие")
            print(f"Pangolin: сайт {name} уже существует, секрет сохранён")
            continue
        if path.exists():
            raise bootstrap.ApiError(f"секрет для {name} есть, но сайта в панели нет — нужен разбор вручную")
        created = api.request("PUT", f"/org/{org}/site", {
            "name": name, "niceId": name, "type": "newt",
        })
        # Сохранить секрет сразу: API выдаёт его только в этом ответе.
        save_site(path, created, endpoint)
        print(f"Pangolin: сайт {name} создан (секрет только в файле)")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", required=True)
    p.add_argument("--org-id", default="cluster")
    p.add_argument("--admin-file", default="/etc/db/secrets/pangolin-admin.json")
    p.add_argument("--secret-dir", default="/etc/db/secrets")
    p.add_argument("--node", action="append", required=True)
    p.add_argument("--status", action="store_true", help="только статус сайтов, без изменений")
    args = p.parse_args()
    try:
        creds = json.loads(Path(args.admin_file).read_text(encoding="utf-8"))
        api = bootstrap.PangolinApi(args.url)
        api.request("POST", "/auth/login", creds)
        if args.status:
            data = api.request("GET", f"/org/{args.org_id}/sites")
            sites = data.get("sites", []) if isinstance(data, dict) else data
            for alias in args.node:
                site = next((s for s in sites if s.get("niceId") == f"cluster-{alias}"), None)
                print(f"cluster-{alias}: " + ("online" if site and site.get("online") else "OFFLINE"))
            return 0 if all(any(s.get("niceId") == f"cluster-{n}" and s.get("online") for s in sites) for n in args.node) else 1
        ensure_sites(api, args.org_id, args.url, args.node, args.secret_dir)
    except (bootstrap.ApiError, OSError, ValueError, KeyError) as exc:
        # Не печатать сетевые ответы/содержимое файлов секретов.
        print(f"Pangolin-сайты: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
