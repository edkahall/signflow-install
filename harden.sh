#!/usr/bin/env bash
# =============================================================================
#  SignFlow CMS — host hardening
#  Usage: sudo bash harden.sh
#
#  Minimum security baseline for a server reachable from the Internet
#  (port-forward or DMZ). Idempotent — safe to run again at any time.
#
#  It does, in this order:
#    1. Firewall (UFW): allow only SSH + the web ports; deny everything else.
#    2. Close Docker-published ports that UFW cannot protect (MinIO).
#    3. SSH: key-only login (disabled ONLY if a key is already installed).
#    4. fail2ban: ban brute-force SSH.
#    5. Automatic security updates.
#
#  Designed NOT to lock you out:
#    - SSH is allowed BEFORE the firewall is turned on;
#    - password login is disabled ONLY when an authorized key already exists;
#    - the sshd config is validated before it is reloaded.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
SignFlow CMS — host hardening

Minimum security baseline for a server reachable from the Internet (port-forward or
DMZ). Idempotent — safe to run again at any time.

USAGE
  sudo bash harden.sh

WHAT IT DOES
  1. Firewall (UFW): allow SSH + 80/443/9443; 8080 (plain-HTTP UI) LAN-only; deny the rest.
  2. Close Docker-published ports UFW cannot filter (binds MinIO to loopback when media
     are served through a TLS proxy).
  3. SSH: key-only login — disabled ONLY if an authorized key already exists (no lockout).
  4. fail2ban: ban brute-force SSH.
  5. Automatic security updates (unattended-upgrades).

SAFE BY DESIGN
  SSH is allowed before the firewall is turned on, password login is disabled only when a
  key is present, and the sshd config is validated before it is reloaded.
EOF
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "This script must be run with sudo"; exit 1; }

INSTALL_DIR="${SIGNFLOW_DIR:-/opt/signflow}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "\n${CYAN}[harden] $*${NC}"; }
ok()   { echo -e "${GREEN}    OK  $*${NC}"; }
warn() { echo -e "${YELLOW}    !!  $*${NC}"; }

# Active SSH port (default 22) — read from the effective config so we never
# lock ourselves out on a non-standard port.
# ⚠️ NEVER let the reader of this pipe exit early (`awk ... exit`, `grep -m1`,
# `head -1`): it closes the pipe under `sshd -T`, which then dies of SIGPIPE.
# With `set -o pipefail` the whole pipeline reports 141 and `set -e` aborts the
# script — so hardening silently did nothing while the installer only printed a
# warning and still exited 0. It is a RACE (it succeeds whenever sshd finishes
# writing first), which is why it worked on some machines and not others.
# Found on the install bench, 2026-08-02. Read everything, keep the last match.
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{if (p) print p}')"
SSH_PORT="${SSH_PORT:-22}"

# -----------------------------------------------------------------------------
say "1/5 — Firewall (UFW)"
# -----------------------------------------------------------------------------
command -v ufw >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq ufw >/dev/null; }
ufw allow "${SSH_PORT}/tcp" >/dev/null   # SSH first, before enabling
ufw allow 80/tcp   >/dev/null            # HTTP + ACME (Let's Encrypt)
ufw allow 443/tcp  >/dev/null            # HTTPS (web UI behind Caddy)
ufw allow 9443/tcp >/dev/null            # HTTPS media (MinIO behind Caddy)
# Plain-HTTP UI on 8080 (nginx): local network only, never the Internet.
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    ufw allow from "$net" to any port 8080 proto tcp >/dev/null
done
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
ok "UFW on — SSH ${SSH_PORT}, 80/443/9443 public, 8080 LAN-only, rest denied"

# -----------------------------------------------------------------------------
say "2/5 — Docker-published ports (UFW does NOT filter these)"
# -----------------------------------------------------------------------------
# Docker inserts its own iptables rules and BYPASSES UFW for published ports.
# The only port SignFlow publishes to the outside is MinIO (9000). When media
# is served through a TLS reverse proxy (…:9443), raw 9000 must be bound to
# loopback so it is not reachable from the Internet.
if [[ -f "${INSTALL_DIR}/.env" ]]; then
    # ⚠️ `grep` returns 1 when a key is simply ABSENT — which is the normal case
    # for MINIO_BIND on a fresh install. Under `set -euo pipefail` that aborted
    # hardening at step 2/5, leaving fail2ban and key-only SSH unconfigured while
    # the installer reported only a warning. Read the value, never let its
    # absence be an error. (`head -1` also closes the pipe early, so the same
    # SIGPIPE trap as step 1 applies — awk keeps the first match instead.)
    env_value() {  # env_value <key> — empty when the key is not there
        awk -F= -v k="$1" '$1 == k && !seen {seen=1; sub(/^[^=]*=/, ""); print}' \
            "${INSTALL_DIR}/.env" 2>/dev/null || true
    }
    PUB_EP="$(env_value MINIO_PUBLIC_ENDPOINT)"
    CUR_BIND="$(env_value MINIO_BIND)"
    if [[ -n "$PUB_EP" && "$PUB_EP" != *:9000* ]]; then
        # Media is proxied elsewhere → 9000 does not need to face the network.
        if [[ "$CUR_BIND" != "127.0.0.1" ]]; then
            sed -i '/^MINIO_BIND=/d' "${INSTALL_DIR}/.env"
            echo "MINIO_BIND=127.0.0.1" >> "${INSTALL_DIR}/.env"
            ( cd "${INSTALL_DIR}" && docker compose up -d --force-recreate minio >/dev/null 2>&1 ) || true
            ok "MinIO rebound to 127.0.0.1 (media still served via ${PUB_EP})"
        else
            ok "MinIO already bound to loopback"
        fi
    else
        warn "Media is served directly on MinIO :9000 (no TLS proxy) — that port"
        warn "is reachable from the network and UFW cannot filter it. Put MinIO"
        warn "behind a TLS proxy (see README_HTTPS.md) then re-run this script."
    fi
else
    warn "No ${INSTALL_DIR}/.env — skipping the MinIO check (not a SignFlow host?)"
fi

# -----------------------------------------------------------------------------
say "3/5 — SSH: key-only login"
# -----------------------------------------------------------------------------
KEYS_FOUND=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] && KEYS_FOUND=1
done
if [[ "$KEYS_FOUND" -eq 1 ]]; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/10-signflow.conf <<'SSHD'
# SignFlow hardening — key-only SSH
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
SSHD
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "Password login disabled (key-only). Open sessions are unaffected."
    else
        rm -f /etc/ssh/sshd_config.d/10-signflow.conf
        warn "sshd test failed — change reverted, password login LEFT ENABLED."
    fi
else
    warn "No authorized SSH key found — password login LEFT ENABLED to avoid a"
    warn "lockout. Install your key (ssh-copy-id) then re-run: sudo bash harden.sh"
fi

# -----------------------------------------------------------------------------
say "4/5 — fail2ban (ban brute-force SSH)"
# -----------------------------------------------------------------------------
command -v fail2ban-client >/dev/null 2>&1 || {
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
}
cat > /etc/fail2ban/jail.d/signflow-sshd.local <<F2B
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 4
findtime = 10m
bantime  = 1h
F2B
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban >/dev/null 2>&1 || true
ok "fail2ban active on SSH"

# -----------------------------------------------------------------------------
say "5/5 — Automatic security updates"
# -----------------------------------------------------------------------------
command -v unattended-upgrade >/dev/null 2>&1 || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
}
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled"

# -----------------------------------------------------------------------------
say "Summary"
# -----------------------------------------------------------------------------
ufw status verbose | sed 's/^/    /'
echo "    SSH: $(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin) ' | tr '\n' ' ')"
systemctl is-active fail2ban >/dev/null 2>&1 && echo "    fail2ban: active"
ss -tln | awk 'NR>1 && $4 !~ /127\.0\.0|::1/ {print "    exposed: "$4}'
ok "Hardening complete."
