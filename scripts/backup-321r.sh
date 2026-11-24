#!/usr/bin/env bash
# 321r: ежедневный бэкап по правилу 3-2-1 (дизайн docs/backups.md).
# Запускается на КАЖДОЙ ноде: готовит согласованные копии СВОИХ данных
# (pg_basebackup / mongodump / конфиги+секреты) и складывает снимки в ДВА удалённых
# restic-репозитория (2 другие ноды = 2 разных failure-домена; restic шифрует всё).
# Уведомления — Telegram (tg-alert.sh). Лог — /var/log/backup321r.log.
STAGE=/var/lib/pgbackup
STAMP=$(date +%Y%m%d-%H%M)
ME="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"
[ -n "$ME" ] || ME="$(hostname | cut -d. -f1)"
. /etc/db/secrets/restic.env 2>/dev/null   # RESTIC_PASSWORD
export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
[ -n "$RESTIC_PASSWORD" ] || { echo "нет RESTIC_PASSWORD в /etc/db/secrets/restic.env"; exit 1; }

# Тишина для живого трафика: бэкапы НЕ должны ложно ронять health-checkи
# (тяжёлый прогон спровоцировал ложный фейловер komodo).
NICE="nice -n 19 ionice -c3"

mkdir -p "$STAGE"
log() { echo "$(date -Is) $*"; }
ERRS=""

# Чистим старый staging (оставляем 2 свежих прогона — инкременты restic не нужны)
ls -1dt "$STAGE"/*/ "$STAGE"/*.gz 2>/dev/null | tail -n +3 | xargs -r rm -rf

# --- 1) PostgreSQL: согласованный basebackup каждого локального инстанса ---
# ИСТОЧНИК — ТЕКУЩИЙ ПЕРВИЧНЫЙ (через VIP), не локальный инстанс! Причина:
# basebackup со СТЕНДБАЯ даёт неполный набор WAL (стендбай не генерирует записи;
# redo-указатель рестарт-поинта смотрит в отсутствующий сегмент) — восстановление
# «must specify restore_command». С первичного WAL полный и самодостаточный.
# Пути: в контейнере /var/lib/pgwal УЖЕ каталог приложения (хост /var/lib/pgwal/<app>).
for d in /var/lib/dbdata/pg-*; do
  app="${d##*/pg-}"; [ -d "$d" ] || continue
  port="$(sed -n 's/^port: *//p' "/etc/db/apps.d/$app.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
  ok=""
  err=""
  for try in 1 2; do
    # ошибку НЕ глотаем: без неё «basebackup не удалась» необъяснима ()
    err="$(docker exec -u postgres "pg-$app" sh -c \
        "PGPASSWORD=\$REPL_PASSWORD pg_basebackup -h 10.66.0.99 -p ${port:-5432} -U replicator -D /var/lib/pgwal/bb-$STAMP -Ft -Xs -z" 2>&1 >/dev/null)" && { ok=1; break; }
    log "pg-$app: попытка $try basebackup не удалась: $(printf '%s' "$err" | tail -2 | tr '\n' ' ' | sed -E 's/password=[^ ]*/password=***/g')"
    sleep 15
  done
  if [ -n "$ok" ]; then
    mkdir -p "$STAGE/pg-$app-$STAMP"
    cp /var/lib/pgwal/"$app"/bb-"$STAMP"/*.gz "$STAGE/pg-$app-$STAMP/" 2>/dev/null
    rm -rf "/var/lib/pgwal/$app/bb-$STAMP"
    if [ -n "$(ls -A "$STAGE/pg-$app-$STAMP" 2>/dev/null)" ]; then
      log "pg-$app: basebackup ок с первичного ($(du -sh "$STAGE/pg-$app-$STAMP" | cut -f1))"
    else
      ERRS="$ERRS pg-$app-copy"
    fi
  else
    ERRS="$ERRS pg-$app-basebackup"
  fi
done

# --- 2) MongoDB: mongodump каждого локального инстанса (арбитр пропускаем — данных нет) ---
for d in /var/lib/dbdata/mongo-*; do
  app="${d##*/mongo-}"; [ -d "$d" ] || continue
  arb="$(sed -n 's/^arbiter: *//p' "/etc/db/apps.d/$app.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
  if [ "$arb" = "$ME" ]; then
    log "mongo-$app: я арбитр — данных нет, дамп пропущен"
    continue
  fi
  if docker exec "mongod-$app" mongodump --archive --gzip > "$STAGE/mongo-$app-$STAMP.archive.gz" 2>/dev/null; then
    log "mongo-$app: dump ок ($(du -h "$STAGE/mongo-$app-$STAMP.archive.gz" | cut -f1))"
  else
    log "mongo-$app: dump не удался, повтор через 15 с"
    sleep 15
    if docker exec "mongod-$app" mongodump --archive --gzip > "$STAGE/mongo-$app-$STAMP.archive.gz" 2>/dev/null; then
      log "mongo-$app: dump ок со второй попытки"
    else
      ERRS="$ERRS mongo-$app-dump"
    fi
  fi
done

# --- 3) Конфиги и секреты (зашифрованы restic'ом; SOPS-ключ офлайн — см. docs/security.md) ---
# Пути собираем по факту наличия (не на каждой ноде есть remnawave/remnanode)
cfgs=""
for p in /etc/db /etc/amnezia /etc/cron.d /etc/systemd/system /opt/pangolin /opt/remnawave /opt/remnanode /opt/db; do
  [ -e "$p" ] && cfgs="$cfgs $p"
done
tar czf "$STAGE/configs-$STAMP.tar.gz" $cfgs 2>/dev/null
rc=$?
if [ "$rc" -le 1 ]; then log "configs: архив собран (rc=$rc)"; else ERRS="$ERRS configs-tar"; fi

# --- 4) Снимки в два удалённых репозитория (2 другие ноды, ПО МЕШУ: mesh-IP из nodes.map) ---
ok=0
targets="$(awk -v me="$ME" '$1!=me{print $2}' /etc/db/nodes.map)"
for ip in $targets; do
  repo="sftp:root@$ip:/var/lib/backup-repos/$ME"
  $NICE restic -r "$repo" snapshots >/dev/null 2>&1 || $NICE restic -r "$repo" init >/dev/null 2>&1 || { ERRS="$ERRS init->$ip"; continue; }
  if $NICE restic -r "$repo" backup "$STAGE" >/dev/null 2>&1; then
    $NICE restic -r "$repo" forget --keep-daily 30 --keep-weekly 12 --keep-monthly 12 --prune >/dev/null 2>&1
    ok=$((ok+1)); log "репозиторий $ip: снимок ок"
  else
    ERRS="$ERRS backup->$ip"
  fi
done

# --- 5) Итог: маяк свежести + уведомление (docs/backups.md) ---
if [ "$ok" -ge 2 ] && [ -z "$ERRS" ]; then
  date +%s > "$STAGE/last_ok"
  /usr/local/bin/tg-alert.sh "бэкап 3-2-1 ок (копий: $ok, нода $ME)" >/dev/null 2>&1
  log "ИТОГ: ок (копий: $ok)"
else
  /usr/local/bin/tg-alert.sh "БЭКАП С ОШИБКАМИ ($ME):${ERRS:- нет копий}" >/dev/null 2>&1
  log "ИТОГ: ОШИБКИ:$ERRS (копий: $ok)"
  exit 1
fi
