#!/bin/bash
# Initialisation PostgreSQL — SignFlow
#
# Exécuté par l'entrypoint de l'image postgres UNIQUEMENT si le répertoire de
# données est vierge (donc à la première installation, jamais aux suivantes).
#
# ⚠️ POURQUOI UN .sh ET NON UN .sql : un fichier .sql est joué tel quel par psql,
# sans substitution de variables — les mots de passe des rôles y seraient donc
# ÉCRITS EN DUR. Publiés dans un dépôt public, ils seraient identiques et connus
# chez tous les clients. Ce script les lit dans l'environnement.
#
# Les valeurs par défaut ne servent qu'à préserver la compatibilité avec les
# installations existantes : toute nouvelle installation DOIT fournir des mots
# de passe aléatoires (install-ubuntu.sh les génère).

set -e

APP_PASSWORD="${POSTGRES_APP_PASSWORD:-signflow_app_secret}"
WORKER_PASSWORD="${POSTGRES_WORKER_PASSWORD:-signflow_worker_secret}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Extensions requises
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
    CREATE EXTENSION IF NOT EXISTS "vector";          -- pgvector (AI Assistant §XXVII)

    -- pg_partman : tables partitionnées par date (Proof of Play, audit, notifications).
    -- Absent de l'image pgvector/pgvector:pg16 → l'échec est tolérable et attendu.
    DO \$\$
    BEGIN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'pg_partman non disponible (attendu sur cette image) : %', SQLERRM;
    END;
    \$\$;

    -- Rôle applicatif : SOUMIS aux politiques RLS (cloisonnement multi-tenant).
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'signflow_app') THEN
        CREATE ROLE signflow_app LOGIN PASSWORD '${APP_PASSWORD}';
        GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO signflow_app;
      END IF;
    END
    \$\$;

    -- Rôle worker : BYPASSRLS — réservé aux workers Celery et aux migrations Alembic,
    -- qui doivent voir toutes les organisations.
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'signflow_worker') THEN
        CREATE ROLE signflow_worker BYPASSRLS LOGIN PASSWORD '${WORKER_PASSWORD}';
        GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO signflow_worker;
      END IF;
    END
    \$\$;
EOSQL

echo "SignFlow : extensions et rôles initialisés."
