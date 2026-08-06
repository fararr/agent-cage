#!/usr/bin/env bash
# bootstrap.sh — run ONCE on a fresh Hetzner Ubuntu server as user `honza`:
#   sudo bash bootstrap.sh
# Idempotent: safe to re-run.
set -euo pipefail

AGENT_USER=${AGENT_USER:-honza}
ROOT=/home/${AGENT_USER}/agent
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
id "$AGENT_USER" >/dev/null || { echo "no such user: $AGENT_USER"; exit 1; }

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  docker.io docker-compose-v2 squid git curl jq tmux \
  iptables iptables-persistent unattended-upgrades ca-certificates
systemctl enable --now docker
usermod -aG docker "$AGENT_USER"

echo "==> swap (4 GB box needs it for composer/tsc spikes)"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

echo "==> layout"
install -d -o "$AGENT_USER" -g "$AGENT_USER" \
  "$ROOT" "$ROOT/project_workspace" "$ROOT/coder" \
  "$ROOT/coder/.claude" "$ROOT/coder/.codex" \
  "$ROOT/coder/.composer" "$ROOT/coder/.cache" "$ROOT/coder/.cache/pip"
mkdir -p /etc/agent && chown "$AGENT_USER":"$AGENT_USER" /etc/agent
echo "$AGENT_USER" > /etc/agent/user

# Docker creates a DIRECTORY for a bind-mount source that does not exist, and a
# directory mounted at ~/.gitconfig breaks git. Create them as files up front.
#
# If that has already happened, the container will not start at all: the image
# has a real /home/node/.gitconfig, and binding a directory over a file fails
# with ENOTDIR. Repair it here rather than only guarding against it, so that
# re-running bootstrap.sh actually fixes the box. rmdir, not rm -rf: if docker
# left anything in there we want to know, not to silently delete it.
for f in "$ROOT/coder/.gitconfig" "$ROOT/coder/.git-credentials"; do
  if [ -d "$f" ]; then
    echo "    $f is a directory (docker created it); removing"
    rmdir "$f"
  fi
  [ -f "$f" ] || install -m 600 -o "$AGENT_USER" -g "$AGENT_USER" /dev/null "$f"
done
chmod 644 "$ROOT/coder/.gitconfig"

echo "==> squid"
install -d /etc/squid/domains
cp -f "$HERE"/domains/*.txt /etc/squid/domains/
cp -f "$HERE"/squid.conf /etc/squid/squid.conf
squid -k parse
systemctl enable --now squid
systemctl reload squid || systemctl restart squid

echo "==> docker daemon"
cat > /etc/docker/daemon.json <<'JSON'
{
  "default-address-pools": [{"base": "172.31.0.0/16", "size": 24}],
  "no-new-privileges": true,
  "log-driver": "local",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
JSON
systemctl restart docker

echo "==> profile switch"
install -m 755 "$HERE"/agent-set-profile /usr/local/sbin/agent-set-profile
install -m 755 "$HERE"/agentctl          /usr/local/bin/agentctl
cat > /etc/sudoers.d/agentctl <<SUDO
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/sbin/agent-set-profile
SUDO
chmod 440 /etc/sudoers.d/agentctl

cat > /etc/systemd/system/agent-profile.service <<'UNIT'
[Unit]
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/local/sbin/agent-set-profile "$(cat /etc/agent/profile 2>/dev/null || echo work)"'
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable agent-profile.service
/usr/local/sbin/agent-set-profile work

echo
echo "Done. Log out and back in so the docker group applies, then:"
echo "  cd ~/agent && bash setup-git.sh"
