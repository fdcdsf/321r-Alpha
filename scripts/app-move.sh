#!/usr/bin/env bash
# 321r: перенос члена БД-группы на другую ноду БЕЗ значимого даунтайма (дизайн docs/databases.md).
# Использование: app-move.sh <app> <откуда> <куда>   (алиасы нод: a/b/c из nodes.map)
#
# Шаги: подготовка инстанса на целевой ноде (secrets+compose) → копия данных
# (pg-rebuild-standby: basebackup через VIP) → синхронизация → смена placement в apps.d
# На всех нодах → (если уезжал ПЕРВИЧНЫЙ — плановый фейловер ~10 с) → вывод старого.
# mongo — пока не поддержан (см. docs/databases.md). Назад откатить так же легко: move в обратную сторону.
set -euo pipefail
APP="${1:?использование: app-move.sh <app> <from> <to>}"
FROM="${2:?нужен алиас ноды-источника}"
TO="${3:?нужен алиас ноды-цели}"

ME2IP() { awk -v s="$1" '$1==s{print $2}' /etc/db/nodes.map; }
FIP="$(ME2IP "$FROM")"; TIP="$(ME2IP "$TO")"
[ -n "$FIP" ] && [ -n "$TIP" ] || { echo "нет такой ноды в nodes.map" >&2; exit 1; }
[ "$FROM" != "$TO" ] || { echo "источник и цель совпадают" >&2; exit 1; }

ENGINE="$(sed -n 's/^engine: *//p' "/etc/db/apps.d/$APP.yaml" | sed 's/#.*//; s/ *$//')"
[ "$ENGINE" = pg ] || { echo "пока поддержан только pg (engine=$ENGINE)" >&2; exit 1; }
PORT="$(sed -n 's/^port: *//p' "/etc/db/apps.d/$APP.yaml" | sed 's/#.*//; s/ *$//')"
PLACEMENT="$(sed -n 's/^placement: *//p' "/etc/db/apps.d/$APP.yaml" | sed 's/#.*//; s/ *$//')"
echo "== перенос $APP: $FROM ($FIP) -> $TO ($TIP), placement $PLACEMENT =="
NEWPLACE="$(echo "$PLACEMENT" | sed "s/$FROM/$TO/")"

sshx() { ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$1" "$2"; }

# 1) подготовка целевой ноды: секреты + compose (свяжем порт и mesh-IP цели)
echo "-- готовлю инстанс на $TO..."
sshx "$TIP" "mkdir -p /opt/db/pg-$APP /var/lib/dbdata/pg-$APP /var/lib/pgwal/$APP"
scp -P 2222 -o BatchMode=yes -q "root@$FIP:/etc/db/secrets/$APP.env" "/tmp/$APP.env" \
  && scp -P 2222 -o BatchMode=yes -q "/tmp/$APP.env" "root@$TIP:/etc/db/secrets/$APP.env" \
  && sshx "$TIP" "chmod 600 /etc/db/secrets/$APP.env" && rm -f "/tmp/$APP.env"
scp -P 2222 -o BatchMode=yes -q "root@$FIP:/opt/db/pg-$APP/docker-compose.yml" "/tmp/$APP-compose.yml"
sed -i "s/$FIP:/$TIP:/" "/tmp/$APP-compose.yml"   # bind на mesh-IP целевой ноды
scp -P 2222 -o BatchMode=yes -q "/tmp/$APP-compose.yml" "root@$TIP:/opt/db/pg-$APP/docker-compose.yml"
rm -f "/tmp/$APP-compose.yml"

# 2) копия данных: тот же штатный скрипт, что и для лечения таймлайнов
echo "-- копирую данные (basebackup через VIP)..."
sshx "$TIP" "/usr/local/bin/pg-rebuild-standby.sh $APP" | tail -2

# 3) смена placement на всех нодах (реестр — источник правды для db-guard)
echo "-- обновляю placement -> $NEWPLACE на всех нодах..."
for n in $(awk '{print $1}' /etc/db/nodes.map); do
  nip="$(ME2IP "$n")"
  sshx "$nip" "sed -i \"s|^placement:.*|placement: $NEWPLACE  # перенос app-move: $FROM->$TO|\" /etc/db/apps.d/$APP.yaml"
done

# 4) если уезжал ПЕРВИЧНЫЙ — детерминированный плановый фейловер:
#    promote цели → перенос метки → проверка VIP → стоп источника (~10-20 с для клиентов)
if sshx "$FIP" "docker exec -u postgres pg-$APP psql -U postgres -tAc 'SELECT pg_is_in_recovery()'" | grep -q '^f$'; then
  echo "-- $FROM держал ПЕРВИЧНЫЙ: плановый фейловер на $TO..."
  sshx "$TIP" "docker exec -u postgres pg-$APP pg_ctl promote >/dev/null 2>&1 && rm -f /var/lib/dbdata/pg-$APP/standby.signal && echo '  promote на $TO выполнен'"
  sshx "$TIP" "/usr/local/bin/db-guard.sh --claim-now $APP $TO >/dev/null 2>&1 && echo '  метка первичного перенесена на $TO'"
  for i in $(seq 1 12); do
    r="$(sshx "$TIP" "docker exec -e PGPASSWORD=\$(grep ^POSTGRES_PASSWORD= /etc/db/secrets/$APP.env | cut -d= -f2) pg-$APP psql -h 10.66.0.99 -p $PORT -U postgres -tAc 'SELECT NOT pg_is_in_recovery()'" 2>/dev/null || echo '?')"
    [ "$r" = t ] && { echo "  VIP уже ведёт на новый первичный ($i)"; break; }
    sleep 5
  done
else
  echo "-- $FROM был стендбаем — фейловер не нужен"
fi

# 5) вывод старого инстанса (данные остаются до ручной очистки — страховка)
echo "-- останавливаю старый инстанс на $FROM (данные НЕ удаляю)..."
sshx "$FIP" "cd /opt/db/pg-$APP && docker compose down >/dev/null 2>&1 && echo '  остановлен'"

echo "== ГОТОВО: $APP теперь в placement $NEWPLACE =="
echo "проверка: pg-rebuild-standby НЕ нужен; стендбаи видны в pg_stat_replication на первичном"
