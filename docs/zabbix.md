# Zabbix

Zabbix 7.0 LTS — опциональный слой мониторинга с историей, графиками и HA ([zabbix.com](https://www.zabbix.com/documentation/7.0/en/manual/concepts/server/ha)). Он не заменяет Telegram-бота и db-guard, а дополняет их ([monitoring.md](monitoring.md)). Включается переменной `ZABBIX_MODE=install` в инвентаре установки; профиль S его не включает — сервер и веб-интерфейс занимают память постоянно.

## Что ставится

| Компонент | Где | Детали |
|---|---|---|
| `zabbix-server` | control-нода и одна standby-нода | native HA, общий каталог конфигов `/opt/zabbix` |
| `zabbix-web` | все ноды | локально на `127.0.0.1:8081` |
| `zabbix-agent2` | все ноды | только активные проверки, внешнего :10050 нет |
| PG-БД `zabbix` | штатный реплицируемый слой 321r | порт 5434 через VIP 10.66.0.99 |

Требования: ≥ 4 ГБ RAM на нодах сервера (установщик проверяет), приложение `zabbix` в инвентаре (placement задаёт ноды БД и HA-пару). Никаких отдельных БД-контейнеров Zabbix не создаётся — используется штатный слой PostgreSQL кластера ([databases.md](databases.md)).

## Как зайти

- URL: `https://zabbix.<домен>` — локальный HTTP-роутер Traefik каждой ноды ведёт на её `zabbix-web`. Это надёжнее маршрутов Pangolin: последние привязаны к exit node, и Newt может подключиться к другому узлу — получите 503 при живом вебе.
- Логин `Admin`, пароль — в `/etc/db/secrets/zabbix-admin.json` на нодах и в памятке владельца (`bash install/handover.sh`).
- Служебный пользователь `321r-bot` паролем не логинится — он только для алертов.

## HA и ресурсы

- `HANodeName` уникален у каждого сервера, `NodeAddress` — mesh-IP:10051. Оба сервера видят одну БД, работает только **active**; standby держит HA manager и почти не опрашивает сеть. Переключение при отказе — около 60 секунд, двух active не бывает.
- Агенты шлют данные на оба узла: `ServerActive=<mesh control>:10051;<mesh standby>:10051`. Точка с запятой означает **один** HA-кластер; запятая создала бы два независимых.
- Фронтенд не задаёт `ZBX_SERVER_HOST`: активный сервер берётся из общей БД.
- Потребление памяти после прогрева: server ~53 МиБ (active) / ~4 МиБ (standby), web ~44 МиБ, pg-zabbix 58–155 МиБ, агент2 ~28 МиБ на ноду.

## Что мониторится

| Слой | Ключи | Где собирается |
|---|---|---|
| Контейнеры Docker | `docker/*` | каждая нода |
| systemd-юниты | `systemd/*` | каждая нода (только enabled) |
| Базы данных | `docker/pg-*`, `docker/mongod-*`, `vip/*` | контейнеры + VIP:порт отвечает |
| VIP приложений | `vip/*` | только control |
| Swarm-сервисы и узлы | `swarm/*`, `swarm-node/*` | только control |
| HTTP приложений | `http/*` | свои маски `vpn-*` на каждой ноде; общие — только control |
| HA Zabbix | `cluster.ha.active`, `cluster.ha.standby` | только control |
| Ресурсы хоста | шаблон Linux | CPU, RAM, диск, сеть, inode |
| Свежесть бэкапа | `backup/fresh` | каждая нода, допуск 36 ч |

Важно: готовность, репликацию и кворум баз **не дублируем** — за них отвечает db-guard с собственными алертами. `backup/fresh` — второй эшелон: первый — алерты самого бэкапа и дозор ([backups.md](backups.md)); Zabbix ловит уже мёртвый cron или подряд идущие отказы.

Кластерные факты (VIP, swarm, HA, общие HTTP) пишутся в снимок **только с control-ноды** — иначе одна авария дала бы три одинаковых алерта. Если `control:` в `cluster.yml` не разобран, факты пишутся везде: лучше дубль, чем слепая зона.

## Свои метрики кластера

- Root-скрипт `zabbix-321r-snapshot.py` (cron каждую минуту, `/etc/cron.d/321r-zabbix-snapshot`) собирает статусы в `/var/lib/zabbix-321r/snapshot.json`. В снимке только имена и 0/1, без секретов.
- Агент читает снимок через `zabbix-321r-metric.sh` (UserParameter в `/etc/zabbix/zabbix_agent2.d/321r.conf`): `cluster.services.discovery`, `cluster.service.status[*]`, `cluster.ha.active`, `cluster.ha.standby`. Агент не получает доступ к `docker.sock`.
- Автообнаружение `cluster.services.discovery` — каждые 5 минут, элементы живут 1 час. Шаблоны: `Linux by Zabbix agent active` + собственный `321r services`.
- Триггеры HA: «нет ровно одного active» (High) и «нет резерва» (Warning).

## HTTP-проверки

Список ссылок — `/etc/db/secrets/http-checks.txt` (chmod 600, свой на каждой ноде): маски `vpn-<нода>` проверяются везде, общие приложения (`komodo`, `pangolin`, `zabbix`, `rem`, `sub`) — только на control. Проверки идут через **локальный** Traefik (`--resolve host:443:127.0.0.1`), поэтому не зависят от DNS и от выбора exit node. Одна неудача — ещё не поломка: перед «0» идёт повтор через 3 секунды.

## Алерты в Telegram

- Медиатип **Script** (`321r Telegram`) вызывает `tg-relay.sh` внутри контейнера `zabbix-server`. Скрипт читает `/run/secrets/zabbix-telegram.env` (зеркало `/etc/db/secrets/zabbix-telegram.env`, chmod 640 под uid контейнера) и шлёт через Bot API. Токен не попадает в БД Zabbix, git или логи.
- Действие `321r: алерты в Telegram`: группа хостов `321r`, severity ≥ Average, recovery-сообщение «восстановлено».
- Пользователь `321r-bot` намеренно **не** в группе `Zabbix administrators` — иначе встроенное действие дублировало бы сообщения.

## Приёмка

Read-only проверка всего слоя (HA, метрики, автообнаружение, алерты):

```bash
python3 /opt/zabbix/zabbix-check.py --control <control-нода> \
  --node <нода-1> --node <нода-2> --node <нода-3>
```

Скрипт проверяет: ровно один active и есть standby, свежие HA-элементы, uptime и статусы сервисов на каждом хосте, наличие кластерных проверок на control, включённые медиатип, пользователя и действие.

## Подводные камни API (если ведёте настройку вручную)

- `mediatype.message_templates` — массив `{eventsource, recovery, subject, message}`, поле называется `recovery`, а не `type`.
- `user.update` принимает `medias` (не `user_medias`); `sendto` для Script — строка, не массив.
- `action.create`: `opmessage` не принимает `subject`/`message` при `default_msg=1`; `recovery_operations` не принимает `evaltype`.
- `trigger.create` не принимает `hostid` — хост берётся из выражения.
- Таблица HA-узлов в БД — `ha_node` (не `hanode`): `status` 3 = active, 0 = standby.
- `problem.get` не принимает `selectHosts`/`recent` вместе с `time_from`.

## Известные ограничения

- Зоны ответственности: db-guard — кворум и здоровье баз, дозор — тренды и ресурсы, Zabbix — общий надзор и история. Дублирование алертов сведено к минимуму, но не запрещено вручную.
- Подтверждение опасных действий из интерфейса Zabbix (через бота) не реализовано — опасные операции выполняйте через бота или по SSH ([monitoring.md](monitoring.md)).
