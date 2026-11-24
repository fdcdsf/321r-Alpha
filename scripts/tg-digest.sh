#!/usr/bin/env bash
# 321r: утренний дайджест (docs/monitoring.md). Каждое утро — одна сводка по кластеру:
# Короткий статус каждой ноды + список проблем (или «всё ок»). Запуск — cron на control-ноде.
set -u
. /etc/db/secrets/telegram.env 2>/dev/null || exit 0
[ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || exit 0
lines="☀ Доброе утро! 321r · дайджест кластера"
probs=""
for n in $(awk '{print $1}' /etc/db/nodes.map); do
  ip="$(awk -v s="$n" '$1==s{print $2}' /etc/db/nodes.map)"
  [ -n "$ip" ] || continue
  st="$(ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" '/usr/local/bin/tg-info.sh status' 2>/dev/null | tr '\n' ' · ')"
  lines="$lines
【$n】${st:-нет ответа}"
  p="$(ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" '/usr/local/bin/tg-watch.sh --check' 2>/dev/null | grep -v 'всё ок' || true)"
  [ -n "$p" ] && probs="$probs
$p"
done
if [ -z "$probs" ]; then
  lines="$lines

✅ Проблем нет — все проверки дозора в норме."
else
  lines="$lines

⚠ ПРОБЛЕМЫ:$probs"
fi
curl -sS --max-time 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=$lines" >/dev/null 2>&1 || true
