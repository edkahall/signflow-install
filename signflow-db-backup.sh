#!/usr/bin/env bash
# =============================================================================
#  SignFlow - daily DATABASE backup to external storage
# =============================================================================
#  Invoked by cron (installed by setup-backup.sh). Reads its destination and
#  retention from ~/.config/signflow-backup/db-backup.env, dumps the database
#  (gzip'd SQL) to that directory, then prunes dumps older than the window.
#
#  DATABASE ONLY. Media (MinIO) are a separate, much larger dataset and are NOT
#  backed up here. This protects the irreplaceable state: schema, versions
#  catalog, users, campaigns, proof-of-play, configuration.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
SignFlow — daily DATABASE backup runner

Invoked by cron (installed by setup-backup.sh). Reads its destination and retention from
~/.config/signflow-backup/db-backup.env, writes a gzip'd database dump there, then prunes
dumps older than the retention window. DATABASE ONLY (media are not included).

USAGE
  bash signflow-db-backup.sh          # normally run by cron, not by hand

SET IT UP
  bash setup-backup.sh                # creates the config + cron entry this script uses
EOF
    exit 0
fi

CONF="$HOME/.config/signflow-backup/db-backup.env"
[[ -f "$CONF" ]] || { echo "No backup config at $CONF - run setup-backup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"   # BACKUP_DIR, RETENTION_DAYS, COMPOSE_DIR

cd "$COMPOSE_DIR" || { echo "COMPOSE_DIR $COMPOSE_DIR missing" >&2; exit 1; }
# mkdir -p doubles as an "is the external mount present?" check: if the NAS/disk is
# unmounted, its mount point is usually not writable and this fails loudly (no silent
# backup onto the local disk under a stale mount point).
mkdir -p "$BACKUP_DIR" || { echo "Cannot reach $BACKUP_DIR (external storage unmounted?)" >&2; exit 1; }

PG_USER=$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2 | tr -d '"'); PG_USER=${PG_USER:-signflow}
PG_DB=$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2 | tr -d '"'); PG_DB=${PG_DB:-signflow}

TS=$(date +%Y%m%d-%H%M%S)
OUT="$BACKUP_DIR/signflow-db-$TS.sql.gz"
TMP="$OUT.part"

# Dump to a .part first, then rename: a truncated/failed dump never masquerades as a good one.
if docker compose exec -T postgres pg_dump -U "$PG_USER" "$PG_DB" | gzip > "$TMP" && [[ -s "$TMP" ]]; then
    mv "$TMP" "$OUT"
    echo "$(date '+%F %T') OK $OUT ($(du -h "$OUT" | cut -f1))"
else
    rm -f "$TMP"
    echo "$(date '+%F %T') FAIL database dump" >&2
    exit 1
fi

# Rotation: drop dumps older than the retention window (default 14 days).
find "$BACKUP_DIR" -maxdepth 1 -name 'signflow-db-*.sql.gz' -mtime +"${RETENTION_DAYS:-14}" -delete 2>/dev/null || true
