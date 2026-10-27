#!/usr/bin/env bash
# Install a FastAPI service from /vagrant/services/<name> into /opt/<name> with a venv,
# OpenTelemetry auto-instrumentation and a systemd unit named <name>.service.
# Usage: python-service.sh <name>
set -euo pipefail
SVC="$1"
SRC="/vagrant/services/${SVC}"
DST="/opt/${SVC}"

id -u "$SVC" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC"

mkdir -p "$DST"
for f in main.py requirements.txt; do
  tr -d '\r' < "${SRC}/${f}" > "${DST}/${f}"
done

[ -x "${DST}/venv/bin/python" ] || python3 -m venv "${DST}/venv"
"${DST}/venv/bin/pip" install -q --upgrade pip
"${DST}/venv/bin/pip" install -q -r "${DST}/requirements.txt"
# Installs instrumentation packages for the libraries found in the venv (fastapi, httpx, redis, ...).
"${DST}/venv/bin/opentelemetry-bootstrap" -a install

chown -R "$SVC:$SVC" "$DST"

tr -d '\r' < "${SRC}/${SVC}.service" > "/etc/systemd/system/${SVC}.service"
systemctl daemon-reload
systemctl enable "${SVC}.service"
systemctl restart "${SVC}.service"

port=$(grep -oP -- '--port \K[0-9]+' "/etc/systemd/system/${SVC}.service")
for i in $(seq 1 30); do
  if curl -fs "http://127.0.0.1:${port}/health" >/dev/null; then
    echo ">>> ${SVC} healthy on :${port}"
    exit 0
  fi
  sleep 1
done
echo "!!! ${SVC} did not become healthy" >&2
journalctl -u "${SVC}.service" -n 50 --no-pager >&2
exit 1
