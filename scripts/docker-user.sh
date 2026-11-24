#!/usr/bin/env bash
# docker-user.sh — фильтрация трафика в контейнеры (docs/security.md).
# DOCKER-USER видит пакеты ПОСЛЕ DNAT, поэтому порт здесь — контейнерный.
# Дисциплина публикаций: сервисы — только на mesh-адрес (10.66.0.X:порт), их защищает
# ufw (INPUT); в мир — только публичные порты §3, разрешённые ниже.
set -euo pipefail

MESH="10.66.0.0/24"
PUBLIC_TCP="80 443 8443 2053"   # контейнерные порты из таблицы §3; дополнять при новых
PUBLIC_UDP="53 21820 51820"     # Pangolin: DNS + WireGuard relay + WireGuard

iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DOCKER-USER -s 172.16.0.0/12 -j ACCEPT   # bridge-сети Docker
iptables -A DOCKER-USER -s 10.0.0.0/8 -j ACCEPT      # mesh + overlay-сети Swarm
iptables -A DOCKER-USER -s 192.168.0.0/16 -j ACCEPT
iptables -A DOCKER-USER -i lo -j ACCEPT
for p in $PUBLIC_TCP; do
  iptables -A DOCKER-USER -p tcp --dport "$p" -j ACCEPT
done
for p in $PUBLIC_UDP; do
  iptables -A DOCKER-USER -p udp --dport "$p" -j ACCEPT
done
iptables -A DOCKER-USER -j DROP

# IPv6 — зеркало; если ip6tables недоступен, блок молча пропускается
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -N DOCKER-USER 2>/dev/null || true
  ip6tables -F DOCKER-USER 2>/dev/null || true
  ip6tables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A DOCKER-USER -s fc00::/7 -j ACCEPT 2>/dev/null || true
  ip6tables -A DOCKER-USER -s fe80::/10 -j ACCEPT 2>/dev/null || true
  ip6tables -A DOCKER-USER -i lo -j ACCEPT 2>/dev/null || true
  for p in $PUBLIC_TCP; do
    ip6tables -A DOCKER-USER -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for p in $PUBLIC_UDP; do
    ip6tables -A DOCKER-USER -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  ip6tables -A DOCKER-USER -j DROP 2>/dev/null || true
fi
