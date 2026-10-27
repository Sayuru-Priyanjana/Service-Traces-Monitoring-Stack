#!/usr/bin/env bash
# Install Docker Engine + Compose plugin from Docker's apt repository (Ubuntu / Debian).
# Same method as the lab's provision/monitor.sh. Usage: sudo ./install-docker.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "docker and compose already installed: $(docker --version)"
  exit 0
fi

. /etc/os-release
case "$ID" in ubuntu|debian) ;; *) echo "unsupported OS $ID: install Docker per https://docs.docker.com/engine/install/" >&2; exit 1;; esac

apt-get update -q
apt-get install -y -q ca-certificates curl openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version
docker compose version
