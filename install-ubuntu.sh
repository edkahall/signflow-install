#!/usr/bin/env bash
# =============================================================================
#  SignFlow CMS — Installation sur Ubuntu
#  Usage : sudo bash install-ubuntu.sh
#
#  Installe SignFlow à partir d'IMAGES PRÉ-CONSTRUITES : aucune compilation,
#  aucun code source sur la machine.
#
#   1.  Vérifie et installe les prérequis (Docker Engine + Compose, openssl, curl)
#   2.  Copie les fichiers d'installation dans /opt/signflow
#   3.  Crée .env avec des secrets aléatoires
#   4.  S'authentifie au registre d'images et télécharge les images
#   5.  Démarre les conteneurs
#   6.  Applique les migrations et prépare le stockage
#   7.  Vérifie le bon fonctionnement (smoke test)
#   8.  Installe le démarrage automatique (systemd)
#   9.  Installe nginx en frontal (accès depuis le réseau local)
#  10.  Crée l'organisation et le compte administrateur
#
#  IDENTIFIANTS DU REGISTRE : fournis par votre fournisseur SignFlow. Ils peuvent
#  être passés par l'environnement pour une installation non interactive :
#     sudo SIGNFLOW_REGISTRY_USER=... SIGNFLOW_REGISTRY_PASSWORD=... bash install-ubuntu.sh
# =============================================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/signflow"
REGISTRY="${SIGNFLOW_REGISTRY:-registry.dernoult.net:8443}"
VERSION="${SIGNFLOW_VERSION:-1.0.0}"

# Propriétaire des fichiers de configuration : celui qui a lancé `sudo`, afin
# qu'il puisse les éditer sans être root. Repli sur root si le compte n'existe pas.
SERVICE_USER="${SIGNFLOW_USER:-${SUDO_USER:-root}}"
id -u "$SERVICE_USER" >/dev/null 2>&1 || SERVICE_USER="root"

BACKEND_PORT=8010
FRONTEND_PORT=3010
MINIO_PORT=9000
NGINX_PORT=8080      # Port d'accès depuis le réseau local (hôte, hors Docker)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()    { echo -e "${GREEN}    OK  $*${NC}"; }
warn()  { echo -e "${YELLOW}    !!  $*${NC}"; }
fail()  { echo -e "${RED}    ERR $*${NC}"; exit 1; }
info()  { echo -e "    ..  $*"; }

# =============================================================================
step "1/10 — Prérequis"
# =============================================================================

[[ $EUID -eq 0 ]] || fail "Ce script doit être lancé avec sudo"

# `command -v` ne convient pas pour un paquet sans binaire homonyme
# (ca-certificates) : dpkg répond dans tous les cas.
MISSING=""
for pkg in openssl ca-certificates curl gnupg; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING="$MISSING $pkg"
done
if [[ -n "$MISSING" ]]; then
    info "Installation des prérequis :$MISSING"
    apt-get update -qq
    apt-get install -y -qq $MISSING >/dev/null || fail "Échec de l'installation de :$MISSING"
    ok "Prérequis installés :$MISSING"
fi

# Docker depuis le dépôt officiel : celui d'Ubuntu fournit un Compose trop ancien.
if ! command -v docker >/dev/null 2>&1; then
    step "1a/10 — Installation de Docker Engine"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc || fail "Téléchargement de la clé Docker impossible"
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null \
        || fail "Échec de l'installation de Docker Engine"
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker Engine installé"
fi

docker info >/dev/null 2>&1 || fail "Le démon Docker n'est pas démarré"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ','), Compose $(docker compose version | awk '{print $4}')"

SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
SERVER_IP="${SERVER_IP:-127.0.0.1}"
info "Adresse du serveur détectée : $SERVER_IP"

# =============================================================================
step "2/10 — Fichiers d'installation"
# =============================================================================

mkdir -p "$INSTALL_DIR"
for f in docker-compose.yml postgres-init.sh litellm-config.yaml; do
    [[ -f "$SRC_DIR/$f" ]] || fail "Fichier manquant : $f (installation incomplète ?)"
    cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
chmod +x "$INSTALL_DIR/postgres-init.sh"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
cd "$INSTALL_DIR"
ok "Fichiers copiés dans $INSTALL_DIR"

# =============================================================================
step "3/10 — Configuration (.env)"
# =============================================================================

if [[ -f .env ]]; then
    warn ".env existant conservé (supprimez-le pour régénérer les secrets)"
else
    # Chaque secret est aléatoire : deux installations ne partagent jamais de clé.
    PG_PASSWORD=$(openssl rand -hex 24)
    PG_APP_PASSWORD=$(openssl rand -hex 24)
    PG_WORKER_PASSWORD=$(openssl rand -hex 24)
    MINIO_KEY=$(openssl rand -hex 12)
    MINIO_SECRET=$(openssl rand -hex 24)
    JWT_SECRET=$(openssl rand -hex 32)
    # Clé Fernet : base64 de 32 octets. Un `rand -hex` serait REFUSÉ au démarrage.
    VAULT_KEY=$(openssl rand -base64 32)

    cat > .env << EOF
# Généré par install-ubuntu.sh le $(date +%Y-%m-%d) — À SAUVEGARDER.
# La perte de CMS_VAULT_KEY rend indéchiffrables les clés API stockées.

SIGNFLOW_REGISTRY=${REGISTRY}
SIGNFLOW_VERSION=${VERSION}

# ── Base de données ───────────────────────────────────────────────────────────
# Ce sont ces variables qui font foi : le compose construit lui-même les URL de
# connexion à partir d'elles. Les rôles sont créés avec ces mots de passe par
# postgres-init.sh, au tout premier démarrage et à ce moment-là seulement.
POSTGRES_USER=signflow
POSTGRES_DB=signflow
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_APP_PASSWORD=${PG_APP_PASSWORD}
POSTGRES_WORKER_PASSWORD=${PG_WORKER_PASSWORD}

# ── Stockage des médias ───────────────────────────────────────────────────────
MINIO_ACCESS_KEY=${MINIO_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET}
# Adresse à laquelle les NAVIGATEURS et les PLAYERS téléchargent les médias.
# Jamais « localhost » : chaque poste s'interrogerait lui-même.
MINIO_PUBLIC_ENDPOINT=${SERVER_IP}:${MINIO_PORT}
MINIO_PUBLIC_USE_SSL=false

# ── Sécurité ──────────────────────────────────────────────────────────────────
CMS_JWT_SECRET=${JWT_SECRET}
CMS_VAULT_KEY=${VAULT_KEY}
CMS_DOCS_ENABLED=false

# ── Adresses publiques ────────────────────────────────────────────────────────
PUBLIC_WEB_URL=http://${SERVER_IP}:${NGINX_PORT}
CORS_ORIGINS=["http://${SERVER_IP}:${NGINX_PORT}"]

# ── Fuseau horaire ────────────────────────────────────────────────────────────
# Détermine l'interprétation des programmations et des heures d'ouverture.
SIGNFLOW_TZ=Europe/Paris

# ── Messagerie sortante (optionnel) ───────────────────────────────────────────
# Vide = envois désactivés ; le reste du produit fonctionne normalement.
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=noreply@example.com
SMTP_TLS=true

# ── Intelligence artificielle (optionnel) ─────────────────────────────────────
ANTHROPIC_API_KEY=

# ── Intégration ERP Kahall (optionnel) ────────────────────────────────────────
ERP_API_URL=
ERP_SSO_ENABLED=false
EOF
    chmod 600 .env
    chown "$SERVICE_USER:$SERVICE_USER" .env
    ok ".env créé (secrets aléatoires, droits 600)"
fi

# =============================================================================
step "4/10 — Téléchargement des images"
# =============================================================================

if [[ -z "${SIGNFLOW_REGISTRY_USER:-}" ]]; then
    echo ""
    info "Identifiants du registre d'images (fournis avec votre licence SignFlow)"
    read -rp "    Utilisateur : " SIGNFLOW_REGISTRY_USER
    read -rsp "    Mot de passe : " SIGNFLOW_REGISTRY_PASSWORD
    echo ""
fi

echo "${SIGNFLOW_REGISTRY_PASSWORD}" \
    | docker login "$REGISTRY" -u "$SIGNFLOW_REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
    || fail "Authentification au registre refusée — vérifiez les identifiants"
ok "Authentifié auprès de $REGISTRY"

info "Téléchargement (~1 Go, quelques minutes selon la connexion)..."
docker compose pull --quiet || fail "Téléchargement des images impossible"
ok "Images téléchargées"

# =============================================================================
step "5/10 — Démarrage"
# =============================================================================

docker compose config >/dev/null || fail "Configuration Compose invalide"
docker compose up -d

info "Attente du backend (60 s maximum)..."
elapsed=0; code="0"
while [[ $elapsed -lt 60 ]]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${BACKEND_PORT}/health" 2>/dev/null || echo "0")
    [[ "$code" == "200" ]] && break
    sleep 3; elapsed=$((elapsed+3))
    info "  ${elapsed}s..."
done
[[ "$code" == "200" ]] || fail "Backend indisponible après 60 s — diagnostic : docker compose logs backend --tail 30"
ok "Backend opérationnel"

# =============================================================================
step "6/10 — Base de données et stockage"
# =============================================================================

docker compose exec -T backend alembic upgrade head
ok "Migrations appliquées"

docker compose exec -T backend python /app/scripts/create_bucket.py
ok "Stockage des médias prêt"

# =============================================================================
step "7/10 — Vérification"
# =============================================================================

API="http://localhost:${BACKEND_PORT}/api/v1"
FAIL=0
check() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$2" 2>/dev/null || echo "0")
    # 401 attendu sur les routes protégées : l'API répond ET refuse l'anonyme.
    if [[ "$code" == "$3" ]]; then ok "$1 → $code"
    else echo -e "${RED}    FAIL $1 → $code (attendu $3)${NC}"; FAIL=$((FAIL+1)); fi
}
check "GET /health"    "http://localhost:${BACKEND_PORT}/health" "200"
check "GET /players"   "$API/players/"   "401"
check "GET /media"     "$API/media"      "401"
check "GET /playlists" "$API/playlists"  "401"
check "GET /schedules" "$API/schedules"  "401"
[[ $FAIL -eq 0 ]] && ok "Vérification 5/5" || warn "$FAIL contrôle(s) en échec"

# =============================================================================
step "8/10 — Démarrage automatique"
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
ok "Service signflow activé (démarrage au boot)"

# =============================================================================
step "9/10 — Accès réseau (nginx)"
# =============================================================================

command -v nginx >/dev/null 2>&1 || { info "Installation de nginx..."; apt-get install -y -qq nginx >/dev/null; }

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

    # Aucune limite de taille : les médias vidéo peuvent peser plusieurs Go.
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

    # WebSocket des players — connexion longue, d'où le timeout d'une heure.
    location /api/v1/ws/ {
        proxy_pass         http://signflow_backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Interface web. Sans ce bloc, le frontend n'écoute que sur la boucle locale
    # et reste injoignable depuis le réseau.
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
nginx -t >/dev/null 2>&1 || fail "Configuration nginx invalide"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "Interface accessible sur le port ${NGINX_PORT}"

if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow ${NGINX_PORT}/tcp >/dev/null
    ufw allow ${MINIO_PORT}/tcp >/dev/null
    ok "Règles de pare-feu ajoutées (${NGINX_PORT}, ${MINIO_PORT})"
fi

# =============================================================================
step "10/10 — Organisation et compte administrateur"
# =============================================================================
# bootstrap.py n'est pas idempotent : on ne l'exécute que si la base est vierge.

EXISTING=$(docker compose exec -T postgres psql -U signflow -d signflow -tAc \
    "SELECT count(*) FROM cms_users;" 2>/dev/null | tr -d '[:space:]' || echo "")

ADMIN_PASSWORD=""
if [[ "$EXISTING" == "0" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)aA1!"
    if docker compose exec -T \
        -e BOOTSTRAP_ADMIN_EMAIL="${ADMIN_EMAIL:-admin@signflow.local}" \
        -e BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        backend python3 /app/scripts/bootstrap.py >/dev/null; then
        ok "Organisation et compte administrateur créés"
    else
        ADMIN_PASSWORD=""
        warn "Amorçage en échec — relancez :"
        warn "  cd ${INSTALL_DIR} && docker compose exec -T backend python3 /app/scripts/bootstrap.py"
    fi
elif [[ -n "$EXISTING" ]]; then
    info "Base déjà amorcée (${EXISTING} utilisateur(s)) — étape ignorée"
else
    warn "État de la base indéterminable — amorçage ignoré par prudence"
fi

# =============================================================================
echo ""
echo -e "${GREEN}  ==============================================${NC}"
echo -e "${GREEN}   SIGNFLOW EST INSTALLÉ${NC}"
echo -e "${GREEN}  ==============================================${NC}"
echo ""
echo -e "   Interface web   : ${CYAN}http://${SERVER_IP}:${NGINX_PORT}${NC}"
if [[ -n "$ADMIN_PASSWORD" ]]; then
echo ""
echo -e "   ${YELLOW}Identifiants administrateur — NOTEZ-LES, ils ne seront plus affichés :${NC}"
echo -e "     Adresse      : ${ADMIN_EMAIL:-admin@signflow.local}"
echo -e "     Mot de passe : ${ADMIN_PASSWORD}"
fi
echo ""
echo -e "   Configuration des players :"
echo -e "     BACKEND_URL = http://${SERVER_IP}:${NGINX_PORT}"
echo ""
echo -e "   Journaux        : cd ${INSTALL_DIR} && docker compose logs -f backend"
echo -e "   Arrêt / relance : systemctl stop signflow / systemctl start signflow"
echo -e "   Mise à jour     : cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
echo ""
echo -e "   ${YELLOW}Sauvegardez ${INSTALL_DIR}/.env${NC} — il contient les clés de chiffrement."
echo ""
