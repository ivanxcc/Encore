#!/usr/bin/env bash
# Encore Relay installer for an Ubuntu or Debian server (Oracle Cloud free tier works, x86 or Arm).
#
#   Install or update:  curl -fsSL https://github.com/ivanxcc/Encore/releases/download/relay-latest/install.sh | sudo bash
#   Status:             … | sudo bash -s status
#   Uninstall:          … | sudo bash -s uninstall
#
# It fits in beside what the server already runs:
#   - Docker with Pangolin: the relay is one more container on Pangolin's network, with no ports of
#     its own. You publish it as a Pangolin resource, like your other services.
#   - Docker, another reverse proxy on 80/443: a container on 127.0.0.1:8089 for your proxy to use.
#   - Nothing on 80/443: the relay plus Caddy for HTTPS on a free sslip.io name.
#
# Everything lives in /opt/encore-relay. Settings and secrets: /opt/encore-relay/relay.env.
#
# Options (environment variables): ENCORE_CLOUD_URL (your Encore Cloud's address; kept from the last
# install when not given), RELAY_HOST (Caddy mode).

# The whole script is one function, run on the last line: bash reads it completely before anything
# runs, so a command that reads standard input can't swallow the rest of a piped script.
main() {
set -Eeuo pipefail
trap 'echo; echo "!! Stopped at line $LINENO: $BASH_COMMAND"; echo "   Run it again, or send this message."; exit 1' ERR

REPO="${RELAY_REPO:-ivanxcc/Encore}"
DIR=/opt/encore-relay
ENV="$DIR/relay.env"
# Encore Cloud's address: given, or the one this server already has. Without one, Encore Web signs in
# with email and password only (no QR sign-in, no profiles from the apps).
CLOUD="${ENCORE_CLOUD_URL:-}"
if [ -z "$CLOUD" ] && [ -f "$ENV" ]; then CLOUD="$(sed -n 's/^ENCORE_CLOUD_URL=//p' "$ENV")"; fi
ACTION="${1:-install}"

[ "$(id -u)" = 0 ] || { echo "Run this with sudo."; exit 1; }

case "$ACTION" in
  install|update) ;;
  status) status; return ;;
  uninstall) uninstall; return ;;
  *) echo "Unknown action: $ACTION (install, status, uninstall)"; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported processor: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$DIR"
cleanup_first_attempt

# Secrets are made once and kept across updates.
if [ ! -f "$ENV" ]; then
  echo "==> Creating the relay's secret and lab code"
  local secret code
  secret="$(random 40 'A-Za-z0-9')"
  code="$(random 8 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789')"
  umask 077
  cat > "$ENV" <<EOF
RELAY_SECRET=$secret
RELAY_LAB_CODE=${code:0:4}-${code:4:4}
ENCORE_CLOUD_URL=$CLOUD
EOF
  umask 022
fi
sed -i "s|^ENCORE_CLOUD_URL=.*|ENCORE_CLOUD_URL=$CLOUD|" "$ENV"
chmod 600 "$ENV"

local mode
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  if docker network inspect pangolin >/dev/null 2>&1; then mode=pangolin
  elif ports_taken; then mode=docker-local
  else mode=caddy
  fi
elif ports_taken; then
  echo "Ports 80/443 are in use and Docker isn't installed: install Docker, or free the ports."; exit 1
else
  mode=caddy
fi

case "$mode" in
  pangolin|docker-local) install_container "$mode" ;;
  caddy) install_caddy ;;
esac
}

random() {   # random <length> <characters>, without a pipe that pipefail would trip over
  local out="" chars="$2"
  while [ "${#out}" -lt "$1" ]; do
    out+="$(LC_ALL=C tr -dc "$chars" < <(head -c 512 /dev/urandom))"
  done
  printf '%s' "${out:0:$1}"
}

# Something listens on 80 or 443 (from the kernel's own table: works without ss or netstat).
ports_taken() {
  local tables=()
  for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && tables+=("$f"); done
  [ "${#tables[@]}" -gt 0 ] || return 1
  awk '$4 == "0A" && ($2 ~ /:0050$/ || $2 ~ /:01BB$/) { found = 1 } END { exit !found }' "${tables[@]}"
}

# The first version of this script stopped early on some servers, after installing Caddy (which
# then waits to take ports 80/443 at boot, ahead of a proxy like Pangolin) and a copy of the relay.
cleanup_first_attempt() {
  if command -v caddy >/dev/null && [ -f /etc/caddy/Caddyfile ] && grep -q "easy way to configure your Caddy" /etc/caddy/Caddyfile; then
    echo "==> Removing Caddy left by an earlier attempt (it was never configured)"
    systemctl disable --now caddy >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq caddy >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  if [ -d /etc/encore-relay ] && [ ! -f /etc/systemd/system/encore-relay.service ]; then
    rm -rf /etc/encore-relay /var/cache/encore-relay /usr/local/bin/encore-relay
    id encore-relay >/dev/null 2>&1 && userdel encore-relay 2>/dev/null || true
  fi
}

install_container() {
  local mode="$1"
  echo "==> Installing the relay as a Docker container ($([ "$mode" = pangolin ] && echo "on Pangolin's network" || echo "on 127.0.0.1:8089"))"
  cat > "$DIR/Dockerfile" <<EOF
FROM alpine:3.20
RUN apk add --no-cache ffmpeg ca-certificates
ADD https://github.com/$REPO/releases/download/relay-latest/encore-relay-linux-$ARCH /usr/local/bin/encore-relay
RUN chmod 755 /usr/local/bin/encore-relay && adduser -D -H relay
USER relay
ENV RELAY_ADDR=0.0.0.0:8089 RELAY_CACHE=/cache RELAY_DATA=/data
ENTRYPOINT ["encore-relay", "serve"]
EOF
  {
    echo "# Encore Relay. Manage with: docker compose -f $DIR/compose.yaml <ps|logs|restart>"
    echo "services:"
    echo "  encore-relay:"
    echo "    build: ."
    echo "    image: encore-relay:local"
    echo "    container_name: encore-relay"
    echo "    restart: unless-stopped"
    echo "    env_file: relay.env"
    echo "    tmpfs: [\"/cache:size=3g,uid=1000\"]"
    echo "    volumes: [\"./data:/data\"]"
    echo "    mem_limit: 4g"
    echo "    healthcheck:"
    echo "      test: [\"CMD\", \"wget\", \"-qO-\", \"http://127.0.0.1:8089/healthz\"]"
    echo "      interval: 30s"
    echo "      timeout: 5s"
    if [ "$mode" = pangolin ]; then
      echo "    networks: [pangolin]"
      echo "networks:"
      echo "  pangolin:"
      echo "    external: true"
    else
      echo "    ports: [\"127.0.0.1:8089:8089\"]"
    fi
  } > "$DIR/compose.yaml"

  # What the relay remembers (linked accounts, file indexes), kept across updates. The container's
  # user is uid 1000.
  mkdir -p "$DIR/data"
  chown 1000:1000 "$DIR/data"
  chmod 700 "$DIR/data"

  cd "$DIR"
  # A newer base image when Docker Hub answers; the one already here when it's busy.
  docker compose build --pull --quiet >/dev/null 2>&1 || docker compose build --quiet >/dev/null
  docker compose up -d --force-recreate --remove-orphans >/dev/null 2>&1 || docker compose up -d --force-recreate
  wait_healthy "docker exec encore-relay wget -qO- http://127.0.0.1:8089/healthz"
  done_message "$mode"
}

install_caddy() {
  echo "==> Installing ffmpeg and Caddy"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq < /dev/null
  apt-get install -y -qq ffmpeg curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https < /dev/null >/dev/null
  if ! command -v caddy >/dev/null; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq < /dev/null
    apt-get install -y -qq caddy < /dev/null >/dev/null
  fi

  echo "==> Installing the relay"
  curl -fsSL -o "$DIR/encore-relay" "https://github.com/$REPO/releases/download/relay-latest/encore-relay-linux-$ARCH"
  chmod 755 "$DIR/encore-relay"
  id encore-relay >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin encore-relay
  cat > /etc/systemd/system/encore-relay.service <<EOF
[Unit]
Description=Encore Relay
After=network-online.target
Wants=network-online.target

[Service]
User=encore-relay
EnvironmentFile=$ENV
Environment=RELAY_ADDR=127.0.0.1:8089
Environment=RELAY_CACHE=/var/cache/encore-relay
Environment=RELAY_DATA=/var/lib/encore-relay
CacheDirectory=encore-relay
StateDirectory=encore-relay
StateDirectoryMode=0700
ExecStart=$DIR/encore-relay serve
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chown root:encore-relay "$ENV"; chmod 640 "$ENV"

  local host="${RELAY_HOST:-}"
  if [ -z "$host" ]; then
    local ip
    ip="$(curl -fsS -4 https://api.ipify.org || curl -fsS -4 https://ifconfig.me)"
    host="${ip//./-}.sslip.io"
  fi
  echo "$host" > "$DIR/host"
  cat > /etc/caddy/Caddyfile <<EOF
# Written by the Encore Relay installer.
$host {
	reverse_proxy 127.0.0.1:8089 {
		flush_interval -1
	}
}
EOF

  # Oracle's Ubuntu images block everything but SSH with iptables, besides the cloud firewall.
  if command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -q -- "-j REJECT"; then
    echo "==> Opening ports 80 and 443 in this server's firewall"
    for port in 80 443; do
      iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
    done
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload
  systemctl enable encore-relay >/dev/null 2>&1
  systemctl restart encore-relay
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  wait_healthy "curl -fsS http://127.0.0.1:8089/healthz"
  done_message caddy
}

wait_healthy() {
  for _ in $(seq 1 30); do
    if eval "$1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "!! The relay didn't start. Its log:"
  if [ -f "$DIR/compose.yaml" ]; then docker logs --tail 30 encore-relay 2>&1; else journalctl -u encore-relay -n 30 --no-pager; fi
  exit 1
}

done_message() {
  local code
  code="$(sed -n 's/^RELAY_LAB_CODE=//p' "$ENV")"
  echo
  echo "Encore Relay is running."
  echo
  case "$1" in
    pangolin)
      cat <<EOF
It's a container named "encore-relay" on Pangolin's network, with no ports of its own: nothing is
reachable until you publish it. In the Pangolin dashboard:

  1. Resources > Add Resource. Name: Encore Relay. Type: HTTP. Subdomain: relay (or any).
  2. Site: the local site Pangolin itself runs on.
  3. Target: method http, host  encore-relay, port  8089.
  4. In the resource's Authentication tab, turn authentication off. The relay checks its own
     tokens, and the video player can't sign in to Pangolin.

Then open  https://<that address>  in any browser, and sign in to Encore.
EOF
      ;;
    docker-local)
      echo "It listens on 127.0.0.1:8089. Point your reverse proxy at it, then open https://<address> and sign in to Encore."
      ;;
    caddy)
      echo "  Encore     https://$(cat "$DIR/host")"
      echo
      echo "If it doesn't open from another device, allow TCP ports 80 and 443 in the Oracle console:"
      echo "Networking > Virtual Cloud Networks > your network > Security Lists > Add Ingress Rules."
      ;;
  esac
  cat <<EOF

  Relay code   $code

The first time you sign in to Encore on this address it asks for the relay code, once per Stremio
account. After that, signing in is all any device needs. (The test page is still at /lab.)

Status:     curl -fsSL https://github.com/$REPO/releases/download/relay-latest/install.sh | sudo bash -s status
Update:     run the install command again
Uninstall:  curl -fsSL https://github.com/$REPO/releases/download/relay-latest/install.sh | sudo bash -s uninstall
EOF
}

status() {
  if [ -f "$DIR/compose.yaml" ]; then
    docker compose -f "$DIR/compose.yaml" ps
    echo; docker logs --tail 15 encore-relay 2>&1
    echo; docker exec encore-relay wget -qO- http://127.0.0.1:8089/healthz && echo
  elif systemctl list-unit-files encore-relay.service >/dev/null 2>&1 && [ -f /etc/systemd/system/encore-relay.service ]; then
    systemctl --no-pager status encore-relay | head -12
    echo; curl -fsS http://127.0.0.1:8089/healthz && echo
  else
    echo "Encore Relay isn't installed."
    return
  fi
  echo "Relay code: $(sed -n 's/^RELAY_LAB_CODE=//p' "$ENV" 2>/dev/null)"
}

uninstall() {
  if [ -f "$DIR/compose.yaml" ]; then
    docker compose -f "$DIR/compose.yaml" down --rmi local >/dev/null 2>&1 || true
  fi
  if [ -f /etc/systemd/system/encore-relay.service ]; then
    systemctl disable --now encore-relay >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/encore-relay.service
    systemctl daemon-reload
    if grep -q "Written by the Encore Relay installer" /etc/caddy/Caddyfile 2>/dev/null; then
      systemctl disable --now caddy >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq caddy >/dev/null 2>&1 || true
    fi
  fi
  id encore-relay >/dev/null 2>&1 && userdel encore-relay 2>/dev/null || true
  rm -rf "$DIR" /var/lib/encore-relay
  echo "Encore Relay is uninstalled. Nothing else on this server was changed."
}

main "$@"
