#!/usr/bin/env bash
# Только чтение root-снимка; Zabbix-агент не получает доступ к docker.sock.
set -euo pipefail
file=/var/lib/zabbix-321r/snapshot.json
[ -r "$file" ] || { echo 'snapshot unavailable' >&2; exit 1; }
case "${1:-}" in
  discover)
    jq -c '{data:[.services|keys[]|{"{#SERVICE}":.}]}' "$file" ;;
  status)
    name="${2:-}"
    [[ "$name" =~ ^(docker|systemd|app-db|vip|backup|swarm-node|swarm|http)/[a-zA-Z0-9_.-]+$ ]] || exit 1
    jq -er --arg name "$name" '.services[$name] // empty' "$file" ;;
  ha-active)
    jq -er '.ha.active' "$file" ;;
  ha-standby)
    jq -er '.ha.standby' "$file" ;;
  *) exit 2 ;;
esac
