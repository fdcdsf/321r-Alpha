#!/usr/bin/env bash
# Zabbix alert -> Telegram бот 321r.
# Токен читается ТОЛЬКО из /etc/db/secrets (в контейнере смонтирован как
# /run/secrets/zabbix-telegram.env). В git, в БД Zabbix и в логах не попадает.
# Вызов от Zabbix: tg-relay.sh {ALERT.SENDTO} {ALERT.SUBJECT} {ALERT.MESSAGE}
set -u
ENV=/run/secrets/zabbix-telegram.env
if [ ! -r "$ENV" ]; then
  echo 'tg-relay: нет /run/secrets/zabbix-telegram.env' >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV"
if [ -z "${TG_BOT_TOKEN:-}" ]; then
  echo 'tg-relay: TG_BOT_TOKEN пуст' >&2
  exit 1
fi
sendto="${1:-}"
subject="${2:-321r}"
message="${3:-}"
chat="${TG_CHAT_ID:-}"
# Если Zabbix передал конкретный chat_id — используем его, иначе общий из секретов.
if [ -n "$sendto" ] && [[ "$sendto" =~ ^(-?[0-9]+|@[A-Za-z0-9_]+)$ ]]; then
  chat="$sendto"
fi
if [ -z "$chat" ]; then
  echo 'tg-relay: chat id не задан' >&2
  exit 1
fi
if [ -z "$message" ]; then
  echo 'tg-relay: пустое сообщение' >&2
  exit 1
fi
text="$subject
$message"
# -sS --fail: ошибки скрыты (чтобы не вывести токен из URL), HTTP-код >=400 = сбой.
curl -sS --fail --max-time 15 -o /dev/null \
  -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${chat}" \
  --data-urlencode "text=${text}" \
  --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ]; then
  echo "tg-relay: отправка не удалась (curl rc=$rc)" >&2
  exit 1
fi
exit 0
