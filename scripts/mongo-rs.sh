#!/usr/bin/env bash
# 321r: состав реплика-сети MongoDB (rs_<app>) — тот же уровень, что и инструменты
# PostgreSQL (pg-rebuild-standby / db-guard). Запускать на ноде, где есть контейнер
# mongod-<app>: команды сами находят первичного и ходят к нему.
#
#   mongo-rs.sh has      <app> <host:port>            — член есть в составе (0 = да)
#   mongo-rs.sh status   <app>                        — состав и статусы
#   mongo-rs.sh primary  <app>                        — host:port текущего первичного
#   mongo-rs.sh add      <app> <host:port> [arbiter]  — добавить члена (данные копируются сами)
#   mongo-rs.sh remove   <app> <host:port>            — убрать члена
#   mongo-rs.sh wait     <app> <host:port> <STATE> [сек] — дождаться статуса члена
#   mongo-rs.sh prio     <app> <host:port>            — сделать единственным приоритетным
#   mongo-rs.sh stepdown <app>                        — первичный уступает (плановый фейловер)
#
# Статусы: PRIMARY, SECONDARY, ARBITER (myState 1/2/3/7). host:port — как видит RS:
# mesh-адрес и порт приложения, например 10.66.0.2:27017.
set -euo pipefail

CMD="${1:?использование: mongo-rs.sh <команда> <app> ...}"
APP="${2:?нужно имя приложения}"
H="${3:-}"
CONT="mongod-${APP}"

docker ps --format '{{.Names}}' | grep -qx "$CONT" || {
  echo "нет контейнера $CONT на $(hostname) — команда выполняется на ноде приложения" >&2
  exit 1
}

local_eval() { docker exec "$CONT" mongosh --quiet --eval "$1" 2>/dev/null || true; }
prim_eval()  { # $1 = js — выполняем на ПЕРВИЧНОМ (иначе rs.add/remove отвергаются)
  local p
  p="$(local_eval 'try { print(rs.getPrimary()) } catch (e) { print("") }')"
  [ -n "$p" ] && [ "$p" != "null" ] || { echo "нет первичного у rs_${APP}" >&2; return 1; }
  docker exec "$CONT" mongosh --quiet "mongodb://${p}" --eval "$1"
}
in_rs() { # $1 = host:port → 0, если член реплика-сети
  docker exec "$CONT" mongosh --quiet --eval \
    "try { var c = rs.conf(); quit(c.members.some(function (m) { return m.host === '$1' }) ? 0 : 1) } catch (e) { quit(1) }" \
    >/dev/null 2>&1
}

case "$CMD" in
  has)
    [ -n "$H" ] || { echo "нужен host:port" >&2; exit 1; }
    in_rs "$H"
    ;;

  status)
    local_eval 'try { rs.status().members.forEach(function (m) { print(m.name, m.stateStr, "health=" + m.health) }) } catch (e) { print("реплика-сеть не инициализирована") }'
    ;;

  primary)
    p="$(local_eval 'try { print(rs.getPrimary()) } catch (e) { print("") }')"
    [ -n "$p" ] && [ "$p" != "null" ] || { echo "нет первичного" >&2; exit 1; }
    echo "$p"
    ;;

  add)
    [ -n "$H" ] || { echo "нужен host:port нового члена" >&2; exit 1; }
    if in_rs "$H"; then echo "$H уже в составе rs_${APP}"; exit 0; fi
    extra=""
    [ "${4:-}" = arbiter ] && extra=", arbiterOnly: true"
    out="$(prim_eval "try { rs.add({ host: '$H', priority: 0${extra} }); print('rs.add ok') } catch (e) { print('rs.add err: ' + e) }")"
    echo "$out"
    case "$out" in *"rs.add ok"*) exit 0 ;; *) exit 1 ;; esac
    ;;

  remove)
    [ -n "$H" ] || { echo "нужен host:port члена" >&2; exit 1; }
    if ! in_rs "$H"; then echo "$H и так вне состава rs_${APP}"; exit 0; fi
    cnt="$(prim_eval 'print(rs.conf().members.length)')"
    if [ "${cnt:-0}" -le 1 ]; then
      echo "нельзя убрать последнего члена rs_${APP}" >&2
      exit 1
    fi
    out="$(prim_eval "try { rs.remove('$H'); print('rs.remove ok') } catch (e) { print('rs.remove err: ' + e) }")"
    echo "$out"
    case "$out" in *"rs.remove ok"*) exit 0 ;; *) exit 1 ;; esac
    ;;

  wait)
    STATE="${4:?нужен статус: PRIMARY|SECONDARY|ARBITER}"
    TMO="${5:-600}"
    deadline=$(( $(date +%s) + TMO ))
    st=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
      st="$(local_eval "try { var m = rs.status().members.filter(function (x) { return x.name === '$H' })[0]; print(m ? m.stateStr : '') } catch (e) { print('') }")"
      [ "$st" = "$STATE" ] && { echo "$H: $STATE"; exit 0; }
      sleep 5
    done
    echo "$H: не стал $STATE за ${TMO} с (сейчас: ${st:-нет в составе})" >&2
    exit 1
    ;;

  prio)
    # единственный приоритетный = единственный, кто может стать первичным.
    # Так плановый фейловер детерминирован: после stepDown выбора нет.
    [ -n "$H" ] || { echo "нужен host:port" >&2; exit 1; }
    in_rs "$H" || { echo "$H не в составе rs_${APP} — приоритеты не трогаю (иначе никто не сможет стать первичным)" >&2; exit 1; }
    out="$(prim_eval "var c = rs.conf(); var p1 = '$H'; var ch = false;
c.members.forEach(function (m) { if (m.arbiterOnly) return;
  var w = (m.host === p1) ? 1 : 0;
  var cur = (m.priority === undefined ? 1 : m.priority);
  if (cur !== w) { m.priority = w; ch = true; } });
if (ch) { try { rs.reconfig(c); print('reconfig ok') } catch (e) { print('reconfig err: ' + e) } } else { print('pri ok') }")"
    echo "$out"
    ;;

  stepdown)
    # соединение с первичным рвётся — это норма, результат проверяем через wait
    local_eval 'try { rs.stepDown(60); print("stepdown ok") } catch (e) { print("stepdown отправлен (" + e + ")") }'
    echo "stepdown отправлен: первичный уступит, когда догонит реплика"
    ;;

  *)
    echo "использование: mongo-rs.sh has|status|primary|add|remove|wait|prio|stepdown <app> ..." >&2
    exit 1 ;;
esac
