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
  [[ "$CHECK_PATH" =~ ^/[a-zA-Z0-9_-]{1,80}$ ]] || fail "неверный путь проверки ресурса"
  shift
fi
[ "$#" -gt 0 ] || fail "укажите минимум один ресурс (например komodo)"

for name in "$@"; do
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || fail "недопустимое имя ресурса: $name"
  host="$name.$DOMAIN"
  step "Ресурс $host: сертификат DNS-01 на каждой ноде"
  pids=(); bad=0
  for a in $(node_names); do
    (
      nssh "$a" "set -e
        test -f /root/.secrets/cloudflare.ini
        test -d /opt/pangolin/config/dynamic
        ok=''
        for try in 1 2 3; do
          certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 60 \
            -d '$host' --non-interactive --agree-tos -m 'admin@$DOMAIN' > /dev/null 2>&1
          if test -s '/etc/letsencrypt/live/$host/fullchain.pem'; then ok=1; break; fi
          echo \"  попытка \$try: сертификат не выдан, жду 30 с\"
          sleep 30
        done
        test -n \"\$ok\"
        test -s '/etc/letsencrypt/live/$host/fullchain.pem'
        test -s '/etc/letsencrypt/live/$host/privkey.pem'
        f='/opt/pangolin/config/dynamic/321r-resource-$name.yml'
        printf '%s\\n' 'tls:' '  certificates:' \
          '    - certFile: /etc/letsencrypt/live/$host/fullchain.pem' \
          '      keyFile: /etc/letsencrypt/live/$host/privkey.pem' > \"\$f.tmp\"
        mv -f \"\$f.tmp\" \"\$f\"
        for i in \$(seq 1 36); do
          curl -fsS -o /dev/null --max-time 12 \
            --resolve '$host:443:127.0.0.1' 'https://$host$CHECK_PATH' 2>/dev/null && break
          sleep 5
        done
        curl -fsS -o /dev/null --max-time 12 \
          --resolve '$host:443:127.0.0.1' 'https://$host$CHECK_PATH' 2>/dev/null
        echo 'сертификат $host выдан, traefik отдаёт доверенный TLS'"
    ) 2>&1 | sed "s/^/[$a] /" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
  [ "$bad" = 0 ] || fail "$host: сертификат не готов на всех нодах (логи certbot/traefik)"
done
