#!/usr/bin/env bash
# 321r install · общие помощники. Подключается (source) скриптами install/.
# Секреты установки (ключ нод) складываются в install/secrets/ — в git никогда.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
INV="${INV:-$HERE/inventory.conf}"
SECRETS="$HERE/secrets"
# Шаги не должны зависеть от того, был ли шаг preflight: установку возобновляют
# С любого места (--from=base|mesh|...), а каталог секретов и ключ кластера
# Создавались только в preflight (--from=base падал на
# «secrets/hpk: No such file or directory»).
install -d -m 700 "$SECRETS" 2>/dev/null || mkdir -p "$SECRETS" 2>/dev/null || true
# Установка может идти из-под systemd (авто-продолжение после
# Смены ядра), где HOME не задан. Без этого `set -u` падает на $HOME в инвентаре.
export HOME="${HOME:-/root}"
# Кто запустил установку: fail2ban обязан его не банить (бан
# Админа убивал прогон). Запоминаем в файл, т.к. продолжение после ребута идёт
# Из-под systemd, где SSH_CLIENT уже нет.
if [ -n "${SSH_CLIENT:-}" ]; then
  mkdir -p /etc/db 2>/dev/null || true
  printf '%s\n' "${SSH_CLIENT%% *}" > /etc/db/install-origin 2>/dev/null || true
fi
ADMIN_IP="${SSH_CLIENT:-}"; ADMIN_IP="${ADMIN_IP%% *}"
[ -n "$ADMIN_IP" ] || ADMIN_IP="$(cat /etc/db/install-origin 2>/dev/null || true)"

[ -f "$INV" ] || { echo "нет $INV: скопируйте install/inventory.conf.example или запустите ./install.sh (мастер)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$INV"

NODES=("${NODES[@]:-}")
APPS=("${APPS[@]:-}")
CONTROL="${CONTROL:-${NODES[1]%% *}}"
VIP="${VIP:-10.66.0.99}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
# Каждый под-скрипт перечитывает инвентарь; если указанного ключа нет
# (например $HOME/.ssh/id_ed25519 на сервере) — берём ключ кластера.
if [ ! -f "$SSH_KEY" ] && [ -f "$SECRETS/id_cluster" ]; then
  SSH_KEY="$SECRETS/id_cluster"
fi
PROFILE="${PROFILE:-L}"
BACKUP_WINDOWS="${BACKUP_WINDOWS:-}"

# ---------- вывод ----------
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  ✗ ОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

# ---------- инвентарь ----------
node_row() { local row; for row in "${NODES[@]}"; do case "$row" in "$1 "|"$1"|"$1 "*) echo "$row"; return;; esac; done; }
node_ip()   { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $2}'; }
node_mesh() { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $3}'; }
node_role() { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $4}'; }
node_names() { local row; for row in "${NODES[@]}"; do echo "${row%% *}"; done; }

app_name()  { echo "${1%% *}"; }
app_engine() { echo "$1" | awk '{print $2}'; }
app_port()  { echo "$1" | awk '{print $3}'; }
app_placement() { echo "$1" | awk '{print $4}' | tr ',' ' '; }
app_arbiter() { echo "$1" | grep -oE 'arbiter=[a-z0-9_-]+' | cut -d= -f2 || true; }

app_row() { # $1=имя приложения
  local row; for row in "${APPS[@]}"; do [ "$(app_name "$row")" = "$1" ] && { echo "$row"; return; }; done
}

mtproto_link() { # $1=домен (tg.<base>) $2=секрет (32 hex) -> tg://-ссылка с FakeTLS
  # ссылка со «сырым» секретом (без ee) = транспорт dd, который mtproto.zig
  # по умолчанию не принимает (fake_tls_only) -> Telegram пишет «прокси недоступен».
  # Нужен FakeTLS: ee + секрет + hex(домен) — точно так же печатает `mtbuddy links`.
  [[ "$1" =~ ^[a-zA-Z0-9.-]+$ && "$2" =~ ^[a-fA-F0-9]{32}$ ]] || return 1
  printf 'tg://proxy?server=%s&port=443&secret=ee%s%s' "$1" "$2" \
    "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
}

backup_window() { # $1=alias -> HH:MM (по умолчанию разнос по порядку: 03:10, 03:40, 04:10...)
  local w; w="$(grep -oE "(^| )$1=[0-9:]+" <<<"$BACKUP_WINDOWS" | awk -F= '{print $2}')"
  if [ -n "$w" ]; then echo "$w"; return; fi
  local i=0 n mins; for n in $(node_names); do [ "$n" = "$1" ] && break; i=$((i+1)); done
  mins=$((10 + 30 * i))                      # минуты переполнялись («03:70» = мёртвый cron)
  printf '%02d:%02d' $((3 + mins / 60)) $((mins % 60))
}

# ---------- ssh к нодам ----------
declare -A NPORT=()
detect_port() { # $1=alias: 2222 (готовая нода) или 22 (свежая) или 0 (нет доступа)
  local a="$1" ip; ip="$(node_ip "$a")"
  # -n обязательно: проба не должна съедать stdin пайпа (пустой telegram.env)
  if ssh -n -i "$SSH_KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null; then
    NPORT[$a]=2222
  elif ssh -n -i "$SSH_KEY" -p 22 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null; then
    NPORT[$a]=22
  else
    NPORT[$a]=0
  fi
}
detect_all_ports() { local a; for a in $(node_names); do detect_port "$a"; done; }

nssh() { # nssh <alias> <команда...>
  local a="$1"; shift
  [ -n "${NPORT[$a]:-}" ] || detect_port "$a"
  [ "${NPORT[$a]:-0}" != 0 ] || fail "нет ssh-доступа к ноде $a (см. docs/quickstart.md: положите ключ)"
  ssh -i "$SSH_KEY" -p "${NPORT[$a]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
      "root@$(node_ip "$a")" "$@"
}
ncp() { # ncp <alias> <опции/файлы...> <куда на ноде>  (последний аргумент — путь на ноде!)
  local a="$1"; shift
  [ -n "${NPORT[$a]:-}" ] || detect_port "$a"
  [ "${NPORT[$a]:-0}" != 0 ] || fail "нет ssh-доступа к ноде $a"
  local n=$(( $# - 1 )) dest="${!#}"
  local -a srcs=( "${@:1:$n}" )
  scp -i "$SSH_KEY" -P "${NPORT[$a]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -q \
      "${srcs[@]}" "root@$(node_ip "$a"):$dest"
}

# ---------- ключ межнодового доступа (ноды ходят друг к другу сами) ----------
my_alias() { # какой алиас из инвентаря — ЭТОТ сервер (по его публичному IP)
  local ips a
  ips="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  for a in $(node_names); do
    grep -qw "$(node_ip "$a")" <<<"$ips" && { echo "$a"; return; }
  done
  echo ""
}

gen_cluster_key() {
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  [ -f "$SECRETS/id_cluster" ] || ssh-keygen -t ed25519 -N "" -f "$SECRETS/id_cluster" -C "321r-cluster" >/dev/null
  [ -f "$SSH_KEY" ] || SSH_KEY="$SECRETS/id_cluster"   # мастер-режим: ходим ключом кластера
}

ensure_access() {
  # Ключевой доступ ко ВСЕМ нодам. Нет ключа — заложим по паролю (разово, sshpass):
  # так и задумано — «ввёл пароли серверов и пошло».
  local a ip pw me
  gen_cluster_key
  me="$(my_alias)"
  for a in $(node_names); do
    if [ "$a" = "$me" ]; then
      mkdir -p /root/.ssh; chmod 700 /root/.ssh
      # Проверяем ИМЕННО текущий ключ, а не комментарий «321r-cluster»: при смене
      # ключа комментарий находился, а новый ключ не попадал в authorized_keys
      # и межнодовый ssh отвергался ().
      grep -qxF "$(cat "$SECRETS/id_cluster.pub")" /root/.ssh/authorized_keys 2>/dev/null \
        || cat "$SECRETS/id_cluster.pub" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      detect_port "$a"
      ok "$a (этот сервер): ключ кластера заложен локально"
      continue
    fi
    detect_port "$a"
    [ "${NPORT[$a]:-0}" != 0 ] && { ok "$a: доступ ключом уже есть"; continue; }
    ip="$(node_ip "$a")"
    command -v sshpass >/dev/null 2>&1 || fail "нет доступа к $ip, а sshpass для входа по паролю не установлен (apt-get install sshpass)"
    read -rsp "  Пароль root@$ip (Enter = пропустить): " pw; echo
    [ -n "$pw" ] || fail "без пароля доступ к $ip не получить"
    sshpass -p "$pw" ssh -p 22 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@$ip" \
      'mkdir -p /root/.ssh && chmod 700 /root/.ssh
       grep -qF "321r-cluster" /root/.ssh/authorized_keys 2>/dev/null || cat >> /root/.ssh/authorized_keys
       chmod 600 /root/.ssh/authorized_keys' < "$SECRETS/id_cluster.pub"
    detect_port "$a"
    [ "${NPORT[$a]:-0}" != 0 ] && ok "$a: ключ заложен по паролю" || fail "$a: ключ заложили, но ssh не отвечает"
  done
}

setup_cluster_key() {
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  [ -f "$SECRETS/id_cluster" ] || ssh-keygen -t ed25519 -N "" -f "$SECRETS/id_cluster" -C "321r-cluster" >/dev/null
  local a
  for a in $(node_names); do
    ncp "$a" "$SECRETS/id_cluster" "/root/.ssh/id_cluster"
    ncp "$a" "$SECRETS/id_cluster.pub" "/root/.ssh/id_cluster.pub"
    nssh "$a" 'chmod 600 /root/.ssh/id_cluster
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      grep -qxF "$(cat /root/.ssh/id_cluster.pub)" /root/.ssh/authorized_keys 2>/dev/null || cat /root/.ssh/id_cluster.pub >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      cat > /root/.ssh/config <<EOF
Host 10.66.0.*
  Port 2222
  IdentityFile /root/.ssh/id_cluster
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /root/.ssh/known_hosts
Host *
  Port 2222
  IdentityFile /root/.ssh/id_cluster
  StrictHostKeyChecking accept-new
EOF
      chmod 600 /root/.ssh/config'
    ok "$a: ключ межнодового доступа положен"
  done
}
