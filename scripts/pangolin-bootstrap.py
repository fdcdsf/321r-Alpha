#!/usr/bin/env python3
"""Первый админ и организация Pangolin через штатное API (только чистая установка).

Не сохраняет setup token, не печатает пароль. Повторный запуск не меняет существующий
аккаунт; если он создан вручную, нужен отдельный доступ к API для дальнейшей настройки.
"""

import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request


class ApiError(RuntimeError):
    pass


class PangolinApi:
    def __init__(self, base):
        if not re.fullmatch(r"https://[a-zA-Z0-9.-]+(?::[0-9]+)?", base):
            raise ValueError("Pangolin URL должен быть HTTPS-адресом без пути")
        self.base = base + "/api/v1"
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def request(self, method, path, body=None):
        payload = None if body is None else json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            self.base + path,
            data=payload,
            method=method,
            headers={"Content-Type": "application/json", "X-CSRF-Token": "x-csrf-protection"},
        )
        # Pangolin API за traefik иногда роняет соединение (на практике:
        # живой API отвечал 200, но раз в несколько запросов — сброс через ~5 с).
        # Сетевые сбои повторяем, ошибки сервера — нет, они детерминированы.
        reply = None
        last = None
        for attempt in range(4):
            try:
                with self.opener.open(req, timeout=25) as res:
                    reply = json.load(res)
                break
            except urllib.error.HTTPError as exc:
                # Ответ сервера не показываем: некоторые ошибки отражают данные запроса.
                raise ApiError(f"Pangolin API {path}: HTTP {exc.code}") from None
            except (urllib.error.URLError, TimeoutError) as exc:
                last = exc
                if attempt < 3:
                    time.sleep(3 * (attempt + 1))
        if reply is None:
            raise ApiError(f"Pangolin API {path} недоступен ({type(last).__name__})") from None
        if reply.get("error") or reply.get("success") is False:
            raise ApiError(f"Pangolin API {path}: операция отклонена")
        return reply.get("data")


def load_credentials(path, email):
    path = Path(path)
    if path.exists():
        st = path.stat()
        if os.name == "posix" and st.st_mode & 0o077:
            raise ApiError("слишком широкие права файла учётных данных Pangolin")
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("email") != email:
            raise ApiError("email администратора отличается от сохранённого; не перезаписываю")
        return data
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Генерируем до POST: после сетевого сбоя повторный запуск использует тот же пароль.
    password = "Aa1!" + secrets.token_urlsafe(32)
    data = {"email": email, "password": password}
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        json.dump(data, file)
    return data


def setup_token():
    result = subprocess.run(
        ["docker", "logs", "--tail", "4000", "pangolin"],
        capture_output=True, text=True, timeout=20, check=False,
    )
    found = re.findall(r"^Token:\s*(\S+)\s*$", result.stdout + result.stderr, re.M)
    if not found:
        raise ApiError("setup token не найден в docker logs pangolin")
    return found[-1]


def apply_license(api, license_file):
    if not license_file:
        return
    path = Path(license_file)
    if not path.is_file():
        raise ApiError("файл лицензии Pangolin не найден")
    if os.name == "posix" and path.stat().st_mode & 0o077:
        raise ApiError("слишком широкие права файла лицензии Pangolin")
    key = path.read_text(encoding="utf-8").strip()
    if not key or len(key) > 255:
        raise ApiError("ключ лицензии пуст или слишком длинный")
    existing = api.request("GET", "/license/keys")
    if existing:
        # Не заменять лицензию владельца при повторном запуске установщика.
        print("Pangolin: лицензия уже заведена; не меняю")
        return
    status = api.request("POST", "/license/activate", {"licenseKey": key})
    if isinstance(status, dict) and status.get("isLicenseValid") is False:
        raise ApiError("Pangolin не подтвердил действительность лицензии")
    print("Pangolin: лицензия активирована")


def bootstrap(api, email, org_id, secret_file, license_file=None):
    state = api.request("GET", "/auth/initial-setup-complete") or {}
    if not state.get("complete"):
        creds = load_credentials(secret_file, email)
        api.request("PUT", "/auth/set-server-admin", {
            "setupToken": setup_token(), "email": creds["email"], "password": creds["password"],
        })
        print("Pangolin: администратор создан (пароль — только в защищённом файле)")
    else:
        print("Pangolin: первичная настройка уже пройдена, аккаунт не трогаю")
        if not Path(secret_file).exists():
            print("Pangolin: админ создан вручную; для автоматизации сайтов нужен отдельный API-доступ")
            return False

    creds = load_credentials(secret_file, email)
    api.request("POST", "/auth/login", creds)
    apply_license(api, license_file)
    orgs = api.request("GET", "/orgs")
    if isinstance(orgs, dict):
        orgs = orgs.get("orgs", [])
    if any(org.get("orgId") == org_id for org in orgs or []):
        print("Pangolin: организация уже существует, не меняю")
        return True
    if orgs:
        raise ApiError("есть другая организация: не создаю вторую поверх ручной настройки")
    defaults = api.request("GET", "/pick-org-defaults")
    if not isinstance(defaults, dict) or not defaults.get("subnet") or not defaults.get("utilitySubnet"):
        raise ApiError("Pangolin не вернул диапазоны организации; создание остановлено")
    api.request("PUT", "/org", {
        "orgId": org_id, "name": "321r", "subnet": defaults["subnet"],
        "utilitySubnet": defaults["utilitySubnet"],
    })
    print("Pangolin: организация создана")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--org-id", default="cluster")
    parser.add_argument("--secret-file", default="/etc/db/secrets/pangolin-admin.json")
    parser.add_argument("--license-file", help="файл с ключом EE (chmod 600); без файла активация пропускается")
    parser.add_argument("--check", action="store_true", help="только проверить статус онбординга")
    args = parser.parse_args()
    try:
        api = PangolinApi(args.url)
        if args.check:
            state = api.request("GET", "/auth/initial-setup-complete") or {}
            print("Pangolin: первичная настройка " + ("пройдена" if state.get("complete") else "не пройдена"))
            return 0
        return 0 if bootstrap(api, args.email, args.org_id, args.secret_file, args.license_file) else 2
    except (ApiError, ValueError) as exc:
        print(f"Pangolin: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
