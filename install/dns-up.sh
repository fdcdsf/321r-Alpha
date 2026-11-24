#!/usr/bin/env bash
# 321r · шаг: DNS (Cloudflare) + ddns + учётки для сертификатов.
# Идемпотентен: существующие верные записи не трогает. Запускается с ноутбука/мастера:
#   bash install/dns-up.sh
# Требует DOMAIN и CF_API_TOKEN в инвентаре (у нового пользователя — окно ввода мастера).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [ -z "${DOMAIN:-}" ] || [ -z "${CF_API_TOKEN:-}" ]; then
  warn "DOMAIN или CF_API_TOKEN пусты — DNS-шаг пропущен (панели поставить нельзя)"
  exit 0
fi

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
ZONE_ID="$(curl -fsS "${AUTH[@]}" "$API/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
[ -n "$ZONE_ID" ] || fail "зона $DOMAIN не найдена или токен без прав Zone.DNS Edit"

record_id() { curl -fsS "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=$1&name=$2&per_page=100" | jq -r '.result[] | select(.content=="'"$3"'") | .id' | head -1; }
name_ids()  { curl -fsS "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=$1&name=$2&per_page=100" | jq -r '.result[].id'; }
name_contents() { curl -fsS "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=$1&name=$2&per_page=100" | jq -r '.result[].content'; }

upsert() { # upsert <type> <name> <content> — одна запись
  local t="$1" n="$2" c="$3" id body
  id="$(record_id "$t" "$n" "$c")"
  if [ -n "$id" ]; then
    echo "  = $n ($t) уже верно"
    return
  fi
  # запись с тем же именем, но другим содержимым → меняем первую (для single-записей)
  id="$(name_ids "$t" "$n" | head -1)"
  body="$(jq -n --arg t "$t" --arg n "$n" --arg c "$c" '{type:$t,name:$n,content:$c,ttl:1,proxied:false}')"
  if [ -n "$id" ]; then
    curl -fsS "${AUTH[@]}" -X PATCH "$API/zones/$ZONE_ID/dns_records/$id" -d "$body" >/dev/null
    ok "$n ($t) → $c (обновлено)"
  else
    curl -fsS "${AUTH[@]}" -X POST "$API/zones/$ZONE_ID/dns_records" -d "$body" >/dev/null
    ok "$n ($t) → $c (создано)"
  fi
}

multi_a() { # multi_a <name> <ip...> — несколько A-записей с одним именем (multi-A)
  local n="$1"; shift
  local ip id body x found
  for ip in "$@"; do
    found=""
    for x in $(name_contents A "$n"); do [ "$x" = "$ip" ] && found=1; done
    if [ -n "$found" ]; then
      echo "  = $n A $ip уже есть"
    else
      body="$(jq -n --arg n "$n" --arg c "$ip" '{type:"A",name:$n,content:$c,ttl:1,proxied:false}')"
      curl -fsS "${AUTH[@]}" -X POST "$API/zones/$ZONE_ID/dns_records" -d "$body" >/dev/null
      ok "$n A → $ip (добавлено)"
    fi
  done
  # лишние A убираем (смена состава нод). НЕ grep -x по "$*" — строка содержит
  # все IP через пробел и не совпадает целиком → вырезались ВСЕ записи.
  for id in $(name_ids A "$n"); do
    ip="$(curl -fsS "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$id" | jq -r '.result.content')"
    found=""
    for x in "$@"; do [ "$x" = "$ip" ] && found=1; done
    if [ -z "$found" ]; then
      curl -fsS "${AUTH[@]}" -X DELETE "$API/zones/$ZONE_ID/dns_records/$id" >/dev/null
      ok "$n: лишняя A $ip удалена"
    fi
  done
}

step "DNS-записи Cloudflare (зона $DOMAIN)"
IPS=(); for a in $(node_names); do IPS+=("$(node_ip "$a")"); done

multi_a "$DOMAIN" "${IPS[@]}"                       # apex — на все ноды
multi_a "*.$DOMAIN" "${IPS[@]}"                     # wildcard-зона
upsert NS "_acme-challenge.$DOMAIN" "dns.$DOMAIN"   # без них DNS-01 wildcard невозможен
upsert NS "cname.$DOMAIN" "dns.$DOMAIN"
upsert NS "site.$DOMAIN" "dns.$DOMAIN"
for a in $(node_names); do
  upsert A "$a.$DOMAIN" "$(node_ip "$a")"           # живая запись ноды (держит ddns)
  upsert A "vpn-$a.$DOMAIN" "$(node_ip "$a")"       # маска ноды — ТОЛЬКО своя (wildcard нельзя)
done
multi_a "dns.$DOMAIN" "${IPS[@]}"                   # хаб + Pangolin DNS
multi_a "tg.$DOMAIN" "${IPS[@]}"                    # mtproto-маска (секрет один — ходим на любую ноду)
for c in pangolin komodo rem app; do
  upsert CNAME "$c.$DOMAIN" "dns.$DOMAIN"
done

step "ddns и учётки сертификатов на нодах"
for a in $(node_names); do
  nssh "$a" "mkdir -p /root/.secrets /var/lib/ddns
    cat > /etc/ddns.env <<EOF
CF_TOKEN='$CF_API_TOKEN'
CF_ZONE_NAME='$DOMAIN'
NODE_NAME='$a'
HUB_NAME='dns'
EOF
    chmod 600 /etc/ddns.env
    printf 'dns_cloudflare_api_token = %s\n' '$CF_API_TOKEN' > /root/.secrets/cloudflare.ini
    chmod 600 /root/.secrets/cloudflare.ini
    printf 'CF_DNS_API_TOKEN=%s\nCLOUDFLARE_DNS_API_TOKEN=%s\n' '$CF_API_TOKEN' '$CF_API_TOKEN' > /etc/db/secrets/traefik-cf.env
    chmod 600 /etc/db/secrets/traefik-cf.env
    cat > /etc/cron.d/ddns <<EOF
*/2 * * * * root /usr/local/bin/ddns.sh >> /var/log/ddns.log 2>&1
@reboot root /usr/local/bin/ddns.sh >> /var/log/ddns.log 2>&1
EOF
    chmod 644 /etc/cron.d/ddns"
  ok "$a: ddns (каждые 2 мин), cloudflare.ini, traefik-cf.env"
done

echo
ok "DNS готов: зона $DOMAIN указывает на ноды, сертификаты смогут выдаваться через DNS-01"
