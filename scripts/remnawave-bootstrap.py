#!/usr/bin/env python3
"""Минимальный профиль Remnawave; локальный и внешний режим используют один API.

Локальная панель: --mode install --panel-url https://rem.<домен>
Внешняя панель: --mode connect --panel-url https://rem.<домен> --token-file <файл>
Ни пароль, ни токен не попадают в аргументы команд или в вывод.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import sys
import urllib.error
import urllib.request


class Failure(Exception):
    pass


def secure(path):
    p = Path(path)
    if not p.is_file() or (os.name == "posix" and p.stat().st_mode & 0o077):
        raise Failure(f"нет защищённого файла: {p}")
    return p.read_text(encoding="utf-8").strip()


def save(path, content):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)


class Api:
    def __init__(self, url):
        if not url.startswith("https://") or "/" in url[8:]:
            raise Failure("нужен HTTPS-адрес панели без пути")
        self.url = url.rstrip("/") + "/api"
        self.token = None
        self.api_token = False

    def call(self, path, method="GET", data=None, browser=False):
        body = json.dumps(data).encode() if data is not None else None
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if browser and not self.api_token:
            headers["X-Remnawave-Client-Type"] = "browser"
        req = urllib.request.Request(self.url + path, method=method, data=body, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                value = json.load(r)
        except urllib.error.HTTPError as e:
            raise Failure(f"{method} {path}: HTTP {e.code}") from None
        except (urllib.error.URLError, TimeoutError):
            raise Failure(f"{method} {path}: панель недоступна") from None
        if not isinstance(value, dict) or "response" not in value:
            raise Failure(f"{method} {path}: неожиданный ответ панели")
        return value["response"]


def admin(api, mode, admin_file, token_file):
    if mode == "connect":
        api.token = secure(token_file)
        api.api_token = True
        print("Remnawave: режим существующей панели (локальную не создаю)")
        return
    status = api.call("/auth/status")
    if not Path(admin_file).exists() and not status.get("isRegisterAllowed"):
        raise Failure("панель уже зарегистрирована, но пароль не сохранён; нужен API-токен")
    if not Path(admin_file).exists():
        creds = {"username": "admin", "password": "Aa1!" + secrets.token_urlsafe(30)}
        save(admin_file, json.dumps(creds))
    creds = json.loads(secure(admin_file))
    if status.get("isRegisterAllowed"):
        result = api.call("/auth/register", "POST", creds)
        print("Remnawave: администратор зарегистрирован")
    else:
        result = api.call("/auth/login", "POST", creds)
        print("Remnawave: администратор уже зарегистрирован")
    api.token = result["accessToken"]


def ensure_profile(api):
    profiles = api.call("/config-profiles", browser=True)
    found = next((p for p in profiles.get("configProfiles", []) if p.get("name") == "321r-mask"), None)
    if found:
        print("Remnawave: профиль 321r-mask уже есть")
        return found["uuid"]
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "masked-vless", "port": 9446, "protocol": "vless",
            "settings": {"clients": [], "decryption": "none", "fallbacks": [{"dest": 9447}]},
            "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {
                "certificates": [{"certificateFile": "/etc/letsencrypt/live/mask/fullchain.pem",
                                  "keyFile": "/etc/letsencrypt/live/mask/privkey.pem"}],
                "alpn": ["http/1.1"]}},
        }],
        "outbounds": [{"tag": "direct", "protocol": "freedom"}],
    }
    result = api.call("/config-profiles", "POST", {"name": "321r-mask", "config": config}, browser=True)
    print("Remnawave: профиль 321r-mask создан")
    return result["uuid"]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=["install", "connect"], required=True)
    p.add_argument("--panel-url", required=True)
    p.add_argument("--admin-file", default="/etc/db/secrets/remnawave-admin.json")
    p.add_argument("--token-file", default="/etc/db/secrets/remnawave-api.token")
    a = p.parse_args()
    try:
        api = Api(a.panel_url)
        admin(api, a.mode, a.admin_file, a.token_file)
        uuid = ensure_profile(api)
        print("Remnawave: профиль готов (UUID сохранится через API; в лог не вывожу)")
        return 0
    except (Failure, ValueError, KeyError, json.JSONDecodeError) as e:
        print(f"Remnawave: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
