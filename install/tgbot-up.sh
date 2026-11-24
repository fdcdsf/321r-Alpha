#!/usr/bin/env bash
# 321r · шаг 7: Telegram-бот (панель управления) — живёт на control-ноде.
# Идемпотентен. Запускается с ноутбука: bash install/tgbot-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ -n "${TG_BOT_TOKEN:-}" ] || { warn "нет TG_BOT_TOKEN — бот не включён (добавьте в inventory.conf и повторите шаг)"; exit 0; }

for a in $(node_names); do
  if [ "$a" = "$CONTROL" ]; then
    nssh "$a" 'systemctl daemon-reload
      systemctl enable --now tgbot.service >/dev/null 2>&1
      systemctl restart tgbot.service'
    ok "$a: tgbot.service запущен (control-нода)"
  else
    nssh "$a" 'systemctl disable --now tgbot.service >/dev/null 2>&1 || true'
  fi
done

sleep 3
if [ "$(nssh "$CONTROL" 'systemctl is-active tgbot.service')" = "active" ]; then
  ok "бот отвечает: меню должно было прийти вам в Telegram"
else
  nssh "$CONTROL" 'journalctl -u tgbot.service --no-pager | tail -5' | sed 's/^/  /'
  fail "tgbot не поднялся — смотрите лог выше"
fi
