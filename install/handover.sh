#!/usr/bin/env bash
# 321r · шаг: ПАМЯТКА ВЛАДЕЛЬЦА — все пароли, ключи, секреты и ссылки одним файлом.
# Файл кладётся на master-сервер (root, chmod 600) и отправляется владельцу в Telegram.
# Содержимое — СЕКРЕТЫ: в git не попадает, наружу не печатается (только путь к файлу).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CTRL="$CONTROL"
OUT="/root/321r-pamyatka-$(date +%F).txt"

step "Сбор секретов с нод"
# значения подхватываются в переменные, НЕ печатаются
R_PGPASS="$(nssh "$CTRL" "grep '^POSTGRES_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
R_APPPASS="$(nssh "$CTRL" "grep '^APP_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
R_PGSERV="$(nssh "$CTRL" "grep '^PANGOLIN_SERVER_SECRET=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
# Логи сохраняют старый token и ПОСЛЕ онбординга; не выдаём недействительный код.
if [ -n "${DOMAIN:-}" ] && curl -fsS --max-time 8 "https://pangolin.$DOMAIN/api/v1/auth/initial-setup-complete" \
     | jq -e '.data.complete == true' >/dev/null 2>&1; then
  SETUP_TOK="(первичная настройка пройдена; код уже не действует)"
else
  SETUP_TOK="$(nssh "$CTRL" 'docker logs --tail 4000 pangolin 2>&1 | grep -A1 "SETUP TOKEN" | grep "Token:" | awk "{print \$2}" | tail -1' 2>/dev/null || true)"
fi
[ -n "$SETUP_TOK" ] && ok "статус setup token Pangolin получен (значение — только в файл)" || warn "setup token в логах не найден"
RW_PASS="$(nssh "$CTRL" "grep '^APP_PASSWORD=' /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d '\"'")"
RW_PG="$(nssh "$CTRL" "grep '^POSTGRES_PASSWORD=' /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d '\"'")"
RW_ADMIN="(внешняя панель: доступы у владельца)"
if [ -s /etc/db/secrets/remnawave-admin.json ]; then
  RW_ADMIN="$(python3 -c 'import json; d=json.load(open("/etc/db/secrets/remnawave-admin.json")); print(d["username"] + " / " + d["password"])')"
fi
RW_PROBE="$(cat /etc/db/secrets/remnawave-probe-url 2>/dev/null || echo '(пока не настроена)')"
ZBX_ADMIN="(Zabbix выключен)"
ZBX_URL="(не установлен)"
if [ "${ZABBIX_MODE:-off}" = install ] || nssh "$CONTROL" '[ -s /etc/db/secrets/zabbix-admin.json ]'; then
  ZBX_ADMIN="$(nssh "$CONTROL" 'python3 -c '\''import json; d=json.load(open("/etc/db/secrets/zabbix-admin.json")); print(d["username"]+" / "+d["password"])'\''')"
fi
[ "$ZBX_ADMIN" != "(Zabbix выключен)" ] && ZBX_URL="https://zabbix.${DOMAIN:-<ваш-домен>}"
RW_PAGE="(домашняя страница подписки ещё не подключена)"
if [ "${REMNAWAVE_MODE:-install}" = install ] && [ -s /etc/db/secrets/remnawave-probe-url ] && [ -n "${DOMAIN:-}" ]; then
  RW_PAGE="https://sub.$DOMAIN/${RW_PROBE##*/}"
fi
K_ADMIN="$(nssh "$CTRL" "grep '^KOMODO_INIT_ADMIN_PASSWORD=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_JWT="$(nssh "$CTRL" "grep '^KOMODO_JWT_SECRET=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_WEBHOOK="$(nssh "$CTRL" "grep '^KOMODO_WEBHOOK_SECRET=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_CORE_KEY="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-keys/core.key')"
K_CORE_PUB="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-keys/core.pub')"
K_ONBOARD="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-onboarding.key')"
RESTIC="$(nssh "$CTRL" "grep '^RESTIC_PASSWORD=' /etc/db/secrets/restic.env | cut -d= -f2- | tr -d '\"'")"
CLUSTER_KEY="$(cat "$SECRETS/id_cluster" 2>/dev/null || echo '(нет)')"
MSEC="$(cat "$SECRETS/mtproto-secret" 2>/dev/null || echo '(нет)')"
PANGOLIN_ADMIN="(настроен вручную — учётные данные у владельца)"
if [ -f /etc/db/secrets/pangolin-admin.json ]; then
  PANGOLIN_ADMIN="$(python3 -c 'import json; d=json.load(open("/etc/db/secrets/pangolin-admin.json")); print(d["email"] + " / " + d["password"])')"
fi
PANGOLIN_LICENSE="(не задана при установке)"
if [ -s "$SECRETS/pangolin-license.key" ]; then
  PANGOLIN_LICENSE="$(cat "$SECRETS/pangolin-license.key")"
fi
NEWT_CREDS="$(for a in $(node_names); do
  if [ -f "/etc/db/secrets/newt-$a.env" ]; then
    printf '\n  cluster-%s: ' "$a"
    tr '\n' ' ' < "/etc/db/secrets/newt-$a.env"
  fi
done)"
if [ -f /etc/db/secrets/newt-home.env ]; then
  NEWT_CREDS="$NEWT_CREDS
  cluster-home: $(tr '\n' ' ' < /etc/db/secrets/newt-home.env)"
fi
if [ -n "${DOMAIN:-}" ] && [[ "$MSEC" =~ ^[a-fA-F0-9]{32}$ ]]; then
  MT_LINK="$(mtproto_link "tg.$DOMAIN" "$MSEC")"
else
  MT_LINK="(нет корректного секрета или домена — проверьте mtbuddy links на ноде)"
fi
TGTOK="${TG_BOT_TOKEN:-$(nssh "$CTRL" "grep '^TG_BOT_TOKEN=' /etc/db/secrets/telegram.env | cut -d= -f2- | tr -d '\"'")}"
ok "секреты собраны (значения — только в файл, не в вывод)"

step "Памятка владельца"
cat > "$OUT" <<EOF
================================================================================
 321r · ПАМЯТКА ВЛАДЕЛЬЦА — $(date -u '+%F %H:%M') UTC
================================================================================
⚠ ВСЁ НИЖЕ — СЕКРЕТЫ. Сохраните в надёжном месте (менеджер паролей / печать).
⚠ Не выкладывайте в git, облака и чаты. Утрата = пересоздание с нуля.

--- 1. СЕРВЕРЫ ---------------------------------------------------------------
ssh: порт 2222, пользователь root, вход ТОЛЬКО ключом (пароль отключён).
$(for a in $(node_names); do printf '  %s = %s (mesh %s)\n' "$a" "$(node_ip "$a")" "$(node_mesh "$a")"; done)
Ваш ssh-ключ: публичная часть установлена на всех серверах; приватный — у вас.
Ключ межнодового доступа (для восстановления доступа между серверами):
$CLUSTER_KEY

--- 2. TELEGRAM-БОТ ----------------------------------------------------------
  Токен:     $TGTOK
  Chat id:   ${TG_CHAT_ID:-см. /etc/db/secrets/telegram.env}

--- 3. БАЗЫ ДАННЫХ (общий адрес VIP $VIP) ------------------------------------
  pangolin  (pg,   :5432): пользователь pangolin / $R_APPPASS
                            postgres / $R_PGPASS
  remnawave (pg,   :5433): пользователь remnawave / $RW_PASS
                            postgres / $RW_PG
  komodo    (mongo, :27017): без авторизации (слышен только внутри меша)

--- 4. PANGOLIN --------------------------------------------------------------
  Панель:      https://pangolin.${DOMAIN:-<ваш-домен>} (первичный онбординг — вы задаёте админа)
  Администратор (автоматический режим): $PANGOLIN_ADMIN
  Newt-сайты (секреты хранятся на первом сервере):$NEWT_CREDS
  Код первичной настройки (setup token):
    ${SETUP_TOK:-(не найден в логах — настройка, похоже, уже пройдена)}
    взять самому: docker logs pangolin | grep -A1 "SETUP TOKEN"
    (актуален, пока не пройден первичный онбординг; если уже прошли — не требуется)
  server.secret: $R_PGSERV
  EE-лицензия: $PANGOLIN_LICENSE
  (в автоматическом режиме установщик активирует её через API Pangolin)

--- 5. KOMODO ---------------------------------------------------------------
  Панель:      https://komodo.${DOMAIN:-<ваш-домен>} (ресурс Pangolin → 127.0.0.1:9120)
  Вход:        admin / $K_ADMIN   (смените после первого входа + 2FA!)
  JWT-secret:  $K_JWT
  Webhook:     $K_WEBHOOK
  Ключ Core X25519 (pkcs8, БЕРЕГИТЕ — идентичность Core):
$K_CORE_KEY
  Публичный ключ Core: $K_CORE_PUB
  Onboarding-key периферии: $K_ONBOARD

--- 6. REMNAWAVE -------------------------------------------------------------
  Режим:       ${REMNAWAVE_MODE:-install}
  Панель:      ${REMNAWAVE_PANEL_URL:-https://rem.${DOMAIN:-<ваш-домен>}}
  Вход:        $RW_ADMIN
  Красивая страница для человека: $RW_PAGE
  Сырая подписка для VPN-приложения: $RW_PROBE
  БД панели (только install): $RW_PASS
  APP_SECRET (только install): /opt/remnawave/.env на control

--- 7. МАСКА TELEGRAM (mtproto.zig) ------------------------------------------
  Ссылка FakeTLS: $MT_LINK
  (секрет один на кластер; клиенты ходят на любую ноду)

--- 8. БЭКАПЫ (правило 3-2-1) -----------------------------------------------
  RESTIC_PASSWORD: $RESTIC
  ⚠ РАСПЕЧАТАЙТЕ ОФЛАЙН: без него копии бэкапов не прочитать!
  Копии: каждая нода пишет на 2 другие (/var/lib/backup-repos), ночью 03:10/03:40/04:10 UTC.
  Выгрузка на физический носитель: 1-го числа + кнопка в боте.

--- 9. CLOUDFLARE / ДОМЕН ----------------------------------------------------
  Домен:       ${DOMAIN:-<ваш-домен>}
  API-токен:   ${CF_API_TOKEN:-см. /etc/ddns.env на нодах}

--- 10. ГДЕ ВСЁ ЛЕЖИТ НА СЕРВЕРАХ -------------------------------------------
  /etc/db/secrets/          — пароли БД и сервисов (umask 077)
  /etc/db/cluster.yml       — манифест кластера (серверы/приложения)
  /opt/321r/install/inventory.conf — ваш инвентарь (мастер-сервер)
  /var/lib/backup-repos/    — репозитории бэкапов соседей
  Zabbix (если включён): $ZBX_URL, вход: $ZBX_ADMIN
  Zabbix server HA: $CONTROL и резервный; web на каждой VPS, агенты по mesh.
================================================================================
EOF
chmod 600 "$OUT"

# копия на control-ноду (файлохранилище кластера)
ncp "$CTRL" "$OUT" "/root/$(basename "$OUT")"
nssh "$CTRL" "chmod 600 /root/$(basename "$OUT")"

# отправка владельцу в Telegram (его же чат алертов)
if [ -n "${TG_CHAT_ID:-}" ] && [ -n "$TGTOK" ]; then
  curl -s -X POST "https://api.telegram.org/bot$TGTOK/sendDocument" \
    -F "chat_id=$TG_CHAT_ID" \
    -F "document=@$OUT" \
    -F "caption=🔐 Памятка 321r: пароли, ключи, ссылки. СОХРАНИТЕ В НАДЁЖНОМ МЕСТЕ!" >/dev/null && \
    ok "памятка отправлена вам в Telegram" || warn "не удалось отправить в Telegram (файл сохранён на сервере)"
else
  warn "нет TG_CHAT_ID — памятка только в файле на сервере"
fi

cat <<EOF

  🔐 ПАМЯТКА ВЛАДЕЛЬЦА ГОТОВА:
   - файл: $OUT (и копия на $CTRL: /root/$(basename "$OUT")), права 600;
   - отправлена вам в Telegram (сохраните в менеджер паролей / распечатайте!).
   В ней: доступы к серверам, токен бота, пароли баз, секреты Pangolin/Komodo/Remnawave,
   ключ Core, RESTIC-пароль, ссылка маски Telegram и Cloudflare-токен.
EOF
