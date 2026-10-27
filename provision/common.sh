#!/usr/bin/env bash
# Base setup for every VM: packages, /etc/hosts, test tooling.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> [common] base packages"
apt-get update -q
apt-get install -y -q curl ca-certificates gnupg jq stress-ng python3-venv python3-pip

echo ">>> [common] /etc/hosts"
sed -i '/# monlab$/d' /etc/hosts
cat >> /etc/hosts <<'EOF'
192.168.56.10 monitor # monlab
192.168.56.11 app1 # monlab
192.168.56.12 app2 # monlab
EOF

timedatectl set-timezone UTC
