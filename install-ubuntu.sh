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
VERSION="${SIGNFLOW_VERSION:-1.0.0}"

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
