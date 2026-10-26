-- Tenants, accounts and sessions, and a tenant column on every
-- tenant-scoped table. Explained in TENANTS.md and SCHEMA.md.

-- The tenant columns are NOT NULL and existing rows would have no tenant, so
-- this migration only runs on a database without data.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM class)
       OR EXISTS (SELECT 1 FROM attribute)
       OR EXISTS (SELECT 1 FROM location)
       OR EXISTS (SELECT 1 FROM item)
       OR EXISTS (SELECT 1 FROM stock)
       OR EXISTS (SELECT 1 FROM attachment)
    THEN
        RAISE EXCEPTION 'Migration 0006 (tenants) needs a database without data; delete all classes, attributes, locations, items, stock and attachments first'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- pgcrypto, in a schema of its own that wtf_api has no access to
-- ---------------------------------------------------------------------------

CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Tenants, accounts, sessions
-- ---------------------------------------------------------------------------

CREATE TYPE privilege AS ENUM ('none', 'read_only', 'read_write');

-- An independent inventory, reached through its own hostname.
CREATE TABLE tenant (
    id       uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    name     text NOT NULL CHECK (btrim(name) <> ''),
    hostname text NOT NULL CHECK (btrim(hostname) <> '')
);

CREATE UNIQUE INDEX tenant_name_unique     ON tenant (lower(name));
CREATE UNIQUE INDEX tenant_hostname_unique ON tenant (lower(hostname));

-- A user of one tenant. The email address is the user name.
CREATE TABLE account (
    id                uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant            uuid        NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT,
    email             text        NOT NULL CHECK (btrim(email) <> ''),
    -- bcrypt hash (pgcrypto); NULL = the account can't log in.
    password_hash     text        NULL,
    data_privilege    privilege   NOT NULL DEFAULT 'none',
    model_privilege   privilege   NOT NULL DEFAULT 'none',
    account_privilege privilege   NOT NULL DEFAULT 'none',
    -- Lockout after repeated failed logins (see TENANTS.md).
    failed_logins     integer     NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    last_failed_login timestamptz NULL,

    CONSTRAINT account_tenant_id_unique UNIQUE (tenant, id)
);

CREATE UNIQUE INDEX account_email_unique ON account (tenant, lower(email));

-- A login. Only the SHA-256 hash of the token is stored.
CREATE TABLE session (
    token_hash bytea       NOT NULL PRIMARY KEY CHECK (length(token_hash) = 32),
    tenant     uuid        NOT NULL,
    account    uuid        NOT NULL,
    last_used  timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (tenant, account) REFERENCES account (tenant, id) ON DELETE CASCADE
);

CREATE INDEX session_account_id_idx ON session (account);

-- ---------------------------------------------------------------------------
-- A tenant column on every tenant-scoped table
-- ---------------------------------------------------------------------------
-- Every reference between tenant-scoped tables becomes a composite foreign
-- key (tenant, x) -> (tenant, id), so references never cross tenants.

-- Drops the single-column foreign key of p_table on p_column.
CREATE FUNCTION pg_temp.drop_foreign_key(p_table regclass, p_column name) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_name name;
BEGIN
    SELECT c.conname INTO STRICT v_name
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.conrelid = p_table
      AND c.contype = 'f'
      AND cardinality(c.conkey) = 1
      AND a.attname = p_column;
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, v_name);
END;
$$;

ALTER TABLE class            ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE attribute        ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE attribute_option ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE class_attribute  ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE item             ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE value            ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE location         ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE stock            ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE stock_value      ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;
ALTER TABLE attachment       ADD COLUMN tenant uuid NOT NULL REFERENCES tenant (id) ON DELETE RESTRICT;

ALTER TABLE class     ADD CONSTRAINT class_tenant_id_unique     UNIQUE (tenant, id);
ALTER TABLE attribute ADD CONSTRAINT attribute_tenant_id_unique UNIQUE (tenant, id);
ALTER TABLE item      ADD CONSTRAINT item_tenant_id_unique      UNIQUE (tenant, id);
ALTER TABLE location  ADD CONSTRAINT location_tenant_id_unique  UNIQUE (tenant, id);
ALTER TABLE stock     ADD CONSTRAINT stock_tenant_id_unique     UNIQUE (tenant, id);

SELECT pg_temp.drop_foreign_key('class', 'parent');
ALTER TABLE class ADD FOREIGN KEY (tenant, parent) REFERENCES class (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('attribute_option', 'attribute');
ALTER TABLE attribute_option ADD FOREIGN KEY (tenant, attribute) REFERENCES attribute (tenant, id) ON DELETE CASCADE;

SELECT pg_temp.drop_foreign_key('class_attribute', 'class');
SELECT pg_temp.drop_foreign_key('class_attribute', 'attribute');
ALTER TABLE class_attribute ADD FOREIGN KEY (tenant, class)     REFERENCES class (tenant, id)     ON DELETE CASCADE;
ALTER TABLE class_attribute ADD FOREIGN KEY (tenant, attribute) REFERENCES attribute (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('item', 'class');
ALTER TABLE item ADD FOREIGN KEY (tenant, class) REFERENCES class (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('value', 'item');
SELECT pg_temp.drop_foreign_key('value', 'attribute');
ALTER TABLE value ADD FOREIGN KEY (tenant, item)      REFERENCES item (tenant, id)      ON DELETE CASCADE;
ALTER TABLE value ADD FOREIGN KEY (tenant, attribute) REFERENCES attribute (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('location', 'parent');
ALTER TABLE location ADD FOREIGN KEY (tenant, parent) REFERENCES location (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('stock', 'item');
SELECT pg_temp.drop_foreign_key('stock', 'location');
ALTER TABLE stock ADD FOREIGN KEY (tenant, item)     REFERENCES item (tenant, id)     ON DELETE RESTRICT;
ALTER TABLE stock ADD FOREIGN KEY (tenant, location) REFERENCES location (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('stock_value', 'stock');
SELECT pg_temp.drop_foreign_key('stock_value', 'attribute');
ALTER TABLE stock_value ADD FOREIGN KEY (tenant, stock)     REFERENCES stock (tenant, id)     ON DELETE CASCADE;
ALTER TABLE stock_value ADD FOREIGN KEY (tenant, attribute) REFERENCES attribute (tenant, id) ON DELETE RESTRICT;

SELECT pg_temp.drop_foreign_key('attachment', 'item');
SELECT pg_temp.drop_foreign_key('attachment', 'stock');
SELECT pg_temp.drop_foreign_key('attachment', 'location');
SELECT pg_temp.drop_foreign_key('attachment', 'class');
ALTER TABLE attachment ADD FOREIGN KEY (tenant, item)     REFERENCES item (tenant, id)     ON DELETE CASCADE;
ALTER TABLE attachment ADD FOREIGN KEY (tenant, stock)    REFERENCES stock (tenant, id)    ON DELETE CASCADE;
ALTER TABLE attachment ADD FOREIGN KEY (tenant, location) REFERENCES location (tenant, id) ON DELETE CASCADE;
ALTER TABLE attachment ADD FOREIGN KEY (tenant, class)    REFERENCES class (tenant, id)    ON DELETE CASCADE;

CREATE INDEX class_tenant_id_idx     ON class (tenant);
CREATE INDEX attribute_tenant_id_idx ON attribute (tenant);
CREATE INDEX item_tenant_id_idx      ON item (tenant);
CREATE INDEX location_tenant_id_idx  ON location (tenant);
CREATE INDEX stock_tenant_id_idx     ON stock (tenant);

-- ---------------------------------------------------------------------------
-- Names are unique per tenant
-- ---------------------------------------------------------------------------

DROP INDEX class_sibling_name_unique;
CREATE UNIQUE INDEX class_sibling_name_unique
    ON class (tenant, parent, lower(name)) NULLS NOT DISTINCT;

DROP INDEX location_sibling_name_unique;
CREATE UNIQUE INDEX location_sibling_name_unique
    ON location (tenant, parent, lower(name)) NULLS NOT DISTINCT;

DROP INDEX attribute_name_unique;
CREATE UNIQUE INDEX attribute_name_unique ON attribute (tenant, lower(name));

-- ---------------------------------------------------------------------------
-- Tree versions per tenant
-- ---------------------------------------------------------------------------

DROP TRIGGER class_bump_data_version ON class;
DROP TRIGGER location_bump_data_version ON location;
DROP TABLE data_version;
DROP FUNCTION bump_data_version();

-- One change counter per tenant and tracked table. A missing row reads as
-- version 0; the first change creates it.
CREATE TABLE data_version (
    tenant  uuid   NOT NULL REFERENCES tenant (id) ON DELETE CASCADE,
    name    text   NOT NULL,
    version bigint NOT NULL DEFAULT 1,
    PRIMARY KEY (tenant, name)
);

-- Statement-level: bumps the counter once per tenant whose rows changed.
-- The changed rows come in the transition table changed_rows.
CREATE FUNCTION bump_data_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        UPDATE data_version SET version = version + 1 WHERE name = TG_TABLE_NAME;
        RETURN NULL;
    END IF;

    INSERT INTO data_version (tenant, name)
    SELECT DISTINCT tenant, TG_TABLE_NAME
    FROM changed_rows
    ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_insert_bump_data_version
    AFTER INSERT ON class REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER class_update_bump_data_version
    AFTER UPDATE ON class REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER class_delete_bump_data_version
    AFTER DELETE ON class REFERENCING OLD TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER class_truncate_bump_data_version
    AFTER TRUNCATE ON class
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();

CREATE TRIGGER location_insert_bump_data_version
    AFTER INSERT ON location REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER location_update_bump_data_version
    AFTER UPDATE ON location REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER location_delete_bump_data_version
    AFTER DELETE ON location REFERENCING OLD TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
CREATE TRIGGER location_truncate_bump_data_version
    AFTER TRUNCATE ON location
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
