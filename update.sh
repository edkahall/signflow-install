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
# Where the STATIC client files live (compose, configs, this very script). The
# public install repo, tracking the latest published release.
BASE_URL="${SIGNFLOW_INSTALL_BASE_URL:-https://raw.githubusercontent.com/edkahall/signflow-install/main}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "\n${CYAN}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC}   $*"; }
warn() { echo -e "  ${YELLOW}!!${NC}   $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*" >&2; exit 1; }

[[ -n "$VERSION" ]] || fail "Missing version. Example: bash update.sh 1.0.5"
[[ -f docker-compose.yml && -f .env ]] \
    || fail "Run this from the installation directory (/opt/signflow)."

# ── 0. Self-refresh ──────────────────────────────────────────────────────────
# The images are versioned in the registry, but the STATIC files (this script,
# docker-compose.yml, configs) are not — they live in the install repo. Without
# this, a release that changes the compose plumbing never reaches an existing
# install: the images update but the container keeps the old wiring. That is
# exactly how a 1.0.6 backend ended up still reporting version "dev" — its
# compose predated the SIGNFLOW_VERSION passthrough. So before anything, pull the
# newest version of THIS script and re-exec it once if it changed.
if [[ -z "${SIGNFLOW_SELF_REFRESHED:-}" ]]; then
    if curl -fsSL "${BASE_URL}/update.sh" -o update.sh.new 2>/dev/null; then
        if ! cmp -s update.sh.new update.sh 2>/dev/null; then
            cp update.sh "update.sh.bak.$(date +%Y%m%d-%H%M%S)"
            mv update.sh.new update.sh
            chmod +x update.sh 2>/dev/null || true
            echo -e "${CYAN}==>${NC} update.sh refreshed — re-running the new version"
            SIGNFLOW_SELF_REFRESHED=1 exec bash update.sh "$VERSION"
        fi
        rm -f update.sh.new
    fi
fi

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

# ── 2b. Refresh the static deployment files ──────────────────────────────────
# docker-compose.yml (topology + env passthroughs) and the service configs are
# shipped files, not images — a release can change them (a new env var handed to
# the backend, a new service). They are meant to be replaced wholesale; local
# customisation lives in docker-compose.override.yml and .env, which we never
# touch here. Best-effort: offline, we keep what's there and warn. Each file is
# backed up before replacement.
step "Refreshing deployment files"
refresh_file() {
    local f="$1"
    curl -fsSL "${BASE_URL}/${f}" -o "${f}.new" 2>/dev/null || { warn "Could not fetch ${f} (kept current)"; rm -f "${f}.new"; return; }
    if [[ -f "$f" ]] && cmp -s "${f}.new" "$f"; then
        rm -f "${f}.new"; return   # unchanged
    fi
    [[ -f "$f" ]] && cp "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
    mv "${f}.new" "$f"
    ok "${f} updated"
}
for f in docker-compose.yml litellm-config.yaml postgres-init.sh setup-backup.sh signflow-db-backup.sh; do refresh_file "$f"; done

# ── 3. Images, containers, schema ────────────────────────────────────────────
step "Downloading images"
docker compose pull --quiet || fail "Download failed."
ok "Images downloaded"

step "Restarting services"
docker compose up -d
ok "Services restarted"

step "Applying database migrations"
sleep 15

# Pre-migration database snapshot — the local rollback point. A migration can change the
# schema irreversibly; this dump lets you restore the database if it goes wrong. It is SEPARATE
# from any external daily backup (setup-backup.sh) and always runs, whether or not the client
# configured automatic backups. Best-effort (a failure warns, never blocks) + rotated (last 3).
PG_USER=$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2 | tr -d '"'); PG_USER=${PG_USER:-signflow}
PG_DB=$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2 | tr -d '"'); PG_DB=${PG_DB:-signflow}
mkdir -p db-snapshots
SNAP="db-snapshots/pre-${VERSION}-$(date +%Y%m%d-%H%M%S).sql.gz"
if docker compose exec -T postgres pg_dump -U "$PG_USER" "$PG_DB" 2>/dev/null | gzip > "$SNAP" && [[ -s "$SNAP" ]]; then
    ok "Pre-migration snapshot: $SNAP ($(du -h "$SNAP" 2>/dev/null | cut -f1))"
    ls -1t db-snapshots/pre-*.sql.gz 2>/dev/null | tail -n +4 | xargs -r rm -f   # keep last 3
else
    rm -f "$SNAP"
    warn "Pre-migration snapshot FAILED (disk space / postgres?). Continuing — but no rollback point."
fi

docker compose exec -T backend alembic upgrade head >/dev/null 2>&1 \
    || fail "Migrations failed — restore db-snapshots/ (gunzip | psql) and roll back the .env backup."
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
