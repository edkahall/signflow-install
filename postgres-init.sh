#!/bin/bash
# PostgreSQL initialisation — SignFlow
#
# Executed by the postgres image entrypoint ONLY when the data directory is
# empty, i.e. on the very first installation and never afterwards.
#
# ⚠️ WHY A .sh AND NOT A .sql: a .sql file is replayed verbatim by psql, with no
# variable substitution — role passwords would therefore be HARD-CODED in it.
# Published in a public repository, they would be identical and publicly known
# across every customer installation. This script reads them from the environment.
#
# The default values exist only to preserve compatibility with existing
# installations: any new installation MUST supply random passwords
# (install-ubuntu.sh generates them).

set -e

APP_PASSWORD="${POSTGRES_APP_PASSWORD:-signflow_app_secret}"
WORKER_PASSWORD="${POSTGRES_WORKER_PASSWORD:-signflow_worker_secret}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Required extensions
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
    CREATE EXTENSION IF NOT EXISTS "vector";          -- pgvector (AI assistant)

    -- pg_partman: date-partitioned tables (proof of play, audit, notifications).
    -- Absent from the pgvector/pgvector:pg16 image, so failing here is expected
    -- and harmless.
    DO \$\$
    BEGIN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'pg_partman unavailable (expected on this image): %', SQLERRM;
    END;
    \$\$;

    -- Application role: SUBJECT to row-level security (multi-tenant isolation).
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'signflow_app') THEN
        CREATE ROLE signflow_app LOGIN PASSWORD '${APP_PASSWORD}';
        GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO signflow_app;
      END IF;
    END
    \$\$;

    -- Worker role: BYPASSRLS — reserved for Celery workers and Alembic migrations,
    -- which must see every organisation.
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'signflow_worker') THEN
        CREATE ROLE signflow_worker BYPASSRLS LOGIN PASSWORD '${WORKER_PASSWORD}';
        GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO signflow_worker;
      END IF;
    END
    \$\$;
EOSQL

echo "SignFlow: extensions and roles initialised."
