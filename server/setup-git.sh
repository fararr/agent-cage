#!/usr/bin/env bash
# setup-git.sh — git identity + credentials + first clone. Run as honza:
#   cd ~/agent && bash setup-git.sh
set -euo pipefail
ROOT="$HOME/agent"
CODER="$ROOT/coder"
mkdir -p "$CODER" "$ROOT/project_workspace"

read -rp "Git user.name         : " GIT_NAME
read -rp "Git user.email        : " GIT_EMAIL
read -rp "Git forge host        [github.com]: " HOST; HOST=${HOST:-github.com}
read -rp "Forge username        : " GIT_USER
read -rsp "Fine-grained PAT      : " GIT_TOKEN; echo

# Credentials the container reads. 0600, never in a repo, never in an image.
umask 077
printf 'https://%s:%s@%s\n' "$GIT_USER" "$GIT_TOKEN" "$HOST" > "$CODER/.git-credentials"
cat > "$CODER/.gitconfig" <<EOF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[credential]
	helper = store --file=/home/node/.git-credentials
[safe]
	directory = *
[init]
	defaultBranch = main
EOF
umask 022
chmod 600 "$CODER/.git-credentials"

echo
read -rp "Clone a repo now? URL (blank to skip): " REPO
if [ -n "$REPO" ]; then
  NAME=$(basename "$REPO" .git)
  sudo /usr/local/sbin/agent-set-profile work
  GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper="store --file=$CODER/.git-credentials" \
        clone "$REPO" "$ROOT/project_workspace/$NAME"
  echo "cloned -> ~/agent/project_workspace/$NAME"
fi

cat <<'NEXT'

Next:
  cd ~/agent/image
  sudo /usr/local/sbin/agent-set-profile build
  docker compose --profile build-only build toolchain   # ~12 min, once
  docker compose build claude codex
  docker compose run --rm claude       # log in, then /exit
  sudo /usr/local/sbin/agent-set-profile work
NEXT
