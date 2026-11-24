#!/usr/bin/env bash
# 321r: перенос члена БД-группы на другую ноду БЕЗ значимого даунтайма
# (docs/databases.md). PostgreSQL и MongoDB поддерживаются одинаково.
# Использование: app-move.sh <app> <откуда> <куда>   (алиасы нод из nodes.map)
#
# pg:    подготовка инстанса → копия данных (pg-rebuild-standby: basebackup через VIP)
#        → смена placement → (если уезжал ПЕРВИЧНЫЙ — плановый фейловер ~10 с) → вывод старого.
# mongo: подготовка инстанса → rs.add (данные догоняются сами) → (если уезжал ПЕРВИЧНЫЙ —
#        плановый stepDown на новый узел) → смена placement → rs.remove → вывод старого.
# Назад откатить так же легко: move в обратную сторону.
set -euo pipefail
APP="${1:?использование: app-move.sh <app> <from> <to>}"
FROM="${2:?нужен алиас ноды-источника}"
TO="${3:?нужен алиас ноды-цели}"

HERE="$(cd "$(dirname "$0")" && pwd)"
YAML="/etc/db/apps.d/${APP}.yaml"
val() { sed -n "s/^$1: *//p" "$YAML" 2>/dev/null | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
map_ip() { awk -v s="$1" '$1==s{print $2}' /etc/db/nodes.map; }

ENGINE="$(val engine | tr -d ' ')"
PORT="$(val port | tr -d ' ')"
PLACEMENT="$(val placement)"
ARB="$(val arbiter | tr -d ' ')"
[ -n "$ENGINE" ] && [ -n "$PORT" ] || { echo "реестр $YAML: нужны engine и port" >&2; exit 1; }
case "$ENGINE" in pg|mongo) ;; *) echo "неизвестный engine: $ENGINE" >&2; exit 1 ;; esac

FIP="$(map_ip "$FROM")"; TIP="$(map_ip "$TO")"
[ -n "$FIP" ] && [ -n "$TIP" ] || { echo "нет такой ноды в nodes.map" >&2; exit 1; }
[ "$FROM" != "$TO" ] || { echo "источник и цель совпадают" >&2; exit 1; }
case " $PLACEMENT " in *" $FROM "*) ;; *) echo "$FROM не в placement [$PLACEMENT]" >&2; exit 1 ;; esac
case " $PLACEMENT " in *" $TO "*) echo "$TO уже в placement [$PLACEMENT]"; exit 0 ;; esac

echo "== перенос $APP ($ENGINE): $FROM ($FIP) -> $TO ($TIP), placement $PLACEMENT =="
NEWPLACE="$(echo "$PLACEMENT" | sed "s/$FROM/$TO/")"

run_on() { # $1 = alias, $2 = команда
  ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$(map_ip "$1")" "$2"
}
ensure_helpers() {
  local h ip; ip="$(map_ip "$1")"
  for h in mongo-rs.sh db-proxy-sync.sh; do
    [ -f "$HERE/$h" ] || continue
    ssh -n -p 2222 -o BatchMode=yes "root@$ip" "test -x /usr/local/bin/$h" 2>/dev/null \
      || scp -P 2222 -o BatchMode=yes -q "$HERE/$h" "root@$ip:/usr/local/bin/$h"
    ssh -n -p 2222 -o BatchMode=yes "root@$ip" "chmod +x /usr/local/bin/$h" 2>/dev/null || true
  done
}
copy_env() { # секреты приложения: донор — источник переноса
  scp -P 2222 -o BatchMode=yes -q "root@$FIP:/etc/db/secrets/$APP.env" "/tmp/$APP.env" \
    && scp -P 2222 -o BatchMode=yes -q "/tmp/$APP.env" "root@$TIP:/etc/db/secrets/$APP.env" \
    && run_on "$TO" "chmod 600 /etc/db/secrets/$APP.env" && rm -f "/tmp/$APP.env"
}
copy_compose() { # $1 = каталог инстанса (/opt/db/pg-<app> или /opt/db/mongo-<app>)
  scp -P 2222 -o BatchMode=yes -q "root@$FIP:$1/docker-compose.yml" "/tmp/$APP-compose.yml"
  sed -i "s/$FIP:/$TIP:/" "/tmp/$APP-compose.yml"   # bind на mesh-IP целевой ноды
  scp -P 2222 -o BatchMode=yes -q "/tmp/$APP-compose.yml" "root@$TIP:$1/docker-compose.yml"
  rm -f "/tmp/$APP-compose.yml"
}
set_placement() {
  local n
  for n in $(awk '{print $1}' /etc/db/nodes.map); do
    ssh -n -p 2222 -o BatchMode=yes "root@$(map_ip "$n")" \
      "sed -i \"s|^placement:.*|placement: $NEWPLACE  # перенос app-move: $FROM->$TO|\" /etc/db/apps.d/$APP.yaml" 2>/dev/null || true
  done
}
sync_proxy() {
  echo "-- блок прокси на всех нодах..."
  local n
  for n in $(awk '{print $1}' /etc/db/nodes.map); do
    run_on "$n" "/usr/local/bin/db-proxy-sync.sh $APP" || echo "  ! $n: блок прокси не обновлён"
  done
}

# =========================== PostgreSQL ===========================
move_pg() {
  echo "-- готовлю инстанс на $TO..."
  run_on "$TO" "mkdir -p /opt/db/pg-$APP /var/lib/dbdata/pg-$APP /var/lib/pgwal/$APP"
  copy_env
  copy_compose "/opt/db/pg-$APP"

  echo "-- копирую данные (basebackup через VIP)..."
  run_on "$TO" "/usr/local/bin/pg-rebuild-standby.sh $APP" | tail -2

  set_placement

  if run_on "$FROM" "docker exec -u postgres pg-$APP psql -U postgres -tAc 'SELECT pg_is_in_recovery()'" | grep -q '^f$'; then
    echo "-- $FROM держал ПЕРВИЧНЫЙ: плановый фейловер на $TO..."
    run_on "$TO" "docker exec -u postgres pg-$APP pg_ctl promote >/dev/null 2>&1 && rm -f /var/lib/dbdata/pg-$APP/standby.signal && echo '  promote на $TO выполнен'"
    run_on "$TO" "/usr/local/bin/db-guard.sh --claim-now $APP $TO >/dev/null 2>&1 && echo '  метка первичного перенесена на $TO'"
    local i r
    for i in $(seq 1 12); do
      r="$(run_on "$TO" "docker exec -e PGPASSWORD=\$(grep ^POSTGRES_PASSWORD= /etc/db/secrets/$APP.env | cut -d= -f2) pg-$APP psql -h 10.66.0.99 -p $PORT -U postgres -tAc 'SELECT NOT pg_is_in_recovery()'" 2>/dev/null || echo '?')"
      [ "$r" = t ] && { echo "  VIP уже ведёт на новый первичный ($i)"; break; }
      sleep 5
    done
  else
    echo "-- $FROM был стендбаем — фейловер не нужен"
  fi
}

# =========================== MongoDB ===========================
move_mongo() {
  ensure_helpers "$FROM"; ensure_helpers "$TO"
  echo "-- готовлю инстанс на $TO..."
  run_on "$TO" "mkdir -p /opt/db/mongo-$APP /var/lib/dbdata/mongo-$APP"
  copy_compose "/opt/db/mongo-$APP"
  if ! run_on "$FROM" "/usr/local/bin/mongo-rs.sh has $APP $TIP:$PORT"; then
    run_on "$TO" "if [ -n \"\$(ls -A /var/lib/dbdata/mongo-${APP} 2>/dev/null | head -1)\" ]; then
      mv /var/lib/dbdata/mongo-${APP} /var/lib/dbdata/mongo-${APP}.retired-\$(date +%s)
      mkdir -p /var/lib/dbdata/mongo-${APP}
      echo '  прежние данные убраны в mongo-${APP}.retired-*'
    fi"
  fi
  run_on "$TO" "cd /opt/db/mongo-$APP && docker compose up -d"
  local i ok=""
  echo "-- жду, пока mongod начнёт слушать :$PORT..."
  for i in $(seq 1 60); do
    if run_on "$TO" "ss -ltn | grep -q ':${PORT} '"; then ok=1; break; fi
    sleep 5
  done
  [ -n "$ok" ] || { echo "mongod не начал слушать :$PORT за 5 минут" >&2; exit 1; }

  echo "-- добавляю $TO в rs_${APP}: данные догоняются сами (initial sync)..."
  run_on "$FROM" "/usr/local/bin/mongo-rs.sh add $APP $TIP:$PORT"
  run_on "$FROM" "/usr/local/bin/mongo-rs.sh wait $APP $TIP:$PORT SECONDARY 900"

  if [ "$(run_on "$FROM" "docker exec mongod-$APP mongosh --quiet --eval 'try{print(rs.status().myState)}catch(e){print(-1)}' 2>/dev/null" || echo '?')" = "1" ]; then
    echo "-- $FROM держал ПЕРВИЧНЫЙ: плановый фейловер на $TO..."
    run_on "$FROM" "/usr/local/bin/mongo-rs.sh prio $APP $TIP:$PORT"
    run_on "$FROM" "/usr/local/bin/mongo-rs.sh stepdown $APP"
    run_on "$TO" "/usr/local/bin/mongo-rs.sh wait $APP $TIP:$PORT PRIMARY 300"
    run_on "$TO" "/usr/local/bin/db-guard.sh --claim-now $APP $TO >/dev/null 2>&1 && echo '  метка первичного перенесена на $TO'"
  else
    echo "-- $FROM был вторичным — фейловер не нужен"
  fi

  set_placement
  sync_proxy

  echo "-- убираю $FROM из rs_${APP}..."
  run_on "$TO" "/usr/local/bin/mongo-rs.sh remove $APP $FIP:$PORT"
}

case "$ENGINE" in
  pg)    move_pg; INST=pg ;;
  mongo) move_mongo; INST=mongo ;;
esac

echo "-- останавливаю старый инстанс на $FROM (данные НЕ удаляю)..."
run_on "$FROM" "cd /opt/db/${INST}-$APP && docker compose down >/dev/null 2>&1 && echo '  остановлен'"

sync_proxy
echo "== ГОТОВО: $APP теперь в placement $NEWPLACE =="
if [ "$ENGINE" = pg ]; then
  echo "проверка: стендбаи видны в pg_stat_replication на первичном"
else
  echo "проверка: /usr/local/bin/mongo-rs.sh status $APP"
fi
