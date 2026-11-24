#!/usr/bin/env bash
# 321r: факты для Telegram-бота (дизайн docs/monitoring.md). Использование: tg-info.sh <cmd>
# status | disk | db | backup | certs | services — текстовый вывод, бот пересылает как есть.
set -u

stamps() { # свежесть бэкапа и верификации
  if [ -f /var/lib/pgbackup/last_ok ]; then
    echo "backup: $(( ($(date +%s) - $(stat -c %Y /var/lib/pgbackup/last_ok)) / 3600 ))ч назад"
  else
    echo "backup: НИКОГДА"
  fi
  if [ -f /var/lib/pgbackup/last_verify ]; then
    echo "verify: $(( ($(date +%s) - $(stat -c %Y /var/lib/pgbackup/last_verify)) / 86400 ))д назад"
  else
    echo "verify: не проводилась"
  fi
}

db_roles() {
  for d in /var/lib/dbdata/pg-*; do
    app="${d##*/pg-}"; [ -d "$d" ] || continue
    if ! docker ps --format '{{.Names}}' | grep -qx "pg-$app"; then echo "pg $app: инстанс остановлен"; continue; fi
    # роль ЛОКАЛЬНОГО инстанса (unix-socket в контейнере) + размер его баз
    r="$(docker exec -u postgres "pg-$app" psql -U postgres -tAc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'PRIMARY' END" 2>/dev/null || echo '?')"
    size="$(docker exec -u postgres "pg-$app" psql -U postgres -tAc "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database" 2>/dev/null || echo '?')"
    echo "pg $app: локально $r, базы: $size"
  done
  for d in /var/lib/dbdata/mongo-*; do
    app="${d##*/mongo-}"; [ -d "$d" ] || continue
    arb="$(sed -n 's/^arbiter: *//p' "/etc/db/apps.d/$app.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
    me="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"; me="${me:-$(hostname | cut -d. -f1)}"
    [ "$arb" = "$me" ] && { echo "mongo $app: арбитр"; continue; }
    docker ps --format '{{.Names}}' | grep -qx "mongod-$app" || { echo "mongo $app: инстанс остановлен"; continue; }
    m="$(mongosh_eval_local "$app")"
    echo "mongo $app: локально $m"
  done
}
mongosh_eval_local() {
  docker exec "mongod-$1" mongosh --quiet --eval 'try { var s=rs.status().myState; print(s==1?"PRIMARY":s==2?"secondary":s==7?"арбитр":"state-"+s) } catch(e) { print("?") }' 2>/dev/null
}

case "${1:-status}" in
  status)
    echo "load: $(cut -d' ' -f1-3 /proc/loadavg) ($(nproc) ядер)"
    echo "ram: свободно $(free -m | awk '/Mem:/{print $7}')MB"
    echo "disk /: $(df -h / | awk 'NR==2{print $5 " занято, " $4 " свободно"}')"
    echo "контейнеры: $(docker ps --filter status=running -q | wc -l) работают"
    db_roles
    stamps
    ;;
  disk)
    df -h | awk 'NR==1 || $6=="/" || /dbdata|pgwal|backup|docker/' | sed 's/^/  /'
    echo "репозитории бэкапов:"; du -sh /var/lib/backup-repos/* 2>/dev/null | sed 's/^/  /' || echo "  (нет)"
    ;;
  db)
    db_roles
    for d in /var/lib/dbdata/pg-*; do
      app="${d##*/pg-}"; [ -d "$d" ] || continue
      port="$(sed -n 's/^port: *//p' "/etc/db/apps.d/$app.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
      ( . "/etc/db/secrets/$app.env" 2>/dev/null
        tgt="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "pg-$app" psql -h 10.66.0.99 -p "${port:-5432}" -U postgres -tAc 'SELECT inet_server_addr()' 2>/dev/null || echo '?')"
        echo "VIP $app -> $tgt"
        docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "pg-$app" psql -h 10.66.0.99 -p "${port:-5432}" -U postgres -tAc \
          "SELECT 'реплики: '||coalesce(string_agg(client_addr::text||'='||state,', '),'нет') FROM pg_stat_replication" 2>/dev/null || echo "реплики: ?"
      )
    done
    ;;
  backup)
    stamps
    echo "снимки в репозиториях:"
    for repo in /var/lib/backup-repos/*; do
      [ -d "$repo" ] || continue
      ( . /etc/db/secrets/restic.env 2>/dev/null; export RESTIC_PASSWORD
        n="$(restic -r "$repo" snapshots --compact 2>/dev/null | tail -n +3 | wc -l)"
        echo "  $(basename "$repo"): снимков: $n"
      )
    done
    ;;
  certs)
    certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry" | sed 's/^/  /' || echo "  certbot: нет данных"
    ;;
  services)
    echo "локальные сервисы:"
    echo -n "  pg через VIP: "; ( . /etc/db/secrets/pangolin.env 2>/dev/null; docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" pg-pangolin psql -h 10.66.0.99 -U postgres -tAc 'SELECT 1' >/dev/null 2>&1 && echo ок || echo НЕТ )
    echo -n "  xray-порты 9446/2087: "; ss -tln 2>/dev/null | grep -qE ':(9446|2087) ' && echo слушают || echo НЕТ
    echo -n "  mtproto 8446: "; ss -tln 2>/dev/null | grep -q ':8446 ' && echo слушает || echo НЕТ
    echo -n "  панель localhost:3001: "; curl -sf -o /dev/null --max-time 5 http://localhost:3001/api/v1/ 2>/dev/null && echo ок || echo нет/чужая
    ;;
  app)
    # состояние БД конкретного приложения на ЭТОЙ ноде: tg-info.sh app <имя>
    app="${2:?нужно имя приложения}"
    if [ -d "/var/lib/dbdata/pg-$app" ]; then
      if docker ps --format '{{.Names}}' | grep -qx "pg-$app"; then
        r="$(docker exec -u postgres "pg-$app" psql -U postgres -tAc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'PRIMARY' END" 2>/dev/null || echo '?')"
        s="$(docker exec -u postgres "pg-$app" psql -U postgres -tAc "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database" 2>/dev/null || echo '?')"
        echo "БД pg-$app: локально $r, базы: $s"
      else
        echo "БД pg-$app: инстанс остановлен"
      fi
    fi
    if [ -d "/var/lib/dbdata/mongo-$app" ]; then
      arb="$(sed -n 's/^arbiter: *//p' "/etc/db/apps.d/$app.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
      me="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"; me="${me:-$(hostname | cut -d. -f1)}"
      if [ "$arb" = "$me" ]; then
        echo "БД mongo-$app: арбитр"
      elif docker ps --format '{{.Names}}' | grep -qx "mongod-$app"; then
        echo "БД mongo-$app: локально $(mongosh_eval_local "$app")"
      else
        echo "БД mongo-$app: инстанс остановлен"
      fi
    fi
    ;;
  *)
    echo "tg-info.sh: status|disk|db|backup|certs|services"; exit 1 ;;
esac
