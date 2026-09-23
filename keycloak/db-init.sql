-- Bootstraps Keycloak's role and database on a fresh Postgres instance.
--
-- Run by `make db-init`, which connects as the RDS master user and passes
-- Keycloak's password from keycloak-secret as :kcpw.


SELECT format('CREATE ROLE keycloak LOGIN PASSWORD %L', :'kcpw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec

SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
