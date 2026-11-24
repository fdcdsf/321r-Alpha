#!/usr/bin/env bash
# 321r · УСТАНОВКА ОДНОЙ КОМАНДОЙ. Запуск от root на ПЕРВОМ сервере:
#
#   curl -fsSL https://raw.githubusercontent.com/fdcdsf/321r-Alpha/master/install/bootstrap.sh | bash
#
# Мастер спросит всё остальное: адреса и пароли других серверов, Telegram, домен.
# Установка идёт на ВСЕ сервера одновременно. На выходе — рабочий кластер.
set -euo pipefail

REPO_TARBALL="https://github.com/fdcdsf/321r-Alpha/archive/refs/heads/master.tar.gz"
TARGET="/opt/321r"

[ "$(id -u)" = 0 ] || { echo "Запускайте от root (sudo -i)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
echo "321r · подготовка установщика..."
# apt у свежей Debian/Ubuntu бывает занят (unattended-upgrades)
# Либо оставляет НЕЗАВЕРШЁННУЮ настройку после прерванной установки. Тогда
# «apt-get install» молча падает с «Could not get lock» (код 100) и установка
# Обрывается без единого объяснения. Ждём, чиним и РЕТРАИМ, ошибки не прячем.
for i in $(seq 1 60); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 10; done
dpkg --configure -a 2>&1 | tail -5 || true
apt_retry() { local n; for n in $(seq 1 12); do "$@" && return 0; echo "  apt занят/недоступен — жду 15 с (попытка $n)"; sleep 15; done; return 1; }
apt_retry apt-get update -qq
# sshpass — разовый вход по паролям на другие серверы (чтобы заложить ключ)
apt_retry apt-get install -y -qq curl tar sshpass

echo "321r · скачиваю установщик..."
# Секреты и инвентарь переживают повторную установку: иначе rm -rf /opt/321r
# Сносит install/secrets/ — ключ кластера, server.secret, лицензию. После этого
# Межнодовый ssh отвергается: ключ пересоздаётся, а authorized_keys не обновляется.
KEEP=/tmp/321r-keep
rm -rf "$KEEP"; mkdir -p "$KEEP"
[ -d "$TARGET/install/secrets" ] && cp -a "$TARGET/install/secrets" "$KEEP/secrets"
[ -f "$TARGET/install/inventory.conf" ] && cp -a "$TARGET/install/inventory.conf" "$KEEP/inventory.conf"
rm -rf "$TARGET"
STAGE=/tmp/321r-src
rm -rf "$STAGE"; mkdir -p "$STAGE"
curl -fsSL "$REPO_TARBALL" | tar xz -C "$STAGE" --strip-components=1
mv "$STAGE" "$TARGET"
[ -d "$KEEP/secrets" ] && cp -a "$KEEP/secrets" "$TARGET/install/secrets"
[ -f "$KEEP/inventory.conf" ] && cp -a "$KEEP/inventory.conf" "$TARGET/install/inventory.conf"
rm -rf "$KEEP"
cd "$TARGET"
chmod +x install/*.sh   # тарбол GitHub может прийти без битов выполнения

# ВАЖНО: при «curl | bash» stdin — это пайп, а не терминал (мастер-вопросы
# Читать не откуда). Переключаем ввод мастера на настоящий терминал пользователя.
if [ -e /dev/tty ]; then
  exec bash install/install.sh < /dev/tty
else
  exec bash install/install.sh
fi
