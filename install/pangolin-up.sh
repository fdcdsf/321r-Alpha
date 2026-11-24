#!/usr/bin/env bash
# 321r · шаг: Pangolin (панель доступа к сервисам) + Valkey + gerbil/traefik.
# Идемпотентен. Запускается с ноутбука/мастера: bash install/pangolin-up.sh
# Рендер конфигов идёт НА НОДАХ — пароли не покидают серверы.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [ -z "${DOMAIN:-}" ] || [ -z "${CF_API_TOKEN:-}" ]; then
  warn "DOMAIN или CF_API_TOKEN пусты — Pangolin без домена невозможен, шаг пропущен"
  exit 0
fi
EMAIL="${EMAIL:-admin@$DOMAIN}"
VALKEY_NODE="$CONTROL"
TRUSTED="$(for a in $(node_names); do node_ip "$a"; done | tr '\n' ','; for a in $(node_names); do node_mesh "$a"; done | tr '\n' ',' | sed 's/,$//')"
TRUSTED="${TRUSTED%,}"
ACME_NODE="$CONTROL"

step "Valkey (кэш Pangolin) на ноде $VALKEY_NODE"
if nssh "$VALKEY_NODE" 'docker ps --format "{{.Names}}" | grep -qx valkey'; then
  ok "valkey уже работает"
else
  nssh "$VALKEY_NODE" 'mkdir -p /opt/valkey /var/lib/dbdata/valkey'
  sed "s|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g" "$ROOT/stacks/valkey.yml" \
    | nssh "$VALKEY_NODE" 'cat > /opt/valkey/docker-compose.yml'
  nssh "$VALKEY_NODE" 'cd /opt/valkey && docker compose up -d' >/dev/null
  ok "valkey поднят ($(node_mesh "$VALKEY_NODE"):6379)"
fi

step "Секреты Pangolin (server.secret и APP_PASSWORD — одинаковые на всех нодах)"
SS_FILE="$SECRETS/pangolin-server-secret"
[ -f "$SS_FILE" ] || openssl rand -hex 24 > "$SS_FILE"
SS="$(cat "$SS_FILE")"
# APP_PASSWORD db-add создаёт ТОЛЬКО на первичной ноде, а Pangolin рендерит
# config.yml на ВСЕХ нодах (на нодах вне placement пароля не
# Было -> connection_string оставался пустым, Pangolin падал с
# «SASL: client password must be a string»). Собираем пароль с любой ноды,
# Где он есть, и раздаём всем.
APP_PASS=""
for a in $(node_names); do
  APP_PASS="$(nssh "$a" "grep '^APP_PASSWORD=' /etc/db/secrets/pangolin.env 2>/dev/null | cut -d= -f2- | tr -d '\"'" || true)"
  [ -n "$APP_PASS" ] && break
done
[ -n "$APP_PASS" ] || fail "нет APP_PASSWORD ни на одной ноде — сначала шаг db (db-add pangolin)"
for a in $(node_names); do
  nssh "$a" "umask 077
    grep -q PANGOLIN_SERVER_SECRET /etc/db/secrets/pangolin.env 2>/dev/null \
      || echo 'PANGOLIN_SERVER_SECRET=$SS' >> /etc/db/secrets/pangolin.env
    grep -q '^APP_PASSWORD=' /etc/db/secrets/pangolin.env 2>/dev/null \
      || echo 'APP_PASSWORD=$APP_PASS' >> /etc/db/secrets/pangolin.env
    chmod 600 /etc/db/secrets/pangolin.env
    grep -q '^APP_PASSWORD=..*' /etc/db/secrets/pangolin.env \
      || { echo 'APP_PASSWORD пустой — конфиг Pangolin будет сломан' >&2; exit 1; }"
  ok "$a: pangolin.env готов (server.secret + APP_PASSWORD)"
done

step "Сертификат дашборда (certbot DNS-01 → файл для traefik)"
# Собственный ACME traefik с dnsChallenge в Cloudflare здесь НЕ работает —
# NS _acme-challenge.<домен> делегирован встроенной DNS Pangolin (это нужно для wildcard),
# Проверка уходит туда, где нет TXT, записанного traefik через API → TRAEFIK DEFAULT CERT
# (браузер блокирует панель). certbot — путь, уже доказанный масками VPN. Идемпотентно:
# Сертификат есть и не просрочен — certbot ничего не перезапрашивает.
for a in $(node_names); do
  nssh "$a" 'command -v certbot >/dev/null 2>&1 || {
    for i in $(seq 1 30); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 5; done
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null; }
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true'
  ok "$a: certbot готов"
done
pids=(); bad=0
for a in $(node_names); do
  (
    ncp "$a" "$ROOT/scripts/panel-cert-reload.sh" "/usr/local/bin/panel-cert-reload.sh"
    nssh "$a" "chmod 755 /usr/local/bin/panel-cert-reload.sh
      mkdir -p /etc/letsencrypt/renewal-hooks/deploy
      cp /usr/local/bin/panel-cert-reload.sh /etc/letsencrypt/renewal-hooks/deploy/
      # DNS-01 надо ЖДАТЬ: когда несколько нод почти одновременно запрашивают
      # сертификаты по одной зоне, 10 с по умолчанию не хватает и часть падает с
      # «CA failed to verify the DNS TXT records» (). Плюс повтор.
      ok=''
      for try in 1 2 3; do
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
          --dns-cloudflare-propagation-seconds 60 \
          -d pangolin.$DOMAIN --non-interactive --agree-tos -m $EMAIL 2>&1 | tail -3
        d=\"/etc/letsencrypt/live/pangolin.$DOMAIN\"
        if [ -f \"\$d/fullchain.pem\" ] && [ -f \"\$d/privkey.pem\" ]; then ok=1; break; fi
        echo \"  попытка \$try: сертификат не выдан, жду 30 с\"
        sleep 30
      done
      [ -n \"\$ok\" ] || { echo 'СЕРТ ДАШБОРДА НЕ ВЫДАН' >&2; exit 1; }
      echo 'сертификат дашборда выдан/актуален'"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "сертификат дашборда не выдан на всех нодах — смотрите вывод certbot"

step "Рендер /opt/pangolin (без запуска: миграции БД выполняет одна нода)"
pids=(); bad=0
for a in $(node_names); do
  (
    nssh "$a" 'mkdir -p /opt/pangolin/config/{traefik,dynamic,certificates}'
    for f in config.yml.tmpl privateConfig.yml.tmpl traefik_config.yml.tmpl docker-compose.yml.tmpl; do
      ncp "$a" "$ROOT/deploy/pangolin/$f" "/opt/pangolin/$f"
    done
    # домен в шаблонах был захардкожен (321r.ru) и не рендерился вовсе —
    # у пользователя с другим доменом панель не работала бы вообще. Рендерим $DOMAIN.
    sed "s/321r\.ru/$DOMAIN/g" "$ROOT/deploy/pangolin/dynamic_config.yml" \
      | nssh "$a" 'cat > /opt/pangolin/config/dynamic/dynamic_config.yml'
    sed "s/321r\.ru/$DOMAIN/g" "$ROOT/deploy/pangolin/panel_cert.yml" \
      | nssh "$a" 'cat > /opt/pangolin/config/dynamic/panel_cert.yml'
    acme=false; [ "$a" = "$ACME_NODE" ] && acme=true
    nssh "$a" "set -e
      cd /opt/pangolin
      APP_PASS=\$(grep '^APP_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"')
      SEC=\$(grep '^PANGOLIN_SERVER_SECRET=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"')
      sed -e \"s|__APP_DB_PASS__|\$APP_PASS|g\" -e \"s|__SERVER_SECRET__|\$SEC|g\" \
          -e \"s|__EXTERNAL_IP__|$(node_ip "$a")|g\" -e \"s|__EXIT_NODE__|$a|g\" \
          -e \"s|321r\\.ru|$DOMAIN|g\" \
          -e 's|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g' config.yml.tmpl > config/config.yml
      sed -e 's|__EMAIL__|$EMAIL|g' -e 's|__ACME__|$acme|g' -e \"s|321r\\.ru|$DOMAIN|g\" \
          -e 's|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g' privateConfig.yml.tmpl > config/privateConfig.yml
      sed -e 's|__EMAIL__|$EMAIL|g' traefik_config.yml.tmpl > config/traefik/traefik_config.yml
      sed -e 's|__MESH_IP__|$(node_mesh "$a")|g' -e 's|__TRUSTED__|$TRUSTED|g' \
          docker-compose.yml.tmpl > docker-compose.yml
      chmod 600 config/config.yml config/privateConfig.yml"
    echo "конфиги готовы"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "конфиги Pangolin разложены не на все ноды — смотрите вывод"

# На чистой БД: если все три контейнера стартуют
# Одновременно, каждый запускает drizzle migrations.mjs. В общей БД гонка
# CREATE TABLE / versionMigrations → два контейнера становятся unhealthy.
# Один мигрирует и полностью запускает API, только потом стартуют остальные.
wait_pangolin() {
  local a="$1" st="" i
  for i in $(seq 1 60); do
    st="$(nssh "$a" 'docker inspect -f "{{.State.Health.Status}}" pangolin 2>/dev/null' || true)"
    [ "$st" = healthy ] && { ok "$a: панель healthy"; return 0; }
    sleep 5
  done
  fail "$a: Pangolin не стал healthy (последний статус: $st); смотрите docker logs pangolin"
}

FIRST="$(node_names | head -1)"
step "Миграции Pangolin — только $FIRST"
nssh "$FIRST" 'cd /opt/pangolin && docker compose up -d pangolin' >/dev/null
# Повторный запуск после неудачной параллельной миграции: compose не ретраит
# Уже созданный unhealthy-контейнер. Перезапускаем ТОЛЬКО панель, не gerbil.
st="$(nssh "$FIRST" 'docker inspect -f "{{.State.Health.Status}}" pangolin 2>/dev/null' || true)"
[ "$st" != unhealthy ] || nssh "$FIRST" 'docker restart pangolin >/dev/null'
wait_pangolin "$FIRST"

step "Pangolin на остальных нодах (схема БД уже готова)"
# Ноды готовим ПАРАЛЛЕЛЬНО: у каждой своя докачка образа, а их может быть
# Сколько угодно — последовательный цикл превращает установку в ползание
# (5 серверов, образы тянулись по очереди).
pids=(); bad=0
for a in $(node_names); do
  [ "$a" = "$FIRST" ] && continue
  (
    nssh "$a" 'cd /opt/pangolin && docker compose up -d pangolin' >/dev/null
    st="$(nssh "$a" 'docker inspect -f "{{.State.Health.Status}}" pangolin 2>/dev/null' || true)"
    [ "$st" != unhealthy ] || nssh "$a" 'docker restart pangolin >/dev/null'
    wait_pangolin "$a"
    echo "панель готова"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "панель Pangolin не стала healthy на всех нодах"

step "Gerbil и Traefik (после готовности всех панелей)"
pids=(); bad=0
for a in $(node_names); do
  ( nssh "$a" 'cd /opt/pangolin && docker compose up -d' >/dev/null && echo "стек запущен" ) \
    2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "gerbil/traefik не запустились на всех нодах"

step "Восстановление TCP-масок после переустановки Pangolin"
# Маски лежат в dynamic/ Pangolin. После чистого переустановления каталог
# Пустой — браузер панели работает, а mtproto/VPN на :443 незаметно пропадают.
# Gateway сети Docker на каждой ноде свой (например, c=172.21.0.1, а не 172.22.0.1).
if [ -f "$ROOT/deploy/remnawave/mask_config.yml" ]; then
  for a in $(node_names); do
    if nssh "$a" 'systemctl is-active --quiet mtproto-proxy.service'; then
      gw="$(nssh "$a" "docker network inspect pangolin --format '{{(index .IPAM.Config 0).Gateway}}'")"
      [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$a: не найден gateway Docker-сети pangolin"
      sed -e "s/321r\.ru/$DOMAIN/g" -e "s/__NODE__/$a/g" -e "s/172\.22\.0\.1/$gw/g" "$ROOT/deploy/remnawave/mask_config.yml" \
        | nssh "$a" 'cat > /opt/pangolin/config/dynamic/mask_config.yml'
      ok "$a: маски восстановлены (Docker gateway $gw)"
    fi
  done
fi

step "Лечение багов Pangolin (wildcard-repair) + cron"
pids=()
for a in $(node_names); do
  ( nssh "$a" "/usr/local/bin/pangolin-wildcard-repair.sh $(node_ip "$a") >/dev/null 2>&1 || true
    cat > /etc/cron.d/321r-pangolin <<EOF
*/30 * * * * root /usr/local/bin/pangolin-wildcard-repair.sh $(node_ip "$a") >> /var/log/wildcard-repair.log 2>&1
EOF
    chmod 644 /etc/cron.d/321r-pangolin" && echo "repair после старта + каждые 30 мин" ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

step "Второй проход: gerbil/traefik после оздоровления панели"
# compose с depends_on: service_healthy НЕ ретраит: если healthcheck на момент
# Первого up ещё не прошёл — gerbil/traefik не стартуют никогда. Сначала ждём панель.
# Ждём ВСЕ ноды одновременно: по очереди это до 3 минут на каждую.
pids=(); bad=0
for a in $(node_names); do
  (
    st=""
    for i in $(seq 1 36); do
      st="$(nssh "$a" 'docker inspect -f "{{.State.Health.Status}}" pangolin 2>/dev/null' || true)"
      [ "$st" = "healthy" ] && break
      sleep 5
    done
    nssh "$a" 'cd /opt/pangolin && docker compose up -d' >/dev/null 2>&1
    echo "панель $st — стек пересобран"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "второй проход gerbil/traefik прошёл не на всех нодах"

step "Проверка"
sleep 10
bad=0
for a in $(node_names); do
  line=""
  for c in pangolin gerbil traefik; do
    st="$(nssh "$a" "docker inspect -f '{{.State.Status}}' $c 2>/dev/null" || true)"
    line="$line $c=${st:-нет}"
    [ "$st" = "running" ] || bad=1
  done
  ok "$a:$line"
done
[ "$bad" = 0 ] || warn "не все контейнеры Pangolin поднялись — смотрите вывод выше"

step "Сертификат дашборда: что реально отдаёт traefik"
# Без этой проверки панель «работала» с TRAEFIK DEFAULT CERT, и это видел
# Только человек в браузере. Машинно ловим именно дефолтный серт.
sleep 5
for a in $(node_names); do
  iss="$(nssh "$a" "echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername pangolin.$DOMAIN 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" || true)"
  case "$iss" in
    *"TRAEFIK DEFAULT"*) warn "$a: дашборд отдаёт TRAEFIK DEFAULT CERT — смотрите логи certbot и panel_cert.yml" ;;
    *"issuer="*) ok "$a: сертификат дашборда: ${iss#issuer=}" ;;
    *) warn "$a: не удалось проверить сертификат дашборда" ;;
  esac
done

if [ "${PANGOLIN_SETUP_MODE:-manual}" = auto ]; then
  echo "Pangolin и сертификат дашборда готовы. Дальше установщик автоматически создаст админа, организацию и сайты; лицензию EE владелец вводит сам."
else
  cat <<EOF
  Pangolin поднят на всех нодах, сертификат дашборда — Let's Encrypt (certbot).
  Ручной режим: открыть https://pangolin.$DOMAIN и пройти первичный онбординг (админ + 2FA).
  Код первичной настройки — в памятке или docker logs pangolin | grep -A1 'SETUP TOKEN'.
  Затем ввести EE-лицензию (панель → Settings), создать сайты и ресурсы.
EOF
fi
