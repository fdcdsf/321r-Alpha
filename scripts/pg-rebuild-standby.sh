#!/usr/bin/env bash
# pg-rebuild-standby.sh — штатная пересборка стендбая PostgreSQL с расхождением таймлайна.
#
# Симптом: контейнер pg-<app> крашится в цикле, в логе:
#   FATAL: requested timeline N is not a child of this server's history
# Это НЕ авария: после ребутов/фейловеров кластер сменил timeline, а диск стендбая
# Отстал. Лечение — пересборка с первичного (~1 мин), данные не теряются.
#
# Запуск: на узле с больным стендбаем.  Использование: pg-rebuild-standby.sh [app]
# (по умолчанию app=pangolin). Пишет через VIP (10.66.0.99) — стендбай находит
# Текущего первичного автоматически.
set -euo pipefail

APP="${1:-pangolin}"
. "/etc/db/secrets/${APP}.env"
DIR="/var/lib/dbdata/pg-${APP}"
WAL="/var/lib/pgwal/${APP}"
# Порт приложения на VIP — из реестра (хардкод 5432 ломал пересборку
# remnawave с портом 5433 — удалял данные и падал на авторизации!)
PORT="$(sed -n 's/^port: *//p' "/etc/db/apps.d/${APP}.yaml" 2>/dev/null | sed 's/#.*//; s/ *$//')"
PORT="${PORT:-5432}"

cd "/opt/db/pg-${APP}"
echo "останавливаю pg-${APP}..."
docker compose down
echo "чистю PGDATA и WAL-каталог..."
rm -rf "${DIR:?}/"* "${WAL:?}/"* 2>/dev/null || true
chown -R 70:70 "$DIR" "$WAL"   # ДО basebackup: на свежей ноде каталоги принадлежат root
echo "pg_basebackup с первичного (через VIP, порт $PORT)..."
docker run --rm -u postgres -e PGPASSWORD="$REPL_PASSWORD" -v "$DIR":/data postgres:17-alpine \
  pg_basebackup -h 10.66.0.99 -p "$PORT" -U replicator -D /data -Fp -Xs
touch "$DIR/standby.signal"
# Сначала убрать старые строки: pg_basebackup копирует auto.conf с первичного,
# А мы добавляем свою — при повторных пересборках копились дубли ().
sed -i '/^primary_conninfo =/d' "$DIR/postgresql.auto.conf" 2>/dev/null || true
echo "primary_conninfo = 'host=10.66.0.99 port=$PORT user=replicator password=${REPL_PASSWORD}'" >> "$DIR/postgresql.auto.conf"
chown -R 70:70 "$DIR" "$WAL"   # alpine postgres uid=70; без chown WAL архив молча ломается
docker compose up -d
sleep 10
echo -n "pg_is_in_recovery (ожидание t): "
docker exec -u postgres "pg-${APP}" psql -tAc "SELECT pg_is_in_recovery()"
echo "если t — стендбай снова в строю; на первичном появится в pg_stat_replication"
