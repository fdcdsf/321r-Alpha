#!/usr/bin/env bash
# ddns.sh — DDNS для узла кластера 321r.ru.
#   Обновляет в Cloudflare две записи СВОЕЙ ноды:
#     1) a/b/c.321r.ru            (свой A-запись)
#     2) dns.321r.ru              (свою строку в хабе — ищет по старому IP)
#   Если IP не изменился — выходит сразу, без запросов к API.
#   Разворачивание CNAME (pangolin/komodo/rem/app) происходит на стороне Cloudflare
#   автоматически — их трогать не нужно.
#
# Установка:
#   скрипт  -> /usr/local/bin/ddns.sh   (chmod 755, root)
#   конфиг  -> /etc/ddns.env            (chmod 600, root), содержимое:
#       CF_TOKEN='***'
#       CF_ZONE_NAME='321r.ru'
#       NODE_NAME='a'            # a | b | c  (для будущих узлов: d | e)
#       HUB_NAME='dns'
#   cron:  */2 * * * * root /usr/local/bin/ddns.sh >> /var/log/ddns.log 2>&1
#   Требуется: curl, jq.

set -euo pipefail

CONFIG="${DDNS_CONFIG:-/etc/ddns.env}"
[ -f "$CONFIG" ] || { echo "ddns: нет конфига $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"
: "${CF_TOKEN:?CF_TOKEN не задан}" "${NODE_NAME:?NODE_NAME не задан}"
CF_ZONE_NAME="${CF_ZONE_NAME:-321r.ru}"
HUB_NAME="${HUB_NAME:-dns}"

command -v jq >/dev/null || { echo "ddns: нужен jq (apt install jq / dnf install -y jq)" >&2; exit 1; }
command -v curl >/dev/null || { echo "ddns: нужен curl" >&2; exit 1; }

STATE_DIR=/var/lib/ddns
mkdir -p "$STATE_DIR"
LAST_FILE="$STATE_DIR/last_ip"

# --- текущий публичный IP: три источника на случай блокировки одного из них ---
IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
   || curl -4 -fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null \
   || curl -4 -fsS --max-time 10 'http://ip-api.com/line/?fields=query' 2>/dev/null || true)"
# Фолбэк: IP интерфейса (все три внешних сервиса стали недоступны,
# ddns молча перестал обновлять записи). Подходят VPS с публичным IP на интерфейсе;
# docker-подсети (10/172.16-31) отфильтрованы.
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1)"
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ddns: не удалось узнать свой IP" >&2; exit 1; }

LAST="$(cat "$LAST_FILE" 2>/dev/null || true)"
if [ "$IP" = "$LAST" ]; then
  exit 0   # IP не менялся — выходим молча, без API-вызовов
fi

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")

api() {
  curl -fsS --max-time 20 "${AUTH[@]}" "$@" \
    || { echo "ddns: ошибка Cloudflare API ($1 ...)" >&2; return 1; }
}

# --- Zone ID (один раз, кэшируем) ---
ZONE_ID="$(cat "$STATE_DIR/zone_id" 2>/dev/null || true)"
if [ -z "$ZONE_ID" ]; then
  ZONE_ID="$(api "$API/zones?name=${CF_ZONE_NAME}" | jq -r '.result[0].id // empty')"
  [ -n "$ZONE_ID" ] || { echo "ddns: не нашёл зону ${CF_ZONE_NAME} — проверь токен и зону" >&2; exit 1; }
  printf '%s\n' "$ZONE_ID" > "$STATE_DIR/zone_id"
fi

OLD="${LAST:-$IP}"

# --- ищем id своих записей ---
ID_A="$(api "$API/zones/${ZONE_ID}/dns_records?type=A&name=${NODE_NAME}.${CF_ZONE_NAME}" \
  | jq -r '.result[0].id // empty')"
ID_HUB="$(api "$API/zones/${ZONE_ID}/dns_records?type=A&name=${HUB_NAME}.${CF_ZONE_NAME}" \
  | jq -r --arg old "$OLD" '.result[] | select(.content == $old) | .id' | head -n1)"

patch_record() { # $1=id, $2=имя записи
  local body
  body="$(jq -n --arg n "$2" --arg c "$IP" '{type:"A",name:$n,content:$c,ttl:1,proxied:false}')"
  api -X PATCH "$API/zones/${ZONE_ID}/dns_records/$1" -d "$body" >/dev/null
}

OK=1
if [ -n "$ID_A" ]; then
  patch_record "$ID_A" "${NODE_NAME}.${CF_ZONE_NAME}"
else
  echo "ddns: НЕ НАЙДЕНА запись ${NODE_NAME}.${CF_ZONE_NAME} — создай её в Cloudflare" >&2
  OK=0
fi
if [ -n "$ID_HUB" ]; then
  patch_record "$ID_HUB" "${HUB_NAME}.${CF_ZONE_NAME}"
else
  echo "ddns: НЕ НАЙДЕНА своя строка в ${HUB_NAME}.${CF_ZONE_NAME} со старым IP ${OLD} — проверь хаб" >&2
  OK=0
fi

# Запоминаем IP только когда ОБЕ записи обновлены — иначе следующий запуск повторит попытку.
if [ "$OK" = 1 ]; then
  printf '%s\n' "$IP" > "$LAST_FILE"
  echo "$(date -Is) ${NODE_NAME}.${CF_ZONE_NAME} и ${HUB_NAME}.${CF_ZONE_NAME} -> ${IP}"
fi
exit 0
