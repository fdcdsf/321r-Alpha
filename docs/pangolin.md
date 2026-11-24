# Pangolin: доступ к сервисам, сертификаты, агенты

Pangolin публикует сервисы кластера на именах второго уровня (`komodo.<домен>`, `rem.<домен>`, …) с wildcard-сертификатом и маршрутизирует трафик через туннели Newt. Кластерная установка держит по одному экземпляру панели на каждой ноде поверх общей базы данных. Здесь описаны устройство, wildcard и DNS-01, ресурсы с health-check, агенты Newt и лечение типовых проблем.

## Как устроен Pangolin-кластер

На каждой ноде работают три контейнера (`/opt/pangolin/docker-compose.yml`):

- `pangolin` — панель и API (память ограничена: `mem_limit: 512m`);
- `gerbil` — SNI-прокси и туннели: WireGuard 51820/udp, relay 21820/udp, DNS 53/udp, API 3004 (только сеть кластера);
- `traefik` — живёт в сетевом пространстве gerbil (`network_mode: service:gerbil`).

Общие службы: PostgreSQL (VIP `10.66.0.99:5432`, база `pangolin`) и Valkey (mesh-адрес control-ноды, порт 6379). `server.secret` обязан быть одинаковым на всех нодах — он шифрует сертификаты в базе. Конфиги рендерятся на нодах из шаблонов `deploy/pangolin/*.tmpl` в `/opt/pangolin/config/`; пароли серверы не покидают.

Дашборд: `https://pangolin.<домен>` — через порт 443 (основной путь) и запасные 8443/2053 (нестандартные порты могут резаться). Внутренний порт 3000 наружу не выходит.

## Wildcard и DNS-01

Записи DNS заводятся заранее (см. [dns-and-tls.md](dns-and-tls.md)):

| Запись | Тип | Значение |
|---|---|---|
| `<домен>`, `*.<домен>` | A | IP всех нод (мульти-A) |
| `_acme-challenge.<домен>` | NS | `dns.<домен>` (встроенная DNS Pangolin) |
| `cname.<домен>`, `site.<домен>` | NS | `dns.<домен>` |

Действует два разных механизма сертификатов — не путайте их:

1. **Встроенный ACME Pangolin** (`cert_mode: "pangolin"`) — сертификаты ресурсов (wildcard `*.<домен>`), DNS-01 через собственную DNS-зону, хранение в PostgreSQL. Клиент ACME (`enable_acme_client: true`) включается **только на одной ноде** кластера — иначе выдачи конфликтуют. Для wildcard нужна подходящая EE-лицензия (панель → Settings; без неё сертификат остаётся pending).
2. **certbot + Cloudflare API (DNS-01)** — файловые сертификаты: дашборд `pangolin.<домен>` (`deploy/pangolin/panel_cert.yml` в `config/dynamic/`) и отдельные ресурсы (`install/pangolin-resource-certs.sh <ресурс>` — сертификат нужен на каждой ноде).

Почему не ACME traefik и не HTTP-01: NS-делегирование `_acme-challenge` уводит DNS-01 проверку от Cloudflare к встроенной DNS (там нет TXT, записанного traefik), а HTTP-01 при multi-A проверяет все IP и получает 404 от чужих нод. Рутеры дашборда поэтому настроены как `tls: {}` **без** `certResolver` — иначе traefik вечно долбит сломанный ACME и тратит лимиты Let's Encrypt. Продление certbot подхватывает deploy-хук `scripts/panel-cert-reload.sh`.

## Ресурсы и health-check

Ресурс — это `<имя>.<домен>` с целью «сайт + ip:порт». Создавайте цели только полным HC-набором (`scripts/pangolin-resources.py --spec "имя:сайт:ip:порт:метод:hc-порт:hc-путь"`):

```
hcEnabled: true, hcPath, hcScheme, hcMode: http, hcHostname, hcPort,
hcInterval: 5, hcUnhealthyInterval: 30, hcTimeout: 5, hcMethod: GET, hcFollowRedirects: true
```

Важно: цель с неполным HC или вовсе без строки HC **не маршрутизируется** (фильтр `hcHealth <> 'unhealthy'` не пропускает и NULL). UI-мастер создаёт неполный HC — полагайтесь на API. Цель для сервиса с самоподписанным сертификатом — `method: https`.

## Агенты Newt

- На каждой ноде кластера — сайт `cluster-<имя>` типа Newt. Секрет одноразовый: API выдаёт его только при создании, поэтому он сразу сохраняется в `/etc/db/secrets/newt-<имя>.env` и копируется в `/etc/newt/newt.env` (600).
- Установка: `install/pangolin-agents.sh`; служба `321r-newt.service` с `ExecStartPre=/usr/local/bin/321r-newt-wait.sh` — агент ждёт здоровый локальный Pangolin до 270 с. Без этого ожидания WebSocket может показаться online, а туннель не создастся — HC останется unhealthy.
- Домашний сервер за серым IP: в LXC (Docker не нужен) запустите `install/home-newt.sh`, введя адрес панели, ID и секрет сайта. Newt создаёт исходящий туннель — входящие порты открывать не требуется.
- Статус сайтов: `python3 /opt/321r/scripts/pangolin-sites.py --status --node <имя> …`.

## Запуск и перезапуски

- Чистая база: миграции выполняет **одна** нода (установщик сначала её, ждёт `healthy`, затем остальные, и только после них gerbil/traefik). Одновременный первый запуск всех трёх панелей конфликтует в миграциях — проигравшие остаются `unhealthy` навсегда (Docker не перезапускает unhealthy-контейнеры).
- Пересоздавать gerbil и traefik **только вместе**: `docker compose up -d --force-recreate gerbil traefik`. Одиночный restart gerbil рвёт сеть traefik.
- `max_connections` в PostgreSQL кластера — норма 200: три пула Pangolin по числу нод быстро исчерпают маленький лимит.
- Файл маскировки VPN/Telegram `/opt/pangolin/config/dynamic/mask_config.yml` — отдельный от конфигов Pangolin; после переустановки каталога `config/dynamic` его нужно восстановить (см. [vpn.md](vpn.md)). Адрес хоста в нём сверяйте с `docker network inspect pangolin` — подсеть Docker у каждой ноды своя.
- Базу правьте только через VIP: запись на standby упадёт с «read-only transaction». И не рестартуйте pangolin сразу после ручной правки — синхронизация при старте пересоздаст испорченные записи.

## Частые проблемы

| Симптом | Причина | Лечение |
|---|---|---|
| `TRAEFIK DEFAULT CERT` на дашборде | ACME traefik не проходит DNS-01 под NS-делегированием | Файловый certbot-сертификат (`panel_cert.yml`), роутеры `tls: {}` без certResolver |
| Ресурсы wildcard-домена отвечают 404, wildcard-сертификата нет | Заказ wildcard-сертификата падает (двойная звёздочка в идентификаторе ACME) | `scripts/pangolin-wildcard-repair.sh <IP>`; штатно — cron раз в 30 минут |
| «Domain is not verified», ресурсы не создаются | В `dnsRecords` осталась плейсхолдерная строка вместо IP | Тот же `pangolin-wildcard-repair.sh` |
| Сертификат «залип» в failed, повторная выдача блокируется | failed-состояние не сбрасывается штатно | Тот же repair (снимает `failed`/`tries`); `pangctl clear-certificates` не использовать — он удаляет и валидные сертификаты |
| `503 no available server` | За туннелем никто не слушает порт цели: агент живёт со старым конфигом | Перезапустите агента Newt или перевыпустите секрет сайта |
| `404 page not found` от gerbil | Цель unhealthy/без HC и отсечена, либо маршруты не сошлись | Полный HC-набор; дайте маршрутам сойтись (1–2 мин) или перезапустите gerbil отстающей ноды |
| Pangolin «жив, но unhealthy» после сбоя базы | Docker не перезапускает unhealthy-контейнеры | Cron `unhealthy-restart.sh` каждую минуту (штатно стоит на нодах) |
| Падает с «SASL: client password must be a string» | `APP_PASSWORD` не прописан на всех нодах в `/etc/db/secrets/pangolin.env` | Раздайте пароль всем нодам (установщик делает это автоматически) |
| Newt online, но HC unhealthy после ребута | Агент стартовал раньше панели | `newt-wait.sh` как `ExecStartPre` (штатно) |
| После правки базы плейсхолдер вернулся | Рестарт pangolin пересоздаёт `dnsRecords` | Запустите repair после каждого рестарта |

## Проверка

```bash
# SAN сертификата должен содержать <домен> и *.<домен>
echo | openssl s_client -connect <ресурс>.<домен>:443 -servername <ресурс>.<домен> 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# ресурс обязан отвечать через КАЖДЫЙ IP (мульти-A)
curl -s --resolve <ресурс>.<домен>:443:<IP-ноды> https://<ресурс>.<домен>/ -o /dev/null -w '%{http_code}\n'
```

Изменения сертификатов вступают в силу не мгновенно: дайте пару минут Let's Encrypt и кэшу traefik.

Подробнее: [dns-and-tls.md](dns-and-tls.md) — DNS и сертификаты, [resources.md](resources.md) — профили ресурсов, [vpn.md](vpn.md) — маскировка поверх traefik, [monitoring.md](monitoring.md) — проверки доступности.
