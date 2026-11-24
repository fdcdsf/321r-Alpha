#!/usr/bin/env bash
# На VPS Newt ждёт локальный Pangolin/gerbil после ребута всей тройки.
# Иначе WebSocket может быть online, но туннель не создастся и HC останется unhealthy.
set -euo pipefail
for i in $(seq 1 90); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || true)" = healthy ] \
      && curl -fsS --max-time 3 http://127.0.0.1/ping >/dev/null 2>&1; then
    exit 0
  fi
  sleep 3
done
echo 'Newt: Pangolin/gerbil не готовы за 270 с — systemd попробует ещё раз' >&2
exit 1
