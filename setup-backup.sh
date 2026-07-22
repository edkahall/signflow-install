#!/usr/bin/env bash
# =============================================================================
#  SignFlow - set up automatic daily DATABASE backup to external storage
# =============================================================================
#  Two ways to run it, from the installation directory (/opt/signflow):
#    - A posteriori, as the operator:            bash setup-backup.sh
#    - Non-interactively (install-ubuntu.sh, root):
#        bash setup-backup.sh --user <account> --dir <path> --retention <days>
#
#  It writes ~<user>/.config/signflow-backup/db-backup.env, installs the daily
#  backup script under ~<user>/.local/bin/, and adds a cron entry (03:30) for
#  that user. Re-runnable (idempotent).
#
#  The destination MUST be storage EXTERNAL to this server (a mounted NAS share
#  or a removable disk). A backup on the same disk as the server does not survive
#  a disk failure - the script refuses / warns if it detects that.
# =============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC}   $*"; }
warn() { echo -e "  ${YELLOW}!!${NC}   $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*" >&2; exit 1; }

TARGET_USER=""; BACKUP_DIR=""; RETENTION=14
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --dir) BACKUP_DIR="$2"; shift 2 ;;
        --retention) RETENTION="$2"; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -f docker-compose.yml && -f .env ]] || fail "Run from the installation directory (e.g. /opt/signflow)."
[[ -f signflow-db-backup.sh ]] || fail "signflow-db-backup.sh not found next to this script."
COMPOSE_DIR="$(pwd)"

# Interactive collection when not passed as arguments.
if [[ -z "$BACKUP_DIR" ]]; then
    echo "Destination for the daily database backup. This MUST be storage EXTERNAL to this server"
    echo "(a mounted NAS share such as /mnt/nas/signflow, or a mounted removable disk)."
    read -rp "Backup directory: " BACKUP_DIR
    [[ -n "$BACKUP_DIR" ]] || fail "No directory given."
    read -rp "Keep how many days of backups? [14]: " r; RETENTION=${r:-14}
fi
[[ -n "$TARGET_USER" ]] || TARGET_USER="$(id -un)"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$USER_HOME" ]] || fail "Unknown user: $TARGET_USER"

mkdir -p "$BACKUP_DIR" 2>/dev/null || fail "Cannot create $BACKUP_DIR."
[[ -w "$BACKUP_DIR" ]] || fail "$BACKUP_DIR is not writable."

# Same-disk guard: a backup on the server's own disk is worthless if that disk dies.
DEV_DATA=$(stat -c %d . 2>/dev/null || echo 0)
DEV_BAK=$(stat -c %d "$BACKUP_DIR" 2>/dev/null || echo 1)
if [[ "$DEV_DATA" == "$DEV_BAK" ]]; then
    warn "$BACKUP_DIR is on the SAME disk as the server -> it will NOT survive a disk failure."
    if [[ -t 0 ]]; then
        read -rp "     Use it anyway? [y/N] " a; [[ "${a,,}" == "y" ]] || fail "Aborted - point it at external storage."
    else
        warn "Continuing (non-interactive) - but this is not a real off-server backup."
    fi
fi

# Install config + the backup script + the cron entry, owned by the target user.
CONF_DIR="$USER_HOME/.config/signflow-backup"
BIN_DIR="$USER_HOME/.local/bin"
mkdir -p "$CONF_DIR" "$BIN_DIR"
cat > "$CONF_DIR/db-backup.env" <<EOF
BACKUP_DIR="$BACKUP_DIR"
RETENTION_DAYS=$RETENTION
COMPOSE_DIR="$COMPOSE_DIR"
EOF
cp signflow-db-backup.sh "$BIN_DIR/signflow-db-backup.sh"
chmod +x "$BIN_DIR/signflow-db-backup.sh"
chown -R "$TARGET_USER" "$CONF_DIR" "$BIN_DIR/signflow-db-backup.sh" 2>/dev/null || true

CRON_LINE="30 3 * * * $BIN_DIR/signflow-db-backup.sh >> $CONF_DIR/backup.log 2>&1"
CRON_KEEP=$( (crontab -u "$TARGET_USER" -l 2>/dev/null || true) | grep -v 'signflow-db-backup.sh' || true )
printf '%s\n%s\n' "$CRON_KEEP" "$CRON_LINE" | grep -v '^[[:space:]]*$' | crontab -u "$TARGET_USER" -

ok "Daily database backup set up for '$TARGET_USER' -> $BACKUP_DIR (kept $RETENTION days), every day at 03:30."
info "Test it now:   sudo -u $TARGET_USER $BIN_DIR/signflow-db-backup.sh"
info "Restore:       gunzip -c <dump>.sql.gz | docker compose exec -T postgres psql -U <user> <db>"
info "Disable later: crontab -u $TARGET_USER -e   (remove the signflow-db-backup.sh line)"
