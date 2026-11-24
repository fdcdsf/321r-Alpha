#!/usr/bin/env bash
# 321r: управление членами БД-группы (docs/databases.md). PostgreSQL и MongoDB —
# одинаково: данные копируются сами, состав правится без даунтайма группы.
#   app-member.sh add <app> <node>     — добавить инстанс на ноду (placement++)
#   app-member.sh remove <app> <node>  — убрать инстанс с ноды (данные остаются на диске)
# Перенос — app-move.sh. Все команды идемпотентны и защищены: нельзя убрать последний
# инстанс и нельзя убрать первичный (для этого сначала перенос).
set -euo pipefail
MODE="${1:?использование: app-member.sh add|remove <app> <node>}"
APP="${2:?нужно имя приложения}"
NODE="${3:?нужен алиас ноды}"

HERE="$(cd "$(dirname "$0")" && pwd)"
YAML="/etc/db/apps.d/${APP}.yaml"
val() { sed -n "s/^$1: *//p" "$YAML" 2>/dev/null | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
ENGINE="$(val engine | tr -d ' ')"
PORT="$(val port | tr -d ' ')"
CUR="$(val placement)"
ARB="$(val arbiter | tr -d ' ')"
MEMBERS="$(echo "$CUR" | tr -d '[] ')"
[ -n "$ENGINE" ] && [ -n "$PORT" ] || { echo "реестр $YAML: нужны engine и port" >&2; exit 1; }
map_ip() { awk -v s="$1" '$1==s{print $2}' /etc/db/nodes.map; }
NIP="$(map_ip "$NODE")"
[ -n "$NIP" ] || { echo "нет ноды $NODE в nodes.map" >&2; exit 1; }

run_on() { # $1 = alias, $2 = команда
  ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$(map_ip "$1")" "$2"
}
ensure_helpers() { # помощники могут отсутствовать на нодах старого кластера — докладываем
  local h ip; ip="$(map_ip "$1")"
  for h in mongo-rs.sh db-proxy-sync.sh; do
    [ -f "$HERE/$h" ] || continue
    ssh -n -p 2222 -o BatchMode=yes "root@$ip" "test -x /usr/local/bin/$h" 2>/dev/null \
      || scp -P 2222 -o BatchMode=yes -q "$HERE/$h" "root@$ip:/usr/local/bin/$h"
    ssh -n -p 2222 -o BatchMode=yes "root@$ip" "chmod +x /usr/local/bin/$h" 2>/dev/null || true
  done
}
set_placement() { # $1 = новый список нод через запятую — на все ноды (реестр читает db-guard)
  local n
  for n in $(awk '{print $1}' /etc/db/nodes.map); do
    ssh -n -p 2222 -o BatchMode=yes "root@$(map_ip "$n")" \
      "sed -i \"s|^placement:.*|placement: [$1]  # app-member $MODE: $NODE|\" /etc/db/apps.d/${APP}.yaml" 2>/dev/null || true
  done
}
sync_proxy() {
  echo "-- блок прокси на всех нодах..."
  local n
  for n in $(awk '{print $1}' /etc/db/nodes.map); do
    run_on "$n" "/usr/local/bin/db-proxy-sync.sh $APP" || echo "  ! $n: блок прокси не обновлён"
  done
}
retire_data() { # mongo: данные прежнего членства мешают первой синхронизации — убираем в сторону
  run_on "$1" "if [ -n \"\$(ls -A /var/lib/dbdata/mongo-${APP} 2>/dev/null | head -1)\" ]; then
    mv /var/lib/dbdata/mongo-${APP} /var/lib/dbdata/mongo-${APP}.retired-\$(date +%s)
    mkdir -p /var/lib/dbdata/mongo-${APP}
    echo '  прежние данные убраны в /var/lib/dbdata/mongo-${APP}.retired-*'
  fi"
}

DONOR="$(echo "$MEMBERS" | awk '{print $1}')"
[ "$DONOR" != "$NODE" ] || DONOR="$(echo "$MEMBERS" | awk '{print $2}')"

# ---------- PostgreSQL ----------
add_pg() {
  local DIP; DIP="$(map_ip "$DONOR")"
  run_on "$NODE" "mkdir -p /opt/db/pg-${APP} /var/lib/dbdata/pg-${APP} /var/lib/pgwal/${APP}"
  scp -P 2222 -o BatchMode=yes -q "root@$DIP:/etc/db/secrets/${APP}.env" "/tmp/${APP}.env"
  scp -P 2222 -o BatchMode=yes -q "/tmp/${APP}.env" "root@$NIP:/etc/db/secrets/${APP}.env"
  run_on "$NODE" "chmod 600 /etc/db/secrets/${APP}.env"; rm -f "/tmp/${APP}.env"
  scp -P 2222 -o BatchMode=yes -q "root@$DIP:/opt/db/pg-${APP}/docker-compose.yml" "/tmp/${APP}-c.yml"
  sed -i "s/$DIP:/$NIP:/" "/tmp/${APP}-c.yml"   # bind на mesh-IP новой ноды
  scp -P 2222 -o BatchMode=yes -q "/tmp/${APP}-c.yml" "root@$NIP:/opt/db/pg-${APP}/docker-compose.yml"
  rm -f "/tmp/${APP}-c.yml"
  echo "-- копия данных (basebackup через VIP)..."
  run_on "$NODE" "/usr/local/bin/pg-rebuild-standby.sh $APP" | tail -2
}
remove_pg() {
  local ROLE
  ROLE="$(run_on "$NODE" "docker exec -u postgres pg-${APP} psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null" || echo '?')"
  [ "$ROLE" = f ] && { echo "на $NODE живёт ПЕРВИЧНЫЙ — сначала перенесите его (app-move), потом убирайте"; exit 1; }
  run_on "$NODE" "cd /opt/db/pg-${APP} && docker compose down >/dev/null 2>&1 && echo '  инстанс остановлен'"
}

# ---------- MongoDB ----------
add_mongo() {
  ensure_helpers "$NODE"; ensure_helpers "$DONOR"
  run_on "$NODE" "mkdir -p /opt/db/mongo-${APP} /var/lib/dbdata/mongo-${APP}"
  scp -P 2222 -o BatchMode=yes -q "root@$(map_ip "$DONOR"):/opt/db/mongo-${APP}/docker-compose.yml" "/tmp/${APP}-c.yml"
  sed -i "s/$(map_ip "$DONOR"):/$NIP:/" "/tmp/${APP}-c.yml"   # bind на mesh-IP новой ноды
  scp -P 2222 -o BatchMode=yes -q "/tmp/${APP}-c.yml" "root@$NIP:/opt/db/mongo-${APP}/docker-compose.yml"
  rm -f "/tmp/${APP}-c.yml"
  if ! run_on "$DONOR" "/usr/local/bin/mongo-rs.sh has $APP $NIP:$PORT"; then
    retire_data "$NODE"
  fi
  run_on "$NODE" "cd /opt/db/mongo-${APP} && docker compose up -d"
  local i ok=""
  echo "-- жду, пока mongod начнёт слушать :$PORT..."
  for i in $(seq 1 60); do
    if run_on "$NODE" "ss -ltn | grep -q ':${PORT} '"; then ok=1; break; fi
    sleep 5
  done
  [ -n "$ok" ] || { echo "mongod не начал слушать :$PORT за 5 минут" >&2; exit 1; }
  echo "-- добавляю в rs_${APP}: данные догоняются автоматически (initial sync)..."
  run_on "$DONOR" "/usr/local/bin/mongo-rs.sh add $APP $NIP:$PORT"
  run_on "$DONOR" "/usr/local/bin/mongo-rs.sh wait $APP $NIP:$PORT SECONDARY 900"
}
remove_mongo() {
  ensure_helpers "$NODE"; ensure_helpers "$DONOR"
  local st
  st="$(run_on "$NODE" "docker exec mongod-${APP} mongosh --quiet --eval 'try{print(rs.status().myState)}catch(e){print(-1)}' 2>/dev/null" || echo '?')"
  [ "$st" = "1" ] && { echo "на $NODE живёт ПЕРВИЧНЫЙ — сначала перенесите его (app-move), потом убирайте"; exit 1; }
  run_on "$DONOR" "/usr/local/bin/mongo-rs.sh remove $APP $NIP:$PORT"
  run_on "$NODE" "cd /opt/db/mongo-${APP} && docker compose down >/dev/null 2>&1 && echo '  инстанс остановлен'"
}

case "$MODE" in
  add)
    case " $MEMBERS " in *" $NODE "*) echo "$NODE уже в placement [$MEMBERS]"; exit 0 ;; esac
    echo "== добавляю инстанс $APP на $NODE (placement [$MEMBERS] -> [$MEMBERS, $NODE], engine $ENGINE) =="
    case "$ENGINE" in
      pg)    add_pg ;;
      mongo) add_mongo ;;
      *) echo "неизвестный engine: $ENGINE" >&2; exit 1 ;;
    esac
    NEWLIST="$(echo "$MEMBERS" | sed 's/ /, /g'), $NODE"
    set_placement "$NEWLIST"
    sync_proxy
    echo "== ГОТОВО: $APP теперь в placement [$NEWLIST] =="
    ;;
  remove)
    CNT=$(echo "$MEMBERS" | wc -w)
    [ "$CNT" -gt 1 ] || { echo "нельзя убрать последний инстанс группы"; exit 1; }
    case " $MEMBERS " in *" $NODE "*) ;; *) echo "$NODE не в группе [$MEMBERS]"; exit 0 ;; esac
    echo "== убираю инстанс $APP с $NODE (данные остаются на диске, engine $ENGINE) =="
    case "$ENGINE" in
      pg)    remove_pg ;;
      mongo) remove_mongo ;;
      *) echo "неизвестный engine: $ENGINE" >&2; exit 1 ;;
    esac
    NEWLIST="$(echo "$MEMBERS" | tr ' ' '\n' | grep -vx "$NODE" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    set_placement "$NEWLIST"
    sync_proxy
    echo "== ГОТОВО: $APP теперь в placement [$NEWLIST] =="
    ;;
  *)
    echo "использование: app-member.sh add|remove <app> <node>"; exit 1 ;;
esac
