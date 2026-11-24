#!/usr/bin/env bash
# 321r · шаг 5: слой баз данных (db-prep → реестр apps.d → db-add → db-guard).
# Идемпотентен: уже развёрнутые приложения пропускаются.
# Запускается с ноутбука: bash install/db-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 1) карта нод (alias -> mesh-ip -> имя в swarm). Генерируем ИЗ ИНВЕНТАРЯ и только если
#    её ещё нет: без карты не работают ни db-prep, ни db-guard, ни скрипты БД.
for a in $(node_names); do
  if nssh "$a" '[ -f /etc/db/nodes.map ]'; then
    ok "$a: nodes.map уже есть (не трогаем)"
    continue
  fi
  {
    for p in $(node_names); do
      echo "$p $(node_mesh "$p") $p"   # на свежей ноде hostname = имя из инвентаря
    done
  } | nssh "$a" 'cat > /etc/db/nodes.map && chmod 600 /etc/db/nodes.map'
  ok "$a: nodes.map собран из инвентаря"
done

# 2) db-prep на всех нодах ПАРАЛЛЕЛЬНО (VIP, ufw контейнеров, каталоги, пред-pull образов)
pids=(); bad=0
for a in $(node_names); do
  ( nssh "$a" '/usr/local/bin/db-prep.sh' ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "db-prep не прошёл на всех нодах"

# 3) реестр приложений → на все ноды (пароли db-add генерирует сам).
#    Существующий реестр НЕ перезаписываем: живой кластер мог настроить placement иначе!
for row in "${APPS[@]}"; do
  app="$(app_name "$row")"; engine="$(app_engine "$row")"; port="$(app_port "$row")"
  pl="$(app_placement "$row")"; arb="$(app_arbiter "$row")"
  primary="$(echo "$pl" | awk '{print $1}')"
  pl_csv="$(echo "$pl" | sed 's/ /, /g')"
  reg="# Реестр приложения (генерирует install/db-up.sh из inventory.conf). Без секретов.
name: $app
engine: $engine
class: cluster
placement: [$pl_csv]
primary: $primary
port: $port"
  [ -n "$arb" ] && reg="$reg
arbiter: $arb"
  skip=0
  for a in $(node_names); do
    if nssh "$a" "[ -f /etc/db/apps.d/$app.yaml ]"; then skip=1; continue; fi
    echo "$reg" | nssh "$a" "mkdir -p /etc/db/apps.d && cat > /etc/db/apps.d/$app.yaml"
  done
  if [ "$skip" = 1 ]; then
    ok "$app: реестр уже существует — не перезаписываю (placement могли менять)"
  else
    ok "$app: реестр разложен (engine=$engine, port=$port, placement=[$pl_csv])"
  fi
done

# 4) db-add для каждого приложения (пропускаем полностью развёрнутые)
CTRL="$CONTROL"
for row in "${APPS[@]}"; do
  app="$(app_name "$row")"; engine="$(app_engine "$row")"
  primary="$(app_placement "$row" | awk '{print $1}')"
  dir="pg-$app"; [ "$engine" = "mongo" ] && dir="mongo-$app"
  # Секрет приложения нужен НЕ только узлам placement: сервисы (панель, бот)
  # рендерят конфиг на ВСЕХ нодах, а их может быть сколько угодно (Pangolin падал с пустым паролем на ноде вне placement).
  # Раздаём БЕЗОГОВОРОЧНО — в том числе когда БД уже развёрнута.
  for a in $(node_names); do
    [ "$a" = "$primary" ] && continue
    # Не затирать существующий секрет пустотой: берём только если на источнике он есть.
    secret="$(nssh "$primary" "cat /etc/db/secrets/${app}.env 2>/dev/null" || true)"
    [ -n "$secret" ] || continue
    printf '%s\n' "$secret" \
      | nssh "$a" "umask 077; cat > /etc/db/secrets/${app}.env; chmod 600 /etc/db/secrets/${app}.env" || true
  done
  # «развёрнуто» = контейнеры запущены на ВСЕХ узлах placement. Каталоги данных
  # НЕ годятся как признак (db-add создаёт их заранее везде → недоделка
  # считалась готовой). Частично развёрнутое доделывается повторным db-add.
  deployed=1
  for a in $(app_placement "$row"); do
    if ! nssh "$a" "docker ps --format '{{.Names}}' | grep -qx $dir"; then deployed=0; break; fi
  done
  if [ "$deployed" = 1 ]; then
    ok "$app: уже развёрнут (секрет разложен на все ноды) — пропускаю"
    continue
  fi
  echo "  $app: развёртываю (первичный: $primary)..."
  nssh "$CTRL" "/usr/local/bin/db-add.sh $app" | tail -5 | sed 's/^/  /'
  ok "$app: развёрнут (секрет разложен на все ноды)"
done

# 5) db-guard на всех нодах (тик 10 с, кворум, фенсинг, аварийный режим)
for a in $(node_names); do
  nssh "$a" 'systemctl daemon-reload
    systemctl enable --now db-guard.timer >/dev/null 2>&1
    systemctl start db-guard.service >/dev/null 2>&1 || true'
  ok "$a: db-guard включён"
done

# 6) сверка: VIP отвечает по каждому приложению
for row in "${APPS[@]}"; do
  app="$(app_name "$row")"; port="$(app_port "$row")"; engine="$(app_engine "$row")"
  if nssh "$CTRL" "timeout 5 bash -c '</dev/tcp/$VIP/$port'" 2>/dev/null; then
    ok "$app: VIP $VIP:$port отвечает"
  else
    warn "$app: VIP $VIP:$port молчит — проверьте db-guard и db-proxy"
  fi
done
