#!/usr/bin/env bash
# 321r cluster: работа с манифестом кластера (дизайн: docs/doctrine-3-2-1.md).
#   cluster.sh status  — манифест + живое состояние всех серверов
#   cluster.sh apply   — разложить манифест по нодам; включить бота на control-ноде
#   cluster.sh move <app> <откуда> <куда> — перенос приложения между нодами
set -euo pipefail
M="${CLUSTER_MANIFEST:-/etc/db/cluster.yml}"
[ -f "$M" ] || M="$(cd "$(dirname "$0")/.." && pwd)/cluster.yml"
[ -f "$M" ] || { echo "не найден cluster.yml" >&2; exit 1; }

nodes() { grep -oE 'name: *[a-z0-9_-]+, *ip: *[0-9.]+' "$M" | sed 's/name: *//; s/, *ip: */ /'; }
control() { grep -E '^control:' "$M" | awk '{print $2}'; }

case "${1:-status}" in
  status)
    echo "== манифест: $M =="
    while read -r name ip; do
      printf "%-4s %-16s " "$name" "$ip"
      ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$ip" \
        'uptime | sed "s/.*load/load/"; free -m | awk "/Mem:/{print \"  RAM свободно: \"\$7\"MB\"}"' 2>/dev/null \
        | tr "\n" " " || printf "нет ответа"
      echo
    done < <(nodes)
    echo "control (бот команд): $(control)"
    ;;
  apply)
    CTRL="$(control)"
    while read -r name ip; do
      scp -P 2222 -o BatchMode=yes -q "$M" "root@$ip:/etc/db/cluster.yml" && echo "  $name: манифест положен"
    done < <(nodes)
    while read -r name ip; do
      if [ "$name" = "$CTRL" ]; then
        ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$ip" 'systemctl enable --now tgbot.service >/dev/null 2>&1 && echo "  '"$name"': tgbot включён (control)"' || true
      else
        ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$ip" 'systemctl disable --now tgbot.service >/dev/null 2>&1; echo "  '"$name"': tgbot выключен (не control)"' || true
      fi
    done < <(nodes)
    ;;
  move)
    shift
    exec "$(dirname "$0")/app-move.sh" "$@" ;;
  *)
    echo "использование: cluster.sh status|apply|move <app> <откуда> <куда>" >&2; exit 1 ;;
esac
