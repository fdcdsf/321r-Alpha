#!/usr/bin/env bash
# 321r: верификация бэкапов — «бэкап, который не восстанавливали, не существует» (docs/backups.md).
# Для каждого локального репозитория (/var/lib/backup-repos/*):
#   1) restic check + чтение 5% данных (целостность);
#   2) восстановление последнего снимка во временную папку;
#   3) НАСТОЯЩИЙ smoke-тест PG: scratch-контейнер postgres поднимается из basebackup
#      и отвечает на запрос (таблицы на месте);
#   4) архивы mongo/конфигов читаются (gzip/tar -t).
# Итог — алерт в Telegram. Запуск: еженедельно (cron) или руками.
set -u
. /etc/db/secrets/restic.env 2>/dev/null; export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
[ -n "$RESTIC_PASSWORD" ] || { echo "нет RESTIC_PASSWORD"; exit 1; }

SCRATCH="$(mktemp -d /tmp/verify-XXXXXX)"
trap 'docker rm -f verify-pg >/dev/null 2>&1; rm -rf "$SCRATCH"' EXIT
ERRS=""

for repo in /var/lib/backup-repos/*; do
  [ -d "$repo" ] || continue
  name="$(basename "$repo")"
  echo "== репозиторий $name =="
  restic -r "$repo" check --read-data-subset=5% >/dev/null 2>&1 || { ERRS="$ERRS $name:check"; echo "  check: FAIL"; continue; }
  echo "  check: ок"
  restic -r "$repo" restore latest --target "$SCRATCH/$name" >/dev/null 2>&1 || { ERRS="$ERRS $name:restore"; echo "  restore: FAIL"; continue; }
  stage="$SCRATCH/$name/var/lib/pgbackup"
  echo "  restore: ок"

  # --- smoke PG: поднимаем scratch-postgres ИЗ basebackup ---
  # ВАЖНО: -Xs кладёт WAL отдельно (pg_wal.tar.gz) — без него crash-recovery не пройдёт
  # («не поднялся» = забытый pg_wal.tar.gz).
  pgdir="$(ls -d "$stage"/pg-*/ 2>/dev/null | head -1)"
  if [ -n "$pgdir" ]; then
    mkdir -p "$SCRATCH/pgdata"
    if tar xzf "$pgdir/base.tar.gz" -C "$SCRATCH/pgdata" 2>/dev/null; then
      # ВАЖНО: pg_wal.tar.gz распаковывается ИМЕННО в pg_wal/ (сегменты в архиве
      # лежат без префикса пути — на практике)
      mkdir -p "$SCRATCH/pgdata/pg_wal"
      [ -f "$pgdir/pg_wal.tar.gz" ] && tar xzf "$pgdir/pg_wal.tar.gz" -C "$SCRATCH/pgdata/pg_wal" 2>/dev/null
      # basebackup СТЕНДБАЯ содержит standby.signal — при восстановлении нужен НЕ standby,
      # а recovery.signal: «восстановиться как независимая база» (PG12+ требует явный сигнал
      # при наличии backup_label; на практике).
      rm -f "$SCRATCH/pgdata/standby.signal" "$SCRATCH/pgdata/promote.signal"
      touch "$SCRATCH/pgdata/recovery.signal"
      # «докататься до первого согласованного состояния» — smoke-тесту не нужен весь WAL:
      # иначе PG требует restore_command для поиска недостающих сегментов ()
      cat >> "$SCRATCH/pgdata/postgresql.auto.conf" <<'EOF'
recovery_target = 'immediate'
recovery_target_action = 'promote'
restore_command = 'false'
EOF
      chown -R 70:70 "$SCRATCH/pgdata"
      # -c-аргументы повторяют прод-настройки (db-add): PG отказывается стартовать,
      # если max_connections меньше, чем в контрольном файле первичного ()
      docker run -d --name verify-pg -v "$SCRATCH/pgdata:/var/lib/postgresql/data" \
        -e POSTGRES_PASSWORD=verify postgres:17-alpine \
        -c max_connections=200 -c shared_buffers=32MB >/dev/null 2>&1
      ok=0
      for i in $(seq 1 30); do
        docker exec verify-pg pg_isready -U postgres >/dev/null 2>&1 && { ok=1; break; }
        sleep 2
      done
      if [ "$ok" = 1 ]; then
        # app = имя приложения из имени каталога (pg-<app>-<stamp>) — проверяем ЕГО базу
        app="$(basename "$pgdir" | sed 's/^pg-//; s/-[0-9-]*$//')"
        nt="$(docker exec verify-pg psql -U postgres -d "$app" -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null || echo 0)"
        if [ "${nt:-0}" -ge 5 ]; then
          echo "  PG smoke: ок (таблиц в $app: $nt)"
        else
          ERRS="$ERRS $name:pg-smoke(таблиц мало: $nt)"; echo "  PG smoke: FAIL (таблиц: $nt)"
        fi
      else
        ERRS="$ERRS $name:pg-start"; echo "  PG smoke: не поднялся"
        docker logs verify-pg 2>&1 | grep -B2 FATAL | tail -6 | sed 's/^/    /'
      fi
      docker rm -f verify-pg >/dev/null 2>&1
    else
      ERRS="$ERRS $name:pg-unpack"; echo "  PG распаковка: FAIL"
    fi
    rm -rf "$SCRATCH/pgdata"
  fi

  # --- архивы mongo и конфигов читаются ---
  for m in "$stage"/mongo-*.gz; do
    [ -e "$m" ] || continue
    gzip -t "$m" 2>/dev/null && echo "  mongo: $(basename "$m") читается" || { ERRS="$ERRS $name:mongo-gzip"; }
  done
  for t in "$stage"/configs-*.tar.gz; do
    [ -e "$t" ] || continue
    tar tzf "$t" >/dev/null 2>&1 && echo "  configs: архив читается" || { ERRS="$ERRS $name:configs-tar"; }
  done
done

if [ -z "$ERRS" ]; then
  date +%s > /var/lib/pgbackup/last_verify   # маяк для бота/мониторинга (docs/backups.md)
  /usr/local/bin/tg-alert.sh "верификация бэкапов: ВСЁ ВОССТАНАВЛИВАЕТСЯ (PG поднялся из снимка, архивы целы)" >/dev/null 2>&1
  echo "ИТОГ: ок"
else
  /usr/local/bin/tg-alert.sh "ВЕРИФИКАЦИЯ БЭКАПОВ УПАЛА:$ERRS" >/dev/null 2>&1
  echo "ИТОГ: ОШИБКИ:$ERRS"
  exit 1
fi
