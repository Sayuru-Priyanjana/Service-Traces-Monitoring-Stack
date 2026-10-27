#!/usr/bin/env bash
# app2: redis + inventory FastAPI service (:8002).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SVC=inventory

echo ">>> [app2] redis"
apt-get install -y -q redis-server
systemctl enable redis-server
systemctl restart redis-server

echo ">>> [app2] ${SVC} service"
bash /vagrant/provision/python-service.sh "$SVC"
