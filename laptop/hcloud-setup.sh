#!/usr/bin/env bash
# Run on YOUR LAPTOP. Needs: brew/apt install hcloud, and `hcloud context create`.
# Puts a network boundary OUTSIDE the server, where nothing on the box can touch it.
set -euo pipefail
SERVER=${1:?usage: hcloud-setup.sh <server-name>}
MYIP=$(curl -fsS https://ipv4.icanhazip.com)

hcloud firewall describe agent-fw >/dev/null 2>&1 || hcloud firewall create --name agent-fw

# Inbound: SSH from you only.
hcloud firewall replace-rules agent-fw --rules-file /dev/stdin <<JSON
[
  {"direction":"in","protocol":"tcp","port":"22","source_ips":["${MYIP}/32"]},
  {"direction":"out","protocol":"tcp","port":"80","destination_ips":["0.0.0.0/0","::/0"]},
  {"direction":"out","protocol":"tcp","port":"443","destination_ips":["0.0.0.0/0","::/0"]},
  {"direction":"out","protocol":"udp","port":"53","destination_ips":["0.0.0.0/0","::/0"]}
]
JSON

hcloud firewall apply-to-resource agent-fw --type server --server "$SERVER"
echo "agent-fw applied to ${SERVER} (ssh from ${MYIP} only; egress 80/443/53 only)"
