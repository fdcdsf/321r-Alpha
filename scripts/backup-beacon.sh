#!/usr/bin/env bash
# 321r: маяк свежести бэкапов (docs/backups.md). Протух бэкап — громкий алерт в Telegram.
# Запуск: ежедневно (cron) + строка в /status бота.
set -u
f=/var/lib/pgbackup/last_ok
ME="$(hostname | cut -d. -f1)"
if [ ! -f "$f" ]; then
  /usr/local/bin/tg-alert.sh "МАЯК ($ME): бэкапа НИКОГДА не было!" >/dev/null 2>&1
  exit 1
fi
age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 3600 ))
if [ "$age" -ge 26 ]; then
  /usr/local/bin/tg-alert.sh "МАЯК ($ME): последний бэкап был $age ч назад — ПРОТУХ!" >/dev/null 2>&1
  exit 1
fi
echo "маяк ок: бэкап $age ч назад"
