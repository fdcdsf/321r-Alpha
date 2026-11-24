#!/bin/sh
# panel-cert-reload.sh — деплой-хук certbot (renewal-hooks/deploy/), ставится на каждую ноду.
# Срабатывает после продления любого серта certbot на ноде:
#  1) дописываем комментарий в panel_cert.yml — file provider traefik (watch: true)
#     перечитывает конфиг и подхватывает новый PEM панели из /etc/letsencrypt/live;
#  2) reload nginx — маски VPN (vpn-<нода>/tg) тоже живут на certbot-сертах,
#     без reload они отдавали бы старый PEM до перезапуска.
# Секретов не содержит. Устанавливается установщиком (install/pangolin-up.sh).
f=/opt/pangolin/config/dynamic/panel_cert.yml
[ -f "$f" ] && printf '# renewed %s\n' "$(date -u +%FT%TZ)" >> "$f"
systemctl reload nginx >/dev/null 2>&1 || true
# Xray внутри remnanode читает PEM при запуске, а не при каждом TLS-хендшейке.
# После продления масочного сертификата ему нужен короткий перезапуск.
case "${RENEWED_LINEAGE:-}" in
  /etc/letsencrypt/live/vpn-*)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
      docker restart remnanode >/dev/null 2>&1 || true
    fi ;;
esac
exit 0
