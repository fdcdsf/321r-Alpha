#!/usr/bin/env bash
# 321r drills — автопрогон учений по отказам (каталог и нормы: docs/drills.md).
#
#   321r-drills.sh list                          — каталог дриллов
#   321r-drills.sh run <имя> [--yes]             — один дрилл
#   321r-drills.sh run all [--yes]               — все обычные
#   321r-drills.sh run all --destructive [--yes] — включая «жёсткие» (стоп docker, кворум, ребуты)
#   321r-drills.sh last                          — показать последний протокол
#
# Запускать на ноде кластера в рабочее окно. Дрилл намеренно ломает часть системы
# и проверяет, что она восстановилась САМА; по завершении всё возвращается на место
# (даже при обрыве — восстановление висит на EXIT). Перед прогоном кластер проверяется
# на здоровье: на сломанном ничего не ломаем.
# Протокол: /root/321r-drilly-<дата>.txt (формат из docs/drills.md).
# Код выхода: 0 — все пройдены, 1 — есть непройденные.
set -uo pipefail

MAP="${R321_NODES_MAP:-/etc/db/nodes.map}"
ADIR="${R321_APPS_DIR:-/etc/db/apps.d}"
[ -f "$MAP" ] || { echo "нет $MAP — запускайте на ноде кластера" >&2; exit 1; }
map_ip() { awk -v a="$1" '$1==a{print $2}' "$MAP"; }
mapfile -t NODES < <(awk '{print $1}' "$MAP")
ME="$(awk -v s="$(hostname)" '$3==s{print $1}' "$MAP")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

val() { sed -n "s/^$1: *//p" "$2" 2>/dev/null | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
run_on() { ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
           "root@$(map_ip "$1")" "$2" 2>/dev/null; }
apps_of() { local reg; for reg in "$ADIR"/*.yaml; do [ -f "$reg" ] || continue
    [ "$(val engine "$reg")" = "$1" ] && val name "$reg"; done; }
place_of() { val placement "$ADIR/$1.yaml" | tr -d '[] ' | tr ',' ' '; }
port_of()  { val port "$ADIR/$1.yaml"; }

# ---------- проверки состояния ----------
pg_is_primary()   { [ "$(run_on "$1" "docker exec -u postgres pg-$2 psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null")" = "f" ]; }
pg_is_standby()   { [ "$(run_on "$1" "docker exec -u postgres pg-$2 psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null")" = "t" ]; }
mongo_state()     { run_on "$1" "docker exec mongod-$2 mongosh --quiet --eval 'try{print(rs.status().myState)}catch(e){print(-1)}' 2>/dev/null"; }
pg_prim()   { local n; for n in $(place_of "$1"); do pg_is_primary "$n" "$1" && { echo "$n"; return 0; }; done; }
mongo_prim(){ local n; for n in $(place_of "$1"); do [ "$(mongo_state "$n" "$1")" = "1" ] && { echo "$n"; return 0; }; done; }

pg_vip_ok() { # запись через VIP идёт на живого первичного
  local p; p="$(pg_prim "$1")"; [ -n "$p" ] || return 1
  [ "$(run_on "$p" "docker exec -e PGPASSWORD=\$(grep ^POSTGRES_PASSWORD= /etc/db/secrets/$1.env | cut -d= -f2) pg-$1 psql -h 10.66.0.99 -p $(port_of "$1") -U postgres -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null")" = "t" ]
}
mongo_vip_ok() {
  local p; p="$(mongo_prim "$1")"; [ -n "$p" ] || return 1
  [ "$(run_on "$p" "docker run --rm --network host mongo:7 mongosh 'mongodb://10.66.0.99:$(port_of "$1")/?replicaSet=rs_$1' --quiet --eval 'print(db.hello().isWritablePrimary)' 2>/dev/null")" = "true" ]
}

gate() {
  echo "-- проверка здоровья кластера перед прогоном..."
  local a app bad=0
  for a in "${NODES[@]}"; do run_on "$a" 'true' || { echo "  ✗ нода $a недоступна"; bad=1; }; done
  for app in $(apps_of pg);    do [ -n "$(pg_prim "$app")" ]    || { echo "  ✗ pg $app: нет первичного"; bad=1; }; done
  for app in $(apps_of mongo); do [ -n "$(mongo_prim "$app")" ] || { echo "  ✗ mongo $app: нет первичного"; bad=1; }; done
  [ "$bad" = 0 ] || { echo "кластер не здоров — сначала приведите в порядок (321r-doctor.sh)"; return 1; }
  echo "  ✓ все ноды отвечают, у каждой БД ровно один первичный"
}

# ---------- протокол ----------
PROTO="${R321_DRILL_OUT:-/root/321r-drilly-$(date '+%Y%m%d-%H%M').txt}"
FACTS=""
sec0=0
begin() { sec0=$(date +%s); FACTS=""; }
fact()  { FACTS="${FACTS}  - $*\n"; echo "    · $*"; }

# ======================================================================
# ДРИЛЛЫ: d_* — действие и проверка (0 = пройден, 1 = провал, 2 = пропущен),
#         r_* — возврат на место (вызывается всегда)
# ======================================================================

# --- Промоушен PG + дрилл данных: смерть первичного при живых клиентах ---
d_pg-failover() {
  local app p other t rv dl ok="" n back=""
  app="$(apps_of pg | head -1)"
  [ -n "$app" ] || { echo "  нет pg-приложений — пропущен"; return 2; }
  p="$(pg_prim "$app")"; [ -n "$p" ] || return 1
  other=""; for n in $(place_of "$app"); do [ "$n" = "$p" ] || other="$n"; done
  [ -n "$other" ] || { echo "  нужен второй узел в placement — пропущен"; return 2; }
  echo "  жертва: $p (первичный $app), приемник: $other"
  t=$(date +%s)
  run_on "$p" "cd /opt/db/pg-$app && docker compose stop >/dev/null"
  dl=$(( t + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    pg_is_primary "$other" "$app" && { ok=1; break; }
    sleep 3
  done
  rv=$(( $(date +%s) - t ))
  [ -n "$ok" ] || { fact "новый первичный не появился за 180 с"; return 1; }
  fact "новый первичный ($other) за ${rv} с (норма ≤120 с)"
  [ "$rv" -le 120 ] || fact "НОРМА ПРЕВЫШЕНА: ${rv} с > 120 с"
  pg_vip_ok "$app" && fact "запись через VIP идёт на нового первичного" || { fact "VIP не ведёт на нового первичного"; return 1; }
  run_on "$other" "grep -q 'server primary $(map_ip "$other")' /opt/db/proxy/haproxy.cfg" \
    && fact "прокси переключён на нового первичного" || fact "внимание: прокси не переключился сам (см. db-guard)"
  echo "  возвращаю жертву..."
  run_on "$p" "cd /opt/db/pg-$app && docker compose start >/dev/null"
  dl=$(( $(date +%s) + 150 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    pg_is_standby "$p" "$app" && { back=1; break; }
    sleep 5
  done
  if [ -n "$back" ]; then
    fact "старый первичный вернулся стендбаем сам"
  else
    echo "  таймлайн разошёлся — пересборка стендбая..."
    run_on "$p" "/usr/local/bin/pg-rebuild-standby.sh $app" >/dev/null 2>&1
    fact "стендбай пересобран pg-rebuild-standby.sh"
  fi
}
r_pg-failover() {
  local app p; app="$(apps_of pg | head -1)"; [ -n "$app" ] || return 0
  for p in $(place_of "$app"); do run_on "$p" "cd /opt/db/pg-$app && docker compose start >/dev/null 2>&1"; done
}

# --- Назначение Mongo: смерть primary mongod ---
d_mongo-failover() {
  local app p other t rv dl ok="" n back=""
  app="$(apps_of mongo | head -1)"
  [ -n "$app" ] || { echo "  нет mongo-приложений — пропущен"; return 2; }
  p="$(mongo_prim "$app")"; [ -n "$p" ] || return 1
  other=""; for n in $(place_of "$app"); do [ "$n" = "$p" ] || other="$n"; done
  [ -n "$other" ] || { echo "  нужен второй узел в placement — пропущен"; return 2; }
  echo "  жертва: $p (primary rs_$app), приемник: $other"
  t=$(date +%s)
  run_on "$p" "docker stop mongod-$app >/dev/null"
  dl=$(( t + 120 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    [ "$(mongo_state "$other" "$app")" = "1" ] && { ok=1; break; }
    sleep 3
  done
  rv=$(( $(date +%s) - t ))
  [ -n "$ok" ] || { fact "новый primary не выбран за 120 с"; return 1; }
  fact "новый primary ($other) за ${rv} с (норма ≤60 с)"
  [ "$rv" -le 60 ] || fact "НОРМА ПРЕВЫШЕНА: ${rv} с > 60 с"
  mongo_vip_ok "$app" && fact "приложения пишут через VIP" || { fact "VIP не ведёт на нового primary"; return 1; }
  echo "  возвращаю жертву..."
  run_on "$p" "docker start mongod-$app >/dev/null"
  dl=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    [ "$(mongo_state "$p" "$app")" = "2" ] && { back=1; break; }
    sleep 5
  done
  [ -n "$back" ] && fact "старый primary вернулся SECONDARY (суммарно $(( $(date +%s) - t )) с)" \
    || fact "внимание: жертва не вернулась в rs — смотрите mongo-rs.sh status $app"
}
r_mongo-failover() {
  local app n; app="$(apps_of mongo | head -1)"; [ -n "$app" ] || return 0
  for n in $(place_of "$app"); do run_on "$n" "docker start mongod-$app >/dev/null 2>&1"; done
}

# --- Панель падает (cgroup-OOM): ingress не страдает ---
d_panel-oom() {
  run_on "${NODES[0]}" 'docker ps --format "{{.Names}}" | grep -qx pangolin' || { echo "  pangolin не развёрнут — пропущен"; return 2; }
  local t rv dl ok=""
  echo "  убиваю контейнер pangolin (имитация OOM)..."
  t=$(date +%s)
  run_on "${NODES[0]}" 'docker kill pangolin >/dev/null'
  dl=$(( t + 60 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    [ "$(run_on "${NODES[0]}" "docker inspect -f '{{.State.Running}}' pangolin 2>/dev/null")" = "true" ] && { ok=1; break; }
    sleep 3
  done
  rv=$(( $(date +%s) - t ))
  [ -n "$ok" ] || { fact "панель не поднялась сама за 60 с"; return 1; }
  fact "панель поднялась сама за ${rv} с (норма ~5 с, допуск ≤60 с)"
}

# --- Нода ложится: стоп docker → Swarm переносит задачи ---
d_node-down() {
  local victim="" a st dl ok=""
  for a in "${NODES[@]}"; do [ "$a" = "$ME" ] || { victim="$a"; break; }; done
  [ -n "$victim" ] || { echo "  в кластере одна нода — пропущен"; return 2; }
  echo "  жертва: $victim (стоп docker), сбор идёт с $ME"
  run_on "$victim" 'systemctl stop docker docker.socket'
  sleep 45
  st="$(run_on "${NODES[0]}" 'docker service ls --format "{{.Name}} {{.Replicas}}" 2>/dev/null' | tr '\n' '; ')"
  fact "реплики сервисов через 45 с после падения $victim: ${st:-нет данных}"
  echo "  возвращаю docker на $victim..."
  run_on "$victim" 'systemctl start docker.socket docker'
  dl=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    if run_on "${NODES[0]}" "docker node ls --format '{{.Hostname}} {{.Status}}' | grep -w \"$victim\" | grep -qw Ready"; then ok=1; break; fi
    sleep 5
  done
  [ -n "$ok" ] && fact "$victim снова Ready в Swarm" || { fact "$victim не вернулась в Swarm за 180 с"; return 1; }
}
r_node-down() {
  local a; for a in "${NODES[@]}"; do [ "$a" = "$ME" ] || run_on "$a" 'systemctl start docker.socket docker >/dev/null 2>&1'; done
}

# --- Меш: падение awg0 на одной ноде ---
d_mesh-down() {
  local victim="" a hs dl ok=""
  for a in "${NODES[@]}"; do [ "$a" = "$ME" ] || { victim="$a"; break; }; done
  [ -n "$victim" ] || { echo "  в кластере одна нода — пропущен"; return 2; }
  echo "  жертва: $victim (стоп awg0)"
  run_on "$victim" 'systemctl stop awg0'
  sleep 20
  fact "awg0 остановлен на $victim — остальные ноды продолжают работать"
  echo "  поднимаю awg0..."
  run_on "$victim" 'systemctl start awg0'
  dl=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    hs="$(run_on "$victim" "awg show wg0 latest-handshakes 2>/dev/null | awk '{print (systime()-\$2)}' | sort -n | tail -1")"
    case "$hs" in (*[!0-9]*) ;; (*) [ "$hs" -lt 60 ] && { ok=1; break; } ;; esac
    sleep 5
  done
  [ -n "$ok" ] && fact "рукопожатия меша восстановились за ≤90 с" || { fact "меш на $victim не восстановился за 90 с"; return 1; }
}
r_mesh-down() { local a; for a in "${NODES[@]}"; do run_on "$a" 'systemctl start awg0 >/dev/null 2>&1'; done; }

# --- Зависший (unhealthy) контейнер чинится сам ---
d_unhealthy() {
  local n="${NODES[0]}" t0 cur t rv dl ok=""
  echo "  создаю контейнер, который станет unhealthy..."
  run_on "$n" 'docker rm -f drill-unhealthy >/dev/null 2>&1; docker run -d --name drill-unhealthy --health-cmd "false" --health-interval 5s --health-timeout 2s --health-start-period 5s alpine sleep 600 >/dev/null'
  sleep 20
  t0="$(run_on "$n" 'docker inspect -f "{{.State.StartedAt}}" drill-unhealthy 2>/dev/null')"
  [ -n "$t0" ] || { fact "контейнер не создался"; return 1; }
  t=$(date +%s); dl=$(( t + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    cur="$(run_on "$n" 'docker inspect -f "{{.State.StartedAt}}" drill-unhealthy 2>/dev/null')"
    [ -n "$cur" ] && [ "$cur" != "$t0" ] && { ok=1; break; }
    sleep 10
  done
  rv=$(( $(date +%s) - t ))
  run_on "$n" 'docker rm -f drill-unhealthy >/dev/null 2>&1'
  [ -n "$ok" ] && fact "unhealthy-restart перезапустил зависший контейнер за ${rv} с" \
    || { fact "unhealthy-restart не сработал за 180 с"; return 1; }
}

# --- Восстановление из бэкапа (restore-тест) ---
d_backup-restore() {
  local n="${NODES[0]}"
  echo "  прогон backup-verify.sh (восстановление в scratch-среду)..."
  if run_on "$n" '/usr/local/bin/backup-verify.sh' > "$TMP/backup.log" 2>&1; then
    fact "backup-verify.sh: копии читаются и восстанавливаются"
  else
    fact "backup-verify.sh: ПРОВАЛ"
    tail -15 "$TMP/backup.log" | sed 's/^/      /'
    return 1
  fi
}

# --- Пересборка «болезненного» стендбая ---
d_pg-standby() {
  local app s="" n t rv dl ok=""
  app="$(apps_of pg | head -1)"
  [ -n "$app" ] || { echo "  нет pg-приложений — пропущен"; return 2; }
  for n in $(place_of "$app"); do pg_is_standby "$n" "$app" && { s="$n"; break; }; done
  [ -n "$s" ] || { echo "  нет стендбая для пересборки — пропущен"; return 2; }
  echo "  пересобираю стендбай на $s..."
  t=$(date +%s)
  run_on "$s" "/usr/local/bin/pg-rebuild-standby.sh $app" >/dev/null 2>&1
  rv=$(( $(date +%s) - t ))
  dl=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    pg_is_standby "$s" "$app" && { ok=1; break; }
    sleep 5
  done
  [ -n "$ok" ] && fact "стендбай $s пересобран за ${rv} с (норма ~60 с)" || { fact "стендбай $s не поднялся за 3 мин"; return 1; }
}

# --- DDNS (автоматизируемая часть «смены IP») ---
d_ddns() {
  local a rc=0
  for a in "${NODES[@]}"; do
    if run_on "$a" '/usr/local/bin/ddns.sh'; then fact "$a: ddns.sh отработал"; else fact "$a: ddns.sh с ошибкой"; rc=1; fi
  done
  return $rc
}

# --- Перенос приложения (нужен свободный узел вне placement) ---
d_app-move() {
  local app n free="" busy from="" t rv
  app="$(apps_of pg | head -1)"
  [ -n "$app" ] || { echo "  нет pg-приложений — пропущен"; return 2; }
  busy=",$(place_of "$app" | tr -d ' \n'),"
  for n in "${NODES[@]}"; do case "$busy" in *",$n,"*) ;; *) free="$n"; break ;; esac; done
  [ -n "$free" ] || { echo "  нет свободного узла вне placement — пропущен"; return 2; }
  for n in $(place_of "$app"); do pg_is_standby "$n" "$app" && { from="$n"; break; }; done
  [ -n "$from" ] || { echo "  нет стендбая для переноса — пропущен"; return 2; }
  echo "  переношу стендбай $app: $from -> $free и обратно"
  t=$(date +%s)
  run_on "$ME" "/usr/local/bin/app-move.sh $app $from $free" >/dev/null 2>&1 || { fact "app-move $from->$free не прошёл"; return 1; }
  rv=$(( $(date +%s) - t ))
  fact "перенос $from -> $free за ${rv} с (норма даунтайма ~10–20 с)"
  pg_vip_ok "$app" || { fact "после переноса VIP не работает"; return 1; }
  run_on "$ME" "/usr/local/bin/app-move.sh $app $free $from" >/dev/null 2>&1 || { fact "обратный перенос $free->$from не прошёл"; return 1; }
  fact "перенос выполнен туда и обратно, запись через VIP работала"
}

# --- Потеря большинства (2 из 3) — РАЗРУШИТЕЛЬНЫЙ ---
d_quorum-loss() {
  local a arr=() v1 v2
  for a in "${NODES[@]}"; do [ "$a" = "$ME" ] || arr+=("$a"); done
  [ "${#arr[@]}" -ge 2 ] || { echo "  нужны минимум 2 ноды помимо этой — пропущен"; return 2; }
  v1="${arr[0]}"; v2="${arr[1]}"
  echo "  жертвы: $v1 и $v2 (стоп docker), выжившая: $ME"
  run_on "$v1" 'systemctl stop docker docker.socket'
  run_on "$v2" 'systemctl stop docker docker.socket'
  fact "docker остановлен на $v1 и $v2 — кворума нет"
  sleep 60
  echo "  аварийный подъём на выжившей ноде..."
  run_on "$ME" '/usr/local/bin/survival.sh' >/dev/null 2>&1 \
    && fact "survival.sh выполнен на $ME" || fact "survival.sh с ошибкой"
  echo "  возвращаю ноды..."
  run_on "$v1" 'systemctl start docker.socket docker'
  run_on "$v2" 'systemctl start docker.socket docker'
  fact "ноды возвращены; авто-восстановление ~90 с. Обязательно: сверка целостности (pg-rebuild-standby.sh, «шаг назад»)"
}
r_quorum-loss() {
  local a; for a in "${NODES[@]}"; do [ "$a" = "$ME" ] || run_on "$a" 'systemctl start docker.socket docker >/dev/null 2>&1'; done
}

# --- Ребут-тест остальных серверов — РАЗРУШИТЕЛЬНЫЙ ---
d_reboot-test() {
  local a n=0 t rv ok=0
  for a in "${NODES[@]}"; do
    [ "$a" = "$ME" ] && continue
    echo "  перезагружаю $a..."
    run_on "$a" 'nohup sh -c "sleep 1; systemctl reboot" >/dev/null 2>&1 &'
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || { echo "  перезагружать некого — пропущен"; return 2; }
  fact "перезагружено нод: $n (сама нода $ME не перезагружалась)"
  t=$(date +%s)
  local dl=$(( t + 600 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    ok=1
    for a in "${NODES[@]}"; do [ "$a" = "$ME" ] && continue; run_on "$a" 'true' || ok=0; done
    [ "$ok" = 1 ] && break
    sleep 15
  done
  rv=$(( $(date +%s) - t ))
  [ "$ok" = 1 ] || { fact "не все ноды вернулись за 10 мин"; return 1; }
  fact "все ноды отвечают через ${rv} с (норма самоизлечения ≤10 мин)"
  echo "  эту ноду ($ME) перезагрузите вручную — иначе тест неполный"
}

ALL_SAFE="pg-failover mongo-failover panel-oom node-down mesh-down unhealthy backup-restore pg-standby ddns app-move"
ALL_HARD="quorum-loss reboot-test"

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

list_drills() {
  cat <<'EOF'
Каталог автопрогона (нормы и ручные дриллы — docs/drills.md):

  pg-failover     смерть первичного PG          норма ≤120 с      обычный
  mongo-failover  смерть primary mongod         норма ≤60 с       обычный
  panel-oom       панель падает (OOM)           сама за ~5 с      обычный
  node-down       нода ложится (стоп docker)    Swarm переносит   обычный
  mesh-down       падение awg0 на ноде          меш восстановился обычный
  unhealthy       зависший контейнер            лечится сам       обычный
  backup-restore  восстановление из бэкапа      копии целы        обычный
  pg-standby      пересборка стендбая           ~60 с             обычный
  ddns            смена IP (прогон ddns)        без ошибок        обычный
  app-move        перенос приложения            ~20 с даунтайма   обычный*

  quorum-loss     потеря большинства (2 из 3)   выживание+возврат РАЗРУШИТЕЛЬНЫЙ
  reboot-test     ребут остальных серверов      ≤10 мин           РАЗРУШИТЕЛЬНЫЙ

  * app-move требует свободный узел вне placement.

Не автоматизируются (проводите руками по docs/drills.md): фенсинг изолированной
ноды, «IP заблокирован», слабая нода, восстановление в другой дата-центр.

Запуск: 321r-drills.sh run <имя> [--yes]  |  run all [--destructive] [--yes]
EOF
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf 'Дрилл намеренно ломает часть кластера. Продолжить? [y/N] '
  read -r x
  case "$x" in y|Y|д|Д) return 0 ;; *) echo "отменено"; exit 1 ;; esac
}

run_drill() {
  local id="$1" rc
  echo
  echo "================================================================"
  echo "=== ДРИЛЛ: $id"
  echo "================================================================"
  begin
  "d_$id"; rc=$?
  case "$rc" in
    0) RESULT="ПРОЙДЕН" ;;
    2) RESULT="ПРОПУЩЕН" ;;
    *) RESULT="НЕ ПРОЙДЕН"; FAILED+=("$id") ;;
  esac
  if declare -F "r_$id" >/dev/null 2>&1; then "r_$id" >/dev/null 2>&1; fi
  {
    echo "## Дрилл $id ($(date '+%F %T')): $RESULT"
    echo "**Метрики и факты:**"
    printf "%b" "${FACTS:-  (нет)}"
    echo
  } >> "$PROTO"
  echo "-- итог: $RESULT"
}

# ======================================================================
CMD=""; TARGET=""; ASSUME_YES=0; DESTRUCTIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    list|last|run) CMD="$1"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --destructive) DESTRUCTIVE=1; shift ;;
    --out) R321_DRILL_OUT="$2"; PROTO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) if [ -z "$TARGET" ]; then TARGET="$1"; shift
       else echo "неизвестный аргумент: $1 (см. --help)" >&2; exit 1; fi ;;
  esac
done

case "$CMD" in
  list) list_drills; exit 0 ;;
  last) cat /root/321r-drilly-*.txt 2>/dev/null | tail -80; exit 0 ;;
  run) [ -n "$TARGET" ] || { echo "укажите дрилл или all (см. list)" >&2; exit 1; } ;;
  *) usage; exit 1 ;;
esac

FAILED=()
# сначала проверяем сам вызов, потом здоровье кластера — на сломанном ничего не ломаем
if [ "$TARGET" != all ]; then
  case " $ALL_SAFE $ALL_HARD " in *" $TARGET "*) ;; *) echo "нет дрилла '$TARGET' (см. list)" >&2; exit 1 ;; esac
  case " $ALL_HARD " in *" $TARGET "*)
    [ "$DESTRUCTIVE" = 1 ] || { echo "дрилл $TARGET разрушительный — нужен флаг --destructive" >&2; exit 1; } ;; esac
fi
gate || exit 1
{
  echo "321r · протокол автопрогона дриллов"
  echo "дата: $(date -u '+%F %T UTC'), нода сбора: $(hostname), дрилл: $TARGET"
  echo "каталог и нормы: docs/drills.md"
  echo
} > "$PROTO"
confirm

if [ "$TARGET" = all ]; then
  for id in $ALL_SAFE; do run_drill "$id"; done
  [ "$DESTRUCTIVE" = 1 ] && for id in $ALL_HARD; do run_drill "$id"; done
else
  run_drill "$TARGET"
fi

echo
echo "================================================================"
echo "протокол: $PROTO"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "НЕ ПРОЙДЕНО: ${FAILED[*]}"
  exit 1
fi
echo "все дриллы пройдены"
