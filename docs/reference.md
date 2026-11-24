# Справочник

Единый справочник фактов продукта 321r: порты, пути, службы, контейнеры, доменная схема,
расписание и версии. Все имена точные — используйте их при разборе сбоёв и при
обращении в поддержку. Если другая документация расходится с этим файлом — верен этот файл.

## Порты

**Открыты наружу (ufw):**

| Порт | Что |
|---|---|
| 80/tcp | редиректы |
| 443/tcp | ресурсы Pangolin (SNI-прокси gerbil) |
| 8443/tcp | дашборд Pangolin (запасной вход) |
| 2053/tcp | запасной вход дашборда (тот же entrypoint, что и 8443) |
| 2087/tcp | Xray Reality (запасной канал VPN, слушает remnanode на host-сети) |
| 53/udp | встроенная DNS кластера (rate-limit 30/сек) |
| 51820/udp | WireGuard-туннели сайтов (gerbil) |
| 21820/udp | gerbil relay |
| 51821/udp | меш AmneziaWG |
| 2222/tcp | SSH (ключи, fail2ban) |

**Только mesh (10.66.0.0/24):** 3000 (внутренний UI Pangolin), 3004 (gerbil API),
6379 (Valkey), 5432–5499 (PostgreSQL-инстансы), 27017–27099 (MongoDB-инстансы),
9120 (Komodo Core), 2377/7946/4789 (Swarm).

**Маскировка VPN/Telegram:** 9446 (Xray VLESS+TLS+fallback) и 8446 (mtproto) — host-порты
за passthrough; правило ufw только от docker-подсети traefik. Важно: правило
`8446/tcp Anywhere` — ошибка, маска не должна светиться на отдельном порту; удаляйте его.
9447/8448 — nginx-заглушки, слушают 0.0.0.0, но извне закрыты ufw (доступны с ноды и из
mesh). 2099 — API remnanode (от 172.16.0.0/12). Метрики панели Remnawave —
127.0.0.1:3002 (3001 — Uptime Kuma через Swarm ingress на всех нодах).

**Контейнерные порты** (DOCKER-USER считает их, не host-маппинги): 3000, 8443, 2053, 80/443.

## Пути и файлы

| Что | Где |
|---|---|
| Корень состояния кластера | `/etc/db/` |
| Секреты (пароли, токены) | `/etc/db/secrets/<app>.env` (umask 077, chmod 600) |
| Манифест кластера (без секретов) | `/etc/db/cluster.yml` (копия `cluster.yml` из репо) |
| Реестр приложений БД | `/etc/db/apps.d/<app>.yaml` |
| Карта узлов (alias → mesh-IP → имя в Swarm) | `/etc/db/nodes.map` |
| Лог установки | `/var/log/321r-install.log` |
| Лог авто-продолжения после ребута | `/var/log/321r-install-resume.log` |
| Памятка владельца | `/root/321r-pamyatka-*.txt` (права 600) |
| Скрипты на нодах | `/usr/local/bin/` (db-guard, ddns, backup-321r, unhealthy-restart, pg-rebuild-standby, mongo-rs, app-move, app-member, db-proxy-sync и др.) |
| Конфиг меша + HeaderProtectionKey | `/etc/amnezia/amneziawg/wg0.conf` (HPK — секрет кластера) |
| Ключи WG | `/etc/wireguard/privatekey`, `/etc/wireguard/publickey` |
| Стек Pangolin | `/opt/pangolin/` (pangolin + gerbil + traefik) |
| Прокси БД (haproxy) | `/opt/db/proxy/haproxy.cfg` |
| Данные PG | `/var/lib/dbdata/`, WAL-архив `/var/lib/pgwal/`, бэкапы `/var/lib/pgbackup/` |
| Репозитории бэкапов соседей | `/var/lib/backup-repos/<нода>` |
| CF-токен DDNS | `/etc/ddns.env` |
| CF-токен для сертификатов traefik | `/etc/db/secrets/traefik-cf.env` |
| mtproto | `/opt/mtproto-proxy/` (`config.toml`; осторожно: mtbuddy uninstall сносит каталог) |

## Службы (systemd)

| Служба | Что делает |
|---|---|
| `awg0` | поднимает меш AmneziaWG (wg0) |
| `db-guard` + `db-guard.timer` | здоровье БД, назначение первичного, фенсинг (тик каждые 10 с) |
| `docker-user` | правила DOCKER-USER для контейнерных публикаций |
| `reresolve-dns` + `reresolve-dns.timer` | перезапрос DNS для endpoint'ов меша (каждые 45 с) |
| `tgbot` | Telegram-бот панель управления (на control-ноде) |
| `321r-newt` | агент-туннель Pangolin (Newt) на ноде |
| `mtproto-proxy` | маска Telegram-прокси (mtproto.zig) |
| `periphery` | агент Komodo на каждой ноде |
| `zabbix-agent2` | агент мониторинга (только активные проверки) |
| `certbot.timer` | автопродление сертификатов маски |

## Контейнеры

| Контейнер | Образ | Роль |
|---|---|---|
| `pg-<app>` | postgres:17-alpine | экземпляр PostgreSQL приложения |
| `mongod-<app>` | mongo:7 | экземпляр MongoDB приложения (RS `rs_<app>`) |
| `db-proxy` | haproxy:3.0-alpine | диспетчер портов на VIP → текущий первичный |
| `pangolin` | fosrl/pangolin:ee-postgresql | панель Pangolin |
| `gerbil` | fosrl/gerbil | SNI-прокси и туннели (владеет :443) |
| `traefik` | traefik:v3.7.11 | программируемый роутинг, ACME, маскировка |
| `valkey` | valkey/valkey:8-alpine | кэш Pangolin |
| `remnawave` | remnawave/backend:3 | панель VPN |
| `remnawave-redis` | valkey/valkey:9-alpine | кэш Remnawave |
| `remnawave-subscription-page` | remnawave/subscription-page | страница подписок |
| `remnanode` | remnawave/node | VPN-нода (Xray, host-сеть) |
| `zabbix-server`, `zabbix-web` | zabbix/*:alpine-7.0-latest | мониторинг (native HA) |

## VIP и адресация

- **VIP БД: 10.66.0.99/32** — на wg0 каждой ноды, постоянный адрес приложений к БД.
  За ним haproxy → текущий первичный; смена первичного невидима приложениям.
- Меш: 10.66.0.0/24, по адресу на ноду. Часы на всех нодах — UTC.
- SSH: порт 2222, только ключи (`PasswordAuthentication no`).
- Кластер: минимум 3 узла; все узлы — менеджеры Swarm (правило 2K+1: чтобы пережить
  K потерь, менеджеров ≥ 2K+1).

## Доменная схема (`<base>` — ваш базовый домен)

| Имя | Запись | Что |
|---|---|---|
| `<base>`, `*.<base>` | A × N (multi-A) | все IP нод; браузер сам перебирает |
| `dns.<base>` | A × N | DNS-хаб кластера |
| `tg.<base>` | A × N | маска Telegram-прокси (секрет один, ходим на любую ноду) |
| `<узел>.<base>` | A | живая запись ноды (правит ddns) |
| `vpn-<узел>.<base>` | A | маска VPN-ноды (только своя, wildcard нельзя) |
| `pangolin.<base>`, `komodo.<base>`, `rem.<base>`, `app.<base>` | CNAME → `dns.<base>` | панели и запасные имена |
| `_acme-challenge.<base>`, `cname.<base>`, `site.<base>` | NS → `dns.<base>` | делегация для DNS-01 и wildcard |
| `sub.<base>` | покрыт wildcard | страница подписок Remnawave |
| `zabbix.<base>` | покрыт wildcard | UI Zabbix (локальный Traefik-роутер ноды) |

Только «серое облако» Cloudflare (proxied: false). Полная таблица и правила —
в [dns-and-tls.md](dns-and-tls.md).

## Расписание (cron и таймеры)

| Период | Что | Где |
|---|---|---|
| каждые 10 сек | `db-guard.sh` — здоровье БД, назначения, фенс | systemd `db-guard.timer` |
| каждые 45 сек | `reresolve-dns.sh` — перезапрос DNS endpoint'ов меша | systemd `reresolve-dns.timer` |
| каждые 2 мин + @reboot | `ddns.sh` — обновление своих A-записей | `/etc/cron.d/ddns` |
| каждую минуту | `unhealthy-restart.sh` — перезапуск зависших контейнеров | `/etc/cron.d/321r` |
| ночью (окно 03:10, 03:40, 04:10… по нодам) | `backup-321r.sh` — снимок на 2 соседние ноды | `/etc/cron.d/321r` |
| 09:05 ежедневно | `backup-beacon.sh` — свежесть бэкапов | `/etc/cron.d/321r` |
| вс 05:20 | `backup-verify.sh` — проверка восстановления | `/etc/cron.d/321r` |
| 09:00 ежедневно | `tg-digest.sh` — дайджест владельцу (control-нода) | `/etc/cron.d/321r` |
| каждые 5 мин (каждый час) | `tg-watch.sh` — дозор: диск/RAM/load/сертификаты/бэкапы | `/etc/cron.d/321r` |
| 1-го числа 06:05 | `tg-export.sh` — экспорт данных в Telegram | `/etc/cron.d/321r` |
| каждые 30 мин | `pangolin-wildcard-repair.sh` — лечение wildcard-записей | root crontab |
| каждую минуту | `zabbix-321r-snapshot.py` (только с Zabbix) | `/etc/cron.d/321r-zabbix-snapshot` |
| ежедневно | certbot — автопродление сертификатов маски | `certbot.timer` |

## Версии компонентов

| Компонент | Версия | Примечание |
|---|---|---|
| OS | Debian 12/13, Ubuntu 22.04/24.04/26.04 | можно смешивать в кластере; нужна полная VM (KVM/VMware/Hyper-V) |
| AmneziaWG | 3.1 (PPA, DKMS) | ядро ≥ 6.7; при устаревшем ядре установщик ставит `linux-image-amd64`+`linux-headers-amd64` и перезагружает ноду |
| PostgreSQL | postgres:17-alpine | max_connections=200, mem_limit 512m, jit=off |
| MongoDB | mongo:7 | кэш WiredTiger 0.256, RS `rs_<app>` |
| haproxy | haproxy:3.0-alpine | контейнер `db-proxy`, mem_limit 128m |
| traefik | v3.7.11 | `network_mode: service:gerbil` |
| Valkey | 8-alpine (Pangolin), 9-alpine (Remnawave) | одиночные |
| Zabbix | 7.0 LTS | server + web (alpine), агент zabbix-agent2 |
| mtproto.zig | mtbuddy v1.15.4 | установка с `--no-dpi` |
| Remnawave | панель `remnawave/backend:3`, нода `remnawave/node` (Xray) | API ноды :2099, Reality :2087, маска :9446 |

## Быстрая сверка фактов

```bash
# на любой ноде:
ip -4 addr show wg0            # 10.66.0.X + 10.66.0.99
docker node ls                 # все узлы Ready
ss -ltn | grep 99              # слушает 10.66.0.99:порт
systemctl is-active db-guard.timer
crontab -l; ls /etc/cron.d/    # ddns, 321r
```

```bash
# с машины установки:
./install/install.sh --check   # полная автоприёмка кластера
```
