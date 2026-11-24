#!/usr/bin/env bash
# unhealthy-restart.sh — перезапуск зависших (unhealthy) контейнеров.
#
# Зачем: docker перезапускает контейнер только когда тот ПАДАЕТ (exit). Контейнер,
# Зависший со статусом "unhealthy" (например, Pangolin без доступа к БД при старте),
# Живёт мёртвым ВЕЧНО. Этот скрипт чинит такие случаи автоматически.
# Запуск: cron/systemd-timer раз в минуту на каждой ноде.
set -euo pipefail
IDS=$(docker ps --filter health=unhealthy --format '{{.ID}}')
if [[ -n "$IDS" ]]; then
  for id in $IDS; do
    echo "unhealthy-restart: перезапускаю $(docker inspect -f '{{.Name}}' "$id")"
    docker restart "$id" >/dev/null
  done
fi
