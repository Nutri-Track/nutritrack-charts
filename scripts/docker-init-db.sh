#!/bin/bash
# =============================================================================
# PostgreSQL DB Init Script for Docker Compose
# =============================================================================
# This script runs automatically as a docker-entrypoint-initdb.d script
# during the first initialization of the PostgreSQL container.
#
# It creates:
#   - 4 databases (auth_db, food_db, macro_db, compliance_db)
#   - 4 dedicated users with readWrite access to their respective databases
# =============================================================================

set -e

echo "[init] Starting NutriTrack database bootstrap..."

# ── Helper function ──────────────────────────────────────────────────────────
create_db_and_user() {
  local DB_NAME="$1"
  local DB_USER="$2"
  local DB_PASS="$3"

  echo "[init] Creating database '${DB_NAME}' and user '${DB_USER}'..."

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    -- Create database
    SELECT 'CREATE DATABASE ${DB_NAME}' WHERE NOT EXISTS (
      SELECT FROM pg_database WHERE datname = '${DB_NAME}'
    );
EOSQL

  psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "postgres" \
    -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null || true

  # Create user
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
      ELSE
        ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';
      END IF;
    END
    \$\$;
EOSQL

  # Grant privileges
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${DB_NAME}" \
    -c "GRANT ALL ON SCHEMA public TO ${DB_USER};"

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${DB_NAME}" \
    -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};"

  echo "[init] ✓ Database '${DB_NAME}' → user '${DB_USER}' ready."
}

# ── Create all databases and users ───────────────────────────────────────────
create_db_and_user "${AUTH_DB_NAME:-auth_db}"             "${AUTH_DB_USER:-auth_user}"             "${AUTH_DB_PASSWORD:-auth_pass}"
create_db_and_user "${FOOD_DB_NAME:-food_db}"             "${FOOD_DB_USER:-food_user}"             "${FOOD_DB_PASSWORD:-food_pass}"
create_db_and_user "${MACRO_DB_NAME:-macro_db}"           "${MACRO_DB_USER:-macro_user}"           "${MACRO_DB_PASSWORD:-macro_pass}"
create_db_and_user "${COMPLIANCE_DB_NAME:-compliance_db}" "${COMPLIANCE_DB_USER:-compliance_user}" "${COMPLIANCE_DB_PASSWORD:-compliance_pass}"

echo "[init] ══════════════════════════════════════════════════════════"
echo "[init] Bootstrap complete. All databases and users are ready."
echo "[init] ══════════════════════════════════════════════════════════"
