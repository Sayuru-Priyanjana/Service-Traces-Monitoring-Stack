#!/usr/bin/env bash
# Deploy or update the monitoring agent on this server. Safe to re-run after config changes.
# Usage (from this folder): sudo ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./deploy.sh)"
command -v docker >/dev/null || die "docker not installed (see ../scripts/install-docker.sh)"
[ -f .env ] || die ".env missing: cp .env.example .env and edit it"
set -a; . ./.env; set +a
[ -S /run/dbus/system_bus_socket ] || die "/run/dbus/system_bus_socket missing (systemd collector needs D-Bus)"

echo ">>> validating configuration"
docker compose config -q
if [[ ",${COMPOSE_PROFILES:-}," == *",otel,"* ]]; then
  docker run --rm -v "$PWD/otel-agent:/c:ro" \
    -e HOST_NAME -e DEPLOYMENT_ENVIRONMENT -e GATEWAY_OTLP_ENDPOINT -e GATEWAY_TLS_INSECURE \
    -e AGENT_OTLP_GRPC_PORT -e AGENT_OTLP_HTTP_PORT \
    otel/opentelemetry-collector-contrib:0.162.0 validate --config=/c/config.yaml
fi

mkdir -p data/otel-queue
chown 10001:10001 data/otel-queue   # 10001 = user of the collector image

echo ">>> starting agent"
docker compose pull -q
docker compose up -d --remove-orphans
docker compose restart   # pick up bind-mounted config changes

ip="${EXPORTER_BIND_IP:-127.0.0.1}"; [ "$ip" = "0.0.0.0" ] && ip=127.0.0.1
with_otel=0; [[ ",${COMPOSE_PROFILES:-}," == *",otel,"* ]] && with_otel=1
for _ in $(seq 1 45); do
  if curl -fs "http://${ip}:9100/metrics" >/dev/null && curl -fs "http://${ip}:9256/metrics" >/dev/null \
     && { [ "$with_otel" = 0 ] || curl -fs http://127.0.0.1:13133/ >/dev/null; }; then
    docker compose ps
    echo ">>> exporters up on ${ip}:9100 and ${ip}:9256"
    [ "$with_otel" = 1 ] && echo ">>> otel-agent healthy: apps send OTLP to 127.0.0.1:${AGENT_OTLP_GRPC_PORT:-4317}"
    echo ">>> process groups found on this host (edit process-exporter/config.yml if one is missing):"
    curl -s "http://${ip}:9256/metrics" | grep -o 'namedprocess_namegroup_num_procs{groupname="[^"]*"} [0-9]*' || echo "    (none)"
    exit 0
  fi
  sleep 2
done
docker compose ps
docker compose logs --tail 30
die "exporters did not come up"
