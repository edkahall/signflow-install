#!/usr/bin/env bash
# =============================================================================
#  SignFlow — update an existing installation to a pinned version
#
#      cd /opt/signflow && bash update.sh 1.0.5
#
#  WHY THIS SCRIPT EXISTS
#  The README used to describe the update as "edit .env, then pull and up".
#  That is correct but incomplete, and the two missing pieces both fail
#  SILENTLY — found on a real bench upgrade on 2026-07-20:
#
#    1. REGISTRY LOGIN. The installer runs under sudo, so `docker login` stores
#       the credentials for ROOT. The operator then runs compose as their own
#       user, which has none, and the pull dies with "repository does not exist
#       or may require authorization" — a message that sends you looking for a
#       missing image rather than a missing login.
#
#    2. DOCUMENTATION INDEX. Indexing happens at INSTALL time. An installation
#       created before that step existed keeps an AI assistant that knows
#       nothing about the product — for ever — because an update never replays
#       it, and nothing ever errors.
# =============================================================================
set -euo pipefail

VERSION="${1:-}"
REGISTRY="${SIGNFLOW_REGISTRY:-registry.dernoult.net:8443}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "\n${CYAN}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC}   $*"; }
warn() { echo -e "  ${YELLOW}!!${NC}   $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*" >&2; exit 1; }

[[ -n "$VERSION" ]] || fail "Missing version. Example: bash update.sh 1.0.5"
[[ -f docker-compose.yml && -f .env ]] \
    || fail "Run this from the installation directory (/opt/signflow)."

# ── 1. Registry access, checked BEFORE touching anything ─────────────────────
step "Checking registry access"
if ! docker pull "${REGISTRY}/signflow-backend:${VERSION}" >/dev/null 2>&1; then
    warn "Cannot pull ${REGISTRY}/signflow-backend:${VERSION}"
    warn "Most often this is a missing login for the CURRENT user, not a missing image."
    warn "Log in with the credentials supplied with your licence:"
    warn "    docker login ${REGISTRY} -u signflow-client"
    fail "Registry unreachable or version ${VERSION} does not exist."
fi
ok "Version ${VERSION} reachable"

# ── 2. Pin the version (with a backup) ───────────────────────────────────────
step "Pinning version"
cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
CURRENT=$(grep -E '^SIGNFLOW_VERSION=' .env | cut -d= -f2 || echo "?")
if grep -qE '^SIGNFLOW_VERSION=' .env; then
    sed -i "s/^SIGNFLOW_VERSION=.*/SIGNFLOW_VERSION=${VERSION}/" .env
else
    echo "SIGNFLOW_VERSION=${VERSION}" >> .env
fi
ok "${CURRENT} -> ${VERSION}"

# ── 3. Images, containers, schema ────────────────────────────────────────────
step "Downloading images"
docker compose pull --quiet || fail "Download failed."
ok "Images downloaded"

step "Restarting services"
docker compose up -d
ok "Services restarted"

step "Applying database migrations"
sleep 15
docker compose exec -T backend alembic upgrade head >/dev/null 2>&1 \
    || fail "Migrations failed — the previous .env backup lets you roll back."
ok "Schema up to date"

# ── 4. Documentation index ───────────────────────────────────────────────────
# Replayed at EVERY update: new releases add and rewrite documentation, and an
# installation predating the indexing step would otherwise never catch up.
step "Indexing product documentation (assistant)"
WAIT=0
until docker compose exec -T litellm python3 -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=5)" \
        >/dev/null 2>&1 || [[ $WAIT -ge 180 ]]; do
    sleep 10; WAIT=$((WAIT + 10))
done
KB=$(docker compose exec -T backend python3 -c \
    "from app.services.doc_index import index_all_docs; r = index_all_docs(); print(f\"{r['files']} files, {r['chunks']} chunks, {r['embedded']} embedded, {len(r['errors'])} errors\")" \
    2>/dev/null | tr -d '\r')
if [[ -n "$KB" ]]; then
    ok "Documentation indexed (${KB})"
else
    warn "Documentation NOT indexed — the assistant will not know the manual."
    warn "  Replay with:"
    warn "    docker compose exec -T backend python3 -c \"from app.services.doc_index import index_all_docs; print(index_all_docs())\""
fi

# ── 5. Did everything actually come back up? ─────────────────────────────────
# A service that stays down is worse than one that crashes: nothing reports it.
step "Checking services"
MISSING=$(comm -23 <(docker compose config --services | sort) \
                   <(docker compose ps --format '{{.Service}}' | sort -u) || true)
[[ -z "$MISSING" ]] && ok "All services running" \
    || warn "Not running: $(echo "$MISSING" | tr '\n' ' ')"

PORT=$(docker compose port backend 8000 2>/dev/null | grep -oE '[0-9]+$' | head -1)
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORT:-8000}/health" || echo 0)
[[ "$CODE" == "200" ]] && ok "API healthy" || warn "API answered ${CODE} — check: docker compose logs backend"

echo -e "\n${GREEN}SignFlow updated to ${VERSION}.${NC}\n"
