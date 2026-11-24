#!/usr/bin/env bash
# Zabbix 7.0 LTS native HA: b/c server+web, общий PG (VIP 5434) в 321r.
# На каждой ноде активный агент ставится отдельно; никаких БД-контейнеров Zabbix.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
[ "${ZABBIX_MODE:-off}" = install ] || { ok "Zabbix выключен (ZABBIX_MODE=off)"; exit 0; }
[ -n "${DOMAIN:-}" ] || fail "Zabbix UI через Pangolin требует DOMAIN"
CONTROL_NODE="$CONTROL"
# Раскладку БД zabbix берём из ИНВЕНТАРЯ (APPS), а не «все ноды»: db-add создаёт
# БД строго по placement, а серверов у пользователя может быть сколько угодно
# (на 5 нодах шаг падал на «PG zabbix не поднят» для d и e).
ZABBIX_ROW=""
for row in "${APPS[@]}"; do [ "$(app_name "$row")" = zabbix ] && ZABBIX_ROW="$row"; done
[ -n "$ZABBIX_ROW" ] || fail "в инвентаре нет приложения zabbix — добавьте строку в APPS"
ZABBIX_PLACEMENT="$(app_placement "$ZABBIX_ROW")"
ZABBIX_PRIMARY="$(echo "$ZABBIX_PLACEMENT" | awk '{print $1}')"
# HA-пара серверов Zabbix — из тех же узлов, что и БД.
STANDBY=""
for a in $ZABBIX_PLACEMENT; do [ "$a" = "$CONTROL_NODE" ] || { STANDBY="$a"; break; }; done
[ -n "$STANDBY" ] || fail "HA требует две разные ноды Zabbix (placement: $ZABBIX_PLACEMENT)"

step "Бюджет памяти и отдельная БД Zabbix (первичный + реплики 321r)"
for a in "$CONTROL_NODE" "$STANDBY"; do
  mem="$(nssh "$a" 'free -m | awk "/Mem:/{print \$2}"')"
  [ "${mem:-0}" -ge 3800 ] || fail "$a: ${mem:-0} МБ RAM — сервер+web Zabbix HA требуют >=4 ГБ"
done
for a in $ZABBIX_PLACEMENT; do
  if ! nssh "$a" '[ -f /etc/db/apps.d/zabbix.yaml ]'; then
    { echo 'name: zabbix'; echo 'engine: pg'; echo 'class: cluster'
      printf 'placement: [%s]\n' "$(echo "$ZABBIX_PLACEMENT" | tr ' ' ',')"
      printf 'primary: %s\n' "$ZABBIX_PRIMARY"
      echo 'port: 5434'
    } | nssh "$a" 'cat > /etc/db/apps.d/zabbix.yaml'
  fi
done
if ! nssh "$ZABBIX_PRIMARY" 'docker ps --format "{{.Names}}" | grep -qx pg-zabbix'; then
  nssh "$CONTROL_NODE" '/usr/local/bin/db-add.sh zabbix' | tail -8
fi
for a in $ZABBIX_PLACEMENT; do
  nssh "$a" 'docker ps --format "{{.Names}}" | grep -qx pg-zabbix' \
    || fail "$a: PG zabbix не поднят (placement: $ZABBIX_PLACEMENT)"
done

step "Zabbix HA (server на $CONTROL_NODE/$STANDBY, web на всех нодах)"
for a in $(node_names); do
  nssh "$a" 'install -d -m 700 /opt/zabbix /etc/db/secrets'
  ncp "$a" "$ROOT/deploy/zabbix/tg-relay.sh" /opt/zabbix/tg-relay.sh
  # Зеркало секрета для контейнера: токен остаётся только в /etc/db/secrets.
  nssh "$a" 'set -e
    if [ -r /etc/db/secrets/telegram.env ]; then
      grep -E "^TG_(BOT_TOKEN|CHAT_ID)=" /etc/db/secrets/telegram.env \
        > /etc/db/secrets/zabbix-telegram.env || true
    else
      : > /etc/db/secrets/zabbix-telegram.env
    fi
    chmod 600 /etc/db/secrets/zabbix-telegram.env
    chmod 755 /opt/zabbix/tg-relay.sh'
  sed -e "s/__NODE__/$a/g" -e "s/__MESH_IP__/$(node_mesh "$a")/g" \
    "$ROOT/deploy/zabbix/docker-compose.yml" \
    | nssh "$a" 'cat > /opt/zabbix/docker-compose.yml'
  nssh "$a" 'set -e
    . /etc/db/secrets/zabbix.env
    umask 077
    printf "POSTGRES_PASSWORD=%s\n" "$APP_PASSWORD" > /opt/zabbix/.env
    chmod 600 /opt/zabbix/.env
    cd /opt/zabbix && docker compose config -q'
done

# С чистой БД образ импортирует схему — запускать ОДИН server, чтобы не
# Повторить гонку миграций Pangolin. Резервный запускать позже.
nssh "$CONTROL_NODE" 'cd /opt/zabbix && docker compose up -d server' >/dev/null
ready=""
for i in $(seq 1 90); do
  if nssh "$CONTROL_NODE" 'set -e
      . /etc/db/secrets/zabbix.env
      docker exec -e PGPASSWORD="$APP_PASSWORD" pg-zabbix psql -X -qAt \
        -h 10.66.0.99 -p 5434 -U zabbix -d zabbix \
        -c "SELECT mandatory FROM dbversion" 2>/dev/null | grep -Eq "^[0-9]+$"'; then
    ready=1; break
  fi
  sleep 5
done
[ -n "$ready" ] || fail "Zabbix не создал схему БД за 7.5 минут; docker logs zabbix-server"
nssh "$STANDBY" 'cd /opt/zabbix && docker compose up -d server' >/dev/null
# Контейнер Zabbix работает под своим uid: даём ему читать зеркало секрета.
for a in "$CONTROL_NODE" "$STANDBY"; do
  zuid="$(nssh "$a" 'docker exec zabbix-server id -u')"
  zgid="$(nssh "$a" 'docker exec zabbix-server id -g')"
  nssh "$a" "chown $zuid:$zgid /etc/db/secrets/zabbix-telegram.env"
  nssh "$a" 'chmod 640 /etc/db/secrets/zabbix-telegram.env'
  ok "$a: секрет алертов доступен контейнеру Zabbix"
done
for a in $(node_names); do
  nssh "$a" 'cd /opt/zabbix && docker compose up -d --no-deps web' >/dev/null
done
for a in $(node_names); do
  up=""
  for i in $(seq 1 60); do
    if nssh "$a" 'curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8081/index.php 2>/dev/null'; then up=1; break; fi
    sleep 5
  done
  [ -n "$up" ] || fail "$a: web Zabbix не отвечает :8081"
  ok "$a: web Zabbix отвечает"
done
step "Админ Zabbix, шаблоны Linux+сервисы, регистрация VPS"
for a in $(node_names); do
  ncp "$a" "$ROOT/scripts/zabbix-provision.py" /opt/zabbix/zabbix-provision.py
  ncp "$a" "$ROOT/scripts/zabbix-check.py" /opt/zabbix/zabbix-check.py
done
hosts=()
for a in $(node_names); do hosts+=(--node "$a:$(node_mesh "$a")"); done
nssh "$CONTROL_NODE" "python3 /opt/zabbix/zabbix-provision.py --control $CONTROL_NODE $(printf '%q ' "${hosts[@]}")"
# Файлы админа/бота раскладываем по всем нодам: приёмку и отладку можно вести
# С ЛЮБОЙ живой VPS, а не только с control (иначе после падения control — тупик).
for a in $(node_names); do
  for f in zabbix-admin.json zabbix-bot-pass.json; do
    if [ "$a" != "$CONTROL_NODE" ] && nssh "$CONTROL_NODE" "[ -s /etc/db/secrets/$f ]"; then
      nssh "$CONTROL_NODE" "cat /etc/db/secrets/$f" | nssh "$a" "cat > /etc/db/secrets/$f && chmod 600 /etc/db/secrets/$f"
    fi
  done
done

step "Активные агенты на всех VPS (b;c = один HA-кластер)"
bash "$HERE/zabbix-agent-up.sh" "$CONTROL_NODE" "$STANDBY"

step "HTTP-доступность приложений (список URL на каждую ноду)"
probe=""
if [ -s /etc/db/secrets/remnawave-probe-url ]; then
  probe="$(cat /etc/db/secrets/remnawave-probe-url)"
  case "$probe" in https://*) ;; *) probe="" ;; esac
fi
for a in $(node_names); do
  {
    echo "vpn|https://vpn-$a.$DOMAIN/"
    if [ "$a" = "$CONTROL_NODE" ]; then
      echo "komodo|https://komodo.$DOMAIN/"
      echo "pangolin|https://pangolin.$DOMAIN/"
      echo "zabbix|https://zabbix.$DOMAIN/index.php"
      echo "rem|https://rem.$DOMAIN/"
      # «Красивая» страница подписки — именно её открывает пользователь.
      if [ -n "$probe" ]; then echo "sub|https://sub.$DOMAIN/$(basename "$probe")"; fi
    fi
  } | nssh "$a" 'umask 077; cat > /etc/db/secrets/http-checks.txt; chmod 600 /etc/db/secrets/http-checks.txt'
  ok "$a: список HTTP-проверок записан"
done

step "Панель Zabbix через локальный frontend на КАЖДОЙ ноде"
if [ -s /etc/db/secrets/pangolin-admin.json ]; then
  specs=()
  for a in $(node_names); do specs+=(--spec "zabbix:$a:127.0.0.1:8081:http:8081:/index.php"); done
  python3 "$ROOT/scripts/pangolin-resources.py" --url "https://pangolin.$DOMAIN" \
    --org-id cluster --domain "$DOMAIN" "${specs[@]}" \
    --repair-ip "$(node_ip "$(node_names | head -1)")"
  bash "$HERE/pangolin-resource-certs.sh" zabbix
  # Pangolin file_mode генерирует маршруты только для exit node с live-целью.
  # Newt может подключиться к другому exit node → 503 при живом web.
  # Локальный HTTP-роутер всегда ведёт на web ТЕКУЩЕЙ ноды.
  for a in $(node_names); do
    sed "s/__DOMAIN__/$DOMAIN/g" "$ROOT/deploy/zabbix/traefik-local.yml" \
      | nssh "$a" 'cat > /opt/pangolin/config/dynamic/zabbix-local.yml'
    ok "$a: HTTPS Zabbix → локальный web"
  done
else
  warn "Pangolin настроен вручную: ресурс zabbix.$DOMAIN нужно создать вручную"
fi
echo "Zabbix HA b/c + web на всех нодах, автообнаружение сервисов запущено."
