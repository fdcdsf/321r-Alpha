#!/usr/bin/env bash
# pangolin-wildcard-repair.sh — лечение багов Pangolin v2.3.4 (кластер + wildcard-домен).
#
# Что чинит (см. docs/pangolin-wildcard.md):
#   1. dnsRecords.value = "Server IP Address" (плейсхолдер) -> реальный IP -> валидация 2/2;
#   2. certificates.domain = "*.base" -> "base" (баг двойной звёздочки: ACME просил *.*.base);
#   3. снимает failed/tries с доменов — иначе валидатор их пропускает навсегда.
#
# Запуск: на любой ноде кластера, ПОСЛЕ старта/рестарта pangolin (и по таймеру —
# синхронизация конфиг-домена при рестарте пересоздаёт плейсхолдер). Идемпотентен.
# Использование: pangolin-wildcard-repair.sh <один из IP A-записей домена>
set -euo pipefail

IP="${1:?использование: pangolin-wildcard-repair.sh <IP из A-записей домена>}"
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "не похоже на IPv4: $IP" >&2; exit 1; }
. /etc/db/secrets/pangolin.env

# Пишем через VIP общего PostgreSQL (10.66.0.99): на стендбай запись упадёт (read-only).
PSQL=(docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" pg-pangolin
      psql -X -v ON_ERROR_STOP=1 -h 10.66.0.99 -p 5432 -U postgres -d pangolin)

echo "1. dnsRecords: плейсхолдер -> $IP"
"${PSQL[@]}" <<SQL
UPDATE "dnsRecords" SET "value" = '$IP' WHERE "value" = 'Server IP Address';
SQL

echo "2. certificates: убираем двойную звёздочку (*.base -> base)"
"${PSQL[@]}" <<'SQL'
UPDATE certificates
   SET "domain" = substring("domain" from 3),
       "status" = 'pending',
       "errorMessage" = NULL,
       "updatedAt" = floor(extract(epoch from now()))::integer
 WHERE "wildcard" = true AND "domain" LIKE '*.%';
SQL

echo "2б. certificates: сбрасываем зависший failed"
# Домен мог быть уже исправлен (без «*.»), а строка остаться в status=failed: повторная
# выдача блокируется, монитор сертификатов считает домен «покрытым» («All domains are
# covered, no fetch needed») — и ресурсы навсегда отвечают 404 с TRAEFIK DEFAULT CERT
# (вскрыто альфа-тестом: сброса в pending достаточно, выдача проходит за минуту).
"${PSQL[@]}" <<'SQL'
UPDATE certificates
   SET "status" = 'pending',
       "errorMessage" = NULL,
       "updatedAt" = floor(extract(epoch from now()))::integer
 WHERE "wildcard" = true AND "status" = 'failed';
SQL

echo "3. domains: снимаем failed/tries (валидатор снова возьмёт домены в работу)"
"${PSQL[@]}" <<'SQL'
UPDATE domains SET "failed" = false, "tries" = 0 WHERE "failed" = true;
SQL

echo "готово. Проверка (метаданные):"
"${PSQL[@]}" <<'SQL'
SELECT "domainId", "domain", "wildcard", "status" FROM certificates ORDER BY "domain";
SQL
echo "Если сертификат pending — дождитесь лога 'Certificate obtained' (пару минут)."
