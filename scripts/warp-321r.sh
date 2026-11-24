#!/usr/bin/env bash
# warp-321r.sh — WARP-туннель для mtproto.zig (обход блокировки Telegram в РФ).
#
# Используется ШТАТНЫЙ механизм mtproto.zig: [upstream].type = "tunnel" — сокеты с
# SO_MARK=200 идут в таблицу 200, mtbuddy держит там default dev <туннель>, сам
# проверяет маршруты к DC Telegram и держит пул туннелей (failover).
# Своя маршрутизация (iptables/ip rule) не нужна и вредна: owner-матч на этом ядре
# сматчил ~99% трафика ноды.
#
# Что делает скрипт:
#   set-config <файл.conf> — подмена WARP-конфига (СВОЙ на каждую ноду!) с автопроверкой
#                           и откатом: не взлетел → прежний восстановлен, взлетел → удалён;
#   up / down              — включить/выключить обход (type tunnel/auto + рестарт прокси);
#   status / stats         — для бота.
#
# Использование: warp-321r.sh up|down|status|stats|set-config <файл.conf>
set -euo pipefail
IFACE="${WARP_IFACE:-warp}"
CONF_DIR=/etc/amnezia/amneziawg
CONF="$CONF_DIR/$IFACE.conf"
PREV="$CONF.prev"
PROXY_CONF=/opt/mtproto-proxy/config.toml

log()  { printf 'warp-321r: %s\n' "$*"; }
fail() { printf 'warp-321r: ОШИБКА: %s\n' "$*" >&2; exit 1; }

have_mtb()   { command -v mtbuddy >/dev/null 2>&1; }
proxy_type() { sed -n 's/^type = "\(.*\)"/\1/p' "$PROXY_CONF" 2>/dev/null | head -1; }
iface_up()   { ip link show "$IFACE" >/dev/null 2>&1; }

_tunnel_ok() { # 0 = туннель РЕАЛЬНО пропускает трафик (handshake + трасса Cloudflare)
  for _ in $(seq 1 10); do
    if awg show "$IFACE" 2>/dev/null | grep -q 'latest handshake'; then
      if curl -sf --interface "$IFACE" --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp='; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

set_type() { # $1 = tunnel | auto
  sed -i "s/^type = \".*\"/type = \"$1\"/" "$PROXY_CONF"
}

ensure_tunnel() { # регистрирует конфиг в пуле mtbuddy (он же валидирует маршруты)
  have_mtb || fail "нет mtbuddy"
  [ -f "$CONF" ] || fail "нет $CONF — сначала: warp-321r.sh set-config <файл.conf>"
  mtbuddy setup tunnel --iface "$IFACE" "$CONF"
}

cmd_up() {
  ensure_tunnel >/dev/null
  set_type tunnel
  systemctl daemon-reload
  systemctl enable --now mtproto-tunnel-pool.timer >/dev/null 2>&1 || true
  systemctl restart mtproto-proxy
  sleep 2
  ip rule show | grep -q 'fwmark 0xc8 lookup 200' || log "предупреждение: правило fwmark 200 не найдено"
  if iface_up && _tunnel_ok; then log "WARP включён: обход через $IFACE (mtproto), прокси с type=tunnel"
  else log "предупреждение: туннель $IFACE не подтверждён (нет handshake/трассы) — проверьте конфиг"; fi
}

cmd_down() {
  set_type auto
  systemctl disable --now mtproto-tunnel-pool.timer >/dev/null 2>&1 || true
  systemctl restart mtproto-proxy
  log "WARP выключен: mtproto ходит напрямую (type=auto)"
}

cmd_status() {
  local t hr tr ep
  t="$(proxy_type)"; [ -n "$t" ] || t="?"
  ep="$(awg show "$IFACE" 2>/dev/null | awk -F': ' '/endpoint/{print $2}' | head -1)"
  hr="$(awg show "$IFACE" 2>/dev/null | awk -F': ' '/latest handshake/{print $2}' | head -1)"
  tr="$(awg show "$IFACE" 2>/dev/null | awk -F': ' '/transfer/{print $2}' | head -1)"
  if iface_up; then echo "warp: up (type=$t, туннель $IFACE, endpoint ${ep:-?}, handshake ${hr:-нет}, transfer ${tr:-?})"
  else echo "warp: down (type=$t)"; fi
}

cmd_stats() { # для бота: одна строка
  cmd_status
  st="$(journalctl -u mtproto-proxy --no-pager -n 200 2>/dev/null | grep 'conn stats' | tail -1 || true)"
  act="$(sed -n 's/.*active=\([0-9]*\).*/\1/p' <<<"$st")"
  tot="$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$st")"
  echo "mtproto: active=${act:-0} total=${tot:-0}"
}

cmd_set_config() {
  local src="${1:?использование: warp-321r.sh set-config <файл.conf>}"
  [ -f "$src" ] || fail "нет файла $src"
  grep -q '^\[Interface\]' "$src" && grep -q '^\[Peer\]' "$src" || fail "это не WARP/WireGuard-конфиг (нет [Interface]/[Peer])"
  have_mtb || fail "нет mtbuddy"
  local was_type; was_type="$(proxy_type)"
  [ -f "$CONF" ] && cp -f "$CONF" "$PREV"
  install -m 600 "$src" "$CONF"
  # mtbuddy не перенастраивает УЖЕ поднятый интерфейс (принимает конфиг «как есть»),
  # поэтому сначала опускаем туннель — иначе в пул попадёт старый peer.
  awg-quick down "$IFACE" >/dev/null 2>&1 || true
  log "конфиг установлен: $src"
  if ensure_tunnel >/dev/null 2>&1 && _tunnel_ok; then
    set_type tunnel
    systemctl enable --now mtproto-tunnel-pool.timer >/dev/null 2>&1 || true
    systemctl restart mtproto-proxy
    rm -f "$PREV"; log "новый конфиг работает — прежний удалён"
  else
    log "новый конфиг НЕ заработал — откат"
    if [ -f "$PREV" ]; then
      mv -f "$PREV" "$CONF"
      awg-quick down "$IFACE" >/dev/null 2>&1 || true
      ensure_tunnel >/dev/null 2>&1 || true
    else
      rm -f "$CONF"
    fi
    [ -n "$was_type" ] && set_type "$was_type"
    systemctl restart mtproto-proxy >/dev/null 2>&1 || true
    exit 1
  fi
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  stats) cmd_stats ;;
  set-config) shift; cmd_set_config "$@" ;;
  *) echo "использование: warp-321r.sh up|down|status|stats|set-config <файл.conf>"; exit 2 ;;
esac
