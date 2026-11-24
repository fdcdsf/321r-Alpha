#!/usr/bin/env bash
# 321r: выгрузка свежего бэкапа владельцу в Telegram → запись на ФИЗИЧЕСКИЙ носитель
# (ритуал раз в месяц; docs/doctrine-3-2-1.md). Каждая нода отправляет СВОЙ последний набор
# (pg_basebackup/mongodump/конфиги из staging) — владелец получает всё, склеив по нодам.
# Лимит Bot API: 50 МБ на файл (наши наборы ~5–10 МБ). Шифрование — restic/архивы.
set -u
. /etc/db/secrets/telegram.env 2>/dev/null; export TG_BOT_TOKEN TG_CHAT_ID
[ -n "${TG_BOT_TOKEN:-}" ] || { echo "нет telegram.env"; exit 1; }
ME="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"
[ -n "$ME" ] || ME="$(hostname | cut -d. -f1)"
OUT=/var/lib/pgbackup/export
mkdir -p "$OUT"; rm -f "$OUT"/*.tar.gz
FILE="$OUT/321r-$ME-$(date +%F).tar.gz"
tar czf "$FILE" -C /var/lib/pgbackup --exclude=export . 2>/dev/null
sz=$(du -m "$FILE" | cut -f1)
if [ "$sz" -ge 48 ]; then
  /usr/local/bin/tg-alert.sh "выгрузка ($ME): набор ${sz}МБ > лимита 50МБ — нужна нарезка (docs/doctrine-3-2-1.md)" >/dev/null 2>&1
  exit 1
fi
curl -sS --max-time 300 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "caption=321r · выгрузка для физического носителя: нода $ME ($(date +%F)). Скопируйте на диск!" \
  -F "document=@$FILE" >/dev/null 2>&1 \
  && /usr/local/bin/tg-alert.sh "выгрузка ($ME): файл отправлен (${sz}МБ) — сохраните на физический носитель" >/dev/null 2>&1 \
  || /usr/local/bin/tg-alert.sh "выгрузка ($ME): ОШИБКА отправки файла" >/dev/null 2>&1
