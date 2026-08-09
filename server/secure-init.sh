#!/usr/bin/env bash
#
# secure-init.sh — create a sudo user and harden SSH on a fresh Ubuntu server.
#
# Run as root ON THE SERVER, from a session you keep open until you have
# verified the new login works. This is the step that makes the rest of the
# install possible: everything after it assumes a sudo user reachable by key.
#
#   scp server/secure-init.sh root@<ip>:/tmp/
#   ssh -t root@<ip> 'bash /tmp/secure-init.sh --user honza --copy-root-key'
#
# Options:
#   -u, --user NAME       user to create / configure          (default: honza)
#   -k, --key STRING      public key as a literal string
#   -f, --key-file PATH   public key read from a file
#       --copy-root-key   reuse the keys already in /root/.ssh/authorized_keys
#       --firewall        also configure ufw — OFF by default, see below
#       --no-restart      write config + verify, but don't restart sshd
#   -y, --yes             don't prompt before restarting sshd
#   -h, --help            this text
#
# ufw is off by default here, unlike on a general-purpose box. This server's
# packet filter belongs to agent-set-profile, which inserts INPUT rules at
# position 1; ufw puts its own chains at the top of INPUT every time it
# reloads, which can cut containers off from squid. The perimeter is the
# Hetzner Cloud Firewall, enforced outside the machine.
#
# It is safe to re-run: every step checks its own state first.

set -euo pipefail

USERNAME="honza"
PUBKEY=""
KEYFILE=""
COPY_ROOT_KEY=0
DO_FIREWALL=0
DO_RESTART=1
ASSUME_YES=0

DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/00-hardening.conf"
MAIN_CONFIG="/etc/ssh/sshd_config"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Directives we take ownership of; any other occurrence gets commented out.
MANAGED_DIRECTIVES=(
  PermitRootLogin
  PasswordAuthentication
  KbdInteractiveAuthentication
  ChallengeResponseAuthentication
  PubkeyAuthentication
  PermitEmptyPasswords
)

# ---------------------------------------------------------------- helpers ---

BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; RED=""; GRN=""; YLW=""; OFF=""; }

log()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s warn%s %s\n' "$YLW" "$OFF" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

usage() { sed -n '3,28p' "$0" | sed 's/^# \?//'; exit 0; }

backup() {
  [[ -f "$1" ]] || return 0
  cp -a "$1" "$1.bak-${STAMP}"
  ok "backed up $1 -> $1.bak-${STAMP}"
}

# ------------------------------------------------------------------ parse ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)       USERNAME="${2:?--user needs a value}"; shift 2 ;;
    -k|--key)        PUBKEY="${2:?--key needs a value}"; shift 2 ;;
    -f|--key-file)   KEYFILE="${2:?--key-file needs a value}"; shift 2 ;;
    --copy-root-key) COPY_ROOT_KEY=1; shift ;;
    --firewall)      DO_FIREWALL=1; shift ;;
    --no-firewall)   DO_FIREWALL=0; shift ;;
    --no-restart)    DO_RESTART=0; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage ;;
    *)               die "unknown option: $1  (try --help)" ;;
  esac
done

# ----------------------------------------------------------- sanity checks ---

[[ $EUID -eq 0 ]] || die "run this as root (or with sudo)"
command -v sshd >/dev/null || die "sshd not found — is this an SSH server?"
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $USERNAME"

if [[ -n "$KEYFILE" ]]; then
  [[ -r "$KEYFILE" ]] || die "cannot read key file: $KEYFILE"
  PUBKEY="$(<"$KEYFILE")"
elif [[ $COPY_ROOT_KEY -eq 1 ]]; then
  [[ -s /root/.ssh/authorized_keys ]] || die "/root/.ssh/authorized_keys is empty or missing"
  PUBKEY="$(grep -v '^\s*\(#\|$\)' /root/.ssh/authorized_keys || true)"
fi

[[ -n "$PUBKEY" ]] || die "no public key given — use --key, --key-file or --copy-root-key"

# Reject anything that isn't a parseable public key, and catch the classic
# mistake of pasting a *private* key.
grep -q 'PRIVATE KEY' <<<"$PUBKEY" && die "that is a PRIVATE key — install the .pub instead"
while IFS= read -r line; do
  [[ -z "${line// }" || "$line" == \#* ]] && continue
  ssh-keygen -l -f /dev/stdin <<<"$line" >/dev/null 2>&1 \
    || die "not a valid public key line: ${line:0:40}..."
done <<<"$PUBKEY"
ok "public key(s) parsed"

# ------------------------------------------------------------ 1. the user ---

log "user: $USERNAME"

if id -u "$USERNAME" >/dev/null 2>&1; then
  ok "user already exists"
else
  adduser --disabled-password --gecos "" "$USERNAME"
  ok "user created"
fi

if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo; then
  ok "already in group sudo"
else
  usermod -aG sudo "$USERNAME"
  ok "added to group sudo"
fi

# A locked password means `sudo` cannot authenticate at all, so make sure one
# gets set while we still have a terminal. bootstrap.sh is run with sudo, and
# only agent-set-profile is NOPASSWD.
if passwd -S "$USERNAME" | awk '{print $2}' | grep -qE '^(L|NP)$'; then
  if [[ -t 0 ]]; then
    warn "no usable password set — sudo will not work without one"
    log "set a password for $USERNAME now:"
    until passwd "$USERNAME"; do warn "try again"; done
  else
    warn "no password set and no terminal to prompt on."
    warn "run 'passwd $USERNAME' before relying on sudo."
  fi
else
  ok "password already set"
fi

# ------------------------------------------------------------- 2. the key ---

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[[ -n "$HOME_DIR" ]] || die "could not resolve home directory for $USERNAME"

SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

log "installing key into $AUTH_KEYS"

install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
touch "$AUTH_KEYS"

added=0
while IFS= read -r line; do
  [[ -z "${line// }" || "$line" == \#* ]] && continue
  if grep -qxF "$line" "$AUTH_KEYS"; then
    ok "key already present: $(ssh-keygen -l -f /dev/stdin <<<"$line" | awk '{print $2, $3}')"
  else
    printf '%s\n' "$line" >> "$AUTH_KEYS"
    added=$((added + 1))
    ok "key added: $(ssh-keygen -l -f /dev/stdin <<<"$line" | awk '{print $2, $3}')"
  fi
done <<<"$PUBKEY"

chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
ok "permissions set (700 dir / 600 authorized_keys), $added new key(s)"

# The hard gate: never disable password auth without a usable key on disk.
[[ -s "$AUTH_KEYS" ]] || die "authorized_keys is empty — refusing to harden sshd"

# ------------------------------------------------------------ 3. harden ---

log "hardening sshd"

# Ubuntu's sshd_config pulls in a drop-in directory, and the FIRST value seen
# for a directive wins. Cloud images ship 50-cloud-init.conf with
# 'PasswordAuthentication yes', which silently beats anything further down —
# hence the 00- prefix, plus the cleanup pass below.
if ! grep -qiE '^\s*Include\s+.*sshd_config\.d' "$MAIN_CONFIG"; then
  warn "$MAIN_CONFIG has no Include for sshd_config.d — adding one at the top"
  backup "$MAIN_CONFIG"
  printf 'Include %s/*.conf\n\n%s\n' "$DROPIN_DIR" "$(cat "$MAIN_CONFIG")" > "$MAIN_CONFIG.new"
  mv "$MAIN_CONFIG.new" "$MAIN_CONFIG"
  chmod 644 "$MAIN_CONFIG"
fi

mkdir -p "$DROPIN_DIR"
backup "$DROPIN"

cat > "$DROPIN" <<EOF
# Managed by secure-init.sh on ${STAMP}
# Loaded first (00-) so these win over any other drop-in.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
chmod 644 "$DROPIN"
ok "wrote $DROPIN"

# Comment out the same directives wherever else they appear, so the effective
# config can't drift back later if someone reorders the includes.
shopt -s nullglob
for f in "$DROPIN_DIR"/*.conf "$MAIN_CONFIG"; do
  [[ "$f" == "$DROPIN" ]] && continue
  for d in "${MANAGED_DIRECTIVES[@]}"; do
    if grep -qiE "^\s*${d}\b" "$f"; then
      backup "$f"
      sed -ri "s|^(\s*${d}\b.*)$|# disabled by secure-init.sh: \1|I" "$f"
      ok "neutralised $d in $(basename "$f")"
    fi
  done
done
shopt -u nullglob

# --------------------------------------------------------- 4. verify ---

log "verifying configuration"

sshd -t || die "sshd config has a syntax error — NOT restarting. Restore from *.bak-${STAMP}"
ok "syntax valid"

# sshd -T prints the *effective* config after all includes are resolved.
# This is the check that actually catches an override winning over us.
EFFECTIVE="$(sshd -T 2>/dev/null)" || die "could not dump effective config"

expect() {
  local key="$1" want="$2" got
  got="$(grep -i "^${key} " <<<"$EFFECTIVE" | head -1 | awk '{print $2}')"
  [[ "${got,,}" == "$want" ]] || die "effective ${key} is '${got}', expected '${want}'"
  ok "${key} = ${got}"
}

expect permitrootlogin           no
expect passwordauthentication    no
expect kbdinteractiveauthentication no
expect pubkeyauthentication      yes

# --------------------------------------------------------- 5. firewall ---

if [[ $DO_FIREWALL -eq 1 ]]; then
  log "firewall"
  warn "ufw manages INPUT too; agent-set-profile inserts its rules at position 1."
  warn "If containers lose squid after a 'ufw reload', this is why."
  if command -v ufw >/dev/null; then
    SSH_PORT="$(grep -i '^port ' <<<"$EFFECTIVE" | head -1 | awk '{print $2}')"
    ufw allow "${SSH_PORT:-22}/tcp" >/dev/null
    ok "allowed ${SSH_PORT:-22}/tcp"
    if ufw status | grep -q '^Status: active'; then
      ok "ufw already active"
    else
      ufw --force enable >/dev/null
      ok "ufw enabled"
    fi
  else
    warn "ufw not installed — skipping (apt install ufw)"
  fi
else
  log "firewall: skipped (Hetzner Cloud Firewall is the perimeter; --firewall to override)"
fi

# --------------------------------------------------------- 6. restart ---

echo
printf '%sBefore restarting, open a SECOND terminal and confirm:%s\n' "$BOLD" "$OFF"
printf '    ssh %s@%s\n' "$USERNAME" "$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '    sudo whoami        # should print: root\n\n'

if [[ $DO_RESTART -eq 0 ]]; then
  warn "--no-restart given; changes take effect after: systemctl restart ssh"
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  if [[ -t 0 ]]; then
    read -rp "Restart sshd now? [y/N] " reply
    [[ "${reply,,}" == y* ]] || { warn "skipped — run 'systemctl restart ssh' when ready"; exit 0; }
  else
    warn "not a terminal and no --yes; skipping restart"
    exit 0
  fi
fi

systemctl restart ssh 2>/dev/null || systemctl restart sshd
ok "sshd restarted"

echo
printf '%sDone.%s Existing sessions stay alive. Do not close this one until you have\n' "$GRN" "$OFF"
printf 'logged in as %s in another terminal.\n' "$USERNAME"
printf 'Rollback: rm %s && systemctl restart ssh\n' "$DROPIN"
