# Домены, DNS и сертификаты

Весь кластер живёт на одном домене `<base>` (например, `example.com`): одна схема записей, один хаб и два разных механизма сертификатов. Записи заводятся один раз, дальше их поддерживает автоматика — при смене IP узла ручных правок не нужно. Здесь — схема зоны, выдача сертификатов и ловушки wildcard-доменов.

См. также: [Pangolin](pangolin.md), [Замена сервера](replace-node.md), [Troubleshooting](troubleshooting.md).

## Схема зоны: один хаб

Идея: правишь одну строку — весь кластер находит всё. Все записи — **серое облако (DNS only), TTL Auto**. Оранжевое облако и туннели Cloudflare не включать нигде.

| Имя | Тип | Значение | Назначение |
|---|---|---|---|
| `<alias>.<base>` | A | IP узла | живая запись ноды (держит `ddns.sh`) |
| `vpn-<alias>.<base>` | A | IP узла | маска VPN-ноды (своя на каждый узел) |
| `dns.<base>` | A ×N | IP всех нод | хаб + адрес встроенной DNS Pangolin |
| `<base>`, `*.<base>` | A ×N | IP всех нод | apex и ресурсы второго уровня без новых записей |
| `tg.<base>` | A ×N | IP всех нод | маска mtproto-прокси |
| `pangolin`, `komodo`, `rem`, `app`.<base> | CNAME | `dns.<base>` | дашборды и сервисы |
| `_acme-challenge.<base>` | NS | `dns.<base>` | делегирование для DNS-01 (wildcard) |
| `cname.<base>`, `site.<base>` | NS | `dns.<base>` | служебные зоны встроенной DNS Pangolin |

CNAME создаются один раз и больше не редактируются: Cloudflare разворачивает их в все IP хаба (multi-A сохраняется). Wildcard `*.<base>` покрывает имена второго уровня (`nov.<base>` и подобные) без отдельных записей.

## Кто поддерживает записи

- **`ddns.sh`** (cron каждые 2 мин, `/etc/cron.d/ddns`) обновляет на своей ноде две записи: свою A `<alias>.<base>` и свою строку в хабе `dns.<base>`. Конфиг — `/etc/ddns.env` (токен Cloudflare, зона, имя ноды). При смене IP узла — **0 ручных правок**.
- **Шаг `dns` установщика** создаёт и расчищает зону по инвентарю: multi-A у `<base>`, `*.<base>`, `dns.<base>`, `tg.<base>`, NS-делегирования, A-записи нод. Лишние A при сужении кластера он удалит сам; записи `vpn-<alias>.<base>` удаляются вручную.

## Сертификаты: два механизма (не путать)

| Механизм | Для чего | Как | Где настроен |
|---|---|---|---|
| **certbot + Cloudflare API** (DNS-01) | дашборд Pangolin `pangolin.<base>` | `certbot certonly --dns-cloudflare`, файл `dynamic/panel_cert.yml` (tls.certificates) | шаг `pangolin` установщика, `scripts/panel-cert-reload.sh` |
| **Встроенный ACME Pangolin** (`cert_mode: pangolin`) | wildcard-сертификат ресурсов `*.<base>` | DNS-01 через свою встроенную DNS (NS `_acme-challenge.<base>` → `dns.<base>`) | `privateConfig.yml`, **только на одной ноде** |

Дашборд берёт именно файловый сертификат: ACME traefik под NS-делегированием `_acme-challenge` не работает — traefik пишет TXT через API Cloudflare, а проверка идёт в делегированную DNS, где этого TXT нет. Продление certbot делает сам (`certbot.timer`), deploy-hook `scripts/panel-cert-reload.sh` подхватывает новый PEM без перезапуска.

## Почему HTTP-01 не работает (важно)

Let's Encrypt проверяет **все** A-записи имени (multi-VA). При multi-A challenge живёт только на ноде-заявителе, остальные отвечают 404 → отказ выдачи. Поэтому **все сертификаты — только DNS-01**; это же закрывает wildcard `*.<base>`.

## Wildcard-ресурсы: три бага Pangolin и лечение

Симптом: ресурсы `name.<base>` отвечают 404, сертификат — «TRAEFIK DEFAULT CERT». Причина — не маршрутизация, а сломанная выдача сертификата (баги Pangolin v2.3.4):

1. **Двойная звёздочка**: к уже wildcard-домену добавляется `*.` ещё раз → Let's Encrypt получает `*.*.<base>` и отказывает, строка остаётся в `failed`.
2. **Плейсхолдер** «Server IP Address» в `dnsRecords.value` → валидация домена никогда не проходит («Domain is not verified»).
3. **`failed` не сбрасывается**: повторная выдача блокируется навсегда.

Лечение — автоматика:

```bash
/usr/local/bin/pangolin-wildcard-repair.sh <один из IP A-записей домена>
```

Скрипт идемпотентен, чинит все три бага, пишет в БД через VIP. Шаг `pangolin` ставит его в cron раз в 30 минут. Правила: запускать **после каждого рестарта Pangolin** — синхронизация конфига при старте пересоздаёт плейсхолдер; БД править только через VIP `10.66.0.99` (на стендбай запись упадёт с «read-only transaction»); не рестартовать Pangolin сразу после ручной правки БД.

## Что нужно в конфиге для wildcard

- `config.yml` (одинаков на всех нодах): домен `<base>` с `prefer_wildcard_cert: true` и `cert_resolver: "letsencrypt"`, `disable_config_managed_domains: false`.
- `privateConfig.yml`: `cert_mode: "pangolin"`, `use_pangolin_dns: true`, NS-имена `dns.<base>` / `cname.<base>` / `site.<base>`; `enable_acme_client: true` — **только на одной ноде кластера** (по умолчанию — control-нода).
- `server.secret` — одинаковый на всех нодах.
- DNS заранее: multi-A на `<base>` и `*.<base>`, NS на `_acme-challenge.<base>`.

## Домен нового сервиса

1. Wildcard-режим (основной): ресурс `name.<base>` создаётся в панели — DNS-записи не нужны.
2. CNAME-режим (запасной): CNAME `name` → `dns.<base>` + ресурс на этот поддомен.
3. Цель ресурса — сайт-агент (`cluster-<alias>`) и `ip:port`; health-check обязателен и полный: без него цель не маршрутизируется и ресурс отвечает 404 ([troubleshooting.md](troubleshooting.md)).

## Проверка

```bash
nslookup a.example.com          # IP своего узла
nslookup pangolin.example.com   # развёрнутый CNAME — все IP нод, порядок не важен

echo | openssl s_client -connect pangolin.example.com:443 -servername pangolin.example.com 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# ожидание: DNS:<base>, DNS:*.<base>
```

Изменения вступают в силу не мгновенно: выдача Let's Encrypt и кэш traefik — дайте пару минут.

## Ловушки

- Два механизма сертификатов — не путать; ACME-клиент Pangolin не включать на нескольких нодах (коллизии TXT при одновременной выдаче).
- Не смешивать UI-домен и config-домен для одного `base_domain`.
- `pangctl clear-certificates` удаляет все сертификаты, включая валидные.
- traefik работает в `network_mode: service:gerbil` — пересоздавать их только вместе: `docker compose up -d --force-recreate gerbil traefik`.
- Wildcard нельзя использовать как маску VPN-ноды: у каждого узла своя `vpn-<alias>.<base>`.
