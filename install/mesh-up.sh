#!/usr/bin/env bash
# 321r · шаг 3: меш AmneziaWG (полный N×N). Идемпотентен.
# Запускается с ноутбука: bash install/mesh-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 1) AmneziaWG на все ноды ПАРАЛЛЕЛЬНО (DKMS-сборка 5–15 минут; важно: нужна полная VM и ядро ≥6.7)
pids=(); bad=0
for a in $(node_names); do
  if nssh "$a" 'command -v awg-quick >/dev/null'; then
    ok "$a: AmneziaWG уже установлен"
    continue
  fi
  (
    nssh "$a" 'set -e
      for i in $(seq 1 60); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 10; done
      apt_retry() { local n; for n in $(seq 1 10); do "$@" && return 0; echo "  apt занят — жду 15 с"; sleep 15; done; return 1; }
      APTQ="apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10"
      mkdir -p /etc/apt/keyrings
      rm -f /etc/apt/keyrings/amnezia.gpg   # иначе gpg спросит «перезаписать?» через /dev/tty
      curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" \
        | gpg --dearmor -o /etc/apt/keyrings/amnezia.gpg
      # PPA Amnezia публикует только серии Ubuntu, а ноды могут быть Debian.
      # Пробуем СВОЮ серию, при её отсутствии — известные рабочие (проверено на
      # Debian 13: пакеты из focal ставятся, это DKMS + утилиты).
      . /etc/os-release
      suite=focal
      for s in "$VERSION_CODENAME" noble jammy focal; do
        [ -n "$s" ] || continue
        if curl -fsS -o /dev/null --max-time 15 \
             "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/$s/Release" 2>/dev/null; then
          suite="$s"; break
        fi
      done
      echo "deb [signed-by=/etc/apt/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu $suite main" \
        > /etc/apt/sources.list.d/amnezia.list
      export DEBIAN_FRONTEND=noninteractive
      apt_retry $APTQ update -qq
      apt_retry $APTQ install -y -qq amneziawg >/dev/null
      # Модуль ядра обязан загрузиться: apt может «успешно» поставить пакет, а DKMS
      # молча пропустить сборку без заголовков () — тогда меша нет.
      modprobe amneziawg 2>/dev/null \
        || { echo "  modprobe не прошёл — пробую пересборку DKMS"; dkms autoinstall >/dev/null 2>&1 || true; modprobe amneziawg; }'
    echo "AmneziaWG установлен"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "AmneziaWG встал не на всех нодах — смотрите вывод выше. Частые причины: контейнерная виртуализация (нужна полная VM), нет заголовков ядра для работающего ядра (шаг base ставит их и при необходимости просит ребут), ядро старше 6.7."

# 2) общий секрет обфускации (HPK) — один на весь кластер (разные = линк молчит).
#    Если ноды уже в меше — берём ИХ HPK (иначе живой меш перестанет сходиться!).
HPK=""
for a in $(node_names); do
  HPK="$(nssh "$a" 'grep -oE "HeaderProtectionKey = .*" /etc/amnezia/amneziawg/wg0.conf 2>/dev/null | head -1 | cut -d" " -f3' || true)"
  [ -n "$HPK" ] && break
done
HPK_FILE="$SECRETS/hpk"
if [ -n "$HPK" ]; then
  echo "$HPK" > "$HPK_FILE"
  ok "HPK взят из работающего меша (не перетираю)"
else
  [ -f "$HPK_FILE" ] || head -c 32 /dev/urandom | base64 > "$HPK_FILE"
  HPK="$(cat "$HPK_FILE")"
fi

# 3) ключи на нодах (приватный с ноды не уходит)
for a in $(node_names); do
  nssh "$a" 'set -e
    mkdir -p /etc/wireguard /etc/amnezia/amneziawg
    [ -s /etc/wireguard/privatekey ] || { awg genkey > /etc/wireguard/privatekey; chmod 600 /etc/wireguard/privatekey; }
    awg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey'
  ok "$a: ключи меша готовы"
done

# 4) рендер wg0.conf на каждую ноду (полный меш: пир — на все ноды в обе стороны)
for a in $(node_names); do
  conf="# 321r mesh · узел $a (генерирует install/mesh-up.sh)
[Interface]
Address = $(node_mesh "$a")/32,$VIP/32
ListenPort = 51821
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 12
S2 = 12
S3 = 12
S4 = 12
HeaderProtectionKey = $HPK
PrivateKey = $(nssh "$a" 'cat /etc/wireguard/privatekey')
"
  for p in $(node_names); do
    [ "$p" = "$a" ] && continue
    conf+="
[Peer]
PublicKey = $(nssh "$p" 'cat /etc/wireguard/publickey')
Endpoint = $(node_ip "$p"):51821
AllowedIPs = $(node_mesh "$p")/32
PersistentKeepalive = 25
"
  done
  nssh "$a" 'cat > /etc/amnezia/amneziawg/wg0.conf && chmod 600 /etc/amnezia/amneziawg/wg0.conf' <<<"$conf"
  ok "$a: wg0.conf расписан ($(($(node_names | wc -w) - 1)) пиров)"
done

# 5) сервис подъёма + порт в firewall
for a in $(node_names); do
  ncp "$a" "$ROOT/scripts/awg0-up.sh" /usr/local/sbin/awg0-up.sh
  nssh "$a" 'chmod +x /usr/local/sbin/awg0-up.sh
    systemctl daemon-reload
    systemctl enable --now awg0.service >/dev/null 2>&1
    ufw allow 51821/udp >/dev/null'
  ok "$a: awg0.service включён"
done

# 6) проверка: рукопожатия и пинги через меш
sleep 5
bad=0
for a in $(node_names); do
  hs="$(nssh "$a" 'bin=$(command -v awg || command -v wg); "$bin" show wg0 latest-handshakes | awk "\$2>0" | wc -l')"
  need=$(($(node_names | wc -w) - 1))
  if [ "${hs:-0}" -ge "$need" ]; then ok "$a: рукопожатия со всеми ($hs/$need)"; else warn "$a: рукопожатий $hs из $need"; bad=1; fi
  ping_ok="$(nssh "$a" "for m in $(node_names | grep -v "^$a\$" | while read -r p; do node_mesh "$p"; done | tr '\n' ' '); do ping -c1 -W2 \$m >/dev/null 2>&1 && echo ok; done | wc -l")"
  [ "$ping_ok" -ge "$need" ] && ok "$a: ping до всех соседей через меш" || { warn "$a: ping до соседей: $ping_ok из $need"; bad=1; }
done
[ "$bad" = 0 ] || fail "меш не сошёлся — проверьте wg show на нодах (docs/troubleshooting.md)"
ok "меш поднят, VIP $VIP прописан на всех нодах"
