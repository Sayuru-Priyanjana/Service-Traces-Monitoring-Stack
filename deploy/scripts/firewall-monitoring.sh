#!/usr/bin/env bash
# Restrict the monitoring stack's Docker-published ports (OTLP 4317/4318 and Grafana).
#
# Docker publishes ports through its own iptables chains, so ufw rules do NOT apply to them.
# Docker's documented hook for this is the DOCKER-USER chain: this script puts the rules in a
# chain of its own (MONITORING-FW) and jumps to it from DOCKER-USER. Re-running replaces them.
# Prometheus, Tempo and Alertmanager are bound to 127.0.0.1 and need no rules.
#
# Usage: sudo ./firewall-monitoring.sh [path/to/monitoring/.env]          apply now
#        sudo ./firewall-monitoring.sh --install [path/to/monitoring/.env] apply now + at every boot
set -euo pipefail

INSTALL=0
if [ "${1:-}" = "--install" ]; then INSTALL=1; shift; fi
ENV_FILE="$(realpath "${1:-$(dirname "$0")/../monitoring/.env}")"
[ -f "$ENV_FILE" ] || { echo "env file $ENV_FILE not found" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${OTLP_ALLOWED_SOURCES:?set OTLP_ALLOWED_SOURCES in $ENV_FILE}"
: "${GRAFANA_ALLOWED_SOURCES:?set GRAFANA_ALLOWED_SOURCES in $ENV_FILE}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
CHAIN=MONITORING-FW

iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
iptables -A "$CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
# Traffic coming from containers / the host itself (e.g. apps on this server).
iptables -A "$CHAIN" -i docker0 -j RETURN
iptables -A "$CHAIN" -i br-+ -j RETURN
iptables -A "$CHAIN" -i lo -j RETURN

# --ctorigdstport = the port the client connected to (host side, before Docker's DNAT).
for src in $OTLP_ALLOWED_SOURCES; do
  iptables -A "$CHAIN" -p tcp -s "$src" -m conntrack --ctorigdstport 4317:4318 -j RETURN
done
iptables -A "$CHAIN" -p tcp -m conntrack --ctorigdstport 4317:4318 -j DROP

for src in $GRAFANA_ALLOWED_SOURCES; do
  iptables -A "$CHAIN" -p tcp -s "$src" -m conntrack --ctorigdstport "$GRAFANA_PORT" -j RETURN
done
iptables -A "$CHAIN" -p tcp -m conntrack --ctorigdstport "$GRAFANA_PORT" -j DROP

iptables -A "$CHAIN" -j RETURN

iptables -N DOCKER-USER 2>/dev/null || true
iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER 1 -j "$CHAIN"
echo ">>> $CHAIN rules:"
iptables -S "$CHAIN"

if [ "$INSTALL" = 1 ]; then
  SCRIPT="$(realpath "$0")"
  cat > /etc/systemd/system/monitoring-firewall.service <<EOF
[Unit]
Description=Restrict Docker-published monitoring ports (DOCKER-USER)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT} ${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable monitoring-firewall.service
  echo ">>> installed monitoring-firewall.service (re-applies the rules after every boot)"
fi
