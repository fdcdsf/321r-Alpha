#!/usr/bin/env bash
# Запуск ВНУТРИ выделенного Debian/Ubuntu LXC на домашнем Proxmox (root).
# LXC уже изолирует Newt; не нужен второй Docker внутри контейнера.
# ВНИМАНИЕ: сначала создайте сайт типа Newt в Pangolin и возьмите ID/secret.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo 'Запустите от root внутри LXC' >&2; exit 1; }
command -v systemctl >/dev/null || { echo 'Нужен LXC с systemd' >&2; exit 1; }
if [ -f /etc/newt/newt.env ]; then
  [ "$(stat -c %a /etc/newt/newt.env)" = 600 ] || chmod 600 /etc/newt/newt.env
  echo 'Newt уже настроен: существующие учётные данные не трогаю.'
else
  [ -r /dev/tty ] || { echo 'Для первого запуска нужен терминал: введите ID/secret сайта в LXC, не через curl-пайп' >&2; exit 1; }
  read -rp 'Адрес панели (например https://pangolin.example.com): ' endpoint </dev/tty
  read -rp 'ID сайта Newt: ' newt_id </dev/tty
  read -rsp 'Секрет сайта Newt (ввод скрыт): ' newt_secret </dev/tty
  echo >/dev/tty
  [[ "$endpoint" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || { echo 'Нужен HTTPS-адрес панели без пути' >&2; exit 1; }
  [[ "$newt_id" =~ ^[a-zA-Z0-9_-]+$ && "$newt_secret" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo 'Неверный формат ID или секрета сайта' >&2; exit 1;
  }
  install -d -m 700 /etc/newt
  umask 077
  printf 'PANGOLIN_ENDPOINT=%s\nNEWT_ID=%s\nNEWT_SECRET=%s\n' \
    "$endpoint" "$newt_id" "$newt_secret" > /etc/newt/newt.env
  chmod 600 /etc/newt/newt.env
  unset newt_secret
fi

if ! command -v newt >/dev/null; then
  # Официальный установщик Pangolin. Скачиваем в файл: он не должен съедать stdin мастера.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL https://static.pangolin.net/get-newt.sh -o "$tmp"
  bash "$tmp" >/dev/null
fi
bin="$(command -v newt || true)"
[ -n "$bin" ] || { echo 'Установщик Newt не создал бинарник' >&2; exit 1; }

cat > /etc/systemd/system/321r-newt.service <<EOF
[Unit]
Description=321r Newt — исходящий туннель из домашнего LXC к Pangolin
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/newt/newt.env
ExecStart=$bin
Restart=always
RestartSec=3
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now 321r-newt.service >/dev/null
systemctl is-active --quiet 321r-newt.service || {
  echo 'Newt не запустился: journalctl -u 321r-newt.service -n 30' >&2; exit 1;
}
echo 'Newt запущен. Проверьте статус сайта в Pangolin (должен быть Online).'
echo 'Туннель исходящий; входящие порты для Newt открывать не требуется.'
