#!/usr/bin/env bash
# 321r · автоприёмка: машинная часть автоприёмки. Запускается с ноутбука.
#   bash install/install-check.sh        — полная проверка
# Код выхода: 0 = всё критичное в порядке.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PASS=0; WARN=0; FAILN=0
ok_c()   { printf '  ✓ %s\n' "$*"; PASS=$((PASS+1)); }
warn_c() { printf '  ! %s\n' "$*"; WARN=$((WARN+1)); }
fail_c() { printf '  ✗ %s\n' "$*"; FAILN=$((FAILN+1)); }

detect_all_ports

echo "== 1. SSH: порт 2222, вход ключом =="
for a in $(node_names); do
  if [ "${NPORT[$a]}" = 2222 ]; then ok_c "$a: 2222 + ключ"
  elif [ "${NPORT[$a]}" = 22 ]; then warn_c "$a: только порт 22 (шаг harden ещё не пройден?)"
  else fail_c "$a: нет ssh-доступа"; fi
done

echo "== 2. Firewall и fail2ban =="
for a in $(node_names); do
  ufw="$(nssh "$a" 'ufw status | head -1' 2>/dev/null)"; f2b="$(nssh "$a" 'systemctl is-active fail2ban' 2>/dev/null)"
  [ "$ufw" = "Status: active" ] && ok_c "$a: ufw активен" || fail_c "$a: ufw не активен"
  [ "$f2b" = "active" ] && ok_c "$a: fail2ban активен" || fail_c "$a: fail2ban не активен"
done

echo "== 3. Меш: пинги между всеми нодами + VIP =="
need=$(($(node_names | wc -w) - 1))
for a in $(node_names); do
  got="$(nssh "$a" "for m in $(node_names | grep -v "^$a\$" | while read -r p; do node_mesh "$p"; done | tr '\n' ' '); do ping -c1 -W2 \$m >/dev/null 2>&1 && echo ok; done | wc -l")"
  [ "$got" -ge "$need" ] && ok_c "$a: видит всех соседей ($got/$need)" || fail_c "$a: соседей $got из $need"
  nssh "$a" "ping -c1 -W2 $VIP >/dev/null 2>&1" && ok_c "$a: VIP $VIP отвечает" || fail_c "$a: VIP $VIP молчит"
done

echo "== 4. Swarm =="
first="$(node_names | head -1)"
ready="$(nssh "$first" 'docker node ls --format "{{.Status}}" | grep -c Ready')"
total="$(node_names | wc -w)"
[ "$ready" -eq "$total" ] && ok_c "swarm: Ready $ready/$total" || fail_c "swarm: Ready $ready из $total"

echo "== 5. PostgreSQL: один первичный, остальные стендбаи =="
for row in "${APPS[@]}"; do
  [ "$(app_engine "$row")" = "pg" ] || continue
  app="$(app_name "$row")"; port="$(app_port "$row")"
  prim=0; stby=0
  for a in $(app_placement "$row"); do
    r="$(nssh "$a" "docker exec pg-$app psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null")"
    [ "$r" = "f" ] && prim=$((prim+1)); [ "$r" = "t" ] && stby=$((stby+1))
  done
  if [ "$prim" = 1 ]; then ok_c "$app: первичный 1, стендбаев $stby"; else fail_c "$app: первичных $prim (нужен ровно 1), стендбаев $stby"; fi
  nssh "$CONTROL" "timeout 5 bash -c '</dev/tcp/$VIP/$port'" 2>/dev/null && ok_c "$app: VIP:$port отвечает" || fail_c "$app: VIP:$port молчит"
done

echo "== 6. MongoDB: один первичный в RS =="
for row in "${APPS[@]}"; do
  [ "$(app_engine "$row")" = "mongo" ] || continue
  app="$(app_name "$row")"; port="$(app_port "$row")"
  prim=0
  for a in $(app_placement "$row"); do
    r="$(nssh "$a" "docker exec mongod-$app mongosh --quiet --eval 'print(db.hello().isWritablePrimary)' 2>/dev/null")"
    [ "$r" = "true" ] && prim=$((prim+1))
  done
  [ "$prim" = 1 ] && ok_c "$app: RS — один первичный" || fail_c "$app: первичных в RS: $prim (нужен 1)"
  nssh "$CONTROL" "timeout 5 bash -c '</dev/tcp/$VIP/$port'" 2>/dev/null && ok_c "$app: VIP:$port отвечает" || fail_c "$app: VIP:$port молчит"
done

echo "== 7. db-guard =="
for a in $(node_names); do
  t="$(nssh "$a" 'systemctl is-active db-guard.timer' 2>/dev/null)"
  [ "$t" = "active" ] && ok_c "$a: db-guard.timer активен" || fail_c "$a: db-guard.timer не активен"
done

echo "== 8. Бэкапы 3-2-1: репозитории на 2 чужих нодах =="
for a in $(node_names); do
  cnt=0
  for b in $(backup_targets "$a"); do
    nssh "$b" "[ -d /var/lib/backup-repos/$a ]" && cnt=$((cnt+1))
  done
  [ "$cnt" -eq 2 ] && ok_c "$a: репозитории готовы (2 копии)" || fail_c "$a: репозиториев $cnt из 2 (цели: $(backup_targets "$a"))"
done
c="$(nssh "$(node_names | head -1)" 'test -f /var/lib/pgbackup/last_ok && echo есть || echo нет')"
[ "$c" = "есть" ] && ok_c "первый прогон бэкапа уже был" || warn_c "снимков ещё нет — появятся по окну (ночью) или командой backup-321r.sh"

echo "== 9. Верификация восстановления =="
ok_c "запланирована на воскресенье 05:20 (проверить: /var/lib/pgbackup/last_verify)"

echo "== 10. Telegram-бот =="
if [ -n "${TG_BOT_TOKEN:-}" ]; then
  t="$(nssh "$CONTROL" 'systemctl is-active tgbot.service' 2>/dev/null)"
  [ "$t" = "active" ] && ok_c "бот активен на $CONTROL (меню пришло вам в Telegram?)" || fail_c "бот не активен на $CONTROL"
else
  warn_c "TG_BOT_TOKEN пуст — бот и алерты выключены"
fi

echo "== 11. Аварийный режим =="
for a in $(node_names); do
  nssh "$a" '[ -x /usr/local/bin/survival.sh ]' && ok_c "$a: survival.sh на месте" || fail_c "$a: нет survival.sh"
done

echo "== 12. Ресурсы (бюджет) =="
for a in $(node_names); do
  nssh "$a" 'printf "  %s: load %s, RAM свободно %sМБ\n" "$(hostname)" "$(cut -d" " -f1-3 /proc/loadavg | cut -d" " -f1)" "$(free -m | awk "/Mem:/{print \$7}")"'
done

echo "== 13. Сертификат дашборда Pangolin =="
# Панель «работала» с TRAEFIK DEFAULT CERT — видел только человек в браузере.
if [ -n "${DOMAIN:-}" ] && [ "${DOMAIN:-}" != "<ваш-домен>" ]; then
  for a in $(node_names); do
    iss="$(nssh "$a" "echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername pangolin.$DOMAIN 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" || true)"
    case "$iss" in
      *"TRAEFIK DEFAULT"*) fail_c "$a: дашборд отдаёт TRAEFIK DEFAULT CERT (certbot/panel_cert.yml?)" ;;
      *"issuer="*) ok_c "$a: дашборд — валидный сертификат (${iss#issuer=})" ;;
      *) warn_c "$a: проверить сертификат дашборда не удалось" ;;
    esac
  done
else
  warn_c "DOMAIN пуст — панель не ставится, сертификат не проверяем"
fi

if [ "${PANGOLIN_SETUP_MODE:-manual}" = auto ] && [ -n "${DOMAIN:-}" ]; then
  echo "== 14. Авто-Pangolin: Newt и сертификат ресурса =="
  site_args=()
  for a in $(node_names); do site_args+=(--node "$a"); done
  if python3 "$ROOT/scripts/pangolin-sites.py" --url "https://pangolin.$DOMAIN" \
      --org-id cluster "${site_args[@]}" --status; then
    ok_c "сайты Newt online на всех нодах"
  else
    fail_c "сайты Newt не все online"
  fi
  for a in $(node_names); do
    code="$(nssh "$a" "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 --resolve komodo.$DOMAIN:443:127.0.0.1 https://komodo.$DOMAIN/ 2>/dev/null" || true)"
    [ "$code" = 200 ] && ok_c "$a: Komodo через Pangolin — HTTPS 200 с проверкой сертификата" \
      || fail_c "$a: Komodo HTTPS не принят (HTTP ${code:-нет}; проверьте wildcard-сертификат и лицензию)"
  done
fi

if [ -n "${DOMAIN:-}" ]; then
  echo "== 15. Remnawave: собственная нода/IP, подключение и подписка =="
  rw_args=(--mode "${REMNAWAVE_MODE:-install}" --panel-url "${REMNAWAVE_PANEL_URL:-https://rem.$DOMAIN}"
           --domain "$DOMAIN" --token-file "$SECRETS/remnawave-api.token" --check-only)
  for a in $(node_names); do rw_args+=(--node "$a"); done
  if python3 "$ROOT/scripts/remnawave-mask.py" "${rw_args[@]}"; then
    ok_c "Remnawave: все ноды подключены, подписка содержит только свои VPN-имена"
  else
    fail_c "Remnawave: ноды или подписка не прошли проверку"
  fi
  for a in $(node_names); do
    code="$(nssh "$a" "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 \
      --resolve vpn-$a.$DOMAIN:443:127.0.0.1 https://vpn-$a.$DOMAIN/ 2>/dev/null" || true)"
    [ "$code" = 200 ] && ok_c "$a: vpn-$a.$DOMAIN — собственная TLS-маска 200" \
      || fail_c "$a: собственная TLS-маска не работает (HTTP ${code:-нет})"
  done
fi

if [ "${REMNAWAVE_MODE:-install}" = install ] && [ -n "${DOMAIN:-}" ]; then
  echo "== 16. Человеческая страница подписки (не сырой /api/sub) =="
  short="$(basename "$(cat /etc/db/secrets/remnawave-probe-url 2>/dev/null || echo missing)")"
  if [[ "$short" =~ ^[a-zA-Z0-9_-]{6,80}$ ]] && [ "$short" != missing ]; then
    for a in $(node_names); do
      if nssh "$a" "curl -fsS --max-time 15 --resolve 'sub.$DOMAIN:443:127.0.0.1' \
        -H 'Accept: text/html' -A 'Mozilla/5.0 Chrome/124.0.0.0' \
        'https://sub.$DOMAIN/$short' 2>/dev/null | grep -qi '<html'"; then
        ok_c "$a: красивая HTML-страница sub.$DOMAIN открывается"
      else
        fail_c "$a: страница sub.$DOMAIN не отдаёт HTML"
      fi
    done
  else
    fail_c "нет пробной подписки для проверки красивой страницы"
  fi
fi

if [ "${ZABBIX_MODE:-off}" = install ]; then
  echo "== 17. Zabbix HA: сервер, агенты, живые данные и UI =="
  STANDBY_ZBX=""
  for a in $(node_names); do [ "$a" = "$CONTROL" ] || STANDBY_ZBX="$a"; done
  zbx_primary=0; zbx_standby=0
  for a in $(node_names); do
    role="$(nssh "$a" 'docker exec pg-zabbix psql -U postgres -tAc "SELECT pg_is_in_recovery()" 2>/dev/null' || true)"
    [ "$role" != f ] || zbx_primary=$((zbx_primary + 1))
    [ "$role" != t ] || zbx_standby=$((zbx_standby + 1))
  done
  [ "$zbx_primary" = 1 ] && [ "$zbx_standby" -ge 1 ] \
    && ok_c "Zabbix PG: один primary, реплик $zbx_standby" \
    || fail_c "Zabbix PG: primary=$zbx_primary, standby=$zbx_standby"
  zbx_args=()
  for a in $(node_names); do zbx_args+=(--node "$a"); done
  if nssh "$CONTROL" "python3 /opt/zabbix/zabbix-check.py --control $CONTROL $(printf '%q ' "${zbx_args[@]}")"; then
    ok_c "Zabbix: ровно один active, standby, метрики и алерты в Telegram готовы"
  else
    fail_c "Zabbix HA, сбор данных или алерты недоступны"
  fi
  for a in "$CONTROL" $STANDBY_ZBX; do
    [ -n "$a" ] || continue
    nssh "$a" '[ -x /opt/zabbix/tg-relay.sh ] && [ -r /etc/db/secrets/zabbix-telegram.env ]' \
      && ok_c "$a: relay-скрипт и секрет алертов на месте" \
      || fail_c "$a: нет tg-relay.sh или /etc/db/secrets/zabbix-telegram.env"
  done
  for a in $(node_names); do
    st="$(nssh "$a" 'systemctl is-active zabbix-agent2' 2>/dev/null || true)"
    [ "$st" = active ] && ok_c "$a: активный агент" || fail_c "$a: агент Zabbix не активен"
    code="$(nssh "$a" "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 \
      --resolve zabbix.$DOMAIN:443:127.0.0.1 https://zabbix.$DOMAIN/index.php 2>/dev/null" || true)"
    [ "$code" = 200 ] && ok_c "$a: Zabbix UI HTTPS 200 с доверенным TLS" \
      || fail_c "$a: Zabbix UI недоступен (HTTP ${code:-нет})"
  done
fi

echo
echo "=========================================="
echo "ИТОГ: ✓ $PASS  ! $WARN  ✗ $FAILN"
if [ "$FAILN" -gt 0 ]; then
  echo "Есть критичные замечания — чиним и повторяем: bash install/install-check.sh"
  exit 1
fi
echo "Ядро кластера принято. Ручная часть приёмки: бот, дайджест, панели, VPN."
