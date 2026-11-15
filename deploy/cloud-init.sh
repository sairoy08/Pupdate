#!/bin/bash
# Runs once on the new Vultr server. __MONGODB_URI__ is filled in by vultr-deploy.sh.
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3-venv git curl debian-keyring debian-archive-keyring apt-transport-https gnupg
# Caddy (automatic HTTPS) from its official repo
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy

git clone --depth 1 https://github.com/JeremyEltho/Pupdate /opt/walkbuddy
python3 -m venv /opt/walkbuddy/backend/.venv
/opt/walkbuddy/backend/.venv/bin/pip install -r /opt/walkbuddy/backend/requirements.txt

cat > /etc/walkbuddy.env <<ENV
MONGODB_URI=__MONGODB_URI__
ENV
chmod 600 /etc/walkbuddy.env

cat > /etc/systemd/system/walkbuddy.service <<UNIT
[Unit]
Description=Pupdate backend
After=network-online.target
[Service]
WorkingDirectory=/opt/walkbuddy/backend
EnvironmentFile=/etc/walkbuddy.env
ExecStart=/opt/walkbuddy/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8100
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now walkbuddy

IP=$(curl -s http://169.254.169.254/v1/interfaces/0/ipv4/address || hostname -I | awk '{print $1}')
HOST="$(echo "$IP" | tr . -).sslip.io"
cat > /etc/caddy/Caddyfile <<CADDY
$HOST {
    reverse_proxy 127.0.0.1:8100
}
CADDY
systemctl restart caddy
ufw allow 22 || true; ufw allow 80 || true; ufw allow 443 || true
echo "WALKBUDDY READY https://$HOST" > /root/walkbuddy-ready
