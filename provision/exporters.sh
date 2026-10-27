#!/usr/bin/env bash
# Host exporters for app VMs: node_exporter (with systemd collector) and process-exporter.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PROCESS_EXPORTER_VERSION="0.8.7"

echo ">>> [exporters] prometheus-node-exporter"
apt-get install -y -q prometheus-node-exporter
tr -d '\r' < /vagrant/exporters/prometheus-node-exporter.default > /etc/default/prometheus-node-exporter
systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

echo ">>> [exporters] process-exporter ${PROCESS_EXPORTER_VERSION}"
if ! dpkg -s process-exporter 2>/dev/null | grep -q "^Version: ${PROCESS_EXPORTER_VERSION}"; then
  deb="/tmp/process-exporter_${PROCESS_EXPORTER_VERSION}_linux_amd64.deb"
  curl -fsSL -o "$deb" \
    "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/process-exporter_${PROCESS_EXPORTER_VERSION}_linux_amd64.deb"
  dpkg -i "$deb"
fi
mkdir -p /etc/process-exporter
tr -d '\r' < /vagrant/exporters/process-exporter.yml > /etc/process-exporter/all.yaml

# Pin the command line so the port and config path don't depend on the .deb defaults.
mkdir -p /etc/systemd/system/process-exporter.service.d
cat > /etc/systemd/system/process-exporter.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/process-exporter --config.path /etc/process-exporter/all.yaml --web.listen-address=:9256
EOF
systemctl daemon-reload
systemctl enable process-exporter
systemctl restart process-exporter
