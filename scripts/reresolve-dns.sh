#!/usr/bin/env bash
# reresolve-dns.sh — в конфиге лежат имена (a/b/c.321r.ru), в ядре — IP;
# При расхождении (смена IP у провайдера, ручная правка DNS) обновляем пира на лету.
set -eu
IFACE="${1:-wg0}"
CFG="/etc/amnezia/amneziawg/${IFACE}.conf"
AWG="$(command -v awg || command -v wg)"
[ -f "$CFG" ] || { echo "reresolve: нет $CFG" >&2; exit 1; }
$AWG show "$IFACE" >/dev/null 2>&1 || exit 0   # интерфейс не поднят — тихо выходим

awk '
  /^\[Peer\]/               { key = "" }
  /^PublicKey[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); key = $0 }
  /^Endpoint[[:space:]]*=/  { sub(/^[^=]*=[[:space:]]*/, ""); if (key != "") print key, $0 }
' "$CFG" | while read -r key ep; do
  [ -n "$key" ] && [ -n "$ep" ] || continue
  host="${ep%:*}"; port="${ep##*:}"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then continue; fi   # уже IP — не трогаем
  ip="$(getent ahostsv4 "$host" | awk '{print $1; exit}')"
  [ -n "$ip" ] || continue
  want="$ip:$port"
  cur="$($AWG show "$IFACE" endpoints | awk -v k="$key" '$1 == k {print $2}')"
  if [ "$cur" != "$want" ] && $AWG set "$IFACE" peer "$key" endpoint "$want"; then
    echo "$(date -Is) $host: ${cur:-нет} -> $want"
  fi
done
