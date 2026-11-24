#!/usr/bin/env bash
# 321r: привести блок приложения в haproxy (db-proxy) к реестру — НА ЭТОЙ ноде.
# Вызывать на всех нодах после смены состава БД (app-move, app-member) и вручную.
#   db-proxy-sync.sh <app>
#
# Особенность: блок PostgreSQL держит db-guard (один upstream = текущий первичный),
# поэтому существующий блок pg не переписываем — иначе отменим фейловер. Блок mongo
# перечисляет всех членов и всегда пересобирается по placement.
set -euo pipefail

APP="${1:?использование: db-proxy-sync.sh <app>}"
REG="/etc/db/apps.d/${APP}.yaml"
[ -f "$REG" ] || { echo "нет реестра $REG" >&2; exit 1; }

val() { sed -n "s/^$1: *//p" "$REG" | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
ENGINE="$(val engine | tr -d ' ')"
CLASS="$(val class | tr -d ' ')"
PORT="$(val port | tr -d ' ')"
read -r -a NODES < <(val placement | tr -d '[] ' | tr ',' ' ')
CLASS="${CLASS:-cluster}"
[ "$CLASS" = cluster ] || { echo "$APP: class=$CLASS — прокси не нужен"; exit 0; }
[ -n "$ENGINE" ] && [ -n "$PORT" ] && [ "${#NODES[@]}" -ge 1 ] || { echo "$REG: неполный реестр" >&2; exit 1; }
[ -f /etc/db/nodes.map ] || { echo "нет /etc/db/nodes.map" >&2; exit 1; }
map_ip() { awk -v a="$1" '$1==a{print $2}' /etc/db/nodes.map; }

DIR=/opt/db/proxy
CFG="$DIR/haproxy.cfg"
mkdir -p "$DIR"
[ -f "$CFG" ] || cat > "$CFG" <<'EOF'
global
  log stdout format raw local0
defaults
  mode tcp
  log global
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF

if [ "$ENGINE" = pg ] && sed -n "/# BEGIN ${APP}/,/# END ${APP}/p" "$CFG" | grep -q 'server primary'; then
  echo "$APP: блок pg уже есть — upstream держит db-guard, не трогаю"
  exit 0
fi

BLOCK="$(mktemp)"
{
  echo "# BEGIN ${APP}"
  if [ "$ENGINE" = pg ]; then
    upip="$(map_ip "$(val primary)")"
    echo "listen pg-${APP}"
    echo "  bind 10.66.0.99:${PORT}"
    echo "  mode tcp"
    echo "  server primary ${upip}:${PORT} check"
  else
    echo "listen mongo-${APP}"
    echo "  bind 10.66.0.99:${PORT}"
    echo "  mode tcp"
    for n in "${NODES[@]}"; do
      ip="$(map_ip "$n")"; [ -n "$ip" ] || continue
      echo "  server m-${n} ${ip}:${PORT} check"
    done
  fi
  echo "# END ${APP}"
} > "$BLOCK"

# правим БЕЗ замены inode: ro-монтирование контейнера держит старую копию файла
sed "/# BEGIN ${APP}/,/# END ${APP}/d" "$CFG" > "${CFG}.tmp"
cat "${CFG}.tmp" > "$CFG"
rm -f "${CFG}.tmp"
cat "$BLOCK" >> "$CFG"
rm -f "$BLOCK"
chmod 644 "$CFG"

[ -f "$DIR/docker-compose.yml" ] || cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: haproxy:3.0-alpine
    container_name: db-proxy
    restart: unless-stopped
    network_mode: host
    mem_limit: 128m
    volumes:
      - /opt/db/proxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
EOF

cd "$DIR"
docker compose up -d >/dev/null 2>&1 || true
docker exec db-proxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null
docker restart db-proxy >/dev/null
echo "$APP: блок прокси обновлён на $(hostname) (${ENGINE}: ${NODES[*]})"
