#!/usr/bin/env bash
# 321r · шаг 6: бэкапы 3-2-1 (restic: каждая нода → 2 другие), верификация, дозор.
# Идемпотентен. Запускается с ноутбука: bash install/backup-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 1) пароль репозиториев — ОДИН на кластер, генерируется здесь, лежит только на нодах
if nssh "$(node_names | head -1)" '[ -s /etc/db/secrets/restic.env ]'; then
  ok "пароль restic уже есть — не пересоздаю (иначе старые копии станут нечитаемы)"
else
  PW="$(openssl rand -base64 24 | tr -d '\n/=+' | head -c 32)"
  for a in $(node_names); do
    echo "RESTIC_PASSWORD=\"$PW\"" | nssh "$a" 'cat > /etc/db/secrets/restic.env && chmod 600 /etc/db/secrets/restic.env'
  done
  ok "пароль restic сгенерирован и разложен по нодам (распечатайте и храните офлайн!)"
fi

# 2) telegram.env на все ноды (алерты шлёт ЛЮБАЯ нода)
if [ -n "${TG_BOT_TOKEN:-}" ]; then
  for a in $(node_names); do
    printf 'TG_BOT_TOKEN="%s"\nTG_CHAT_ID="%s"\n' "$TG_BOT_TOKEN" "$TG_CHAT_ID" \
      | nssh "$a" 'cat > /etc/db/secrets/telegram.env && chmod 600 /etc/db/secrets/telegram.env'
    # страховка: файл обязан быть непустым (проба ssh съедала stdin пайпа)
    sz="$(nssh "$a" 'wc -c < /etc/db/secrets/telegram.env')"
    [ "${sz:-0}" -gt 10 ] || fail "$a: telegram.env пуст ($sz байт) — токен не записался"
    ok "$a: telegram.env записан ($sz байт)"
  done
  ok "telegram.env разложен (токен — только на нодах, в git не попадает)"
else
  warn "нет TG_BOT_TOKEN — алерты и бот работать не будут (добавьте в inventory и перезапустите шаг)"
fi

# 3) репозитории: своя копия живёт на 2 других нодах (sftp по мешу) — все пары параллельно
pids=(); bad=0
for a in $(node_names); do
  for b in $(node_names); do
    [ "$b" = "$a" ] && continue
    (
      nssh "$a" "set -a; . /etc/db/secrets/restic.env; set +a
        restic -r sftp:root@$(node_mesh "$b"):/var/lib/backup-repos/$a snapshots >/dev/null 2>&1 \
          || restic -r sftp:root@$(node_mesh "$b"):/var/lib/backup-repos/$a init >/dev/null"
    ) 2>&1 | sed "s/^/[$a→$b] /" &
    pids+=($!)
  done
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "репозитории restic инициализированы не везде"
for a in $(node_names); do ok "$a: репозитории на 2 чужих нодах инициализированы"; done

# 4) cron: окно бэкапа своё у каждой ноды (не копимся одновременно), остальное общее
for a in $(node_names); do
  if nssh "$a" 'crontab -l 2>/dev/null | grep -q backup-321r'; then
    warn "$a: backup-321r уже есть в crontab-е root — уберите оттуда, иначе задания будут дважды"
  fi
  # старая схема «файл на задачу» заменяется единым 321r — дубли убираем 
  nssh "$a" 'rm -f /etc/cron.d/backup321r /etc/cron.d/backup-beacon /etc/cron.d/backup-verify \
              /etc/cron.d/tg-export /etc/cron.d/tg-watch /etc/cron.d/tg-digest
    crontab -l 2>/dev/null | grep -v unhealthy-restart | crontab - 2>/dev/null || true'
  win="$(backup_window "$a")"
  cron="# 321r · бэкапы и дозор (генерирует install/backup-up.sh)
${win#*:} ${win%:*} * * * root /usr/local/bin/backup-321r.sh >> /var/log/backup321r.log 2>&1
5 9 * * * root /usr/local/bin/backup-beacon.sh >> /var/log/backup321r.log 2>&1
20 5 * * 0 root /usr/local/bin/backup-verify.sh >> /var/log/backup-verify.log 2>&1
5 * * * * root /usr/local/bin/tg-watch.sh >> /var/log/tg-watch.log 2>&1
5 6 1 * * root /usr/local/bin/tg-export.sh >> /var/log/tg-export.log 2>&1
* * * * * root /usr/local/bin/unhealthy-restart.sh >> /var/log/unhealthy-restart.log 2>&1"
  if [ "$a" = "$CONTROL" ]; then
    cron="$cron
0 9 * * * root /usr/local/bin/tg-digest.sh >> /var/log/tg-digest.log 2>&1"
  fi
  echo "$cron" | nssh "$a" 'cat > /etc/cron.d/321r && chmod 644 /etc/cron.d/321r'
  ok "$a: окно бэкапа $win (UTC), дозор и маяки по расписанию"
done

echo
echo "  Расписание (UTC): бэкап по окнам $(node_names | while read -r n; do printf '%s=%s ' "$n" "$(backup_window "$n")"; done)"
echo "  Маяк 09:00, верификация вс 05:20, дозор каждый час, выгрузка на диск 1-го числа, дайджест 09:00 (control=$CONTROL)."
