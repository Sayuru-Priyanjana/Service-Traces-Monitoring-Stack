#!/usr/bin/env bash
# monitor: Docker CE + Compose plugin from Docker's official apt repo, then the
# OTel Collector / Prometheus / Grafana stack from /opt/monitoring.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null; then
  echo ">>> [monitor] installing Docker from download.docker.com"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
usermod -aG docker vagrant

echo ">>> [monitor] syncing /vagrant/monitoring -> /opt/monitoring"
mkdir -p /opt/monitoring
cp -r /vagrant/monitoring/. /opt/monitoring/
chmod -R a+rX /opt/monitoring

cd /opt/monitoring
docker compose pull -q
docker compose up -d --remove-orphans
# Pick up config changes on re-provision: bind-mounted config files don't make
# `up -d` recreate a container. (Grafana re-reads dashboards by itself, but not datasources.)
docker compose restart otel-collector tempo grafana
curl -fs -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true

echo ">>> [monitor] waiting for Grafana and Prometheus"
for i in $(seq 1 60); do
  if curl -fs http://127.0.0.1:3000/api/health >/dev/null && curl -fs http://127.0.0.1:9090/-/ready >/dev/null; then
    docker compose ps
    echo ">>> Grafana: http://192.168.56.10:3000 (admin/admin)  Prometheus: http://192.168.56.10:9090"
    exit 0
  fi
  sleep 2
done
docker compose ps
docker compose logs --tail 30
exit 1
