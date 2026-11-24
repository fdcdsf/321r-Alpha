#!/usr/bin/env bash
# 321r: дозор (docs/monitoring.md). По умолчанию — алерт в Telegram при проблеме, молчание при норме.
# tg-watch.sh --check — только ПЕЧАТАТЬ проблемы (для дайджеста), без алертов.
set -u
MODE="${1:-alert}"
ME="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"; ME="${ME:-$(hostname | cut -d. -f1)}"
prob=""

# диск: корень и каталоги данных
for d in / /var/lib/dbdata /var/lib/backup-repos; do
  [ -d "$d" ] || continue
  u="$(df -h "$d" | awk 'NR==2{gsub("%","");print $5}')"
  [ "${u:-0}" -ge 85 ] 2>/dev/null && prob="$prob; диск $d занят на ${u}%"
done

# память
free_mb="$(free -m | awk '/Mem:/{print $7}')"
[ "${free_mb:-999}" -le 100 ] 2>/dev/null && prob="$prob; RAM свободно всего ${free_mb}MB"

# нагрузка: 5-мин > 2×ядер
l5="$(cut -d' ' -f2 /proc/loadavg)"; n="$(nproc)"
echo "$l5 $n" | awk '{exit !($1 > $2*2)}' && prob="$prob; load $l5 при ${n} ядрах"

# сертификаты маски: < 14 дней
exp="$(certbot certificates 2>/dev/null | grep 'Expiry Date' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
if [ -n "$exp" ]; then
  days=$(( ($(date -d "$exp" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
  [ "$days" -le 14 ] 2>/dev/null && prob="$prob; сертификат маски истекает через ${days} дн"
fi

# бэкап
if [ ! -f /var/lib/pgbackup/last_ok ]; then
  prob="$prob; бэкапа НИКОГДА не было"
else
  age=$(( ($(date +%s) - $(stat -c %Y /var/lib/pgbackup/last_ok)) / 3600 ))
  [ "$age" -ge 26 ] && prob="$prob; бэкап ${age}ч назад (протух!)"
fi

# верификация восстановления
if [ -f /var/lib/pgbackup/last_verify ]; then
  age=$(( ($(date +%s) - $(stat -c %Y /var/lib/pgbackup/last_verify)) / 86400 ))
  [ "$age" -ge 8 ] && prob="$prob; верификация восстановления ${age}д назад"
fi

prob="${prob#; }"
if [ -n "$prob" ]; then
  if [ "$MODE" = "--check" ]; then
    echo "$ME: $prob"
    exit 1
  fi
  # Не долбить одним и тем же каждый час: алерт при ИЗМЕНЕНИИ проблемы
  # и не чаще раза в 12 ч, пока она сохраняется ().
  state=/var/lib/pgbackup/.tgwatch-alert
  prev=""; prev_ts=0
  if [ -f "$state" ]; then
    prev="$(head -1 "$state" 2>/dev/null || true)"
    prev_ts="$(tail -1 "$state" 2>/dev/null || echo 0)"
  fi
  now="$(date +%s)"
  if [ "$prob" != "$prev" ] || [ $((now - ${prev_ts:-0})) -ge 43200 ]; then
    printf '%s\n%s\n' "$prob" "$now" > "$state"
    /usr/local/bin/tg-alert.sh "ДОЗОР ($ME): $prob" >/dev/null 2>&1
    echo "$(date -u +%FT%TZ) $ME: ПРОБЛЕМА -> $prob"
  else
    echo "$(date -u +%FT%TZ) $ME: проблема прежняя, алерт подавлен (повтор через 12ч)"
  fi
  exit 1
fi
# Тихий лог: видно, что дозор реально отрабатывает (раньше файл был пустым).
# В режиме --check состояние НЕ трогаем — его зовёт дайджест.
if [ "$MODE" != "--check" ] && [ -f /var/lib/pgbackup/.tgwatch-alert ]; then
  rm -f /var/lib/pgbackup/.tgwatch-alert
  echo "$(date -u +%FT%TZ) $ME: проблема ушла -> всё ок"
fi
[ "$MODE" = "--check" ] && echo "$ME: всё ок"
exit 0
