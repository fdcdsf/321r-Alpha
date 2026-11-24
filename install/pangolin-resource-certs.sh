#!/usr/bin/env bash
# Файловые сертификаты ресурсов Pangolin через certbot/Cloudflare (без EE ACME).
# Запуск с первого сервера: bash install/pangolin-resource-certs.sh komodo [rem sub ...]
# Каждый traefik обслуживает свой IP, поэтому сертификат требуется на каждой ноде.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
[ -n "${DOMAIN:-}" ] || fail "нет DOMAIN"
CHECK_PATH="/"
if [[ "${1:-}" == --check-path=* ]]; then
  CHECK_PATH="${1#--check-path=}"
  [[ "$CHECK_PATH" =~ ^/[a-zA-Z0-9_-]{0,80}$ ]] || fail "неверный путь проверки ресурса"
  shift
fi
[ "$#" -gt 0 ] || fail "укажите минимум один ресурс (например komodo)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Скрипт для ноды пишем ОТДЕЛЬНЫМ файлом и БЕЗ set -e: повторы и проверки решают
# сами. Раньше блок шёл под set -e — первая же неудача certbot или curl убивала его
# молча, не доходя до своих же повторов («попытка N» никогда не выполнялась).
gen_node_script() {
  cat > "$TMP/res-cert.sh" <<'EOS'
#!/usr/bin/env bash
HOST='@HOST@'; NAME='@NAME@'; DOMAIN='@DOMAIN@'; CHECK_PATH='@PATH@'
set -u
[ -f /root/.secrets/cloudflare.ini ] || { echo "  нет /root/.secrets/cloudflare.ini"; exit 1; }
[ -d /opt/pangolin/config/dynamic ] || { echo "  нет /opt/pangolin/config/dynamic"; exit 1; }
ok=""
for try in 1 2 3; do
  if certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
       --dns-cloudflare-propagation-seconds 60 \
       -d "$HOST" --non-interactive --agree-tos -m "admin@$DOMAIN" \
       >"/tmp/certbot-$NAME.log" 2>&1 \
     && [ -s "/etc/letsencrypt/live/$HOST/fullchain.pem" ]; then
    ok=1; break
  fi
  echo "  попытка $try: сертификат не выдан, жду 30 с"
  tail -2 "/tmp/certbot-$NAME.log" 2>/dev/null | sed 's/^/    /'
  sleep 30
done
if [ -z "$ok" ]; then
  echo "  certbot не справился за 3 попытки (лог: /tmp/certbot-$NAME.log)"
  exit 1
fi
[ -s "/etc/letsencrypt/live/$HOST/privkey.pem" ] || { echo "  нет privkey.pem"; exit 1; }
f="/opt/pangolin/config/dynamic/321r-resource-$NAME.yml"
printf '%s\n' 'tls:' '  certificates:' \
  "    - certFile: /etc/letsencrypt/live/$HOST/fullchain.pem" \
  "      keyFile: /etc/letsencrypt/live/$HOST/privkey.pem" > "$f.tmp"
mv -f "$f.tmp" "$f"
for i in $(seq 1 36); do
  curl -fsS -o /dev/null --max-time 12 --resolve "$HOST:443:127.0.0.1" "https://$HOST$CHECK_PATH" 2>/dev/null && break
  sleep 5
done
if curl -fsS -o /dev/null --max-time 12 --resolve "$HOST:443:127.0.0.1" "https://$HOST$CHECK_PATH" 2>/dev/null; then
  echo "сертификат $HOST выдан, traefik отдаёт доверенный TLS"
else
  echo "  $HOST: нет доверенного TLS. Причины по частоте: (1) не выдан wildcard-сертификат"
  echo "  Pangolin для ресурсов — см. pangolin-wildcard-repair.sh и status в таблице certificates;"
  echo "  (2) нет маршрута для имени (см. /opt/pangolin/config/dynamic/);"
  echo "  (3) не подхватился файловый сертификат (логи traefik)."
  exit 1
fi
EOS
  sed -i "s/@HOST@/$1/g; s/@NAME@/$2/g; s/@DOMAIN@/$DOMAIN/g; s|@PATH@|$CHECK_PATH|g" "$TMP/res-cert.sh"
}

for name in "$@"; do
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || fail "недопустимое имя ресурса: $name"
  host="$name.$DOMAIN"
  step "Ресурс $host: сертификат DNS-01 на каждой ноде"
  gen_node_script "$host" "$name"
  pids=(); bad=0
  for a in $(node_names); do
    (
      ncp "$a" "$TMP/res-cert.sh" /tmp/res-cert.sh
      nssh "$a" 'bash /tmp/res-cert.sh; rc=$?; rm -f /tmp/res-cert.sh; exit $rc'
    ) 2>&1 | sed "s/^/[$a] /" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
  [ "$bad" = 0 ] || fail "$host: сертификат не готов на всех нодах (логи certbot/traefik)"
done
