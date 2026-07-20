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
VERSION="${SIGNFLOW_VERSION:-1.0.1}"

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

GPU_MODE="none"

# NVIDIA — the card being present is NOT enough: without a working driver the
# container toolkit has nothing to talk to. `nvidia-smi` answering is the only
# reliable proof that the driver is loaded and healthy.
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_MODE="nvidia"
    info "NVIDIA GPU detected: $(nvidia-smi -L 2>/dev/null | head -1)"

    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        info "Installing nvidia-container-toolkit (driver untouched)"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null \
            || { warn "Could not fetch the NVIDIA key — falling back to CPU encoding"; GPU_MODE="none"; }
        if [[ "$GPU_MODE" == "nvidia" ]]; then
            curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                > /etc/apt/sources.list.d/nvidia-container-toolkit.list
            apt-get update -qq
            apt-get install -y -qq nvidia-container-toolkit >/dev/null \
                || { warn "nvidia-container-toolkit failed to install — falling back to CPU"; GPU_MODE="none"; }
        fi
    fi

    if [[ "$GPU_MODE" == "nvidia" ]]; then
        # ⚠️ `nvidia-ctk runtime configure` rewrites /etc/docker/daemon.json. The
        # change only takes effect once the Docker DAEMON is restarted — and that
        # MUST happen here, before any container exists. Doing it later would
        # restart every running container mid-installation.
        nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 \
            || { warn "nvidia-ctk configure failed — falling back to CPU"; GPU_MODE="none"; }
        if [[ "$GPU_MODE" == "nvidia" ]]; then
            systemctl restart docker
            for _ in $(seq 1 15); do docker info >/dev/null 2>&1 && break; sleep 1; done
            docker info >/dev/null 2>&1 || fail "Docker did not come back after restart."
            ok "NVIDIA runtime configured (Docker restarted)"
        fi
    fi
fi

# Intel / AMD — VAAPI and QuickSync go through the DRM render node. No package to
# install: the kernel driver ships with Ubuntu and the image already carries the
# userspace bits. Passing the device through is enough, and costs nothing when
# the encoder turns out to be unusable (SignFlow falls back on its own).
if [[ "$GPU_MODE" == "none" ]] && compgen -G "/dev/dri/renderD*" >/dev/null 2>&1; then
    GPU_MODE="dri"
    info "DRM render node detected: $(ls /dev/dri/renderD* | tr '\n' ' ')"
fi

case "$GPU_MODE" in
    nvidia) ok "Hardware encoding: NVIDIA (NVENC)" ;;
    dri)    ok "Hardware encoding: Intel/AMD (VAAPI or QuickSync)" ;;
    none)   info "No usable GPU found — encoding on CPU (libx264). Nothing is broken." ;;
esac

# =============================================================================
step "2/10 — Installation files"
# =============================================================================

mkdir -p "$INSTALL_DIR"
for f in docker-compose.yml postgres-init.sh litellm-config.yaml; do
    [[ -f "$SRC_DIR/$f" ]] || fail "Missing file: $f (incomplete download?)"
    cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
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
if [[ "$GPU_MODE" != "none" ]]; then
    if [[ -f docker-compose.override.yml ]]; then
        warn "docker-compose.override.yml already exists — left untouched."
        warn "GPU access NOT configured; merge it by hand if you want it."
    elif [[ "$GPU_MODE" == "nvidia" ]]; then
        cat > docker-compose.override.yml << 'EOF'
# Generated by install-ubuntu.sh — NVIDIA hardware encoding.
# Delete this file to go back to CPU encoding.
services:
  celery-media:
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      # ⚠️ "video" is what exposes NVENC. With the default capabilities the GPU
      # appears inside the container but the encoder is absent, and ffmpeg fails
      # with a misleading "unknown encoder h264_nvenc".
      NVIDIA_DRIVER_CAPABILITIES: video,compute,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, video]
EOF
        ok "NVIDIA access written to docker-compose.override.yml"
    else
        cat > docker-compose.override.yml << 'EOF'
# Generated by install-ubuntu.sh — Intel/AMD hardware encoding (VAAPI/QuickSync).
# Delete this file to go back to CPU encoding.
services:
  celery-media:
    devices:
      - /dev/dri:/dev/dri
EOF
        ok "DRM render node access written to docker-compose.override.yml"
    fi
    chown "$SERVICE_USER:$SERVICE_USER" docker-compose.override.yml 2>/dev/null || true
fi

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
    read -rp "    Path [/var/lib/signflow/media]: " MEDIA_DATA_PATH
    MEDIA_DATA_PATH="${MEDIA_DATA_PATH:-/var/lib/signflow/media}"
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
        read -rp "    Use it anyway? [y/N] " a
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
EOF
    chmod 600 .env
    chown "$SERVICE_USER:$SERVICE_USER" .env
    ok ".env created (random secrets, mode 600)"
fi

# =============================================================================
step "4/10 — Downloading images"
# =============================================================================

if [[ -z "${SIGNFLOW_REGISTRY_USER:-}" ]]; then
    echo ""
    info "Image registry credentials (supplied with your SignFlow licence)"
    read -rp "    Username: " SIGNFLOW_REGISTRY_USER
    read -rsp "    Password: " SIGNFLOW_REGISTRY_PASSWORD
    echo ""
fi

# Asked here so every prompt happens up front, rather than stopping the install
# ten minutes later.
if [[ -z "${ADMIN_EMAIL:-}" ]]; then
    echo ""
    info "Email address for the administrator account"
    read -rp "    Email [admin@signflow.io]: " ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@signflow.io}"
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
if [[ "$GPU_MODE" != "none" ]]; then
    HW=$(docker compose exec -T celery-media python3 -c \
        "from app.core import encoders; print(','.join(encoders.detect_hw_encoders()))" 2>/dev/null | tr -d '\r')
    if [[ -n "$HW" ]]; then
        ok "Hardware encoding active: ${HW}"
    else
        warn "GPU was passed through, but NO hardware encoder is usable."
        warn "Transcoding will run on CPU — correct, just slower."
        warn "Inspect with: docker compose exec celery-media ffmpeg -encoders | grep -E 'nvenc|vaapi|qsv'"
    fi
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
echo -e "   Stop / start    : systemctl stop signflow / systemctl start signflow"
echo -e "   Update          : cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
echo ""
if [[ -n "${DOCKER_GROUP_ADDED:-}" ]]; then
echo -e "   ${YELLOW}Log out and back in${NC} before running docker commands as ${SERVICE_USER},"
echo -e "   or they will fail with \"permission denied\" until the new group applies."
echo ""
fi
echo -e "   ${YELLOW}Back up ${INSTALL_DIR}/.env${NC} — it holds this installation's encryption keys."
echo ""
