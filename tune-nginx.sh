#!/usr/bin/env bash
# =============================================================================
#  SignFlow CMS — nginx capacity for a large fleet
#
#  Usage:  sudo bash tune-nginx.sh            apply the tuning (idempotent)
#          sudo bash tune-nginx.sh --status   what nginx is really configured for
#          sudo bash tune-nginx.sh --off      restore the file as it was before us
#
#  A player is not a visitor who comes and goes: it holds ONE WebSocket open
#  24/7. nginx proxies it, and a proxied WebSocket costs TWO connections — one
#  to the player, one to the backend. Ubuntu ships `worker_connections 768`, so
#  with the usual 4 workers the fleet hits a wall at roughly 1500 screens.
#  Measured on the bench, 2026-08-02: 164 refusals at 1600 connections while the
#  machine was still at 30% CPU. That ceiling fell right in the middle of the
#  500-1000 and 1000+ tiers our own sizing guide sells, and it had nothing to do
#  with the hardware.
#
#  ⚠️ `worker_connections` lives in the `events` block, and conf.d/ is included
#  inside `http` — so this CANNOT be shipped as a drop-in. The distribution's
#  own file has to be patched. We do it idempotently, keep a backup, verify with
#  `nginx -t`, and roll back if the test fails.
#
#  Why this exists as its own script: the tuning used to live only inside
#  install-ubuntu.sh, so it reached NEW installations only. A customer installed
#  last month would have stayed at ~1500 screens for ever, because update.sh
#  refreshes our files but never touched a distribution file. install-ubuntu.sh
#  now sources this one, and update.sh runs it — a single definition, reaching
#  both paths. (Same blind spot as harden.sh and the un-reindexed KB.)
# =============================================================================
set -euo pipefail

NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
NGINX_BAK="${NGINX_CONF}.signflow.bak"
# The site file we write at install time. Its presence is what tells us this
# nginx is OURS to tune: on a server where nginx fronts something else entirely
# and SignFlow sits behind another proxy, we have no business editing it.
SIGNFLOW_SITE="${SIGNFLOW_SITE:-/etc/nginx/sites-enabled/signflow}"

WANT_CONNECTIONS="${SIGNFLOW_NGINX_CONNECTIONS:-8192}"
WANT_NOFILE="${SIGNFLOW_NGINX_NOFILE:-65535}"

# When sourced by install-ubuntu.sh these already exist — do not clobber them.
if ! declare -F ok >/dev/null 2>&1; then
    _R='\033[0;31m'; _G='\033[0;32m'; _Y='\033[1;33m'; _C='\033[0;36m'; _N='\033[0m'
    step()  { echo -e "\n${_C}[$(date +%H:%M:%S)] $*${_N}"; }
    ok()    { echo -e "${_G}    OK  $*${_N}"; }
    warn()  { echo -e "${_Y}    !!  $*${_N}"; }
    fail()  { echo -e "${_R}    ERR $*${_N}"; exit 1; }
    info()  { echo -e "    ..  $*"; }
fi

# Reads a directive's current value; empty when the directive is absent.
_nginx_value() {
    local key="$1"
    grep -oPm1 "^\s*${key}\s+\K[0-9]+" "$NGINX_CONF" 2>/dev/null || true
}

# ── Apply ────────────────────────────────────────────────────────────────────
# Returns 0 in every case that is not a real failure: no nginx, not ours, or
# already correct. An update must never be aborted by this.
nginx_tune() {
    if ! command -v nginx >/dev/null 2>&1; then
        info "nginx not installed — nothing to tune."
        return 0
    fi
    if [[ ! -f "$NGINX_CONF" ]]; then
        warn "$NGINX_CONF not found — nginx tuning skipped."
        return 0
    fi
    # Installer path: the site is written just before we are called, so it is
    # already there. Update path: no site means this nginx serves someone else.
    if [[ ! -e "$SIGNFLOW_SITE" ]] && [[ "${SIGNFLOW_NGINX_FORCE:-0}" != "1" ]]; then
        info "nginx is not fronting SignFlow here — left untouched."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        warn "Tuning nginx needs root — run: sudo bash tune-nginx.sh"
        return 0
    fi

    local cur_conn cur_nofile
    cur_conn=$(_nginx_value worker_connections)
    cur_nofile=$(_nginx_value worker_rlimit_nofile)
    if [[ "$cur_conn" == "$WANT_CONNECTIONS" && "$cur_nofile" == "$WANT_NOFILE" ]]; then
        ok "nginx already tuned for a large fleet (${WANT_CONNECTIONS} connections/worker)"
        return 0
    fi

    # Two different backups, on purpose:
    #  - .signflow.bak is the ORIGINAL, kept once (cp -n) so --off can always go
    #    back to the file as the distribution shipped it;
    #  - the temp copy is the state RIGHT NOW, which is what we must restore if
    #    our edit breaks the config. Rolling back to the original instead would
    #    silently discard everything the operator changed since installation.
    cp -n "$NGINX_CONF" "$NGINX_BAK" 2>/dev/null || true
    local before
    before=$(mktemp)
    cp "$NGINX_CONF" "$before"

    # The master process runs as root and can raise the soft limit up to the
    # hard one. Without this, worker_connections is promised and not honoured.
    if [[ -n "$cur_nofile" ]]; then
        sed -i -E "s/^\s*worker_rlimit_nofile.*/worker_rlimit_nofile ${WANT_NOFILE};/" "$NGINX_CONF"
    else
        sed -i -E "/^\s*worker_processes/a worker_rlimit_nofile ${WANT_NOFILE};" "$NGINX_CONF"
    fi

    if [[ -n "$cur_conn" ]]; then
        sed -i -E "s/^(\s*)worker_connections.*/\1worker_connections ${WANT_CONNECTIONS};/" "$NGINX_CONF"
    else
        # Absent from a customised file: put it inside the events block, which
        # is the only place nginx accepts it.
        sed -i -E "/^\s*events\s*\{/a \\        worker_connections ${WANT_CONNECTIONS};" "$NGINX_CONF"
    fi

    if ! nginx -t >/dev/null 2>&1; then
        cp "$before" "$NGINX_CONF"; rm -f "$before"
        warn "nginx rejected the tuned configuration — restored it unchanged."
        warn "Fleet capacity stays at the default (~1500 screens)."
        return 0
    fi
    rm -f "$before"

    # Only reload when we actually changed something, and only if nginx is up:
    # at install time it is started a few lines later anyway.
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1 \
            || warn "Configuration valid but reload failed — run: sudo systemctl reload nginx"
    fi
    ok "nginx tuned for a large fleet (${WANT_CONNECTIONS} connections/worker)"
}

# ── Status ───────────────────────────────────────────────────────────────────
nginx_status() {
    echo ""
    if ! command -v nginx >/dev/null 2>&1; then
        info "nginx             : not installed"
        echo ""; return 0
    fi
    local conn nofile workers
    conn=$(_nginx_value worker_connections); conn=${conn:-unset}
    nofile=$(_nginx_value worker_rlimit_nofile); nofile=${nofile:-unset}
    workers=$(grep -oPm1 '^\s*worker_processes\s+\K\S+' "$NGINX_CONF" 2>/dev/null | tr -d ';')

    info "Fronting SignFlow : $([[ -e "$SIGNFLOW_SITE" ]] && echo yes || echo 'no (site not enabled)')"
    info "worker_processes  : ${workers:-unset}"
    info "worker_connections: ${conn}"
    info "worker_rlimit_nofile: ${nofile}"
    if [[ "$conn" == "unset" || "$conn" -lt "$WANT_CONNECTIONS" ]] 2>/dev/null; then
        # A proxied WebSocket costs two connections, so the screen count is half.
        warn "Below the recommended ${WANT_CONNECTIONS} — run 'sudo bash tune-nginx.sh' before"
        warn "growing the fleet: each screen costs TWO connections through the proxy."
    else
        ok "Tuned for a large fleet"
    fi
    echo ""
}

# ── Revert ───────────────────────────────────────────────────────────────────
nginx_untune() {
    [[ $EUID -eq 0 ]] || fail "Needs root — run: sudo bash tune-nginx.sh --off"
    [[ -f "$NGINX_BAK" ]] || fail "No backup at ${NGINX_BAK} — nothing to restore."
    cp "$NGINX_CONF" "${NGINX_CONF}.before-off.$(date +%Y%m%d-%H%M%S)"
    cp "$NGINX_BAK" "$NGINX_CONF"
    if nginx -t >/dev/null 2>&1; then
        systemctl is-active --quiet nginx 2>/dev/null && systemctl reload nginx >/dev/null 2>&1 || true
        ok "Original nginx configuration restored."
    else
        fail "The restored file does not pass 'nginx -t' — inspect ${NGINX_CONF}."
    fi
}

# Sourced as a library by install-ubuntu.sh: define the functions and stop.
[[ "${1:-}" == "--lib" ]] && return 0 2>/dev/null

case "${1:-}" in
    ""|--on|on)      nginx_tune ;;
    --off|off)       nginx_untune ;;
    --status|status) nginx_status ;;
    -h|--help)
        sed -n '2,29p' "$0" | sed 's/^#\s\?//'
        ;;
    *) echo "usage: sudo bash tune-nginx.sh [--on|--off|--status]"; exit 1 ;;
esac
