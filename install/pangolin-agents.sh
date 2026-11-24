#!/usr/bin/env bash
# Newt на каждой VPS для сайтов cluster-<alias>, без секретов в stdout.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

for a in $(node_names); do
  env_file="/etc/db/secrets/newt-$a.env"
  [ -f "$env_file" ] || fail "$a: нет $env_file — сначала pangolin-sites.py"
  nssh "$a" 'install -d -m 700 /etc/newt'
  ncp "$a" "$env_file" /etc/newt/newt.env
  ncp "$a" "$ROOT/install/home-newt.sh" /usr/local/bin/321r-newt-install.sh
  ncp "$a" "$ROOT/scripts/newt-wait.sh" /usr/local/bin/321r-newt-wait.sh
  nssh "$a" 'chmod 600 /etc/newt/newt.env
    bash /usr/local/bin/321r-newt-install.sh
    chmod 755 /usr/local/bin/321r-newt-wait.sh
    mkdir -p /etc/systemd/system/321r-newt.service.d
    printf "[Unit]\nAfter=docker.service\nRequires=docker.service\n[Service]\nExecStartPre=/usr/local/bin/321r-newt-wait.sh\n" > /etc/systemd/system/321r-newt.service.d/ready.conf
    systemctl daemon-reload
    systemctl is-active --quiet 321r-newt.service'
  ok "$a: агент Newt запущен (секрет — только в /etc/newt/newt.env)"
done
