-- ──────────────────────────────────────────────────────────────────────────────
-- PostgreSQL Initialization Script
-- Creates databases for each microservice
-- ──────────────────────────────────────────────────────────────────────────────

-- Create databases if they don't exist
SELECT 'CREATE DATABASE auth_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'auth_db');
\gexec

SELECT 'CREATE DATABASE food_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'food_db');
\gexec

SELECT 'CREATE DATABASE macro_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'macro_db');
\gexec

SELECT 'CREATE DATABASE compliance_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'compliance_db');
\gexec
