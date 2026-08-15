#!/usr/bin/env bash
# =============================================================================
#  SignFlow CMS — Ubuntu installer
#  Usage: sudo bash install-ubuntu.sh
#
#  Installs SignFlow from PRE-BUILT IMAGES: nothing is compiled, and no source
#  code is placed on the machine.
#
#   1.  Checks and installs prerequisites (Docker Engine + Compose, openssl, curl)
#   2.  Copies installation files to /opt/signflow
#   3.  Creates .env with randomly generated secrets
#   4.  Authenticates against the image registry and pulls the images
#   5.  Starts the containers
#   6.  Applies database migrations and prepares object storage
#   7.  Runs health checks
#   8.  Installs auto-start on boot (systemd)
#   9.  Installs nginx as front end (access from the local network)
#  10.  Creates the organisation and the administrator account
#
#  REGISTRY CREDENTIALS: supplied with your SignFlow licence. They may be passed
#  through the environment for an unattended install:
#     sudo SIGNFLOW_REGISTRY_USER=... SIGNFLOW_REGISTRY_PASSWORD=... bash install-ubuntu.sh
# =============================================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/signflow"
REGISTRY="${SIGNFLOW_REGISTRY:-registry.dernoult.net:8443}"
VERSION="${SIGNFLOW_VERSION:-1.0.42}"

# Owner of the configuration files: whoever ran `sudo`, so they can edit them
# without root. Falls back to root when that account does not exist.
SERVICE_USER="${SIGNFLOW_USER:-${SUDO_USER:-root}}"
id -u "$SERVICE_USER" >/dev/null 2>&1 || SERVICE_USER="root"

BACKEND_PORT=8010
FRONTEND_PORT=3010
MINIO_PORT=9000
NGINX_PORT=8080      # Local-network access port (host, outside Docker)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()    { echo -e "${GREEN}    OK  $*${NC}"; }
warn()  { echo -e "${YELLOW}    !!  $*${NC}"; }
fail()  { echo -e "${RED}    ERR $*${NC}"; exit 1; }
info()  { echo -e "    ..  $*"; }

# ── Asking questions safely ──────────────────────────────────────────────────
# Every prompt in this installer goes through ask(). Without a terminal — a
# scripted install, cloud-init, CI — `read` returns EOF immediately, and under
# `set -euo pipefail` that KILLS the script. That is what made the documented
# "unattended install" impossible: it died at the first prompt (the media path),
# after installing Docker but before pulling a single image, and returned 1.
# Measured on a bare install bench, 2026-08-02.
#
# With no terminal we therefore take the default and SAY SO, rather than stop.
NONINTERACTIVE=0
[[ -t 0 ]] || NONINTERACTIVE=1

# ask <variable> <prompt> [default]
ask() {
    local __var="$1" __prompt="$2" __default="${3-}" __answer=""
    if (( NONINTERACTIVE )); then
        printf -v "$__var" '%s' "$__default"
        info "$__prompt[${__default:-empty}] (no terminal — default used)"
        return 0
    fi
    read -rp "$__prompt" __answer || __answer=""
    printf -v "$__var" '%s' "${__answer:-$__default}"
}

show_help() {
    cat <<EOF
SignFlow CMS — Ubuntu installer

Installs SignFlow from PRE-BUILT images (nothing is compiled, no source code is put
on the machine): Docker + Compose, generated secrets, image pull, database migrations,
object storage, health checks, systemd autostart, nginx front end, and the initial
organisation + administrator account.

USAGE
  sudo bash install-ubuntu.sh

REGISTRY CREDENTIALS (supplied with your SignFlow licence)
  Provide them interactively, or pass them for an UNATTENDED install:
    sudo SIGNFLOW_REGISTRY_USER=<licence_id> SIGNFLOW_REGISTRY_PASSWORD=<secret> \\
         bash install-ubuntu.sh

USEFUL ENVIRONMENT VARIABLES
  SIGNFLOW_REGISTRY_USER / _PASSWORD   registry login (asked otherwise)
  SIGNFLOW_VERSION                     version to install (default: ${VERSION})
  MEDIA_DATA_PATH                      where media are stored (asked otherwise)
  SIGNFLOW_HARDEN=yes|no               run the security hardening step unattended

AFTER INSTALL
  Web UI:            http://<server>:${NGINX_PORT}
  Update later:      cd ${INSTALL_DIR} && bash update.sh <version>
  Harden (public):   sudo bash harden.sh
  Daily DB backup:   bash setup-backup.sh
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help; exit 0; }

# =============================================================================
step "1/10 — Prerequisites"
# =============================================================================

[[ $EUID -eq 0 ]] || fail "This script must be run with sudo"

# `command -v` is unreliable for packages with no same-named binary
# (ca-certificates); dpkg answers correctly in every case.
MISSING=""
for pkg in openssl ca-certificates curl gnupg; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING="$MISSING $pkg"
done
if [[ -n "$MISSING" ]]; then
    info "Installing prerequisites:$MISSING"
    apt-get update -qq
    apt-get install -y -qq $MISSING >/dev/null || fail "Could not install:$MISSING"
    ok "Prerequisites installed:$MISSING"
fi

# Docker from the official repository: the Ubuntu one ships a Compose release
# too old for the `!override` tag and other features used here.
if ! command -v docker >/dev/null 2>&1; then
    step "1a/10 — Installing Docker Engine"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc || fail "Could not download the Docker signing key"
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null \
        || fail "Could not install Docker Engine"
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker Engine installed"
fi

docker info >/dev/null 2>&1 || fail "The Docker daemon is not running"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ','), Compose $(docker compose version | awk '{print $4}')"

# Without this, every `docker compose` command in the documentation fails with
# "permission denied while trying to connect to the Docker API" for the operator,
# who would have to prefix everything with sudo.
# ⚠️ Membership of the `docker` group grants root-equivalent access to the host.
# That is the accepted trade-off on a machine dedicated to this application, where
# the operator already has sudo.
if [[ "$SERVICE_USER" != "root" ]] && ! id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$SERVICE_USER"
    ok "$SERVICE_USER added to the 'docker' group (effective at next login)"
    DOCKER_GROUP_ADDED=1
fi

SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
SERVER_IP="${SERVER_IP:-127.0.0.1}"
info "Detected server address: $SERVER_IP"

# =============================================================================
step "1b/10 — Hardware video acceleration (optional)"
# =============================================================================
#
# Transcoding is by far the heaviest task this server performs. SignFlow already
# picks the best encoder on its own — it TESTS nvenc, qsv and vaapi in turn and
# falls back to libx264 — so the only thing missing is access to the hardware
# from inside the container. That is what this step arranges.
#
# ⚠️ THIS STEP NEVER INSTALLS A GPU DRIVER. Installing a proprietary driver on
# someone else's server can break their display stack and require a reboot to
# recover. We use the driver that is already there, or we do without.
#
# Detection order matters: a machine can expose /dev/dri (Intel iGPU) *and* hold
# an NVIDIA card. NVIDIA is checked first because it is the faster encoder.

# The wiring itself lives in setup-gpu.sh, sourced here as a library. ONE
# definition, used by two paths: this installer, and a customer who fits a card
# months later (`sudo bash setup-gpu.sh`). Two copies would drift, and the drift
# would be silent — the exact class of defect this installer was full of.
if [[ -f "${SRC_DIR}/setup-gpu.sh" ]]; then
    # shellcheck source=setup-gpu.sh
    source "${SRC_DIR}/setup-gpu.sh" --lib
    gpu_detect      # sets GPU_MODE to nvidia | dri | none
else
    warn "setup-gpu.sh not found — skipping hardware acceleration (CPU encoding)."
    GPU_MODE="none"
fi

# =============================================================================
step "2/10 — Installation files"
# =============================================================================

mkdir -p "$INSTALL_DIR"
for f in docker-compose.yml postgres-init.sh litellm-config.yaml; do
    [[ -f "$SRC_DIR/$f" ]] || fail "Missing file: $f (incomplete download?)"
    cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
# update.sh is the supported upgrade path (pull + migrate + REINDEX the assistant
# docs, which a bare `compose pull` skips). Copy it so it is there when needed;
# absent, an operator would fall back to a manual pull and the assistant would
# never catch up on new documentation. Optional in the download — warn, do not fail.
if [[ -f "$SRC_DIR/update.sh" ]]; then
    cp "$SRC_DIR/update.sh" "$INSTALL_DIR/update.sh"
    chmod +x "$INSTALL_DIR/update.sh"
else
    warn "update.sh not found next to the installer — updates will be manual"
fi
# The operator-facing tools. They MUST land in the installation directory: both
# this script and the printed instructions call them from there (`cd /opt/signflow
# && sudo bash setup-gpu.sh`), and update.sh refreshes them in place. Until
# 2026-08-02 only harden.sh was copied — so `bash setup-backup.sh` at the end of a
# fresh install ran against a file that was not there, and a customer who fitted a
# GPU later had no setup-gpu.sh to run. Optional in the download: warn, never fail.
for f in harden.sh setup-gpu.sh tune-nginx.sh setup-backup.sh signflow-db-backup.sh; do
    if [[ -f "$SRC_DIR/$f" ]]; then
        cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
        chmod +x "$INSTALL_DIR/$f"
    else
        warn "$f not found next to the installer — it will appear at the first update."
    fi
done
chmod +x "$INSTALL_DIR/postgres-init.sh"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
cd "$INSTALL_DIR"
ok "Files copied to $INSTALL_DIR"

# ── GPU access, when one was found at step 1b ────────────────────────────────
# Written to docker-compose.override.yml, which Compose loads automatically:
# `docker compose up -d` picks it up with no extra flag, including from the
# systemd unit. Only celery-media needs it — it is the ONLY service that
# transcodes (verified: app/core/encoders is imported by media_worker alone).
declare -F gpu_write_override >/dev/null 2>&1 && gpu_write_override

# ── Where the media are stored ───────────────────────────────────────────────
# ⚠️ ASKED BEFORE THE .env IS WRITTEN, and not with the other prompts further
# down: the value is written INTO the .env by the next step. Placed after it,
# the variable would still be empty at write time and every installation would
# silently fall back to the system disk — the exact problem this solves.
#
# Media live in MinIO. Left alone, MinIO writes into a named Docker volume, i.e.
# under /var/lib/docker on the SYSTEM disk — the worst possible place for the
# one dataset that grows without bound. A signage library reaches hundreds of
# gigabytes; the system disk is usually the smallest one in the machine.
#
# Asking now, before anything is created, is the only cheap moment: once MinIO
# has written its first object, moving the store means stopping the stack and
# copying the data across by hand.
if [[ -z "${MEDIA_DATA_PATH:-}" ]]; then
    echo ""
    info "Where should MEDIA be stored? (videos, images — this is what grows)"
    echo "    Leave empty for the default. Point it at a large disk if you have one."
    ask MEDIA_DATA_PATH "    Path [/var/lib/signflow/media]: " "/var/lib/signflow/media"
fi

[[ "$MEDIA_DATA_PATH" = /* ]] || fail "Media path must be absolute: '${MEDIA_DATA_PATH}'"
# Docker does NOT create the directory for an `o: bind` volume: it fails with an
# unhelpful error at first start. Create it here.
mkdir -p "$MEDIA_DATA_PATH" || fail "Cannot create '${MEDIA_DATA_PATH}'."

# ⚠️ MinIO stores objects on a POSIX filesystem and relies on its semantics.
# NFS and above all SMB/CIFS do not provide them reliably: the failure mode is
# not a clear error at startup but silent corruption and locking stalls under
# load. A network NAS is fine as a *block* device (iSCSI, mounted as ext4/xfs);
# it is not fine as a file share. Warn rather than refuse — the operator may
# know exactly what they are doing.
MEDIA_FSTYPE=$(findmnt -n -o FSTYPE --target "$MEDIA_DATA_PATH" 2>/dev/null || echo "")
case "$MEDIA_FSTYPE" in
    nfs|nfs4|cifs|smb3|fuse.sshfs|fuse.s3fs)
        warn "'${MEDIA_DATA_PATH}' is on a ${MEDIA_FSTYPE} share."
        warn "MinIO needs POSIX semantics that file shares do not guarantee —"
        warn "expect stalls and possible corruption. Prefer a local disk, an"
        warn "iSCSI block device, or point SignFlow at an external S3 endpoint."
        # No terminal: default to "no". Silently accepting a share that MinIO
        # cannot use reliably would trade a clear stop for data corruption later.
        ask a "    Use it anyway? [y/N] " "n"
        [[ "${a,,}" == "y" ]] || fail "Aborted — choose a local path."
        ;;
esac

MEDIA_AVAIL=$(df -BG --output=avail "$MEDIA_DATA_PATH" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$MEDIA_AVAIL" && "$MEDIA_AVAIL" -lt 50 ]]; then
    warn "Only ${MEDIA_AVAIL} GB free on '${MEDIA_DATA_PATH}' — media fill a disk fast."
fi
ok "Media stored in ${MEDIA_DATA_PATH} (${MEDIA_FSTYPE:-unknown fs}, ${MEDIA_AVAIL:-?} GB free)"

# =============================================================================
step "3/10 — Configuration (.env)"
# =============================================================================

if [[ -f .env ]]; then
    warn "Existing .env kept (delete it to regenerate the secrets)"
else
    # Every secret is random: no two installations ever share a key.
    PG_PASSWORD=$(openssl rand -hex 24)
    PG_APP_PASSWORD=$(openssl rand -hex 24)
    PG_WORKER_PASSWORD=$(openssl rand -hex 24)
    MINIO_KEY=$(openssl rand -hex 12)
    MINIO_SECRET=$(openssl rand -hex 24)
    JWT_SECRET=$(openssl rand -hex 32)
    # Fernet key: base64 of 32 bytes. A `rand -hex` value would be REJECTED at startup.
    VAULT_KEY=$(openssl rand -base64 32)

    cat > .env << EOF
# Generated by install-ubuntu.sh on $(date +%Y-%m-%d) — BACK THIS FILE UP.
# Losing CMS_VAULT_KEY makes every stored API key permanently unreadable.

SIGNFLOW_REGISTRY=${REGISTRY}
SIGNFLOW_VERSION=${VERSION}

# ── Database ──────────────────────────────────────────────────────────────────
# These variables are what matters: Compose builds the connection URLs from them.
# The roles are created with these passwords by postgres-init.sh, on the very
# first startup and only then.
POSTGRES_USER=signflow
POSTGRES_DB=signflow
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_APP_PASSWORD=${PG_APP_PASSWORD}
POSTGRES_WORKER_PASSWORD=${PG_WORKER_PASSWORD}

# ── Media storage ─────────────────────────────────────────────────────────────
# Host directory holding every media object. Chosen at install time; moving it
# later means stopping the stack and copying the data across by hand.
MEDIA_DATA_PATH=${MEDIA_DATA_PATH}
MINIO_ACCESS_KEY=${MINIO_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET}
# The address BROWSERS and PLAYERS use to download media.
# Never "localhost": every machine would end up querying itself.
MINIO_PUBLIC_ENDPOINT=${SERVER_IP}:${MINIO_PORT}
MINIO_PUBLIC_USE_SSL=false
# Which interface MinIO listens on. Written EXPLICITLY, even though it matches the
# compose default, because an exposure nobody declared is an exposure nobody reviews:
# with media served straight from :9000, this port MUST face the network or players and
# browsers cannot fetch anything. Put MinIO behind a TLS proxy (README_HTTPS.md), then
# re-run harden.sh -- it rebinds this to 127.0.0.1 once media no longer needs :9000.
# ⚠️ Docker publishes ports through its own iptables rules and BYPASSES ufw, so this
# port stays reachable whatever `ufw status` shows. harden.sh states it explicitly.
MINIO_BIND=0.0.0.0

# ── Security ──────────────────────────────────────────────────────────────────
CMS_JWT_SECRET=${JWT_SECRET}
CMS_VAULT_KEY=${VAULT_KEY}
CMS_DOCS_ENABLED=false

# ── Public addresses ──────────────────────────────────────────────────────────
PUBLIC_WEB_URL=http://${SERVER_IP}:${NGINX_PORT}
CORS_ORIGINS=["http://${SERVER_IP}:${NGINX_PORT}"]

# ── Time zone ─────────────────────────────────────────────────────────────────
# Governs how schedules and opening hours are interpreted.
SIGNFLOW_TZ=Europe/Paris

# ── Outgoing mail (optional) ──────────────────────────────────────────────────
# Empty = sending disabled; everything else keeps working.
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=noreply@example.com
SMTP_TLS=true

# ── Artificial intelligence (optional) ────────────────────────────────────────
ANTHROPIC_API_KEY=

# ── Kahall ERP integration (optional) ─────────────────────────────────────────
ERP_API_URL=
ERP_SSO_ENABLED=false

# ── Product licence ───────────────────────────────────────────────────────────
# PUBLIC key of the publisher, used to verify the licence file locally (there is
# no phone-home). Supplied with your licence. Leave empty and the server simply
# runs "unlicensed": nothing is restricted, and playback is never affected.
# The licence file itself goes to ./config/licence.json (mounted into the stack).
SIGNFLOW_LICENCE_PUBLIC_KEY=${LICENCE_PUBLIC_KEY:-}
EOF
    chmod 600 .env
    chown "$SERVICE_USER:$SERVICE_USER" .env
    ok ".env created (random secrets, mode 600)"
fi

# =============================================================================
step "4/10 — Downloading images"
# =============================================================================

if [[ -z "${SIGNFLOW_REGISTRY_USER:-}" ]]; then
    # These two have no sensible default: without them nothing can be downloaded.
    # Say so plainly instead of dying on an unanswerable prompt.
    (( NONINTERACTIVE )) && fail "SIGNFLOW_REGISTRY_USER and SIGNFLOW_REGISTRY_PASSWORD are required when there is no terminal. They come with your licence."
    echo ""
    # The prompt names the field the customer is actually looking at: their handoff sheet
    # says "Licence ID", and the same value is the `licence_id` of their licence.json.
    # Asking for a "Username" sent them hunting for something that does not exist.
    info "Image registry credentials — see the handoff sheet supplied with your licence"
    read -rp "    Licence ID (\"licence_id\" in your licence.json): " SIGNFLOW_REGISTRY_USER
    read -rsp "    Registry password: " SIGNFLOW_REGISTRY_PASSWORD
    echo ""
fi

# ── Product licence (optional at install time) ───────────────────────────────
# Verified LOCALLY against the publisher's public key — no call home, so a server
# on a closed network works exactly the same. Skipping this leaves the server
# "unlicensed": NOTHING is restricted and playback is never affected; the licence
# can be dropped in later from the banner in the interface.
mkdir -p config
chown "$SERVICE_USER:$SERVICE_USER" config
if [[ -z "${LICENCE_PUBLIC_KEY:-}" ]]; then
    echo ""
    info "Publisher public key — on your handoff sheet, under \"Clé publique de l'éditeur\""
    info "(paste it exactly as printed, literal \\n included — press Enter to skip)"
    ask LICENCE_PUBLIC_KEY "    Public key: "
fi
# ⚠️ Asked INDEPENDENTLY of the public key. It used to be nested under it, so a customer who
# could not answer the key question was never even offered to install their licence: the step
# vanished silently and the server came up unlicensed. Found on a real install, 2026-08-08.
if [[ ! -f config/licence.json ]]; then
    echo ""
    info "Path to your licence file (press Enter to drop it in later)"
    # LICENCE_FILE may also be passed as an environment variable (unattended).
    ask LICENCE_FILE "    licence.json: " "${LICENCE_FILE:-}"
    if [[ -n "${LICENCE_FILE:-}" ]]; then
        if [[ -f "$LICENCE_FILE" ]]; then
            # The server reads the file as `utf-8-sig` and tolerates a BOM, but we
            # strip it here so the file stays readable by any tool.
            sed '1s/^ï»¿//' "$LICENCE_FILE" > config/licence.json
            chown "$SERVICE_USER:$SERVICE_USER" config/licence.json
            ok "Licence installed (config/licence.json)"
        else
            warn "File not found: $LICENCE_FILE — continuing unlicensed."
        fi
    fi
fi
# A licence without the key that verifies it is inert — and nothing else would say so.
if [[ -f config/licence.json && -z "${LICENCE_PUBLIC_KEY:-}" ]]; then
    warn "Licence installed but NO public key: the server cannot verify it and will behave"
    warn "as unlicensed. Re-run with LICENCE_PUBLIC_KEY, or add SIGNFLOW_LICENCE_PUBLIC_KEY"
    warn "to /opt/signflow/.env and restart. The key is on your handoff sheet."
fi

# The .env is written at step 3, BEFORE the question above is asked — so a key
# typed here would never reach the server. Sync it now.
#
# 🔴 Same ordering, worse symptom, until 2026-08-02: the .env template read
# `${LICENCE_PUBLIC_KEY}` with no default, so under `set -u` ANY install that did
# not pass the variable in the environment died at step 3/10 with
# "unbound variable" — interactive ones included, since the question comes later.
# Present in every published version since 1.0.9 (2026-07-23); found by running
# the installer on a bare machine, never by reading it.
if [[ -n "${LICENCE_PUBLIC_KEY:-}" ]]; then
    # ⚠️ NOT with `sed`: the key is a single line containing literal `\n`
    # sequences, and sed turns those into REAL newlines in its replacement text.
    # The value then spans three lines and Compose refuses the file with
    # "key cannot contain a space". printf writes it verbatim.
    # `cat > .env` rewrites in place, so mode 600 and ownership are preserved.
    _envtmp="$(mktemp)"
    grep -v '^SIGNFLOW_LICENCE_PUBLIC_KEY=' .env > "$_envtmp" || true
    printf 'SIGNFLOW_LICENCE_PUBLIC_KEY=%s\n' "$LICENCE_PUBLIC_KEY" >> "$_envtmp"
    cat "$_envtmp" > .env
    rm -f "$_envtmp"
fi

# ── Organisation name ────────────────────────────────────────────────────────
# The organisation is what the customer sees at the top of the interface, in
# report headers and in the emails SignFlow sends. Left unasked it silently
# became "SignFlow" for everyone — our own product name on the customer's
# screens (reported by Ed, 2026-07-20).
if [[ -z "${ORG_NAME:-}" ]]; then
    echo ""
    info "Name of your organisation (shown in the interface and on reports)"
    ask ORG_NAME "    Organisation [SignFlow]: " "SignFlow"
fi

# The slug identifies the organisation in URLs and generated identifiers, so it
# has to be ASCII, lowercase, without spaces. Derived rather than asked: one less
# question, and a hand-typed slug is a reliable source of mistakes.
#
# ⚠️ `iconv //TRANSLIT` does not simply drop accents, it emits the ACCENT MARK as
# a separate character: "Média" comes out as "M'edia". Left in, that apostrophe
# becomes a separator and yields "dernoult-m-edia". The marks are therefore
# deleted BEFORE punctuation is collapsed. The bug was invisible on a name
# starting with an accent ("Éclair" → "eclair"), because the leading separator is
# stripped anyway — which is exactly why it was worth testing mid-word.
ORG_SLUG=$(echo "$ORG_NAME" \
    | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
    | tr -d "'\`^\"~" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//')
[[ -n "$ORG_SLUG" ]] || ORG_SLUG="signflow"
info "Organisation: ${ORG_NAME} (identifier: ${ORG_SLUG})"

# Asked here so every prompt happens up front, rather than stopping the install
# ten minutes later.
if [[ -z "${ADMIN_EMAIL:-}" ]]; then
    echo ""
    info "Email address for the administrator account"
    ask ADMIN_EMAIL "    Email [admin@signflow.io]: " "admin@signflow.io"
fi

# ⚠️ Reserved top-level domains (.local, .test, .invalid…) are REJECTED by the
# API's email validator. The account would be created successfully and then be
# impossible to log into: the login endpoint answers 422, and the interface
# reports "invalid credentials" — pointing at the password while the address is
# at fault. Caught on a bare-metal install; the previous default was
# admin@signflow.local, which locked every installation out of itself.
case "${ADMIN_EMAIL,,}" in
    *.local|*.localhost|*.test|*.invalid|*.example|*.internal|*.home|*.lan|*.localdomain)
        fail "'${ADMIN_EMAIL}' uses a reserved top-level domain, which the API rejects — the account could never log in. Use a real domain name."
        ;;
    *@*.*) : ;;
    *) fail "'${ADMIN_EMAIL}' is not a valid email address." ;;
esac

echo "${SIGNFLOW_REGISTRY_PASSWORD}" \
    | docker login "$REGISTRY" -u "$SIGNFLOW_REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
    || fail "Registry authentication refused — check your credentials"
ok "Authenticated with $REGISTRY"

# ── Store the same login for the OPERATOR, not just root ─────────────────────
# This script runs under sudo, so the login above landed in ROOT's
# ~/.docker/config.json. The operator (SERVICE_USER, added to the docker group)
# runs `docker compose` as THEMSELVES — and their first pull on their own, i.e.
# the first UPDATE, would die with "repository does not exist or may require
# authorization": a missing login that reads like a missing image. Storing the
# credential for them now, while the password is in hand, is what makes
# `docker compose pull` (and update.sh) just work later without a re-login.
# Best-effort: update.sh degrades gracefully if this ever fails.
if [[ "$SERVICE_USER" != "root" ]]; then
    if echo "${SIGNFLOW_REGISTRY_PASSWORD}" \
        | sudo -u "$SERVICE_USER" -H docker login "$REGISTRY" \
            -u "$SIGNFLOW_REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
        ok "Registry login also stored for $SERVICE_USER (updates need no re-login)"
    else
        warn "Could not store the registry login for $SERVICE_USER — an update may"
        warn "  ask for 'docker login ${REGISTRY}' first. Not fatal."
    fi
fi

info "Downloading (~1 GB, a few minutes depending on your connection)..."
docker compose pull --quiet || fail "Could not download the images"
ok "Images downloaded"

# =============================================================================
step "5/10 — Startup"
# =============================================================================

docker compose config >/dev/null || fail "Invalid Compose configuration"
docker compose up -d

info "Waiting for the backend (up to 60s)..."
elapsed=0; code="0"
while [[ $elapsed -lt 60 ]]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${BACKEND_PORT}/health" 2>/dev/null || echo "0")
    [[ "$code" == "200" ]] && break
    sleep 3; elapsed=$((elapsed+3))
    info "  ${elapsed}s..."
done
[[ "$code" == "200" ]] || fail "Backend unavailable after 60s — inspect with: docker compose logs backend --tail 30"
ok "Backend running"

# =============================================================================
step "6/10 — Database and storage"
# =============================================================================

docker compose exec -T backend alembic upgrade head
ok "Migrations applied"

docker compose exec -T backend python /app/scripts/create_bucket.py
ok "Media storage ready"

# ── Assistant knowledge base ─────────────────────────────────────────────────
# Without this, a fresh install ships an AI assistant that knows nothing about
# the product: `cms_doc_chunks` is empty, so every documentation lookup returns
# nothing and the assistant answers from general knowledge instead of from this
# installation's manual. Found on 2026-07-20 while auditing why a new page was
# invisible to the assistant.
#
# Embeddings go through litellm -> ollama, and ollama has to PULL its embedding
# model on first boot (a couple of minutes). We therefore wait for it, and treat
# a failure as non-fatal: the CMS itself is perfectly usable without the
# assistant, and indexing can be replayed at any time.
info "Indexing product documentation (assistant)..."
KB_WAIT=0
until docker compose exec -T litellm python3 -c         "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=5)"         >/dev/null 2>&1 || [[ $KB_WAIT -ge 180 ]]; do
    sleep 10; KB_WAIT=$((KB_WAIT + 10))
done
KB=$(docker compose exec -T backend python3 -c     "from app.services.doc_index import index_all_docs; r = index_all_docs(); print(f\"{r['files']} files, {r['chunks']} chunks, {r['embedded']} embedded, {len(r['errors'])} errors\")"     2>/dev/null | tr -d '
')
if [[ -n "$KB" && "$KB" != *", 0 embedded"* ]]; then
    ok "Assistant documentation indexed (${KB})"
else
    warn "Assistant documentation NOT indexed — the AI assistant will not know the manual."
    warn "  Replay later with:"
    warn "    docker compose exec -T backend python3 -c \"from app.services.doc_index import index_all_docs; print(index_all_docs())\""
fi

# ── Player update bundles ────────────────────────────────────────────────────
# Without this, a fresh install ships an EMPTY player version catalogue: the CMS
# updates itself but none of its players ever can, security fixes included (found
# on 2026-07-20, still true on 2026-07-27). The bundles travel as an OCI image in
# the same registry (same credentials, read-only) and are seeded into this
# server's own storage: players then download them from THEIR server, over the
# relative URL the catalogue stores. Best-effort: never fails an installation.
info "Seeding player update bundles..."
if docker pull "${REGISTRY}/signflow-player-bundles:${VERSION}" >/dev/null 2>&1; then
    BID=$(docker create "${REGISTRY}/signflow-player-bundles:${VERSION}" 2>/dev/null || true)
    if [[ -n "$BID" ]]; then
        rm -rf /tmp/sf-bundles && mkdir -p /tmp/sf-bundles
        docker cp "$BID:/bundles/." /tmp/sf-bundles/ >/dev/null 2>&1 || true
        docker rm -f "$BID" >/dev/null 2>&1 || true
        BCID=$(docker compose ps -q backend)
        if [[ -n "$BCID" ]]; then
            docker cp /tmp/sf-bundles "$BCID:/tmp/sf-bundles" >/dev/null 2>&1 || true
            SEED=$(docker compose exec -T backend python3 scripts/seed_player_bundles.py \
                       /tmp/sf-bundles 2>&1 | tail -1 | tr -d '\r')
            docker exec "$BCID" rm -rf /tmp/sf-bundles >/dev/null 2>&1 || true
            [[ -n "$SEED" ]] && ok "Player bundles: ${SEED}" \
                || warn "Player bundles not seeded — import them later from Settings > Updates."
        fi
        rm -rf /tmp/sf-bundles
    fi
else
    warn "No player bundles published for ${VERSION} — the player catalogue starts empty."
fi

# =============================================================================
step "7/10 — Health checks"
# =============================================================================

API="http://localhost:${BACKEND_PORT}/api/v1"
FAIL=0
check() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$2" 2>/dev/null || echo "0")
    # 401 is expected on protected routes: the API answers AND rejects anonymous callers.
    if [[ "$code" == "$3" ]]; then ok "$1 -> $code"
    else echo -e "${RED}    FAIL $1 -> $code (expected $3)${NC}"; FAIL=$((FAIL+1)); fi
}
# ⚠️ The trailing slash matters and is NOT uniform across endpoints: some routes
# are declared with it, some without. Calling the wrong form returns 307 or 405
# instead of 401, which looks like a failure while the API is perfectly healthy.
# The forms below are the ones that actually answer 401 — verified on a live
# installation, not assumed.
check "GET /health"    "http://localhost:${BACKEND_PORT}/health" "200"
check "GET /players"   "$API/players/"   "401"
check "GET /media"     "$API/media/"     "401"
check "GET /playlists" "$API/playlists/" "401"
check "GET /schedules" "$API/schedules"  "401"
[[ $FAIL -eq 0 ]] && ok "Health checks 5/5" || warn "$FAIL check(s) failed"

# ── Did hardware encoding actually come up? ──────────────────────────────────
# Passing the device through is not proof that it works: the driver may be too
# old, the capability missing, the node unreadable. SignFlow then falls back to
# libx264 SILENTLY — correct behaviour, but the operator would believe the
# server is encoding on GPU when it is not. So we ask the worker itself, inside
# its own container, which encoders it can really use.
if [[ "$GPU_MODE" != "none" ]] && declare -F gpu_verify >/dev/null 2>&1; then
    gpu_verify || true    # informative here: a failure must not stop the install
fi

# =============================================================================
step "8/10 — Start on boot"
# =============================================================================

cat > /etc/systemd/system/signflow.service << EOF
[Unit]
Description=SignFlow CMS
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=root
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable signflow.service >/dev/null
ok "signflow service enabled (starts on boot)"

# =============================================================================
step "9/10 — Network access (nginx)"
# =============================================================================

command -v nginx >/dev/null 2>&1 || { info "Installing nginx..."; apt-get install -y -qq nginx >/dev/null; }

cat > /etc/nginx/sites-available/signflow << NGINXEOF
upstream signflow_backend  { server 127.0.0.1:${BACKEND_PORT};  keepalive 32; }
upstream signflow_frontend { server 127.0.0.1:${FRONTEND_PORT}; keepalive 32; }

server {
    listen ${NGINX_PORT};
    server_name _;

    location /health {
        proxy_pass         http://signflow_backend;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        access_log         off;
    }

    # No size limit: video media can run to several GB.
    client_max_body_size 0;

    location /api/v1/media/upload {
        proxy_pass              http://signflow_backend;
        proxy_http_version      1.1;
        proxy_set_header        Host              \$host;
        proxy_set_header        X-Real-IP         \$remote_addr;
        proxy_set_header        X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_request_buffering off;
        proxy_read_timeout      7200s;
        proxy_send_timeout      7200s;
    }

    location /api/ {
        proxy_pass            http://signflow_backend;
        proxy_http_version    1.1;
        proxy_set_header      Host              \$host;
        proxy_set_header      X-Real-IP         \$remote_addr;
        proxy_set_header      X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_read_timeout    300s;
        proxy_send_timeout    300s;
    }

    # Player WebSocket — long-lived connection, hence the one-hour timeout.
    location /api/v1/ws/ {
        proxy_pass         http://signflow_backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Web interface. Without this block the frontend only listens on loopback
    # and stays unreachable from the network.
    location / {
        proxy_pass            http://signflow_frontend;
        proxy_http_version    1.1;
        proxy_set_header      Host              \$host;
        proxy_set_header      X-Real-IP         \$remote_addr;
        proxy_set_header      X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto \$scheme;
        proxy_read_timeout    300s;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/signflow /etc/nginx/sites-enabled/signflow
[[ -e /etc/nginx/sites-enabled/default ]] && unlink /etc/nginx/sites-enabled/default

# ── Capacity: every screen holds a WebSocket, permanently ────────────────────
# The tuning itself lives in tune-nginx.sh, sourced here as a library. ONE
# definition, used by two paths: this installer, and update.sh on an existing
# server — a customer installed last month would otherwise have stayed at the
# distribution's ~1500-screen ceiling for ever. Called AFTER the site is
# enabled: its presence is what tells the script this nginx is ours to tune.
if [[ -f "${SRC_DIR}/tune-nginx.sh" ]]; then
    # shellcheck source=tune-nginx.sh
    source "${SRC_DIR}/tune-nginx.sh" --lib
    nginx_tune
else
    warn "tune-nginx.sh not found — nginx left at the default fleet capacity (~1500 screens)."
fi

nginx -t >/dev/null 2>&1 || fail "Invalid nginx configuration"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "Interface reachable on port ${NGINX_PORT}"

if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow ${NGINX_PORT}/tcp >/dev/null
    ufw allow ${MINIO_PORT}/tcp >/dev/null
    ok "Firewall rules added (${NGINX_PORT}, ${MINIO_PORT})"
fi

# =============================================================================
step "10/10 — Organisation and administrator account"
# =============================================================================
# bootstrap.py is not idempotent: run it only when the database is still empty.

EXISTING=$(docker compose exec -T postgres psql -U signflow -d signflow -tAc \
    "SELECT count(*) FROM cms_users;" 2>/dev/null | tr -d '[:space:]' || echo "")

ADMIN_PASSWORD=""
TOTP_SECRET=""
TOTP_URI=""
if [[ "$EXISTING" == "0" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)aA1!"
    if docker compose exec -T \
        -e BOOTSTRAP_ADMIN_EMAIL="${ADMIN_EMAIL}" \
        -e BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        -e BOOTSTRAP_ORG_NAME="${ORG_NAME}" \
        -e BOOTSTRAP_ORG_SLUG="${ORG_SLUG}" \
        backend python3 /app/scripts/bootstrap.py >/dev/null; then
        ok "Organisation and administrator account created"

        # An organisation-admin account has two-factor authentication ENFORCED.
        # Without the enrolment details below, the operator holds a password that
        # cannot be used and the installation ends locked out of itself.
        # reveal_totp_secret() is used rather than the raw column so this keeps
        # working if secrets are encrypted at rest.
        TOTP_OUT=$(docker compose exec -T -e SF_EMAIL="$ADMIN_EMAIL" backend python3 - <<'PYEOF' 2>/dev/null || true
import asyncio, os
import pyotp
from sqlalchemy import select
from app.db.session import WorkerSessionLocal
from app.models.user import CmsUser
from app.models.organization import CmsOrganization
from app.services.totp import reveal_totp_secret

async def main() -> None:
    email = os.environ["SF_EMAIL"]
    async with WorkerSessionLocal() as db:
        user = (await db.execute(select(CmsUser).where(CmsUser.email == email))).scalar_one_or_none()
        if user is None or not user.totp_secret:
            return
        org = (await db.execute(
            select(CmsOrganization.org_name).where(CmsOrganization.id_org == user.id_org)
        )).scalar_one_or_none() or "SignFlow"
        secret = reveal_totp_secret(user.totp_secret)
        print(secret)
        print(pyotp.TOTP(secret).provisioning_uri(name=email, issuer_name=org))

asyncio.run(main())
PYEOF
)
        TOTP_SECRET=$(echo "$TOTP_OUT" | sed -n '1p' | tr -d '\r')
        TOTP_URI=$(echo "$TOTP_OUT" | sed -n '2p' | tr -d '\r')
        [[ -n "$TOTP_SECRET" ]] && ok "Two-factor enrolment retrieved" \
            || warn "Could not read the 2FA enrolment — see the note at the end"
    else
        ADMIN_PASSWORD=""
        warn "Bootstrap failed — run it again with:"
        warn "  cd ${INSTALL_DIR} && docker compose exec -T backend python3 /app/scripts/bootstrap.py"
    fi
elif [[ -n "$EXISTING" ]]; then
    info "Database already initialised (${EXISTING} user(s)) — step skipped"
else
    warn "Could not determine database state — bootstrap skipped as a precaution"
fi

# =============================================================================
echo ""
echo -e "${GREEN}  ==============================================${NC}"
echo -e "${GREEN}   SIGNFLOW IS INSTALLED${NC}"
echo -e "${GREEN}  ==============================================${NC}"
echo ""
echo -e "   Web interface   : ${CYAN}http://${SERVER_IP}:${NGINX_PORT}${NC}"
if [[ -n "$ADMIN_PASSWORD" ]]; then
echo ""
echo -e "   ${YELLOW}Administrator credentials — WRITE THESE DOWN, they are shown only once:${NC}"
echo -e "     Organisation : ${ORG_NAME}"
echo -e "     Email    : ${ADMIN_EMAIL}"
echo -e "     Password : ${ADMIN_PASSWORD}"
echo ""
if [[ -n "$TOTP_SECRET" ]]; then
echo -e "   ${YELLOW}Two-factor authentication is REQUIRED for this account.${NC}"
echo -e "   Add it to your authenticator app NOW — you cannot log in without it:"
echo -e "     Key : ${CYAN}${TOTP_SECRET}${NC}"
echo -e "     URI : ${TOTP_URI}"
else
echo -e "   ${YELLOW}Two-factor authentication is REQUIRED for this account.${NC}"
echo -e "   Retrieve the enrolment key with:"
echo -e "     cd ${INSTALL_DIR} && docker compose exec -T -e SHOW_TOTP_EMAIL=${ADMIN_EMAIL} \\"
echo -e "       backend python3 /app/scripts/show_totp.py"
fi
fi
echo ""
case "$GPU_MODE" in
    nvidia) echo -e "   Video encoding  : ${GREEN}NVIDIA GPU (NVENC)${NC}" ;;
    dri)    echo -e "   Video encoding  : ${GREEN}Intel/AMD GPU (VAAPI/QuickSync)${NC}" ;;
    none)   echo -e "   Video encoding  : CPU (libx264) — no usable GPU found" ;;
esac
echo ""
echo -e "   Player configuration:"
echo -e "     BACKEND_URL = http://${SERVER_IP}:${NGINX_PORT}"
echo ""
echo -e "   Logs            : cd ${INSTALL_DIR} && docker compose logs -f backend"
echo -e "   Stop / start    : sudo systemctl stop signflow / sudo systemctl start signflow"
echo -e "   Update          : cd ${INSTALL_DIR} && bash update.sh <version>   (e.g. ${VERSION})"
echo ""
echo -e "   ${YELLOW}About sudo:${NC} systemctl always needs it. The docker commands do NOT,"
echo -e "   because ${SERVICE_USER} was added to the 'docker' group. Any other account"
echo -e "   must either join that group or prefix docker with sudo."
echo ""
if [[ -n "${DOCKER_GROUP_ADDED:-}" ]]; then
echo -e "   ${YELLOW}Log out and back in${NC} before running docker commands as ${SERVICE_USER}:"
echo -e "   until then they fail with \"permission denied\" and need sudo."
echo ""
fi
echo -e "   ${YELLOW}Back up ${INSTALL_DIR}/.env${NC} — it holds this installation's encryption keys."
echo ""

# ── Security hardening (firewall + key-only SSH + fail2ban) ──────────────────
# Strongly recommended for any server reachable from the Internet (port-forward
# or DMZ). Safe: SSH stays allowed, and password login is only disabled if a key
# is already installed (so a password-only session is never locked out).
if [[ -f "$INSTALL_DIR/harden.sh" ]]; then
    DO_HARDEN="${SIGNFLOW_HARDEN:-}"
    if [[ -z "$DO_HARDEN" ]]; then
        ask DO_HARDEN "Apply the recommended security hardening now (firewall + key-only SSH + fail2ban)? [Y/n] " "y"
    fi
    if [[ "${DO_HARDEN,,}" == "y" || "${DO_HARDEN,,}" == "yes" ]]; then
        bash "$INSTALL_DIR/harden.sh" || warn "Hardening did not complete cleanly — review the output above."
    else
        echo -e "   Skipped. Run it any time: ${CYAN}cd ${INSTALL_DIR} && sudo bash harden.sh${NC}"
    fi
fi
echo ""

# ── Optional: automatic daily DATABASE backup to external storage ────────────
# Unattended: set SIGNFLOW_BACKUP_DIR to configure it, leave it unset to skip.
# This was the LAST unguarded prompt: it turned a fully successful unattended
# install into exit code 1, which any automation reads as a failure.
if [[ -n "${SIGNFLOW_BACKUP_DIR:-}" ]]; then
    SETUP_BAK="y"
else
    ask SETUP_BAK "Set up an automatic daily DATABASE backup now? (requires storage EXTERNAL to this server) [y/N] " "n"
fi
if [[ "${SETUP_BAK,,}" == "y" ]]; then
    ask BAK_DIR "  Backup directory (mounted NAS share or external disk, e.g. /mnt/nas/signflow): " "${SIGNFLOW_BACKUP_DIR:-}"
    ask BAK_RET "  Keep how many days? [14]: " "${SIGNFLOW_BACKUP_RETENTION:-14}"
    if [[ -z "$BAK_DIR" ]] || ! ( cd "$INSTALL_DIR" && bash setup-backup.sh --user "$SERVICE_USER" --dir "$BAK_DIR" --retention "${BAK_RET:-14}" ); then
        echo -e "   ${YELLOW}Backup not configured.${NC} Set it up later: cd ${INSTALL_DIR} && bash setup-backup.sh"
    fi
else
    echo -e "   No automatic backup. Set one up any time: cd ${INSTALL_DIR} && bash setup-backup.sh"
    echo -e "   (A one-off dump into ${INSTALL_DIR}/db-snapshots/ still runs before every update's migrations.)"
fi
echo ""
