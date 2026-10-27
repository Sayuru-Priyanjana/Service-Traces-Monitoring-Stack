#!/usr/bin/env bash
# Allow only the monitoring server to scrape the exporters (9100, 9256) on this host.
# The agent containers use the host network, so ufw rules apply to them.
#
# This script only ADDS rules for the exporter ports. It does not change ufw's default
# policy and does not enable ufw, so it cannot cut off your application or SSH traffic.
# Usage: sudo ./firewall-agent.sh [path/to/deploy/.env]
set -euo pipefail

ENV_FILE="${1:-$(dirname "$0")/../.env}"
[ -f "$ENV_FILE" ] || { echo "env file $ENV_FILE not found" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${MONITORING_SOURCES:?set MONITORING_SOURCES in $ENV_FILE}"
command -v ufw >/dev/null || { echo "ufw not installed: allow tcp/9100,9256 from $MONITORING_SOURCES in your firewall" >&2; exit 1; }

for src in $MONITORING_SOURCES; do
  ufw allow proto tcp from "$src" to any port 9100,9256 comment 'monitoring scrape'
done
ufw deny proto tcp to any port 9100,9256 comment 'monitoring exporters'

if ufw status | grep -q "Status: active"; then
  ufw status numbered | grep -E '9100|9256'
else
  echo "NOTE: ufw is inactive, so these rules are not enforced yet. Review 'ufw show added'"
  echo "      (make sure SSH and your app ports are allowed) before running 'ufw enable'."
fi
