#!/usr/bin/env bash
# db-prep.sh — подготовка ноды к слою БД (docs/databases.md).
# Копируется на КАЖДУЮ ноду и запускается там же; идемпотентен.
#   1) VIP 10.66.0.99/32 на wg0: сейчас + в Address= конфига (awg0-up поднимет сам);
#   2) ufw: зона контейнеров -> порты БД на VIP (иначе default deny режет INPUT от bridge);
#   3) каталоги /etc/db, /var/lib/dbdata, /var/lib/pgwal, /var/lib/pgbackup;
#   4) карта нод: alias -> mesh-адрес -> имя ноды в Swarm (nodes.map);
#   5) заранее pull образов (не тянуть в момент отказа).
set -euo pipefail
umask 077

VIP=10.66.0.99
CONF=/etc/amnezia/amneziawg/wg0.conf

# --- 1) VIP ---
[ -f "$CONF" ] || { echo "ОШИБКА: нет $CONF" >&2; exit 1; }
ip addr replace "${VIP}/32" dev wg0
ip -4 addr show dev wg0 | grep -q "${VIP}" || { echo "ОШИБКА: VIP ${VIP} не на wg0" >&2; exit 1; }
if ! grep -q "${VIP}" "$CONF"; then
  # строка "Address = 10.66.0.X/32" -> "Address = 10.66.0.X/32,10.66.0.99/32"
  sed -i "s|^Address = \(.*\)$|Address = \1,${VIP}/32|" "$CONF"
fi
grep -q "Address = .*${VIP}" "$CONF" || { echo "ОШИБКА: VIP не вписан в $CONF" >&2; exit 1; }

# --- 2) ufw: контейнеры (bridge 172.16/12, overlay-сети Swarm 10/8) -> порты БД на VIP ---
#     Диапазоны = реестр портов (PG 5432+, Mongo 27017+); при выходе порта за диапазон —
#     дописать аналогичное правило.
ufw allow from 172.16.0.0/12 to any port 5432:5499  proto tcp comment 'db-vip-pg'      >/dev/null
ufw allow from 172.16.0.0/12 to any port 27017:27099 proto tcp comment 'db-vip-mongo'   >/dev/null
ufw allow from 10.0.0.0/8     to any port 5432:5499  proto tcp comment 'db-vip-pg-ovl'   >/dev/null
ufw allow from 10.0.0.0/8     to any port 27017:27099 proto tcp comment 'db-vip-mongo-ovl' >/dev/null
# Valkey (шаг 5) слушает mesh-адрес ноды, а не VIP — свой порт; правило было добавлено
# вручную при первом деплое; здесь — чтобы пересборка ноды и новые узлы не потеряли его.
ufw allow from 172.16.0.0/12 to any port 6379 proto tcp comment 'db-valkey'    >/dev/null
ufw allow from 10.0.0.0/8     to any port 6379 proto tcp comment 'db-valkey-ovl' >/dev/null

# --- 3) каталоги ---
mkdir -p /etc/db/apps.d /etc/db/secrets /var/lib/dbdata /var/lib/pgwal /var/lib/pgbackup /opt/db

# --- 4) карта нод: alias -> mesh-адрес -> имя ноды в Swarm (nodes.map) ---
# Карту собирает установщик из инвентаря (install/db-up.sh): имена и адреса узлов
# у каждого свои, поэтому никаких зашитых вариантов здесь быть не может.
if [ ! -f /etc/db/nodes.map ]; then
  echo "ОШИБКА: нет /etc/db/nodes.map — карту узлов собирает установщик из инвентаря." >&2
  echo "       Запустите шаг db (bash install/install.sh --from=db) или положите файл" >&2
  echo "       вручную: по строке «<имя> <mesh-IP> <swarm-имя>» на узел." >&2
  exit 1
fi

# --- 5) образы заранее (дрилл отказа не должен ждать pull) ---
for img in postgres:17-alpine haproxy:3.0-alpine mongo:7; do
  docker pull "$img" || echo "ПРЕДУПРЕЖДЕНИЕ: $img не вытянулся — повторите docker pull позже"
done
docker compose version >/dev/null 2>&1 || \
  echo "ПРЕДУПРЕЖДЕНИЕ: нет docker compose v2 (нужен для db-add): apt-get install -y docker-compose-plugin"

echo "OK db-prep ($(hostname)): VIP ${VIP} на wg0, ufw-правила, каталоги, nodes.map, образы"
