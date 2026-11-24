#!/usr/bin/env python3
"""Мелкий root cron: только статусы, без секретов и постоянного процесса."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlparse


OUT = Path('/var/lib/zabbix-321r/snapshot.json')


def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=12, check=True).stdout
    except (subprocess.SubprocessError, OSError):
        return ''


def run_rc(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=12).returncode
    except (subprocess.SubprocessError, OSError):
        return 1


def host_alias():
    return socket.gethostname().split('.')[0]


def control_alias():
    """Alias control-ноды из /etc/db/cluster.yml (пусто — если не разобрали)."""
    try:
        for line in Path('/etc/db/cluster.yml').read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.match(r'^\s*control:\s*([A-Za-z][A-Za-z0-9_-]*)', line)
            if m:
                return m.group(1).strip()
    except OSError:
        pass
    return ''


def is_control():
    """Кластерные факты (VIP, swarm, HA) пишем ТОЛЬКО с control-ноды: иначе одна
    авария дала бы три одинаковых алерта (по числу VPS). Если control не разобрали —
    пишем факты везде: лучше дубль, чем слепая зона."""
    control = control_alias()
    return host_alias() == control if control else True


def zabbix_ha():
    """Число активных/резервных узлов HA из общей БД Zabbix. None при недоступности."""
    env = Path('/etc/db/secrets/zabbix.env')
    if not env.is_file():
        return None
    password = ''
    for line in env.read_text(encoding='utf-8', errors='replace').splitlines():
        if line.startswith('APP_PASSWORD='):
            password = line.split('=', 1)[1].strip().strip('"').strip("'")
            break
    if not password:
        return None
    out = run('docker', 'exec', '-e', 'PGPASSWORD=' + password, 'pg-zabbix', 'psql',
              '-X', '-qAt', '-h', '10.66.0.99', '-p', '5434', '-U', 'zabbix', '-d', 'zabbix',
              '-c', 'SELECT status,count(*) FROM ha_node GROUP BY status')
    if not out.strip():
        return None
    counts = {}
    for line in out.splitlines():
        parts = line.strip().split('|')
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            counts[int(parts[0])] = int(parts[1])
    return counts


def collect():
    services = {}
    # ha держим ВНЕ services: LLD завёл бы на них неверные триггеры (=0),
    # а HA-контроль — это «ровно один active», и делают его отдельные элементы.
    ha = {}
    for line in run('docker', 'ps', '-a', '--format', '{{.Names}}|{{.State}}|{{.Status}}').splitlines():
        parts = line.split('|', 2)
        if len(parts) == 3:
            name, state, health = parts
            # Swarm оставляет завершённые task-контейнеры с новыми именами.
            # Это НЕ сервисы, иначе каждый rolling update вызывает ложный алерт.
            # Сами сервисы Swarm проверяются отдельно — см. ниже.
            if re.search(r'\.\d+\.[a-z0-9]{8,}$', name):
                continue
            if name and len(name) < 128:
                services['docker/' + name] = int(state == 'running' and '(unhealthy)' not in health)
    for name in ('db-guard.timer', 'tgbot.service', '321r-newt.service',
                 'mtproto-proxy.service', 'certbot.timer', 'periphery.service',
                 'warp.service'):
        if Path('/etc/systemd/system/' + name).exists() or Path('/lib/systemd/system/' + name).exists():
            if run('systemctl', 'is-enabled', name).strip() not in ('enabled', 'static'):
                continue  # например, tgbot отключён на не-control нодах
            services['systemd/' + name] = int(run('systemctl', 'is-active', name).strip() == 'active')
    for path in Path('/etc/db/apps.d').glob('*.yaml'):
        name = path.stem
        if not (name.isalnum() and len(name) < 80):
            continue
        # Здоровье БД (готовность, репликация, кворум) — это db-guard каждые 10 с,
        # у него уже есть свои алерты: здесь НЕ дублируем. И НЕ зовём mongosh/
        # pg_isready ради готовности — `docker exec` живёт ВНУТРИ cgroup контейнера
        # и подбрасывает пик ~200 МБ, из-за чего арбитр mongo уходил в cgroup-OOM
        # (dmesg: task=mongosh) и всё флапало. Контейнеры БД и так видны как
        # docker/pg-* и docker/mongod-*.
        if is_control():
            text = path.read_text(encoding='utf-8', errors='replace')
            match = re.search(r'^port:\s*(\d+)\s*$', text, re.M)
            if match:
                try:
                    with socket.create_connection(('10.66.0.99', int(match.group(1))), timeout=2):
                        services['vip/' + name] = 1
                except OSError:
                    services['vip/' + name] = 0
    stamp = Path('/var/lib/pgbackup/last_ok')
    # Бэкапы запускаются по ночам; до первого полного окна на новой ноде это
    # честный 0, а не «всё нормально». Допуск 36 часов (разнос окон + задержки).
    services['backup/fresh'] = int(stamp.is_file() and time.time() - stamp.stat().st_mtime < 36 * 3600)

    # HTTP-доступность приложений через ЛОКАЛЬНЫЙ роутер traefik (127.0.0.1):
    # так не зависит от DNS и от того, к какому exit node подключился Newt.
    # Список пишет установщик; он свой на каждой ноде — свои маски проверяются
    # везде, а общие приложения кладутся только в файл control-ноды.
    checks = Path('/etc/db/secrets/http-checks.txt')
    if checks.is_file():
        for line in checks.read_text(encoding='utf-8', errors='replace').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '|' not in line:
                continue
            name, url = (p.strip() for p in line.split('|', 1))
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', name) or not url.startswith('https://'):
                continue
            host = urlparse(url).hostname
            if not host:
                continue
            # Одна неудача — ещё не поломка: TLS-хендшейк через traefik к живому
            # бэкенду иногда проседает и даёт минутный флап ().
            args = ('curl', '-sS', '-o', '/dev/null', '--fail', '--max-time', '12',
                    '--resolve', host + ':443:127.0.0.1', url)
            rc = run_rc(*args)
            if rc != 0:
                time.sleep(3)
                rc = run_rc(*args)
            services['http/' + name] = int(rc == 0)

    if is_control():
        # Swarm: task-контейнеры отфильтрованы выше, поэтому мёртвый сервис
        # остаётся БЕЗ единого контейнера — проверяем сами сервисы и узлы.
        for line in run('docker', 'service', 'ls', '--format', '{{.Name}}|{{.Replicas}}').splitlines():
            if '|' not in line:
                continue
            name, rep = line.split('|', 1)
            name, rep = name.strip(), rep.strip()
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', name):
                continue
            cur, _, want = rep.partition('/')
            ok = int(cur.isdigit() and want.isdigit() and want != '0' and cur == want)
            services['swarm/' + name] = ok
        for line in run('docker', 'node', 'ls', '--format', '{{.Hostname}}|{{.Status}}|{{.Availability}}').splitlines():
            parts = line.split('|')
            if len(parts) != 3:
                continue
            node, status, avail = (p.strip() for p in parts)
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', node):
                continue
            services['swarm-node/' + node] = int(status == 'Ready' and avail == 'Active')
        # HA Zabbix: 3 = active, 0 = standby. -1 = БД/кластер недоступен (тоже тревога).
        counts = zabbix_ha()
        ha['active'] = counts.get(3, 0) if counts is not None else -1
        ha['standby'] = counts.get(0, 0) if counts is not None else -1
    return {'services': services, 'ha': ha}


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    fd, path = tempfile.mkstemp(prefix='.snapshot-', dir=str(OUT.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(collect(), f, separators=(',', ':'))
            f.write('\n')
        os.chmod(path, 0o644)  # здесь только имена и 0/1, без секретов
        os.replace(path, OUT)
    finally:
        if os.path.exists(path):
            os.unlink(path)


if __name__ == '__main__':
    main()
