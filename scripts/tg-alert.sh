#!/usr/bin/env bash
# 321r: отправка алерта в Telegram. Работает с ЛЮБОЙ ноды (простой curl, без лидера) —
# уведомления переживают смерть любой машины. Токен — /etc/db/secrets/telegram.env (НЕ в git).
# Использование: tg-alert.sh "текст сообщения"
set -u
. /etc/db/secrets/telegram.env 2>/dev/null || exit 0
[ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || exit 0
MSG="${1:-без текста}"
HOST="$(hostname | cut -d. -f1)"
# Тихий фейл: алертер никогда не должен ломать вызывающий скрипт
curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=321r · ${HOST}: ${MSG}" >/dev/null 2>&1 || true
exit 0
