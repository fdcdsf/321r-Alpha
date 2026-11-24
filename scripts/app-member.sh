#!/usr/bin/env bash
# 321r: управление членами БД-группы (дизайн docs/databases.md, настройка через Telegram-бота).
#   app-member.sh add <app> <node>     — добавить инстанс на ноду (копия через VIP, placement++)
#   app-member.sh remove <app> <node>  — убрать инстанс с ноды (placement--, данные НЕ трогаем)
# Перенос — app-move.sh. Поддержан только pg (mongo — отдельная история). Все команды
# Идемпотентны и защищены: нельзя убрать последний инстанс и нельзя убрать первичный
# (для этого сначала перенос).
set -euo pipefail
MODE="${1:?использование: app-member.sh add|remove <app> <node>}"
APP="${2:?нужно имя приложения}"
NODE="${3:?нужен алиас ноды}"

YAML="/etc/db/apps.d/${APP}.yaml"
ENGINE="$(sed -n 's/^engine: *//p' "$YAML" 2>/dev/null | sed 's/#.*//; s/ *$//')"
[ "$ENGINE" = pg ] || { echo "поддержан только pg (engine=$ENGINE)"; exit 1; }
PORT="$(sed -n 's/^port: *//p' "$YAML" | sed 's/#.*//; s/ *$//')"
CUR="$(sed -n 's/^placement: *//p' "$YAML" | sed 's/#.*//; s/ *$//')"
MEMBERS="$(echo "$CUR" | tr -d '[] ')"
NIP="$(awk -v s="$NODE" '$1==s{print $2}' /etc/db/nodes.map)"
[ -n "$NIP" ] || { echo "нет ноды $NODE в nodes.map"; exit 1; }
SSHX() { ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$NIP" "$1"; }
set_placement() { # $1 = новый список через запятую
  for n in $(awk '{print $1}' /etc/db/nodes.map); do
    nip="$(awk -v s="$n" '$1==s{print $2}' /etc/db/nodes.map)"
    ssh -n -p 2222 -o BatchMode=yes "root@$nip" \
      "sed -i \"s|^placement:.*|placement: [$1]  # app-member $MODE: $NODE|\" /etc/db/apps.d/${APP}.yaml" 2>/dev/null || true
  done
}

case "$MODE" in
  add)
    case " $MEMBERS " in *" $NODE "*) echo "$NODE уже в placement [$MEMBERS]"; exit 0 ;; esac
    echo "== добавляю инстанс $APP на $NODE (placement [$MEMBERS] -> [$MEMBERS, $NODE]) =="
    # донор конфигов — любой текущий член группы
    DONOR="$(echo "$MEMBERS" | awk '{print $1}')"
    DIP="$(awk -v s="$DONOR" '$1==s{print $2}' /etc/db/nodes.map)"
    SSHX "mkdir -p /opt/db/pg-${APP} /var/lib/dbdata/pg-${APP} /var/lib/pgwal/${APP}"
    scp -P 2222 -o BatchMode=yes -q "root@$DIP:/etc/db/secrets/${APP}.env" "/tmp/${APP}.env"
    scp -P 2222 -o BatchMode=yes -q "/tmp/${APP}.env" "root@$NIP:/etc/db/secrets/${APP}.env"
    SSHX "chmod 600 /etc/db/secrets/${APP}.env"; rm -f "/tmp/${APP}.env"
    scp -P 2222 -o BatchMode=yes -q "root@$DIP:/opt/db/pg-${APP}/docker-compose.yml" "/tmp/${APP}-c.yml"
    sed -i "s/$DIP:/$NIP:/" "/tmp/${APP}-c.yml"   # bind на mesh-IP новой ноды
    scp -P 2222 -o BatchMode=yes -q "/tmp/${APP}-c.yml" "root@$NIP:/opt/db/pg-${APP}/docker-compose.yml"
    rm -f "/tmp/${APP}-c.yml"
    echo "-- копия данных (basebackup через VIP)..."
    SSHX "/usr/local/bin/pg-rebuild-standby.sh $APP" | tail -2
    NEWLIST="$(echo "$MEMBERS" | sed 's/ /, /g'), $NODE"
    set_placement "$NEWLIST"
    echo "== ГОТОВО: $APP теперь в placement [$NEWLIST] =="
    ;;
  remove)
    CNT=$(echo "$MEMBERS" | wc -w)
    [ "$CNT" -gt 1 ] || { echo "нельзя убрать последний инстанс группы"; exit 1; }
    case " $MEMBERS " in *" $NODE "*) ;; *) echo "$NODE не в группе [$MEMBERS]"; exit 0 ;; esac
    # защита: первичного не убираем (сначала перенос через app-move)
    ROLE="$(SSHX "docker exec -u postgres pg-${APP} psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null" || echo '?')"
    [ "$ROLE" = f ] && { echo "на $NODE живёт ПЕРВИЧНЫЙ — сначала перенесите его (app-move), потом убирайте"; exit 1; }
    echo "== убираю инстанс $APP с $NODE (данные остаются на диске) =="
    NEWLIST="$(echo "$MEMBERS" | tr ' ' '\n' | grep -vx "$NODE" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    set_placement "$NEWLIST"
    SSHX "cd /opt/db/pg-${APP} && docker compose down >/dev/null 2>&1 && echo '  инстанс остановлен'"
    echo "== ГОТОВО: $APP теперь в placement [$NEWLIST] =="
    ;;
  *)
    echo "использование: app-member.sh add|remove <app> <node>"; exit 1 ;;
esac
