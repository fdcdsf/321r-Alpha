#!/usr/bin/env bash
# 321r · УСТАНОВЩИК КЛАСТЕРА. Один запуск — весь кластер с нуля (docs/quickstart.md).
#
#   ./install.sh                  — мастер: спросит всё и установит
#   ./install.sh my.conf          — установка по готовому инвентарю
#   ./install.sh --from=db        — продолжить с шага (preflight|base|mesh|swarm|db|backup|tgbot|dns|pangolin|komodo|remnawave|check|handover|harden)
#   ./install.sh --from=pangolin --to=pangolin — повторить только один шаг
#   ./install.sh --check          — только автоприёмка
#   ./install.sh --manifest       — только перегенерировать cluster.yml из инвентаря
#
# Каждый шаг идемпотентен: повторный запуск ничего сломанного не оставит.
# После вопросов мастера установка уходит в фон и переживает обрыв ssh:
# Лог — /var/log/321r-install.log, продолжить можно с любого шага (--from=).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

FROM=""; TO=""; CHECK_ONLY=""; MANIFEST_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --from=*) FROM="${arg#--from=}" ;;
    --to=*) TO="${arg#--to=}" ;;
    --check) CHECK_ONLY=1 ;;
    --manifest) MANIFEST_ONLY=1 ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) INV="$arg" ;;
  esac
done

# ---------- мастер: собрать инвентарь ----------
wizard() {
  echo "321r · установка кластера (новый пользователь)"
  echo "Отвечайте на вопросы; Enter = значение по умолчанию."
  CONF="$HERE/inventory.conf"
  local n=3 name ip role i=1
  read -rp "Сколько серверов (минимум 3) [$n]: " x; n="${x:-$n}"
  local nodes=()
  while [ "$i" -le "$n" ]; do
    def="$(printf "\\$(printf '%03o' $((96+i)))")"
    read -rp "Сервер $i: имя (короткое, напр. a) [$def]: " x
    name="${x:-$def}"
    read -rp "Сервер $i ($name): IP-адрес: " ip
    [ -n "$ip" ] || { echo "IP обязателен"; continue; }
    role="work"; [ "$i" = 1 ] && role="state"; [ "$i" = "$n" ] && role="bulk"
    nodes+=("$name $ip 10.66.0.$i $role")
    i=$((i+1))
  done
  read -rp "Нода команд бота (control) [${nodes[1]%% *}]: " x; CONTROL="${x:-${nodes[1]%% *}}"
  # Раскладка БД вычисляется из РЕАЛЬНЫХ имён и ЧИСЛА серверов, а не зашита на
  # a,b,c: у пользователя может быть сколько угодно нод с любыми именами
  # (). Реплики БД — 3 (правило 3-2-1), arbiter mongo — отдельный узел.
  local nm=()
  local i n d3="" d2="" arb=""
  for row in "${nodes[@]}"; do nm+=("${row%% *}"); done
  n="${#nm[@]}"
  for ((i=0; i<n && i<3; i++)); do d3+="${d3:+,}${nm[i]}"; done
  for ((i=1; i<n && i<3; i++)); do d2+="${d2:+,}${nm[i]}"; done
  arb="${nm[0]}"
  [ -n "$d2" ] || d2="${nm[0]}"
  echo "Приложения (базы данных): по умолчанию pangolin(pg), remnawave(pg), komodo(mongo)."
  read -rp "Оставить как есть? [Y/n]: " x
  local apps=()
  if [ "${x:-y}" = "y" ] || [ "${x:-Y}" = "Y" ]; then
    apps=("pangolin pg 5432 $d3" "remnawave pg 5433 $d3" "komodo mongo 27017 $d2 arbiter=$arb")
    echo "  раскладка на $n серверов: pg=$d3, mongo=$d2 (арбитр $arb)"
  else
    echo "Вводите по одному: имя engine(pg|mongo) порт placement (напр. myapp pg 5434 a,b,c). Пустая строка = конец."
    while read -rp "> " line; do [ -z "$line" ] && break; apps+=("$line"); done
  fi
  read -rp "Токен Telegram-бота (от @BotFather): " TG_BOT_TOKEN
  read -rp "Chat id владельца (от @userinfobot): " TG_CHAT_ID
  read -rp "Домен (можно пусто, если ставим только ядро): " DOMAIN
  read -rp "Cloudflare API-токен (можно пусто): " CF_API_TOKEN
  PANGOLIN_SETUP_MODE="manual"
  if [ -n "$DOMAIN" ]; then
    read -rp "Pangolin: настроить админа, сайты и доступ к Komodo автоматически? [Y/n]: " x
    case "${x:-y}" in y|Y) PANGOLIN_SETUP_MODE="auto" ;; n|N) PANGOLIN_SETUP_MODE="manual" ;; *) echo 'Ответьте y или n'; exit 1 ;; esac
    read -rsp "Лицензия Pangolin EE (если есть; Enter = без неё): " pangolin_license </dev/tty; echo
    if [ -n "$pangolin_license" ]; then
      install -d -m 700 "$HERE/secrets"
      (umask 077; printf '%s' "$pangolin_license" > "$HERE/secrets/pangolin-license.key")
      unset pangolin_license
    fi
    read -rp "Remnawave: панель на кластере или существующая дома? [install/connect]: " x
    REMNAWAVE_MODE="${x:-install}"
    case "$REMNAWAVE_MODE" in
      install) REMNAWAVE_PANEL_URL="https://rem.$DOMAIN" ;;
      connect)
        read -rp "HTTPS-адрес домашней панели через Pangolin [https://rem.$DOMAIN]: " x
        REMNAWAVE_PANEL_URL="${x:-https://rem.$DOMAIN}"
        read -rsp "API-токен существующей Remnawave: " rem_token </dev/tty; echo
        [ -n "$rem_token" ] || { echo 'для connect нужен API-токен'; exit 1; }
        install -d -m 700 "$HERE/secrets"
        (umask 077; printf '%s' "$rem_token" > "$HERE/secrets/remnawave-api.token")
        unset rem_token ;;
      *) echo 'Выберите install или connect'; exit 1 ;;
    esac
    if [ "$REMNAWAVE_MODE" = connect ]; then
      # Домашняя панель хранит свою БД дома; на VPS отдельный PG remnawave не нужен.
      remaining=()
      for row in "${apps[@]}"; do
        [ "${row%% *}" = remnawave ] || remaining+=("$row")
      done
      apps=("${remaining[@]}")
    fi
    warp_files=()
    for row in "${nodes[@]}"; do
      a="${row%% *}"
      read -rp "Путь к индивидуальному WARP .conf для $a на этом сервере (пусто = загрузить через бота позже): " x
      warp_files+=("$a $x")
    done
  fi
  read -rp "Ваш публичный ssh-ключ (пусто = оставить парольный вход): " USER_SSH_KEY
  read -rp "Профиль ресурсов S/M/L [L]: " x; PROFILE="${x:-L}"
  read -rp "Установить Zabbix HA (панель + мониторинг на всех VPS; нужен хотя бы один сервер >=4 ГБ)? [y/N]: " x
  case "${x:-n}" in
    y|Y) ZABBIX_MODE=install
         found=0
         for row in "${apps[@]}"; do [ "${row%% *}" != zabbix ] || found=1; done
         [ "$found" = 1 ] || apps+=("zabbix pg 5434 $d3") ;;
    n|N) ZABBIX_MODE=off ;;
    *) echo 'Ответьте y или n'; exit 1 ;;
  esac
  {
    echo "# Сгенерировано мастером $(date -u +%F). Правьте — установщик перечитывает."
    echo "NODES=("
    printf '  "%s"\n' "${nodes[@]}"
    echo ")"
    echo "CONTROL=\"$CONTROL\""
    echo "VIP=\"10.66.0.99\""
    echo "APPS=("
    printf '  "%s"\n' "${apps[@]}"
    echo ")"
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\""
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\""
    echo "DOMAIN=\"$DOMAIN\""
    echo "CF_API_TOKEN=\"$CF_API_TOKEN\""
    echo "PANGOLIN_SETUP_MODE=\"$PANGOLIN_SETUP_MODE\""
    echo "REMNAWAVE_MODE=\"${REMNAWAVE_MODE:-install}\""
    echo "REMNAWAVE_PANEL_URL=\"${REMNAWAVE_PANEL_URL:-}\""
    for item in "${warp_files[@]:-}"; do
      [ -n "$item" ] || continue
      a="${item%% *}"; conf="${item#* }"
      if [ -n "$conf" ]; then printf 'WARP_CONF_%s=%q\n' "$a" "$conf"; fi
    done
    echo "USER_SSH_KEY=\"$USER_SSH_KEY\""
    echo "PROFILE=\"$PROFILE\""
    echo "ZABBIX_MODE=\"$ZABBIX_MODE\""
    echo "BACKUP_WINDOWS=\"\""
    echo "SSH_KEY=\"\${HOME:-/root}/.ssh/id_ed25519\""
  } > "$CONF"
  chmod 600 "$CONF"
  echo "Инвентарь сохранён: $CONF"
  INV="$CONF"
}

if [ -z "${INV:-}" ] && [ -f "$HERE/inventory.conf" ]; then INV="$HERE/inventory.conf"; fi
if [ -z "${INV:-}" ]; then
  if [ -t 0 ]; then wizard; else cp "$HERE/inventory.conf.example" "$HERE/inventory.conf" && INV="$HERE/inventory.conf"; fi
fi
export INV
# shellcheck source=/dev/null
source "$HERE/lib.sh"

# ---------- шаги ----------
step_preflight() {
  step "Предпроверки и доступ к серверам"
  if [ -f "$SSH_KEY" ]; then
    ok "ключ доступа: $SSH_KEY"
  else
    gen_cluster_key
    ok "создан ключ кластера: $SECRETS/id_cluster"
  fi
  ensure_access    # где ключа ещё нет — спросит пароль и заложит ключ (разово)
  local a bad=0
  for a in $(node_names); do
    local virt cont ram ker
    virt="$(nssh "$a" 'systemd-detect-virt --vm 2>/dev/null | head -1' || true)"
    cont="$(nssh "$a" 'systemd-detect-virt --container 2>/dev/null | head -1' || true)"
    ram="$(nssh "$a" 'free -m | awk "/Mem:/{print \$2}"')"
    ker="$(nssh "$a" 'uname -r')"
    if [ -n "$cont" ] && [ "$cont" != "none" ]; then
      warn "$a: виртуализация '$cont' (контейнерная) — AmneziaWG не встанет, нужна полная VM"; bad=1
    else
      ok "$a: виртуализация ${virt:-bare-metal}, RAM ${ram}МБ, ядро $ker"
    fi
    [ "${ram:-0}" -ge 900 ] || warn "$a: RAM ${ram}МБ — меньше честного минимума 1 ГБ (docs/resources.md)"
  done
  # Бюджет по составу (docs/resources.md): полный состав (панели + mongo + базы) требует ноду ≥4ГБ.
  # На практике: все ноды по 2ГБ + полный состав = swap-шторм, load 70, mongod без первичного.
  if [ "${PROFILE:-L}" != "S" ]; then
    local maxram=0 r row has_mongo=""
    for a in $(node_names); do
      r="$(nssh "$a" 'free -m | awk "/Mem:/{print \$2}"' || echo 0)"
      [ "${r:-0}" -gt "$maxram" ] && maxram="$r"
    done
    for row in "${APPS[@]}"; do [ "$(app_engine "$row")" = "mongo" ] && has_mongo=1; done
    if [ "$maxram" -lt 3800 ] && [ "$maxram" -gt 0 ]; then
      warn "бюджет: самая большая нода — ${maxram}МБ, а полный состав по docs/resources.md требует ≥4ГБ на одной ноде."
      warn "При 2ГБ ставьте PROFILE=S (панели вовне, без mongo) или возьмите сервер побольше — иначе будет swap-шторм."
    fi
    if [ -n "$has_mongo" ] && [ "$maxram" -lt 1900 ]; then
      warn "mongo на нодах <2ГБ — по docs/resources.md не рекомендуется (wiredTiger + mongosh = OOM-риск)"
    fi
  fi
  [ "$bad" = 0 ] || fail "предпроверки не пройдены — исправьте и повторите (можно --from=preflight)"
  setup_cluster_key
}

step_base() {
  step "Базовая подготовка нод (все сервера одновременно)"
  local a pids=() pid bad=0
  # fail2ban не должен банить ни того, кто ставит, ни сами ноды: они ходят друг
  # к другу по ПУБЛИЧНЫМ адресам (nssh), а не только по мешу ().
  local IGNORE_IPS="$ADMIN_IP"
  for a in $(node_names); do
    IGNORE_IPS="$IGNORE_IPS,$(node_ip "$a")"
  done
  for a in $(node_names); do
    (
      ncp "$a" -r "$ROOT/scripts/." "/usr/local/bin/"
      nssh "$a" 'chmod +x /usr/local/bin/*.sh'
      for u in "$ROOT"/systemd/*; do ncp "$a" "$u" "/etc/systemd/system/$(basename "$u")"; done
      nssh "$a" "bash -s -- $a $(node_mesh "$a") $VIP $PROFILE $IGNORE_IPS" < "$HERE/prepare-node.sh"
    ) 2>&1 | sed "s/^/[$a] /" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
  [ "$bad" = 0 ] || fail "базовая подготовка не на всех нодах — смотрите вывод выше"
  # Ядро могло устареть так, что заголовков для него в репо уже нет (Debian чистит
  # старые версии). Тогда prepare-node ставит свежее ядро и просит ребут — без
  # него DKMS не соберёт модуль AmneziaWG. Перезагружаем и ждём ноду обратно.
  local ra=()
  for a in $(node_names); do
    nssh "$a" 'test -f /etc/321r-reboot-required' 2>/dev/null && ra+=("$a")
  done
  if [ "${#ra[@]}" -gt 0 ]; then
    step "Перезагрузка нод со сменой ядра (${ra[*]})"
    # Мастер-нода — тоже нода: её ребут убил бы установку посреди шага.
    # Поэтому для МАСТЕРА ставим авто-продолжение (инвентарь уже записан мастером),
    # а остальные просто перезагружаем и ждём.
    local master_me; master_me="$(hostname | cut -d. -f1)"
    for a in "${ra[@]}"; do
      if [ "$a" = "$master_me" ]; then
        cat > /etc/systemd/system/321r-resume.service <<EOF
[Unit]
Description=321r: продолжение установки после смены ядра
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=HOME=/root
# Самоудаляемся ТОЛЬКО при успехе: иначе сбой оставит установку брошенной.
ExecStart=/bin/bash -c 'sleep 20; if bash $HERE/install.sh --from=mesh >> /var/log/321r-install-resume.log 2>&1; then systemctl disable 321r-resume.service >/dev/null 2>&1; rm -f /etc/systemd/system/321r-resume.service; else echo "ПРОДОЛЖЕНИЕ НЕ УДАЛОСЬ — повторить: bash $HERE/install.sh --from=mesh" >> /var/log/321r-install-resume.log; fi'
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable 321r-resume.service >/dev/null 2>&1
        ok "$a (мастер): после ребута установка продолжится сама (--from=mesh)"
      fi
      nssh "$a" 'rm -f /etc/321r-reboot-required; nohup sh -c "sleep 1; systemctl reboot" >/dev/null 2>&1 &' || true
    done
    for a in "${ra[@]}"; do
      [ "$a" = "$master_me" ] && continue   # мастер продолжит сам, сессия с ним умерла
      local up=""
      for i in $(seq 1 60); do
        if nssh "$a" 'uname -r' >/dev/null 2>&1; then up=1; break; fi
        sleep 10
      done
      [ -n "$up" ] || fail "$a: не вернулась после перезагрузки"
      ok "$a: снова в строю, ядро $(nssh "$a" 'uname -r')"
    done
    local me_in_ra=""
    for a in "${ra[@]}"; do [ "$a" = "$master_me" ] && me_in_ra=1; done
    if [ -n "$me_in_ra" ]; then
      echo
      echo "  ВНИМАНИЕ: мастер-нода ($master_me) перезагружается для смены ядра."
      echo "  Установка продолжится автоматически, лог: /var/log/321r-install-resume.log"
      exit 0
    fi
  fi
  detect_all_ports   # теперь все ноды отвечают на 2222
  render_manifest
  ok "базовая подготовка завершена на всех нодах"
}

render_manifest() {
  # cluster.yml — «прозрачный список серверов» (без секретов) → на все ноды
  local M="$ROOT/cluster.yml" a row arb
  {
    echo "# 321r · манифест кластера (генерирует install/install.sh из install/inventory.conf)"
    echo "# Правится руками или через инвентарь; копия — на нодах в /etc/db/cluster.yml; секретов нет."
    echo "cluster: 321r"
    echo "servers:"
    for a in $(node_names); do
      echo "  - {name: $a, ip: $(node_ip "$a"), geo: -, provider: -, size: $(echo "$PROFILE" | tr 'A-Z' 'a-z'), role: $(node_role "$a")}"
    done
    echo "control: $CONTROL   # «говорящая» нода бота (команды); алерты шлёт ЛЮБАЯ нода"
    echo "apps:"
    for row in "${APPS[@]}"; do
      arb="$(app_arbiter "$row")"
      printf '  - {name: %s, engine: %s, replicas: %s' "$(app_name "$row")" "$(app_engine "$row")" "$(app_placement "$row" | wc -w)"
      [ -n "$arb" ] && printf ', arbiter: 1'
      printf ', rule: "321"}\n'
    done
    echo "backup: {on: 2-other-domains, retention: {daily: 30, weekly: 12, monthly: 12}, export: telegram-monthly}"
    echo "survival: {policy: manual-via-bot, auto_after: null}"
  } > "$M"
  for a in $(node_names); do ncp "$a" "$M" "/etc/db/cluster.yml"; done
  ok "манифест cluster.yml разложен по нодам"
}

run_script() { # run_script <файл> <название шага>
  if [ -f "$HERE/$1" ]; then
    bash "$HERE/$1"
  else
    warn "шаг «$2» ещё не реализован ($1) — пропускаю (добавится позже, повторить: --from=…)"
  fi
}
step_mesh()     { step "Меш AmneziaWG";        bash "$HERE/mesh-up.sh"; }
step_swarm()    { step "Docker Swarm";         bash "$HERE/swarm-up.sh"; }
step_db()       { step "Слой баз данных";      bash "$HERE/db-up.sh"; }
step_backup()   { step "Бэкапы 3-2-1";         bash "$HERE/backup-up.sh"; }
step_tgbot()    { step "Telegram-бот и дозор"; bash "$HERE/tgbot-up.sh"; }
step_dns()      { step "DNS и сертификаты";    run_script dns-up.sh "DNS"; }
step_pangolin() {
  step "Pangolin (доступ к сервисам)"
  run_script pangolin-up.sh "Pangolin"
  if [ "${PANGOLIN_SETUP_MODE:-manual}" = auto ] && [ -n "${DOMAIN:-}" ]; then
    lic=()
    [ ! -s "$SECRETS/pangolin-license.key" ] || lic=(--license-file "$SECRETS/pangolin-license.key")
    python3 "$ROOT/scripts/pangolin-bootstrap.py" --url "https://pangolin.$DOMAIN" \
      --email "${EMAIL:-admin@$DOMAIN}" --org-id cluster "${lic[@]}"
    sites=(--url "https://pangolin.$DOMAIN" --org-id cluster)
    for a in $(node_names); do sites+=(--node "$a"); done
    python3 "$ROOT/scripts/pangolin-sites.py" "${sites[@]}"
    bash "$HERE/pangolin-agents.sh"
    # Судим по ПОВТОРНОЙ проверке, а не по первой: Newt стартует ~6 с, и при первом
    # осмотре последняя нода ещё подключается — ложное OFFLINE обрывало шаг (set -e),
    # а восстановительный блок ниже никогда не выполнялся (альфа-тест).
    if ! python3 "$ROOT/scripts/pangolin-sites.py" "${sites[@]}" --status; then
      # Newt мог стартовать раньше готовности Pangolin и остаться офлайн: процесс
      # жив (websocket поднят), но туннель не установлен и сам он не восстанавливается
      # (). Переподнимаем агентов и перепроверяем.
      for a in $(node_names); do
        nssh "$a" 'systemctl restart 321r-newt.service >/dev/null 2>&1 || true' &
      done
      wait
    fi
    ok=""
    for _ in $(seq 1 6); do
      sleep 10
      if python3 "$ROOT/scripts/pangolin-sites.py" "${sites[@]}" --status; then ok=1; break; fi
    done
    [ -n "$ok" ] || fail "сайты Newt не все online — смотрите journalctl -u 321r-newt на ноде и /etc/newt/newt.env"
    if [ "${REMNAWAVE_MODE:-install}" = connect ]; then
      python3 "$ROOT/scripts/pangolin-sites.py" --url "https://pangolin.$DOMAIN" \
        --org-id cluster --node home
      ok "сайт cluster-home для будущего домашнего LXC готов; его ключи — в памятке"
    fi
  fi
}
step_komodo() {
  step "Komodo (управление серверами)"
  run_script komodo-up.sh "Komodo"
  if [ "${PANGOLIN_SETUP_MODE:-manual}" = auto ] && [ -n "${DOMAIN:-}" ]; then
    python3 "$ROOT/scripts/pangolin-resources.py" --url "https://pangolin.$DOMAIN" \
      --org-id cluster --domain "$DOMAIN" \
      --spec "komodo:$CONTROL:127.0.0.1:9120:http:9120:/" \
      --repair-ip "$(node_ip "$(node_names | head -1)")"
    bash "$HERE/pangolin-resource-certs.sh" komodo
  fi
}
step_remnawave(){ step "Remnawave, VPN-ноды и маскировка"; run_script remnawave-up.sh "Remnawave+маски"; }
step_zabbix()   { [ "${ZABBIX_MODE:-off}" != install ] || run_script zabbix-up.sh "Zabbix HA"; }
step_check()    { step "Автоприёмка";          bash "$HERE/install-check.sh"; }
step_handover() { step "Памятка владельца";    bash "$HERE/handover.sh"; }
step_harden()   { step "Финальная защита ssh"
  local a
  if [ -n "${USER_SSH_KEY:-}" ]; then
    for a in $(node_names); do
      nssh "$a" "grep -qF '$USER_SSH_KEY' /root/.ssh/authorized_keys 2>/dev/null || echo '$USER_SSH_KEY' >> /root/.ssh/authorized_keys
        grep -qF '$USER_SSH_KEY' /root/.ssh/authorized_keys || { echo 'ключ не попал в authorized_keys' >&2; exit 1; }"
    done
    ok "ваш публичный ключ заложен на все ноды (и проверен!) ⚠ ПАРНЫЙ К НЕМУ приватный ключ должен быть у вас:"
    warn "перед выходом УБЕДИТЕСЬ, что вход вашим ключом работает: ssh -p 2222 root@<IP> (с вашего компьютера)!"
    for a in $(node_names); do
      nssh "$a" "sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        grep -q '^Port 22$' /etc/ssh/sshd_config && sed -i '/^Port 22$/d' /etc/ssh/sshd_config
        systemctl reload sshd 2>/dev/null || systemctl reload ssh
        ufw --force delete allow 22/tcp >/dev/null 2>&1 || true"
      ok "$a: парольный вход отключён, порт 22 закрыт"
    done
  else
    warn "ваш публичный ключ не задан — парольный вход ОСТАЁТСЯ (безопасность ниже)."
    warn "Ваш ключ можно добавить позже в inventory (USER_SSH_KEY) и повторить: --from=harden"
  fi
  # Защиту от брутфорса включаем только ЗДЕСЬ: во время установки jail sshd
  # выключен (fail2ban убивал сессию админа посреди шага).
  for a in $(node_names); do
    nssh "$a" "sed -i 's/^enabled = false/enabled = true/' /etc/fail2ban/jail.d/zz-321r.conf 2>/dev/null
      systemctl restart fail2ban >/dev/null 2>&1
      fail2ban-client status sshd >/dev/null 2>&1" || true
    ok "$a: защита sshd (fail2ban) включена"
  done
}

if [ -n "$MANIFEST_ONLY" ]; then
  detect_all_ports
  render_manifest
  exit 0
fi

# ---------- установка переживает обрыв ssh ----------
# Мастеру и входу по паролям нужен терминал, поэтому вся интерактивность живёт
# ЗДЕСЬ, в этой сессии. Дальше шаги идут отсоединённым процессом: если ssh
# Оборвётся или вы закроете окно, установка продолжится, а лог можно открыть
# В любой момент (tail -f /var/log/321r-install.log).
if [ -z "${R321_DETACHED:-}" ] && [ -t 1 ] && [ -z "$CHECK_ONLY" ]; then
  ensure_access   # пароли серверов спрашиваем тут — пока есть терминал
  LOG="${R321_LOG:-/var/log/321r-install.log}"
  touch "$LOG"; chmod 600 "$LOG"
  echo
  echo "Установка продолжится в фоне и переживёт обрыв ssh."
  echo "  лог:      $LOG"
  echo "  следить:  tail -f $LOG"
  echo "  прервана? повторить тот же запуск — шаги идемпотентны"
  setsid env R321_DETACHED=1 HOME="$HOME" bash "$HERE/install.sh" "$@" >>"$LOG" 2>&1 </dev/null &
  bg=$!
  echo "$bg" > /var/log/321r-install.pid
  tail -n +1 -f "$LOG" &
  tp=$!
  set +e; wait "$bg"; rc=$?; set -e
  kill "$tp" 2>/dev/null || true
  echo
  if [ "$rc" = 0 ]; then
    echo "УСТАНОВКА ЗАВЕРШЕНА. Итоги и памятка владельца — в логе и в Telegram."
  else
    echo "УСТАНОВКА ПРЕРВАЛАСЬ (код $rc). Продолжить с шага: bash $HERE/install.sh --from=<шаг>"
    echo "Лог: $LOG"
  fi
  exit "$rc"
fi

STEPS=(preflight base mesh swarm db backup tgbot dns pangolin komodo remnawave zabbix check handover harden)
for choice in "$FROM" "$TO"; do
  [ -z "$choice" ] && continue
  [[ " ${STEPS[*]} " == *" $choice "* ]] || fail "неизвестный шаг: $choice"
done
started=1
[ -n "$FROM" ] && started=0
for s in "${STEPS[@]}"; do
  [ "$s" = "$FROM" ] && started=1
  [ "$started" = 1 ] || continue
  [ -n "$CHECK_ONLY" ] && [ "$s" != check ] && continue
  "step_${s}"
  [ "$s" != "$TO" ] || break
done

echo
echo "=========================================="
if [ -z "$CHECK_ONLY" ]; then
  if [ -n "$TO" ] && [ "$TO" != harden ]; then
    echo "ДО ШАГА $TO ВКЛЮЧИТЕЛЬНО — ГОТОВО. Остальные шаги не запускались."
  else
    echo "УСТАНОВКА ЗАВЕРШЕНА. Что дальше:"
    echo " 1. сверьте отчёт автоприёмки выше — все ✓?"
    echo " 2. 🔐 ПАМЯТКА ВЛАДЕЛЬЦА уже в Telegram: все пароли, ключи, ссылки и секреты."
    echo "    Сохраните её в надёжном месте (менеджер паролей / печать); копия на сервере:"
    echo "    /root/321r-pamyatka-*.txt (права 600)."
    echo " 3. панели (Pangolin/Remnawave/Komodo) — по руководству docs/, если они вам нужны;"
    echo " 4. дриллы и эксплуатация — docs/drills.md, docs/operations.md; бот — @ваш_бот."
  fi
fi
echo "Повторная проверка: ./install.sh --check"
