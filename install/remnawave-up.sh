#!/usr/bin/env bash
# 321r · шаг: Remnawave (панель на кластере ИЛИ дома) + ноды Xray + маскировка.
# Идемпотентен. Запускается: bash install/remnawave-up.sh
# Требует: шаги db (pg remnawave) и dns (сертификаты DNS-01) уже пройдены.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ -n "${DOMAIN:-}" ] || { warn "нет DOMAIN — Remnawave/маски без домена невозможны, шаг пропущен"; exit 0; }
CTRL="$CONTROL"
MODE="${REMNAWAVE_MODE:-install}"
case "$MODE" in install|connect) ;; *) fail "REMNAWAVE_MODE должен быть install или connect" ;; esac
PANEL_URL="${REMNAWAVE_PANEL_URL:-https://rem.$DOMAIN}"
[[ "$PANEL_URL" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || fail "REMNAWAVE_PANEL_URL должен быть HTTPS-адресом без пути"
H="$ROOT/deploy/remnawave"
if [ "$MODE" = connect ]; then
  [ -s "$SECRETS/remnawave-api.token" ] || fail "connect требует $SECRETS/remnawave-api.token"
  curl -fsS -o /dev/null --max-time 15 "$PANEL_URL/api/auth/status" \
    || fail "домашняя панель недоступна по $PANEL_URL — сначала подключите Newt и ресурс rem.$DOMAIN"
fi

step "Сертификаты маскировки (DNS-01, свой vpn-<имя> + tg на каждой ноде)"
# certbot в базовый набор не входит; без сертификатов nginx маски не стартует.
for a in $(node_names); do
  nssh "$a" 'command -v certbot >/dev/null 2>&1 || {
    for i in $(seq 1 30); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 5; done
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null; }'
  ok "$a: certbot готов"
done
pids=(); bad=0
for a in $(node_names); do
  (
    nssh "$a" "set -e
      d='/etc/letsencrypt/live/vpn-$a.$DOMAIN'
      if [ -s \"\$d/fullchain.pem\" ]; then
        certbot renew --cert-name 'vpn-$a.$DOMAIN' --non-interactive >/dev/null
      else
        # DNS-01 надо ждать: 10 с по умолчанию мало при одновременных запросах
        # нескольких нод по одной зоне ().
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
          --dns-cloudflare-propagation-seconds 60 \
          --cert-name vpn-$a.$DOMAIN -d vpn-$a.$DOMAIN -d tg.$DOMAIN \
          --non-interactive --agree-tos -m admin@$DOMAIN >/dev/null
      fi
      if [ -n \"\$d\" ]; then
        test -s \"\$d/fullchain.pem\"
        ln -sfn \"\$d\" /etc/letsencrypt/live/mask
        echo 'маска: сертификат vpn-$a.$DOMAIN готов'
      else
        echo \"СЕРТИФИКАТ НЕ ВЫДАН — nginx маски не будет запущен\" >&2
        exit 1
      fi"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "без сертификатов маски не работают — смотрите вывод certbot выше"

step "nginx-заглушки маски (9447 http, 8448 ssl) + страница-приманка"
for a in $(node_names); do
  nssh "$a" 'command -v nginx >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq nginx >/dev/null; }'
  sed "s/tg\.321r\.ru/tg.$DOMAIN/g" "$H/nginx-mask.conf" | nssh "$a" 'cat > /etc/nginx/sites-enabled/mask'
  # дефолтный сайт nginx лезет на :80, а его держит gerbil Pangolin («bind() to
  # 0.0.0.0:80 failed»). Заглушке маски :80 не нужен — убираем. И учтите: nginx -t
  # занятые порты НЕ ловит — проверяем именно старт.
  nssh "$a" 'rm -f /etc/nginx/sites-enabled/default
    mkdir -p /var/www/mask
    [ -f /var/www/mask/index.html ] || echo "<html><body>Welcome</body></html>" > /var/www/mask/index.html
    nginx -t >/dev/null 2>&1 || { echo "nginx -t падает (нет сертификатов?)" >&2; exit 1; }
    systemctl restart nginx
    systemctl is-active --quiet nginx || { echo "nginx не стартовал (порт занят?)" >&2; exit 1; }'
  ok "$a: nginx-заглушки на месте"
done

if [ "$MODE" = install ]; then
 step "Панель Remnawave на $CTRL (БД — наш VIP:5433)"
 if nssh "$CTRL" 'docker ps --format "{{.Names}}" | grep -qx remnawave'; then
   ok "панель уже работает"
 else
  nssh "$CTRL" 'mkdir -p /opt/remnawave/subscription /var/lib/dbdata'
  ncp "$CTRL" "$H/remnawave-compose.yml" /opt/remnawave/docker-compose.yml
  ncp "$CTRL" "$H/subpage-compose.yml" /opt/remnawave/subscription/docker-compose.yml
  nssh "$CTRL" 'set -e
    cd /opt/remnawave
    APP_PASS=$(grep "^APP_PASSWORD=" /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d "\"")
    SECRET=$(openssl rand -hex 24)
    METPASS=$(openssl rand -hex 10)
    cat > .env <<EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL=postgresql://remnawave:${APP_PASS}@10.66.0.99:5433/remnawave
REDIS_SOCKET=/var/run/valkey/valkey.sock
APP_SECRET=${SECRET}
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
PANEL_DOMAIN=rem.'"$DOMAIN"'
FRONT_END_DOMAIN=rem.'"$DOMAIN"'
SUB_PUBLIC_DOMAIN=sub.'"$DOMAIN"'
METRICS_USER=metrics
METRICS_PASS=${METPASS}
WEBHOOK_ENABLED=false
SHORT_UUID_METHOD=nanoid
SERVICE_SNI_VERIFICATION=false
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${APP_PASS}
POSTGRES_DB=remnawave
EOF
    chmod 600 .env
    docker compose up -d'
   ok "панель поднята (первый старт — миграции, ~1-2 мин)"
 fi
else
  step "Подключение к домашней Remnawave ($PANEL_URL)"
  [ -s "$SECRETS/remnawave-api.token" ] || fail "connect требует $SECRETS/remnawave-api.token"
  ok "панель на VPS не устанавливаю"
fi

if [ "$MODE" = install ]; then
  step "Локальные HC-адаптеры Remnawave"
  sed "s/sub\.321r\.ru/sub.$DOMAIN/g" "$H/nginx-subpage-hc.conf" | nssh "$CTRL" 'cat > /etc/nginx/sites-enabled/subpage-hc'
  sed "s/__DOMAIN__/$DOMAIN/g" "$H/nginx-rem-hc.conf" | nssh "$CTRL" 'cat > /etc/nginx/sites-enabled/rem-hc'
  nssh "$CTRL" 'nginx -t >/dev/null 2>&1 && systemctl reload nginx' || fail "nginx HC-конфиг не применился"
  # На чистой БД Remnawave мигрирует ~1–2 мин: до healthy nginx отдаёт 502.
  hc_ok=""
  for i in $(seq 1 60); do
    if nssh "$CTRL" 'curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3012/ 2>/dev/null'; then
      hc_ok=1; break
    fi
    sleep 5
  done
  [ -n "$hc_ok" ] || fail "Remnawave HC :3012 не отвечает за 5 минут"
fi

step "VPN-ноды Xray (remnanode) ×3"
for a in $(node_names); do
  if nssh "$a" 'docker ps --format "{{.Names}}" | grep -qx remnanode'; then
    ok "$a: remnanode уже работает"
    continue
  fi
  nssh "$a" 'mkdir -p /opt/remnanode'
  ncp "$a" "$H/remnanode-compose.yml" /opt/remnanode/docker-compose.yml
  nssh "$a" 'ufw allow from 172.16.0.0/12 to any port 2099 proto tcp >/dev/null 2>&1
    ufw allow 2087/tcp >/dev/null 2>&1
    ufw allow from 172.16.0.0/12 to any port 9446 proto tcp >/dev/null 2>&1'
  ok "$a: remnanode расписан (SECRET_KEY и регистрация — следующий шаг, нужна панель)"
done

step "Маска Telegram (mtproto.zig) на всех нодах"
MSEC_FILE="$SECRETS/mtproto-secret"
[ -f "$MSEC_FILE" ] || openssl rand -hex 16 > "$MSEC_FILE"
MSEC="$(cat "$MSEC_FILE")"
pids=()
for a in $(node_names); do
  (
    nssh "$a" 'set -e
      if ! command -v mtbuddy >/dev/null 2>&1; then
        mkdir -p /tmp/mtb
        curl -fsSL https://github.com/sleep3r/mtproto.zig/releases/download/v1.15.4/mtbuddy-linux-x86_64.tar.gz | tar xz -C /tmp/mtb
        bin=$(find /tmp/mtb -type f -name "mtbuddy*" | head -1)
        install -m 755 "$bin" /usr/local/bin/mtbuddy
        rm -rf /tmp/mtb
      fi
      echo "mtbuddy: $(/usr/local/bin/mtbuddy --version 2>/dev/null | head -1 || echo есть)"'
    sed -e "s/tg\.321r\.ru/tg.$DOMAIN/g" -e "s/user = \".*\"/user = \"$MSEC\"/" "$H/mtproto-config.toml" \
      | nssh "$a" 'cat > /root/mtproto-config.toml'
    nssh "$a" 'if [ ! -x /opt/mtproto-proxy/mtproto-proxy ]; then
        /usr/local/bin/mtbuddy install --config /root/mtproto-config.toml --no-dpi --yes >/dev/null 2>&1 || true
      fi
      systemctl enable --now mtproto-proxy.service >/dev/null 2>&1 || true
      # mtbuddy сам открывает порт наружу — закрываем и открываем только от docker
      ufw status numbered | grep -E "8446.*ALLOW.*Anywhere" | cut -d"]" -f1 | tr -d " [" | sort -rn | xargs -r -n1 ufw --force delete >/dev/null 2>&1 || true
      ufw allow from 172.16.0.0/12 to any port 8446 proto tcp >/dev/null 2>&1 || true
      echo "mtproto: $(systemctl is-active mtproto-proxy.service 2>/dev/null || echo не-установлен)"'
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

step "WARP-туннель для mtproto (обход РКН; только mtproto)"
# Старая схема «tg-egress/mesh-egress через ноду-шлюз» не работает —
# Все ноды кластера в РФ, чужой egress не спасает. WARP
# (обфусцированный WireGuard до Cloudflare) выводит трафик mtproto наружу с IP Cloudflare.
# Через WARP идут только помеченные mtproto.zig сокеты (SO_MARK=200 от mtbuddy).
for a in $(node_names); do
  ncp "$a" "$ROOT/scripts/warp-321r.sh" /usr/local/bin/warp-321r.sh
  ncp "$a" "$H/warp.service" /etc/systemd/system/warp.service
  nssh "$a" 'chmod +x /usr/local/bin/warp-321r.sh
    systemctl daemon-reload
    systemctl enable warp.service >/dev/null 2>&1 || true'
done
# Один файл на весь кластер запрещён: для каждой ноды свой приватный ключ WARP.
# Инвентарь: WARP_CONF_a=/path/a.conf (или отдельная загрузка через бот).
declare -A WARP_HASHES=()
for a in $(node_names); do
  var="WARP_CONF_$a"; src="${!var:-}"
  if nssh "$a" '[ -s /etc/amnezia/amneziawg/warp.conf ]'; then
    ok "$a: WARP-конфиг уже есть, не перезаписываю (могли заменить через бота)"
  elif [ -n "$src" ]; then
    [ -f "$src" ] || fail "$a: WARP-конфиг не найден ($src)"
    hash="$(sha256sum "$src" | cut -d' ' -f1)"
    [ -z "${WARP_HASHES[$hash]:-}" ] || fail "$a: WARP-конфиг совпадает с ${WARP_HASHES[$hash]} — каждой ноде нужен свой ключ"
    WARP_HASHES[$hash]="$a"
    ncp "$a" "$src" /etc/amnezia/amneziawg/warp.conf
    nssh "$a" 'chmod 600 /etc/amnezia/amneziawg/warp.conf'
    ok "$a: индивидуальный WARP-конфиг разложен"
  fi
done
pids=()
for a in $(node_names); do
  (
    if nssh "$a" '[ -f /etc/amnezia/amneziawg/warp.conf ]'; then
      nssh "$a" 'systemctl start warp.service >/dev/null 2>&1 || true
        sleep 1; /usr/local/bin/warp-321r.sh status' || echo "warp: не поднялся (см. awg show warp)"
    else
      echo "warp: нет конфига — пропущен"
    fi
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
# Старую схему сносим целиком (юниты, скрипты, маршруты, правку AllowedIPs в wg0.conf)
for a in $(node_names); do
  nssh "$a" 'systemctl disable --now tg-egress.service mesh-egress.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/tg-egress.service /etc/systemd/system/mesh-egress.service
    rm -f /usr/local/bin/tg-egress.sh /usr/local/bin/mesh-egress.sh
    systemctl daemon-reload
    ip route del 91.108.4.0/22 2>/dev/null || true
    ip route del 91.108.8.0/22 2>/dev/null || true
    ip route del 91.108.56.0/22 2>/dev/null || true
    ip route del 149.154.160.0/20 2>/dev/null || true'
done
ok "старая схема egress через шлюз удалена; mtproto использует WARP при наличии индивидуального конфига"

step "Traefik-маска (passthrough vpn-* и tg)"
# force-recreate gerbil/traefik через compose НАДЕЖНО зависает (traefik живёт в
# netns gerbil). Динамические конфиги traefik перечитываются сами — достаточно
# Рестарта самого traefik (gerbil не трогаем: его одиночный рестарт рвёт ingress).
for a in $(node_names); do
  gw="$(nssh "$a" "docker network inspect pangolin --format '{{(index .IPAM.Config 0).Gateway}}'")"
  [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$a: не найден gateway Docker-сети pangolin"
  sed -e "s/321r\.ru/$DOMAIN/g" -e "s/__NODE__/$a/g" -e "s/172\.22\.0\.1/$gw/g" "$H/mask_config.yml" \
    | nssh "$a" 'cat > /opt/pangolin/config/dynamic/mask_config.yml'
  nssh "$a" 'docker restart traefik >/dev/null 2>&1 || true' &
done
wait
ok "маска подключена к traefik (каждая VPN-нода — только свой SNI и IP)"

step "Доступ к панели и автонастройка минимального VPN (режим $MODE)"
if [ "$MODE" = install ]; then
  # Панель слушает localhost control-ноды, Newt cluster-<control> ведёт к ней.
  panel_health=""
  for i in $(seq 1 60); do
    panel_health="$(nssh "$CTRL" 'docker inspect -f "{{.State.Health.Status}}" remnawave 2>/dev/null' || true)"
    [ "$panel_health" = healthy ] && break
    sleep 5
  done
  [ "$panel_health" = healthy ] || fail "панель Remnawave не healthy за 5 минут"
  [ -s /etc/db/secrets/pangolin-admin.json ] \
    || fail "для автоматического ресурса rem.$DOMAIN нужна автонастройка Pangolin"
  python3 "$ROOT/scripts/pangolin-resources.py" --url "https://pangolin.$DOMAIN" \
    --org-id cluster --domain "$DOMAIN" \
    --spec "rem:$CTRL:127.0.0.1:3000:http:3012:/" \
    --repair-ip "$(node_ip "$(node_names | head -1)")"
  bash "$HERE/pangolin-resource-certs.sh" rem
else
  # Домашний Proxmox за серым IP: сначала создать site cluster-home и запустить
  # install/home-newt.sh внутри LXC, затем направить rem.<домен> к домашней панели.
  curl -fsS -o /dev/null --max-time 15 "$PANEL_URL/api/auth/status" \
    || fail "домашняя панель недоступна по $PANEL_URL — подключите Newt и ресурс rem.$DOMAIN"
fi

args=(--mode "$MODE" --panel-url "$PANEL_URL"
      --admin-file /etc/db/secrets/remnawave-admin.json
      --token-file "$SECRETS/remnawave-api.token")
python3 "$ROOT/scripts/remnawave-bootstrap.py" "${args[@]}"
node_args=()
for a in $(node_names); do node_args+=(--node "$a:$(node_mesh "$a")"); done
python3 "$ROOT/scripts/remnawave-nodes.py" "${args[@]}" \
  --ssh-key "$SSH_KEY" --compose "$H/remnanode-compose.yml" "${node_args[@]}"
mask_args=()
for a in $(node_names); do mask_args+=(--node "$a"); done
python3 "$ROOT/scripts/remnawave-mask.py" "${args[@]}" --domain "$DOMAIN" "${mask_args[@]}"
ok "профиль, ноды и минимальная подписка настроены в режиме $MODE"
if [ "$MODE" = install ]; then
  step "Красивая страница подписки (официальный subscription-page)"
  python3 "$ROOT/scripts/remnawave-subpage.py" --panel-url "$PANEL_URL" \
    --control-ip "$(node_mesh "$CTRL")" --ssh-key "$SSH_KEY" \
    --compose "$H/subpage-compose.yml"
  raw="$(cat /etc/db/secrets/remnawave-probe-url)"
  short="${raw##*/}"
  [[ "$short" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "неверный shortUuid пробной подписки"
  sub_ok=""
  for i in $(seq 1 36); do
    if nssh "$CTRL" "curl -fsS -o /dev/null --max-time 8 -H 'X-Forwarded-For: 127.0.0.1' \
         -H 'X-Forwarded-Proto: https' -H 'Host: sub.$DOMAIN' \
         -H 'Accept: text/html' -A 'Mozilla/5.0 Chrome/124.0.0.0' \
         'http://127.0.0.1:3011/$short' 2>/dev/null"; then
      sub_ok=1; break
    fi
    sleep 5
  done
  [ -n "$sub_ok" ] || fail "страница подписки :3011 не отвечает"
  python3 "$ROOT/scripts/pangolin-resources.py" --url "https://pangolin.$DOMAIN" \
    --org-id cluster --domain "$DOMAIN" \
    --spec "sub:$CTRL:127.0.0.1:3010:http:3011:/$short" \
    --repair-ip "$(node_ip "$(node_names | head -1)")"
  bash "$HERE/pangolin-resource-certs.sh" "--check-path=/$short" sub
  # В браузере показываем UI; /api/sub/<shortUuid> остаётся для VPN-клиентов.
  for a in $(node_names); do
    response="$(nssh "$a" "curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' \
      --resolve 'sub.$DOMAIN:443:127.0.0.1' -H 'Accept: text/html' \
      -A 'Mozilla/5.0 Chrome/124.0.0.0' 'https://sub.$DOMAIN/$short' 2>/dev/null" || true)"
    [ "$response" = 200 ] || fail "$a: красивая страница не отвечает (HTTP ${response:-нет})"
  done
  ok "страница https://sub.$DOMAIN/<shortUuid> работает через каждую ноду"
fi
echo "Пробная подписка (сырой формат для клиента) — /etc/db/secrets/remnawave-probe-url."
echo "Ссылка маски Telegram — в памятке владельца (FakeTLS)."
