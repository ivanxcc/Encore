#!/usr/bin/env bash
# Installs Encore Relay on an Ubuntu server (Oracle Cloud free tier, x86 or Arm): ffmpeg, the relay as
# a service, and Caddy in front of it for HTTPS. Run it again to update.
#
#   curl -fsSL https://github.com/ivanxcc/Encore/releases/download/relay-latest/install.sh | sudo bash
#
# Optional settings (environment variables):
#   RELAY_HOST         the name browsers reach the relay by. Default: <public-ip>.sslip.io, a free name
#                      that needs no setup. Use your own domain by pointing it at this server first.
#   ENCORE_CLOUD_URL   your Encore Cloud address (https://….workers.dev), for signing in on the lab page.
set -euo pipefail

REPO="${RELAY_REPO:-ivanxcc/Encore}"
[ "$(id -u)" = 0 ] || { echo "Run this with sudo."; exit 1; }

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported processor: $(uname -m)"; exit 1 ;;
esac

echo "==> Installing ffmpeg and Caddy"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ffmpeg curl debian-keyring debian-archive-keyring apt-transport-https >/dev/null
if ! command -v caddy >/dev/null; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

echo "==> Installing the relay"
curl -fsSL -o /usr/local/bin/encore-relay.new "https://github.com/${REPO}/releases/download/relay-latest/encore-relay-linux-${ARCH}"
chmod +x /usr/local/bin/encore-relay.new
mv /usr/local/bin/encore-relay.new /usr/local/bin/encore-relay
id encore-relay >/dev/null 2>&1 || useradd --system --home /var/lib/encore-relay --shell /usr/sbin/nologin encore-relay
mkdir -p /etc/encore-relay /var/cache/encore-relay
chown encore-relay: /var/cache/encore-relay

# Secrets are made once and kept across updates.
ENV=/etc/encore-relay/env
if [ ! -f "$ENV" ]; then
  CODE="$(tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' < /dev/urandom | head -c 8)"
  {
    echo "RELAY_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"
    echo "RELAY_LAB_CODE=${CODE:0:4}-${CODE:4:4}"
    echo "RELAY_CACHE=/var/cache/encore-relay"
    echo "RELAY_ADDR=127.0.0.1:8089"
  } > "$ENV"
  chmod 600 "$ENV"
fi
if [ -n "${ENCORE_CLOUD_URL:-}" ]; then
  sed -i '/^ENCORE_CLOUD_URL=/d' "$ENV"
  echo "ENCORE_CLOUD_URL=${ENCORE_CLOUD_URL}" >> "$ENV"
fi

cat > /etc/systemd/system/encore-relay.service <<UNIT
[Unit]
Description=Encore Relay
After=network-online.target
Wants=network-online.target

[Service]
User=encore-relay
EnvironmentFile=$ENV
ExecStart=/usr/local/bin/encore-relay serve
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/cache/encore-relay
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

HOST="${RELAY_HOST:-}"
if [ -z "$HOST" ]; then
  IP="$(curl -fsS -4 https://ifconfig.me || curl -fsS -4 https://api.ipify.org)"
  HOST="${IP//./-}.sslip.io"
fi
cat > /etc/caddy/Caddyfile <<CADDY
$HOST {
	encode zstd gzip {
		match header Content-Type application/json* application/vnd.apple.mpegurl* text/*
	}
	reverse_proxy 127.0.0.1:8089 {
		flush_interval -1
	}
}
CADDY

echo "==> Opening ports 80 and 443 on this server"
# Oracle's Ubuntu images block everything but SSH with iptables, apart from the cloud firewall.
if command -v iptables >/dev/null && iptables -L INPUT -n 2>/dev/null | grep -q REJECT; then
  for port in 80 443; do
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport "$port" -j ACCEPT
  done
  iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p udp --dport 443 -j ACCEPT
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable --now encore-relay >/dev/null
systemctl restart encore-relay
systemctl reload caddy 2>/dev/null || systemctl restart caddy

sleep 2
curl -fsS http://127.0.0.1:8089/healthz >/dev/null && echo "==> The relay is running" || { echo "The relay did not start: journalctl -u encore-relay"; exit 1; }
. "$ENV"
cat <<DONE

Encore Relay is installed.

  Lab page   https://$HOST/lab
  Lab code   $RELAY_LAB_CODE

If the page does not open from another device, allow ports 80 and 443 in the Oracle console:
Networking > Virtual Cloud Networks > your network > Security Lists > Add Ingress Rules
(source 0.0.0.0/0, TCP, destination ports 80 and 443).

Time a file from this server:   sudo -u encore-relay encore-relay bench -url 'https://...'
DONE
