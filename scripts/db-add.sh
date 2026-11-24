#!/usr/bin/env bash
# db-add.sh — поднимает слой БД приложения по реестру (docs/databases.md).
# Запуск: на bootstrap-ноде (b, менеджер):   bash /root/db-add.sh pangolin
# Реестр /etc/db/apps.d/<app>.yaml клонируется db-add на ВСЕ ноды — их db-guard читает
# Его для голосов даже вне S(X). Секреты генерируются на узлах (umask 077) — в чат и
# В гит не попадают.
#
# engine=pg    : инстанс на каждом узле S(X); на первичном initdb + роли/база приложения
#                + pg_hba для mesh; на стендбаях pg_basebackup -R; метки; haproxy на VIP.
# engine=mongo : mongod --replSet на узлах S(X) (+ арбитр при |S|=2); rs.initiate с
#                priority 1 только у стартового первичного; дальше назначает db-guard.
# class=local  : без репликации и прокси — инстанс публикуется на VIP напрямую.
set -euo pipefail
umask 077

APP="${1:?usage: db-add.sh <app>}"
REG="/etc/db/apps.d/${APP}.yaml"
SSHOPTS=(-p 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
# У scp порт — заглавный -P (у ssh -p): отдельный массив, иначе scp примет 2222 за файл
SCPOPTS=(-P 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT

[ -f "$REG" ] || { echo "нет реестра $REG" >&2; exit 1; }
[ -f /etc/db/nodes.map ] || { echo "нет /etc/db/nodes.map — сначала db-prep.sh на всех нодах" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "нет docker compose v2: apt-get install -y docker-compose-plugin" >&2; exit 1; }

# ---------- реестр (комментарии и пробелы отрезаем) ----------
val() { sed -n "s/^$1: *//p" "$REG" | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
ENGINE="$(val engine | tr -d ' ')"
CLASS="$(val class | tr -d ' ')"
PRIMARY="$(val primary | tr -d ' ')"
PORT="$(val port | tr -d ' ')"
ARB="$(val arbiter | tr -d ' ')"
read -r -a NODES < <(val placement | tr -d '[] ' | tr ',' ' ')
CLASS="${CLASS:-cluster}"

[ -n "$ENGINE" ] && [ -n "$PORT" ] && [ -n "$PRIMARY" ] && [ "${#NODES[@]}" -ge 1 ] || {
  echo "реестр: нужны engine, port, primary, placement" >&2; exit 1; }
case "$ENGINE" in pg|mongo) ;; *) echo "неизвестный engine: $ENGINE" >&2; exit 1;; esac
[[ " ${NODES[*]} " == *" $PRIMARY "* ]] || { echo "primary $PRIMARY вне placement" >&2; exit 1; }

# ---------- nodes.map ----------
map_ip()    { awk -v a="$1" '$1==a{print $2}' /etc/db/nodes.map; }
map_swarm() { awk -v a="$1" '$1==a{print $3}' /etc/db/nodes.map; }
# mapfile, а НЕ read -a: read читает одну строку и получался только первый узел
mapfile -t ALL_NODES < <(awk '{print $1}' /etc/db/nodes.map)
ME_ALIAS="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"

for n in "${NODES[@]}" "$PRIMARY" ${ARB:+"$ARB"}; do
  [ -n "$(map_ip "$n")" ] || { echo "нода $n не в nodes.map" >&2; exit 1; }
done
PRIMARY_IP="$(map_ip "$PRIMARY")"
run_on() { ssh "${SSHOPTS[@]}" "root@$(map_ip "$1")" "$2"; }

# ---------- 0) реестр + каталоги на все ноды (db-guard голосует даже вне S) ----------
for n in "${ALL_NODES[@]}"; do
  ip="$(map_ip "$n")"; [ -n "$ip" ] || continue
  ssh "${SSHOPTS[@]}" "root@$ip" 'mkdir -p /etc/db/apps.d /etc/db/secrets /opt/db'
  scp "${SCPOPTS[@]}" "$REG" "root@$ip:/etc/db/apps.d/"
done

# ---------- генераторы файлов (пишутся локально, раздаются scp) ----------
gen_pg_compose() { # $1 = alias узла (куда публикуем)
  local b
  if [ "$CLASS" = local ]; then b=10.66.0.99; else b="$(map_ip "$1")"; fi
  cat <<EOF
services:
  db:
    image: postgres:17-alpine
    container_name: pg-${APP}
    restart: unless-stopped
    mem_limit: 512m
    command: ["postgres","-c","shared_buffers=32MB","-c","max_connections=200","-c","wal_level=replica","-c","hot_standby=on","-c","archive_mode=always","-c","archive_command=cp %p /var/lib/pgwal/%f"]
    env_file:
      - /etc/db/secrets/${APP}.env
    ports:
      - "${b}:${PORT}:5432"
    volumes:
      - /var/lib/dbdata/pg-${APP}:/var/lib/postgresql/data
      - /var/lib/pgwal/${APP}:/var/lib/pgwal
EOF
}

gen_init_app() { # роли/база + pg_hba для mesh; читает ЛОКАЛЬНЫЕ секреты на первичном
  cat > "$GEN/init-app.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. /etc/db/secrets/@APP@.env
q() { docker exec -u postgres pg-@APP@ psql -U postgres -tAc "$1"; }
# Не `cmd && break` под set -e — так непонятно, что именно не так (здоровый PG считался «не поднявшимся за 180 с»). Явный флаг +
# Диагностика при провале.
ok=""
for _ in $(seq 1 180); do
  if q "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [ -z "$ok" ]; then
  echo "PG не поднялся за 180 с" >&2
  docker ps -a --filter "name=pg-@APP@" --format '  {{.Names}} {{.State}} {{.Status}}' >&2 || true
  echo "  --- последние строки лога ---" >&2
  docker logs --tail 20 "pg-@APP@" >&2 || true
  exit 1
fi
q "SELECT 1 FROM pg_roles WHERE rolname='replicator'" | grep -q '^1$' || \
  q "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}'"
q "SELECT 1 FROM pg_roles WHERE rolname='@APP@'" | grep -q '^1$' || \
  q "CREATE ROLE @APP@ WITH LOGIN PASSWORD '${APP_PASSWORD}'"
q "SELECT 1 FROM pg_database WHERE datname='@APP@'" | grep -q '^1$' || \
  q "CREATE DATABASE @APP@ OWNER @APP@"
# JIT гасим: сложные запросы панелей с JIT на слабых нодах деградируют в 10+ секунд
# (план с битой статистикой + JIT = таймауты 57014 и пустые списки UI)
q "ALTER DATABASE @APP@ SET jit = off"
# Скрипт бежит на хосте: hba-файл лежит в хост-каталоге тома (там смонтирован PGDATA)
HBA=/var/lib/dbdata/pg-@APP@/pg_hba.conf
grep -q '10.66.0.0/24' "$HBA" || cat >> "$HBA" <<'HBA'
host    all             all             10.66.0.0/24            scram-sha-256
host    replication     replicator      10.66.0.0/24            scram-sha-256
HBA
docker exec -u postgres pg-@APP@ psql -U postgres -tc "SELECT pg_reload_conf()" >/dev/null
echo "init-app OK: база, роли, pg_hba для mesh"
EOF
  sed -i "s/@APP@/${APP}/g" "$GEN/init-app.sh"
}

gen_bb() { # pg_basebackup -R на стендбай (пароль берёт из ЛОКАЛЬНОГО файла секретов)
  cat > "$GEN/bb.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077
. /etc/db/secrets/@APP@.env
DIR=/var/lib/dbdata/pg-@APP@
mkdir -p "$DIR" /var/lib/pgwal/@APP@
if [ -f "$DIR/PG_VERSION" ]; then
  echo "данные уже есть — basebackup пропущен"
else
  # сначала владелец (внутри образа uid postgres), иначе pg_basebackup от root не стартует
  docker run --rm -v "$DIR":/data -v /var/lib/pgwal/@APP@:/pwal postgres:17-alpine \
    chown -R postgres:postgres /data /pwal
  docker run --rm -u postgres -e PGPASSWORD="$REPL_PASSWORD" -v "$DIR":/data postgres:17-alpine \
    pg_basebackup -h @PRIMARY_IP@ -p @PORT@ -U replicator -D /data -R -X stream
  # свой primary_conninfo (с паролем) поверх строки от -R
  sed -i '/^primary_conninfo =/d' "$DIR/postgresql.auto.conf" 2>/dev/null || true
  echo "primary_conninfo = 'host=@PRIMARY_IP@ port=@PORT@ user=replicator password=${REPL_PASSWORD}'" \
    >> "$DIR/postgresql.auto.conf"
  echo "basebackup готов, primary_conninfo записан"
fi
EOF
  sed -i "s/@APP@/${APP}/g; s/@PRIMARY_IP@/${PRIMARY_IP}/g; s/@PORT@/${PORT}/g" "$GEN/bb.sh"
}

gen_mongo_compose() { # $1 = alias узла
  local b rs="" mem="640m"
  if [ "$CLASS" = local ]; then b=10.66.0.99; else b="$(map_ip "$1")"; fi
  [ "$CLASS" = cluster ] && rs=",\"--replSet\",\"rs_${APP}\""
  # Лимит 640m и арбитру тоже (). КЭШ НЕ УЖИМАТЬ: mongo не принимает
  # wiredTigerCacheSizeGB < 0.25 (BadValue при старте), поэтому
  # даже арбитр без данных держит ~380 МБ в установившемся режиме (кэш 256 МБ + overhead).
  # А `docker exec mongosh` живёт ВНУТРИ cgroup контейнера и даёт пик ~200 МБ:
  # при 400m у арбитра 383+200 > 400 → cgroup-OOM убивал mongosh и mongod,
  # db-guard и мониторинг флапали каждые пару минут (dmesg: task=mongosh).
  # Правило: лимит = установившееся потребление + ~250 МБ на проверку.
  if [ -n "$ARB" ] && [ "$1" = "$ARB" ]; then mem="640m"; fi
  cat <<EOF
services:
  db:
    image: mongo:7
    container_name: mongod-${APP}
    restart: unless-stopped
    mem_limit: ${mem}
    command: ["mongod","--bind_ip_all","--wiredTigerCacheSizeGB","0.256"${rs}]
    ports:
      - "${b}:${PORT}:27017"
    volumes:
      - /var/lib/dbdata/mongo-${APP}:/data/db
EOF
}

gen_proxy() { # блоки haproxy + compose прокси (cluster-класс)
  cat > "$GEN/proxy-compose.yml" <<'EOF'
services:
  proxy:
    image: haproxy:3.0-alpine
    container_name: db-proxy
    restart: unless-stopped
    network_mode: host
    # 128m (): haproxy держал ~42 МБ, а 64m не вмещало пик
    # соединений — cgroup-OOM убивал haproxy (dmesg: task=haproxy), рестарты 2–4.
    mem_limit: 128m
    volumes:
      - /opt/db/proxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
EOF
  cat > "$GEN/base.cfg" <<'EOF'
global
  log stdout format raw local0
defaults
  mode tcp
  log global
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF
  if [ "$ENGINE" = pg ]; then
    cat > "$GEN/block.cfg" <<EOF
# BEGIN ${APP}
listen pg-${APP}
  bind 10.66.0.99:${PORT}
  mode tcp
  server primary ${PRIMARY_IP}:${PORT} check
# END ${APP}
EOF
  else
    { echo "# BEGIN ${APP}"
      echo "listen mongo-${APP}"
      echo "  bind 10.66.0.99:${PORT}"
      echo "  mode tcp"
      for n in "${NODES[@]}"; do echo "  server m-${n} $(map_ip "$n"):${PORT} check"; done
      echo "# END ${APP}"; } > "$GEN/block.cfg"
  fi
}

deploy_proxy() { # $1 = alias узла. Блок приложения ставится на ВСЕ ноды (не только S(X)):
  # адрес VIP:порт обязан работать одинаково везде (docs/architecture.md) — иначе клиент вне S(X)
  # получает ECONNREFUSED (вскрыто дрилом Mongo).
  local nip; nip="$(map_ip "$1")"
  ssh "${SSHOPTS[@]}" "root@$nip" 'mkdir -p /opt/db/proxy'
  if ! run_on "$1" 'test -f /opt/db/proxy/haproxy.cfg'; then
    scp "${SCPOPTS[@]}" "$GEN/base.cfg" "root@${nip}:/opt/db/proxy/haproxy.cfg"
  fi
  # правим БЕЗ замены inode: sed -i подкладывает новый файл, а ro-монтирование контейнера
  # держит старую копию — правим через tmp + cat > (нижний аппенд и так не меняет inode)
  run_on "$1" "sed '/# BEGIN ${APP}/,/# END ${APP}/d' /opt/db/proxy/haproxy.cfg > /opt/db/proxy/haproxy.tmp && cat /opt/db/proxy/haproxy.tmp > /opt/db/proxy/haproxy.cfg && rm -f /opt/db/proxy/haproxy.tmp"
  scp "${SCPOPTS[@]}" "$GEN/block.cfg" "root@${nip}:/opt/db/proxy/block.cfg"
  # конфиг должен быть читаем ИЗ контейнера: haproxy в образе идёт не от root,
  # а файлы от нас уходят с umask 077 (0600) — чиним права после дозаписи блока
  run_on "$1" "cat /opt/db/proxy/block.cfg >> /opt/db/proxy/haproxy.cfg && chmod 644 /opt/db/proxy/haproxy.cfg && rm -f /opt/db/proxy/block.cfg"
  scp "${SCPOPTS[@]}" "$GEN/proxy-compose.yml" "root@${nip}:/opt/db/proxy/docker-compose.yml"
  # сначала поднять/пересоздать (монтирование подхватит файл), потом проверить конфиг
  # ВНУТРИ контейнера и только при успехе — USR1 (падение проверки = видимая ошибка db-add)
  # USR1 = для Docker явная остановка (autorestart не поднимает!) — прокси умирал на месте;
  # docker restart детерминированно поднимает с новым конфигом (дрилл)
  run_on "$1" "cd /opt/db/proxy && docker compose up -d && docker exec db-proxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg && docker restart db-proxy"
}

set_labels() { # svc.<app> на узлы S; db-primary-<app> = алиас первичного (запуск на менеджере)
  local n
  for n in "${NODES[@]}"; do
    docker node update --label-add "svc.${APP}=true" "$(map_swarm "$n")"
  done
  docker node update --label-add "db-primary-${APP}=${PRIMARY}" "$(map_swarm "$PRIMARY")"
}

show_checks() {
  echo "=== метки нод ==="
  local n
  for n in "${ALL_NODES[@]}"; do
    printf '%s: ' "$n"
    docker node inspect "$(map_swarm "$n")" --format '{{json .Spec.Labels}}' 2>/dev/null || printf '(нет)'
    printf '\n'
  done
}

# ======================================================================
if [ "$ENGINE" = pg ]; then
  # ---------------- PostgreSQL ----------------
  for n in "${NODES[@]}"; do
    run_on "$n" "mkdir -p /opt/db/pg-${APP} /var/lib/dbdata/pg-${APP} /var/lib/pgwal/${APP}"
  done
  # каталог WAL-архива создаёт root, а пишет в него postgres из контейнера → archive_command
  # падал с Permission denied на ВСЕХ нодах с самого начала (вскрыто дрилом).
  # Чиним владельца через сам образ — uid образа, без хардкода чисел.
  for n in "${NODES[@]}"; do
    run_on "$n" "docker run --rm -v /var/lib/pgwal/${APP}:/pwal postgres:17-alpine chown -R postgres:postgres /pwal"
  done

  # секреты: генерируются на первичном, раздаются узлам S
  run_on "$PRIMARY" "[ -f /etc/db/secrets/${APP}.env ] || { echo POSTGRES_PASSWORD=\$(openssl rand -hex 16); echo APP_PASSWORD=\$(openssl rand -hex 16); echo REPL_PASSWORD=\$(openssl rand -hex 16); } > /etc/db/secrets/${APP}.env; chmod 600 /etc/db/secrets/${APP}.env"
  if [ "$PRIMARY" = "$ME_ALIAS" ]; then
    SEC="/etc/db/secrets/${APP}.env"
  else
    scp "${SCPOPTS[@]}" "root@${PRIMARY_IP}:/etc/db/secrets/${APP}.env" "$GEN/env"
    SEC="$GEN/env"
  fi
  for n in "${NODES[@]}"; do
    [ "$n" = "$PRIMARY" ] && continue
    scp "${SCPOPTS[@]}" "$SEC" "root@$(map_ip "$n"):/etc/db/secrets/${APP}.env"
  done

  # первичный: compose + роли/база/pg_hba
  gen_pg_compose "$PRIMARY" > "$GEN/docker-compose.yml"
  gen_init_app
  scp "${SCPOPTS[@]}" "$GEN/docker-compose.yml" "root@${PRIMARY_IP}:/opt/db/pg-${APP}/docker-compose.yml"
  scp "${SCPOPTS[@]}" "$GEN/init-app.sh" "root@${PRIMARY_IP}:/opt/db/init-${APP}.sh"
  run_on "$PRIMARY" "cd /opt/db/pg-${APP} && docker compose up -d"
  run_on "$PRIMARY" "chmod 700 /opt/db/init-${APP}.sh && /opt/db/init-${APP}.sh"

  # стендбай(ы): basebackup -> стендбай
  if [ "$CLASS" = cluster ]; then
    gen_bb
    for n in "${NODES[@]}"; do
      [ "$n" = "$PRIMARY" ] && continue
      gen_pg_compose "$n" > "$GEN/docker-compose.yml"
      scp "${SCPOPTS[@]}" "$GEN/docker-compose.yml" "root@$(map_ip "$n"):/opt/db/pg-${APP}/docker-compose.yml"
      scp "${SCPOPTS[@]}" "$GEN/bb.sh" "root@$(map_ip "$n"):/opt/db/pg-${APP}/bb.sh"
      run_on "$n" "chmod 700 /opt/db/pg-${APP}/bb.sh && bash /opt/db/pg-${APP}/bb.sh && cd /opt/db/pg-${APP} && docker compose up -d"
    done
    sleep 3
  fi

  set_labels

  if [ "$CLASS" = cluster ]; then
    gen_proxy
    for n in "${ALL_NODES[@]}"; do deploy_proxy "$n"; done
    echo "=== первичный $PRIMARY: pg_stat_replication ==="
    run_on "$PRIMARY" "docker exec -u postgres pg-${APP} psql -U postgres -c 'SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication'"
    for n in "${NODES[@]}"; do
      [ "$n" = "$PRIMARY" ] && continue
      echo "=== стендбай $n: pg_is_in_recovery ==="
      run_on "$n" "docker exec -u postgres pg-${APP} psql -U postgres -tc 'SELECT pg_is_in_recovery()'"
    done
    echo "=== прокси на VIP:${PORT} ==="
    for n in "${NODES[@]}"; do
      printf '%s: ' "$n"
      run_on "$n" "ss -ltn | grep -o '10.66.0.99:${PORT}' || echo НЕТ"
    done
  else
    echo "=== local-класс: инстанс на VIP:${PORT} ==="
    run_on "$PRIMARY" "ss -ltn | grep -o '10.66.0.99:${PORT}' || echo НЕТ"
  fi

# ======================================================================
elif [ "$ENGINE" = mongo ]; then
  # ---------------- MongoDB ----------------
  START_NODES=("${NODES[@]}")
  [ -n "$ARB" ] && START_NODES+=("$ARB")
  for n in "${START_NODES[@]}"; do
    run_on "$n" "mkdir -p /opt/db/mongo-${APP} /var/lib/dbdata/mongo-${APP}"
  done
  for n in "${START_NODES[@]}"; do
    gen_mongo_compose "$n" > "$GEN/docker-compose.yml"
    scp "${SCPOPTS[@]}" "$GEN/docker-compose.yml" "root@$(map_ip "$n"):/opt/db/mongo-${APP}/docker-compose.yml"
    run_on "$n" "cd /opt/db/mongo-${APP} && docker compose up -d"
  done

  # Дождаться, пока ВСЕ mongod начнут слушать (rs.initiate
  # сразу после up -d падал с «Connection refused» на арбитре, и весь шаг
  # komodo умирал).
  for n in "${START_NODES[@]}"; do
    okk=""
    for i in $(seq 1 60); do
      if run_on "$n" "ss -ltn | grep -q ':${PORT} '" >/dev/null 2>&1; then okk=1; break; fi
      sleep 5
    done
    if [ -n "$okk" ]; then
      echo "  $n: mongod слушает :$PORT"
    else
      echo "  $n: ОШИБКА — mongod не начал слушать :$PORT за 5 минут" >&2
      exit 1
    fi
  done

  if [ "$CLASS" = cluster ]; then
    # rs.initiate: priority 1 — только у стартового первичного, остальные 0, арбитр — arbiterOnly
    CFG="{_id:\"rs_${APP}\",members:["
    i=0
    for n in "${NODES[@]}"; do
      p=0; [ "$n" = "$PRIMARY" ] && p=1
      CFG+="{_id:${i},host:\"$(map_ip "$n"):${PORT}\",priority:${p}},"
      i=$((i+1))
    done
    if [ -n "$ARB" ]; then
      CFG+="{_id:${i},host:\"$(map_ip "$ARB"):${PORT}\",arbiterOnly:true},"
      i=$((i+1))
    fi
    CFG="${CFG%,}]}"
    cat > "$GEN/rs-init.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
st=$(docker exec mongod-@APP@ mongosh --quiet --eval 'try { print(rs.status().myState) } catch (e) { print(-1) }')
if [ "$st" = "-1" ]; then
  # rs.initiate требует, чтобы ВСЕ члены ответили; если кто-то ещё поднимается —
  # повторяем ().
  ok=""
  for i in $(seq 1 12); do
    if docker exec mongod-@APP@ mongosh --quiet --eval 'rs.initiate(@CFG@)' 2>/dev/null; then
      ok=1; break
    fi
    echo "  rs.initiate попытка $i не удалась, жду 10 с"
    sleep 10
  done
  if [ -n "$ok" ]; then echo "rs.initiate отправлен"; else echo "rs.initiate НЕ УДАЛСЯ" >&2; exit 1; fi
else
  echo "rs уже инициализирован (myState=$st)"
fi
EOF
    cat > "$GEN/rs-wait.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
st=-1
for _ in $(seq 1 45); do
  st=$(docker exec mongod-@APP@ mongosh --quiet --eval 'try { print(rs.status().myState) } catch (e) { print(-1) }')
  [ "$st" = "1" ] && { echo "первичный myState=1"; exit 0; }
  sleep 2
done
echo "ОШИБКА: rs не вышел на первичного за 90 с (myState=$st)" >&2
exit 1
EOF
    sed -i "s/@APP@/${APP}/g; s|@CFG@|${CFG}|g" "$GEN/rs-init.sh"
    sed -i "s/@APP@/${APP}/g" "$GEN/rs-wait.sh"
    scp "${SCPOPTS[@]}" "$GEN/rs-init.sh" "$GEN/rs-wait.sh" "root@${PRIMARY_IP}:/opt/db/"
    run_on "$PRIMARY" "chmod 700 /opt/db/rs-init.sh /opt/db/rs-wait.sh && /opt/db/rs-init.sh && /opt/db/rs-wait.sh"
  fi

  set_labels

  if [ "$CLASS" = cluster ]; then
    gen_proxy
    for n in "${ALL_NODES[@]}"; do deploy_proxy "$n"; done
    echo "=== реплика-сет $APP ==="
    run_on "$PRIMARY" "docker exec mongod-${APP} mongosh --quiet --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'"
    echo "=== прокси на VIP:${PORT} ==="
    for n in "${NODES[@]}"; do
      printf '%s: ' "$n"
      run_on "$n" "ss -ltn | grep -o '10.66.0.99:${PORT}' || echo НЕТ"
    done
  else
    echo "=== local-класс: инстанс на VIP:${PORT} ==="
    run_on "$PRIMARY" "ss -ltn | grep -o '10.66.0.99:${PORT}' || echo НЕТ"
  fi
fi

show_checks
echo "db-add ${APP}: ГОТОВО"
