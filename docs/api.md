# API и полезные команды

Шпаргалки по API панелей и команды повседневной эксплуатации. Если что-то ведёт себя не так —
к [troubleshooting.md](troubleshooting.md); сценарии отказов — [operations.md](operations.md).

## Pangolin API (панель, порт 443/8443)

Сессия — из браузера (куки логина); **обязательные заголовки**:
`X-CSRF-Token: x-csrf-protection` (статическая строка) и `Content-Type: application/json`.
База: `https://pangolin.<домен>`; `<org>` — идентификатор организации (в установщике — `cluster`).

| Задача | Вызов |
|---|---|
| Список сайтов-агентов | `GET /api/v1/org/<org>/sites` |
| Список ресурсов | `GET /api/v1/org/<org>/resources` |
| Создать домен | `PUT /api/v1/org/<org>/domain` |
| Удалить домен | `DELETE /api/v1/org/<org>/domain/{id}` |
| Создать ресурс | `PUT /api/v1/org/<org>/resource` (name, subdomain, domainId, mode) |
| Обновить ресурс | `PUT /api/v1/resource` |
| Добавить цель | `PUT /api/v1/resource/{id}/target` (siteId, ip, port, method, hc*) |
| Обновить цель | `POST /api/v1/target/{id}` |
| Цели ресурса | `GET /api/v1/resource/{id}/targets` |
| DNS-записи | `GET/DELETE /api/v1/org/<org>/dns-records` |

Полный набор HC-полей для цели (обязательно! — цель с неполным HC или вовсе без HC не
маршрутизируется):

```json
{"siteId": 1, "mode": "http", "method": "https", "ip": "192.168.1.100", "port": 8006,
 "enabled": true, "pathMatchType": "prefix", "path": "/",
 "rewritePathType": "prefix", "rewritePath": "/", "priority": 1,
 "hcEnabled": true, "hcPath": "/", "hcScheme": "https", "hcMode": "http",
 "hcHostname": "192.168.1.100", "hcPort": 8006, "hcInterval": 5,
 "hcUnhealthyInterval": 30, "hcTimeout": 5, "hcMethod": "GET", "hcFollowRedirects": true}
```

## Komodo API (Core, порт 9120)

**Тело — ПРОСТОЕ (params), НЕ wrapped** (wrapped на голом `/auth` даёт 405!).

```bash
# вход:
curl -s -X POST http://127.0.0.1:9120/auth/login/LoginLocalUser \
  -H 'Content-Type: application/json' -d '{"username":"admin","password":"..."}'
# → извлечь токен: grep '"jwt"'; дальше: -H "Authorization: <токен>"
```

| Задача | Вызов |
|---|---|
| Список серверов | `POST /read/ListServers` |
| Список Swarm | `POST /read/ListSwarms` |
| Создать Swarm | `POST /write/CreateSwarm` |
| Создать стек | `POST /write/CreateStack` |
| Выкатить стек | `POST /execute/DeployStack` |
| Onboarding-ключ | `POST /write/CreateOnboardingKey` |

Важно: Pangolin API и Komodo API — разные продукты с разными API, не путать.

## Telegram-бот

Служба `tgbot.service` на control-ноде; алерты шлёт любая нода (`tg-alert.sh`). Данные —
снимок раз в сутки или кнопка «Обновить». Меню: Статус, Внешние точки, Приложения,
Контейнеры, Бэкапы, Базы данных, Серверы, Логи, WARP/mtproto, Действия, Помощь. Опасные
действия — с подтверждением: бэкап сейчас, верификация восстановления, выгрузка на физический
диск, аварийный режим.

```text
/start /menu /help /status /services /backup /db /disk /logs /apps /containers /warp
/ping                     # проверка бота
/restart <контейнер>      # перезапуск контейнера на ноде бота (с подтверждением)
```

Кнопка «Заменить WARP-конфиг»: отправьте файл `.conf` ответом — конфиг применится к ноде
с автооткатом, если туннель не поднимется.

## Команды на ноде

```bash
# --- манифест кластера ---
cluster.sh status          # манифест + живое состояние всех серверов
cluster.sh apply           # разложить манифест по нодам, включить бота на control-ноде

# --- базы данных ---
db-add.sh <app>                    # инстансы БД по реестру /etc/db/apps.d/<app>.yaml
app-member.sh add <app> <нода>     # добавить инстанс (данные копируются сами)
app-member.sh remove <app> <нода>  # убрать инстанс (первичный нельзя — сначала перенос)
app-move.sh <app> <откуда> <куда>  # перенос инстанса (даунтайм ~10–20 с; pg и mongo)
mongo-rs.sh status <app>           # состав реплика-сети Mongo (add/remove/prio/stepdown)
db-proxy-sync.sh <app>             # пересобрать блок прокси по реестру (на всех нодах)
pg-rebuild-standby.sh [app]        # пересборка стендбая (~1 мин; app по умолчанию pangolin)

# --- PG: роли и репликация ---
docker exec -u postgres pg-<app> psql -U postgres -tAc "SELECT pg_is_in_recovery()"
docker exec -u postgres pg-<app> psql -U postgres -tAc \
  "SELECT application_name, client_addr, state FROM pg_stat_replication"
# запись через VIP:
. /etc/db/secrets/<app>.env
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" pg-<app> psql -h 10.66.0.99 -p <порт> -U postgres

# --- Mongo (ТОЛЬКО отдельным контейнером!) ---
docker run --rm --network host mongo:7 mongosh \
  "mongodb://10.66.0.99:27017/?replicaSet=rs_komodo" --quiet --eval 'rs.status().members.map(m=>m.name+":"+m.stateStr)'

# --- здоровье и сеть ---
docker node ls
docker ps --format '{{.Names}}\t{{.Status}}' | sort
journalctl -t db-guard -n 30 --no-pager
wg show | grep -E 'peer|latest handshake'
docker node inspect <swarm-имя> --format '{{json .Spec.Labels}}'
iptables -L DOCKER-USER -n --line-numbers

# --- Pangolin ---
cd /opt/pangolin && docker compose up -d --force-recreate gerbil traefik   # только вместе!
/usr/local/bin/pangolin-wildcard-repair.sh <ip>

# --- бэкапы ---
backup-321r.sh              # снимок сейчас
backup-verify.sh            # верификация: restic check + restore + smoke-тест PG
tg-watch.sh --check         # проблемы дозора без алертов
tg-export.sh                # выгрузка копий в чат для записи на физический носитель

# --- аварийный режим ---
survival.sh                 # = db-guard.sh --survival-now; живой первичный через VIP → отмена
```

## WARP и маска Telegram (mtproto.zig)

```bash
warp-321r.sh up|down|status|stats       # управление WARP-туннелем (обход блокировок Telegram)
warp-321r.sh set-config <файл.conf>     # замена WARP-конфига с проверкой и автооткатом
mtbuddy links                           # готовая FakeTLS-ссылка прокси (секрет один на кластер)
mtbuddy setup tunnel --iface warp /etc/amnezia/amneziawg/warp.conf
```

Важно: `mtbuddy uninstall` сносит `/opt/mtproto-proxy/` вместе с конфигом и секретом —
выгружайте конфиг заранее. `mtbuddy install` может открыть ufw-порт — закрывайте обратно
(маскировка требует закрытого порта). Подробнее — [vpn.md](vpn.md).

## Полезные команды с рабочей машины

```bash
curl -sk --resolve <имя>:443:<ip> https://<имя>/ -o /dev/null -w "via <ip>: %{http_code}\n"
echo | openssl s_client -connect <имя>:443 -servername <имя> 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
dig +short <имя>
ssh -p 2222 root@<ip>       # порт 2222, вход ключом
```
