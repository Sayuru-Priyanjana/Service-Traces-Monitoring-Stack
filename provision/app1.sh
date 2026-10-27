#!/usr/bin/env bash
# app1: nginx reverse proxy (:80) -> orders FastAPI service (:8001).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SVC=orders

echo ">>> [app1] nginx"
apt-get install -y -q nginx
tr -d '\r' < /vagrant/services/nginx/orders.conf > /etc/nginx/sites-available/orders.conf
ln -sf /etc/nginx/sites-available/orders.conf /etc/nginx/sites-enabled/orders.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload-or-restart nginx

echo ">>> [app1] ${SVC} service"
bash /vagrant/provision/python-service.sh "$SVC"
