#!/usr/bin/env bash
# 321r · шаг 4: Docker Swarm (все менеджеры — правило 2K+1) + политика DOCKER-USER.
# Идемпотентен. Запускается с ноутбука: bash install/swarm-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FIRST="$(node_names | head -1)"

# 1) init на первой ноде (по mesh-адресу — важно: swarm живёт только в меше)
if [ "$(nssh "$FIRST" 'docker info --format "{{.Swarm.LocalNodeState}}"')" != "active" ]; then
  nssh "$FIRST" "docker swarm init --advertise-addr $(node_mesh "$FIRST") --listen-addr $(node_mesh "$FIRST"):2377" >/dev/null
  ok "$FIRST: swarm init (менеджер)"
else
  ok "$FIRST: уже в swarm"
fi
TOKEN="$(nssh "$FIRST" 'docker swarm join-token -q manager')"

# 2) join остальных (менеджерами)
for a in $(node_names); do
  [ "$a" = "$FIRST" ] && continue
  if [ "$(nssh "$a" 'docker info --format "{{.Swarm.LocalNodeState}}"')" != "active" ]; then
    nssh "$a" "docker swarm join --token $TOKEN $(node_mesh "$FIRST"):2377" >/dev/null
    ok "$a: вступил в swarm"
  else
    ok "$a: уже в swarm"
  fi
done

# 3) все — менеджеры (воркеры не берём: db-guard на воркере не работает)
# Метки проставляем ОДНОЙ командой и с повтором: Swarm оптимистично блокирует
# обновления узлов и отвечает «update out of sequence», если они идут слишком
# быстро друг за другом (шаг swarm падал на пятой ноде из пяти).
node_update() { # $1 = аргументы docker node update
  local n out=""
  for n in $(seq 1 10); do
    out="$(nssh "$FIRST" "docker node update $1 2>&1")" && return 0
    case "$out" in
      *"out of sequence"*) sleep 3; continue ;;
      *) break ;;
    esac
  done
  echo "docker node update ($1) не прошёл: $out" >&2
  return 1
}

for id in $(nssh "$FIRST" 'docker node ls -q'); do
  node_update "--availability active $id" >/dev/null
done
for a in $(node_names); do
  id="$(nssh "$a" 'docker info --format "{{.Swarm.NodeID}}"')"
  role="$(node_role "$a")"; role="${role:-work}"
  # метки ролей: state|work|bulk — по инвентарю; обе метки за один вызов
  node_update "--label-add role=$role --label-add name=$a $id" >/dev/null
  ok "$a: метки role=$role, name=$a"
done

# 4) DOCKER-USER (фенсинг и whitelist портов) — сервис на всех нодах
for a in $(node_names); do
  nssh "$a" 'systemctl daemon-reload && systemctl enable --now docker-user.service >/dev/null 2>&1'
  ok "$a: DOCKER-USER политика включена"
done

# 5) сверка
sleep 2
ready="$(nssh "$FIRST" 'docker node ls --format "{{.Status}}" | grep -c Ready')"
need="$(node_names | wc -w)"
[ "$ready" -eq "$need" ] || fail "swarm: Ready $ready из $need"
ok "swarm: $ready/$need Ready"
