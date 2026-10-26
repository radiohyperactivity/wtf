#!/usr/bin/env bash
# Creates the roles wtf_dba and wtf_api and the test database on a fresh
# PostgreSQL server, as README.md describes ("Database setup" and "Test
# database"). Meant for throw-away servers, such as the one CI starts.
#
# Run it with superuser access through psql's usual variables (PGHOST,
# PGPORT, PGUSER, PGPASSWORD). The roles get their passwords from
# WTFD_DBA_DATABASE_PASSWORD and WTFD_API_DATABASE_PASSWORD, the same
# variables wtfd and the tests use. The database is WTFD_TEST_DATABASE_NAME
# (default wtf_test); its name must end in _test.
set -euo pipefail

: "${WTFD_DBA_DATABASE_PASSWORD:?set WTFD_DBA_DATABASE_PASSWORD}"
: "${WTFD_API_DATABASE_PASSWORD:?set WTFD_API_DATABASE_PASSWORD}"
db="${WTFD_TEST_DATABASE_NAME:-wtf_test}"
case "$db" in
*_test) ;;
*)
    echo "The test database's name must end in _test: the tests delete all its data." >&2
    exit 1
    ;;
esac

# psql replaces :'name' and :"name" with the variables given by -v, quoted
# as a string or as an identifier.
psql -v ON_ERROR_STOP=1 -v dba="$WTFD_DBA_DATABASE_PASSWORD" -v api="$WTFD_API_DATABASE_PASSWORD" \
    -v db="$db" --dbname postgres <<'SQL'
CREATE ROLE wtf_dba LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'dba';
CREATE ROLE wtf_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 50 PASSWORD :'api';
CREATE DATABASE :"db"
    OWNER           wtf_dba
    TEMPLATE        template0
    ENCODING        'UTF8'
    LOCALE_PROVIDER icu
    ICU_LOCALE      'und';
SQL

psql -v ON_ERROR_STOP=1 -v db="$db" --dbname "$db" <<'SQL'
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO wtf_api;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO wtf_api;
ALTER ROLE wtf_api IN DATABASE :"db" SET search_path = public;
ALTER ROLE wtf_dba IN DATABASE :"db" SET search_path = public;
SQL

echo "Created roles wtf_dba and wtf_api and database $db."
