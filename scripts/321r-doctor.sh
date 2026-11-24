#!/usr/bin/env bash
# 321r doctor — диагностика кластера ОДНИМ файлом (docs/troubleshooting.md).
# Запуск на любой ноде кластера:
#   321r-doctor.sh                — отчёт в /root/321r-diagnostika-<дата>.txt
#   321r-doctor.sh -o /tmp/x.txt  — указать файл
#   321r-doctor.sh --no-logs      — без фрагментов журналов (отчёт короче)
#
# Собирает состояние всех нод, слоя БД, меша, бэкапов и мониторинга, сверяет их
# между собой и в конце печатает список находок. Секреты (пароли, токены, ключи,
# лицензии) в отчёт не попадают: значения вырезаются автоматически.
# Код выхода: 0 — расхождений не найдено, 1 — есть находки (удобно для cron/бота).
set -uo pipefail

OUT=""; LOGS=1
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="${2:?после -o нужен путь к файлу}"; shift 2 ;;
    --no-logs) LOGS=0; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1 (см. --help)" >&2; exit 1 ;;
  esac
done

MAP="${R321_NODES_MAP:-/etc/db/nodes.map}"
[ -f "$MAP" ] || { echo "нет $MAP — запускайте на ноде кластера" >&2; exit 1; }
map_ip() { awk -v a="$1" '$1==a{print $2}' "$MAP"; }
map_swarm() { awk -v a="$1" '$1==a{print $3}' "$MAP"; }
mapfile -t NODES < <(awk '{print $1}' "$MAP")

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/report.txt"; : > "$R"
FIND="$T/findings.txt"; : > "$FIND"
say()  { printf '%s\n' "$*" >> "$R"; }
note() { # находки не дублируем — иначе одна недоступная нода засыпает список
  grep -qxF "$*" "$FIND" 2>/dev/null || printf '%s\n' "$*" >> "$FIND"
}

run_node() { # $1=alias $2=команда → вывод; недоступная нода не роняет отчёт
  local out rc
  out="$(ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "root@$(map_ip "$1")" "$2" 2>&1)"; rc=$?
  if [ "$rc" = 255 ]; then echo "НЕДОСТУПНА (ssh)"; note "нода $1 недоступна по ssh"; else printf '%s\n' "$out"; fi
}
collect() { # то же, но сразу в отчёт и с отступом
  run_node "$1" "$2" | sed 's/^/  /' >> "$R"
}
val() { sed -n "s/^$1: *//p" "$2" 2>/dev/null | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }

# ============================== шапка ==============================
me_ip="$(map_ip "${ME:-}")"; [ -n "$me_ip" ] || me_ip="вне карты нод"
say "321r · диагностика кластера"
say "дата:   $(date -u '+%F %T UTC')"
say "нода:   $(hostname) ($me_ip), сбор отчёта — с неё"
if [ -f /opt/321r/install/install.sh ]; then
  say "версия: установщик /opt/321r от $(date -r /opt/321r/install/install.sh '+%F %T')"
else
  say "версия: установщик /opt/321r не найден"
fi
say ""
say "=== манифест кластера (/etc/db/cluster.yml) ==="
sed 's/^/  /' /etc/db/cluster.yml 2>/dev/null || say "  (нет)"
say ""

# ============================== ноды ==============================
for a in "${NODES[@]}"; do
  say "================================================================"
  say "### НОДА $a  (public $(map_ip "$a"), mesh $(awk -v s="$a" '$1==s{print $2}' "$MAP"), swarm $(map_swarm "$a"))"
  say "================================================================"
  run_node "$a" 'bash -s' <<'REMOTE' | sed 's/^/  /' >> "$R"
echo "-- система"
. /etc/os-release 2>/dev/null; echo "ОС: ${PRETTY_NAME:-?}, ядро $(uname -r), виртуализация: $(systemd-detect-virt 2>/dev/null || echo '?')"
uptime | sed 's/.*up/up/'
free -m | awk '/Mem:/{printf "RAM: занято %s из %s МБ, свободно %s МБ\n", $3, $2, $7}'
df -h / 2>/dev/null | awk 'NR==2{printf "диск /: занято %s из %s (%s)\n", $3, $2, $5}'
df -h /var/lib/docker 2>/dev/null | awk 'NR==2{printf "диск docker: занято %s из %s (%s)\n", $3, $2, $5}'
echo "docker: $(docker --version 2>/dev/null | sed 's/Docker version //; s/,.*//')"

echo "-- контейнеры"
docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.RunningFor}}' 2>/dev/null | sort

echo "-- службы"
for s in awg0 db-guard.timer docker-user reresolve-dns.timer tgbot 321r-newt mtproto-proxy periphery certbot.timer; do
  printf '  %-20s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo 'нет')"
done

echo "-- меш: секунд с последнего рукопожатия"
awg show wg0 latest-handshakes 2>/dev/null | awk '{printf "  %s -> %d с\n", $1, (systime()-$2)}'

echo "-- VIP: что слушается на 10.66.0.99"
ss -ltn 2>/dev/null | grep -o '10\.66\.0\.99:[0-9]*' | sort -u | sed 's/^/  /'

echo "-- firewall / антибрут"
ufw status 2>/dev/null | head -2
fail2ban-client status sshd 2>/dev/null | grep -E 'Total banned|Currently banned' | sed 's/^/  /'

echo "-- блоки прокси (db-proxy)"
grep -h '^# BEGIN' /opt/db/proxy/haproxy.cfg 2>/dev/null | sed 's/^/  /'

echo "-- cron кластера"
ls -1 /etc/cron.d 2>/dev/null | sed 's/^/  /'

echo "-- свежесть данных"
for f in /var/lib/pgbackup/last_verify /var/lib/pgbackup/last_backup; do
  [ -f "$f" ] && echo "  $(basename "$f"): $(date -d @$(cat "$f") '+%F %T' 2>/dev/null || echo '?')"
done
REMOTE
  say ""
done

# ============================== слой БД ==============================
say "================================================================"
say "### СЛОЙ БД (реестр /etc/db/apps.d)"
say "================================================================"
ADIR="${R321_APPS_DIR:-/etc/db/apps.d}"
for reg in "$ADIR"/*.yaml; do
  [ -f "$reg" ] || { say "  реестра нет — приложения не развёрнуты"; break; }
  app="$(val name "$reg")"
  engine="$(val engine "$reg")"
  class="$(val class "$reg")"; class="${class:-cluster}"
  port="$(val port "$reg")"
  arb="$(val arbiter "$reg")"
  place="$(val placement "$reg" | tr -d '[] ')"
  say ""
  say "-- $app: engine=$engine class=$class port=$port placement=$place ${arb:+arbiter=$arb}"
  prim=0
  for n in $(echo "$place" | tr ',' ' '); do
    st="$(run_node "$n" "docker ps --format '{{.Names}}' | grep -c -E '^(pg|mongod)-$app\$'")"
    case "$st" in
      *НЕДОСТУПНА*) say "  $n: нода недоступна"; continue ;;
    esac
    if [ "${st:-0}" = "0" ]; then
      say "  $n: контейнера БД НЕТ"; note "$app: на ноде $n нет контейнера БД"
      continue
    fi
    if [ "$engine" = pg ]; then
      role="$(run_node "$n" "docker exec -u postgres pg-$app psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null")"
      case "$role" in
        f) say "  $n: ПЕРВИЧНЫЙ"; prim=$((prim+1)) ;;
        t) say "  $n: стендбай" ;;
        *) say "  $n: роль не определена ($role)"; note "$app: на ноде $n не удалось определить роль" ;;
      esac
    else
      role="$(run_node "$n" "docker exec mongod-$app mongosh --quiet --eval 'try{print(rs.status().myState)}catch(e){print(-1)}' 2>/dev/null")"
      case "$role" in
        1) say "  $n: PRIMARY"; prim=$((prim+1)) ;;
        2) say "  $n: SECONDARY" ;;
        3|7) say "  $n: ARBITER" ;;
        *) say "  $n: не в реплика-сети ($role)"; note "$app: на ноде $n mongod не в реплика-сети" ;;
      esac
    fi
    blk="$(run_node "$n" "awk '/^# BEGIN $app\$/ {c++} END {print c+0}' /opt/db/proxy/haproxy.cfg 2>/dev/null")"
    [ "${blk:-0}" = "0" ] && [ "$class" = cluster ] && { say "  $n: блока $app в haproxy НЕТ"; note "$app: на ноде $n нет блока в haproxy"; }
  done
  if [ "$class" = cluster ] && [ "$prim" != "1" ]; then
    note "$app: первичных $prim (нужен ровно 1)"
  fi
  first="$(echo "$place" | cut -d, -f1)"
  say "  секреты на $first: $(run_node "$first" "ls -1 /etc/db/secrets 2>/dev/null | tr '\n' ' '")"
done
say ""

# ============================== меш, swarm, бэкапы ==============================
say "================================================================"
say "### МЕШ, SWARM, БЭКАПЫ, МОНИТОРИНГ"
say "================================================================"
bad_hs=0
for a in "${NODES[@]}"; do
  hs="$(run_node "$a" "awg show wg0 latest-handshakes 2>/dev/null | awk '{print (systime()-\$2)}' | sort -n | tail -1")"
  case "$hs" in
    ''|*НЕДОСТУПНА*) say "  $a: рукопожатий нет"; bad_hs=1 ;;
    *)
      say "  $a: самое старое рукопожатие — ${hs} с назад"
      case "$hs" in (*[!0-9]*) ;; (*) [ "$hs" -gt 300 ] && { say "     ⚠ больше 5 минут"; bad_hs=1; } ;; esac
      ;;
  esac
done
[ "$bad_hs" = 1 ] && note "меш: есть узлы без свежих рукопожатий (>5 мин)"
say ""
say "-- swarm"
collect "${NODES[0]}" 'docker node ls --format "{{.Hostname}} {{.Status}} {{.Availability}} {{.ManagerStatus}}" 2>/dev/null; echo "метки:"; for id in $(docker node ls -q 2>/dev/null); do docker node inspect "$id" --format "{{.Description.Hostname}}: {{range \$k,\$v := .Spec.Labels}}{{\$k}}={{\$v}} {{end}}"; done'
say ""
say "-- бэкапы (последние снимки)"
collect "${NODES[0]}" 'ls -lt /var/lib/pgbackup/*.tar.gz /var/lib/pgbackup/*.gz 2>/dev/null | head -5'
say ""
say "-- мониторинг и дозор"
collect "${NODES[0]}" 'ls -l /etc/cron.d/ 2>/dev/null; echo; systemctl list-timers --no-pager 2>/dev/null | grep -E "321r|db-guard|reresolve|certbot" | head -6'
say ""

# ============================== журналы ==============================
if [ "$LOGS" = 1 ]; then
  say "================================================================"
  say "### ЖУРНАЛЫ (последние строки)"
  say "================================================================"
  for a in "${NODES[@]}"; do
    say "-- $a"
    collect "$a" 'journalctl -u awg0 -u db-guard -u docker-user --no-pager -n 25 -q 2>/dev/null | tail -25'
  done
  say ""
fi

# ============================== находки ==============================
say "================================================================"
say "### ИТОГ"
say "================================================================"
if [ -s "$FIND" ]; then
  say "НАХОДКИ (что стоит проверить):"
  sed 's/^/  ✗ /' "$FIND" >> "$R"
else
  say "Расхождений не найдено: ноды отвечают, БД согласованы, меш живой."
fi

# ---------- секреты вырезаем на выходе, а не по ходу дела ----------
STAMP="$(date '+%Y%m%d-%H%M')"
[ -n "$OUT" ] || OUT="/root/321r-diagnostika-$STAMP.txt"
sed -E 's/((PASSWORD|PASSWD|TOKEN|SECRET|LICENSE|API[_-]?KEY|пароль|Пароль|секрет|Секрет|лицензи|Лицензи)[^:=]*[=:][ ]*)("[^"]*"|[^ ,"}]*)/\1<скрыто>/gI' "$R" > "$OUT"
chmod 600 "$OUT"

echo "отчёт: $OUT ($(wc -l < "$OUT") строк)"
if [ -s "$FIND" ]; then
  echo "находок: $(wc -l < "$FIND") — они в конце отчёта"
  exit 1
fi
echo "проблем не найдено"
