#!/usr/bin/env bash
# Deploy or update the monitoring stack on this server. Safe to re-run after any config change.
# Usage (from this folder): sudo ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./deploy.sh)"
command -v docker >/dev/null || die "docker not installed (see ../scripts/install-docker.sh)"
[ -f .env ] || die ".env missing: cp .env.example .env and edit it"
set -a; . ./.env; set +a
grep -q 'change-me' .env && die ".env still contains 'change-me'"
for f in prometheus/targets/node.yml prometheus/targets/process.yml; do
  [ -f "$f" ] || die "$f missing: copy $f.example and list your servers"
done

# Grafana TLS: self-signed certificate unless one was provided.
mkdir -p certs
if [ ! -f certs/grafana.crt ] || [ ! -f certs/grafana.key ]; then
  echo ">>> creating self-signed certificate for ${GRAFANA_CERT_CN}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout certs/grafana.key -out certs/grafana.crt \
    -subj "/CN=${GRAFANA_CERT_CN}" -addext "subjectAltName=${GRAFANA_CERT_SANS}" 2>/dev/null
fi
chown 472:0 certs/grafana.key certs/grafana.crt   # 472 = grafana user in the image
chmod 600 certs/grafana.key
chmod 644 certs/grafana.crt

echo ">>> validating configuration"
docker compose config -q
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.15.0 check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/alertmanager:/c:ro" --entrypoint amtool \
  prom/alertmanager:v0.28.1 check-config /c/alertmanager.yml
docker run --rm -v "$PWD/otel-collector:/c:ro" \
  otel/opentelemetry-collector-contrib:0.162.0 validate --config=/c/config.yaml

echo ">>> starting stack"
docker compose pull -q
docker compose up -d --remove-orphans
# Bind-mounted config changes don't make `up -d` recreate containers: reload / restart them.
docker compose restart otel-collector tempo alertmanager grafana
curl -fs -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true

echo ">>> waiting for services"
for _ in $(seq 1 90); do
  if curl -fsk "https://127.0.0.1:${GRAFANA_PORT:-3000}/api/health" >/dev/null \
     && curl -fs http://127.0.0.1:9090/-/ready >/dev/null \
     && curl -fs http://127.0.0.1:3200/ready >/dev/null \
     && curl -fs http://127.0.0.1:9093/-/ready >/dev/null; then
    docker compose ps
    echo ">>> ready. Grafana: ${GRAFANA_ROOT_URL}"
    exit 0
  fi
  sleep 2
done
docker compose ps
docker compose logs --tail 30
die "services did not become ready within 3 minutes"
