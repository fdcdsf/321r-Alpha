#!/usr/bin/env bash
# Официальный agent2 (Debian/Ubuntu): активные проверки к HA b;c.
# Путь репозитория Zabbix = ${ID}${VERSION_ID} (debian13, ubuntu24.04) — проверено.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
a1="$1"; a2="$2"
active="$(node_mesh "$a1"):10051;$(node_mesh "$a2"):10051"
for a in $(node_names); do
  step "$a: Zabbix agent2, метрики хоста + динамические статусы сервисов"
  nssh "$a" 'set -e
    if ! command -v zabbix_agent2 >/dev/null 2>&1; then
      . /etc/os-release
      # Не привязываемся к Ubuntu: у Zabbix есть ветки debian/ и ubuntu/,
      # имя пакета репозитория = ${ID}${VERSION_ID} (debian13, ubuntu24.04).
      url="https://repo.zabbix.com/zabbix/7.0/${ID}/pool/main/z/zabbix-release/zabbix-release_latest_7.0+${ID}${VERSION_ID}_all.deb"
      curl -fsSL --max-time 30 "$url" -o /root/zabbix-release.deb \
        || { echo "$ID $VERSION_ID: нет пакета репозитория Zabbix ($url)" >&2; exit 1; }
      dpkg -i /root/zabbix-release.deb >/dev/null
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq zabbix-agent2 jq >/dev/null
    fi
    command -v jq >/dev/null 2>&1 || {
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y -qq jq >/dev/null
    }
    install -d -m 755 /var/lib/zabbix-321r /etc/zabbix/zabbix_agent2.d'
  ncp "$a" "$ROOT/scripts/zabbix-321r-snapshot.py" /usr/local/bin/zabbix-321r-snapshot.py
  ncp "$a" "$ROOT/scripts/zabbix-321r-metric.sh" /usr/local/bin/zabbix-321r-metric.sh
  nssh "$a" "set -e
    chmod 755 /usr/local/bin/zabbix-321r-snapshot.py /usr/local/bin/zabbix-321r-metric.sh
    printf '%s\\n' 'Hostname=$a' 'ServerActive=$active' 'Server=127.0.0.1' \
      'ListenIP=127.0.0.1' 'HostMetadata=321r' \
      'UserParameter=cluster.services.discovery,/usr/local/bin/zabbix-321r-metric.sh discover' \
      'UserParameter=cluster.service.status[*],/usr/local/bin/zabbix-321r-metric.sh status \$1' \
      'UserParameter=cluster.ha.active,/usr/local/bin/zabbix-321r-metric.sh ha-active' \
      'UserParameter=cluster.ha.standby,/usr/local/bin/zabbix-321r-metric.sh ha-standby' \
      > /etc/zabbix/zabbix_agent2.d/321r.conf
    cat > /etc/cron.d/321r-zabbix-snapshot <<'CRON'
* * * * * root /usr/local/bin/zabbix-321r-snapshot.py >/dev/null 2>&1
CRON
    chmod 644 /etc/cron.d/321r-zabbix-snapshot
    /usr/local/bin/zabbix-321r-snapshot.py
    /usr/local/bin/zabbix-321r-metric.sh discover >/dev/null
    systemctl enable --now zabbix-agent2 >/dev/null
    systemctl restart zabbix-agent2
    systemctl is-active --quiet zabbix-agent2"
  ok "$a: активный Zabbix agent2 (без внешнего :10050)"
done
