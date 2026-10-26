-- History: a log of every change to tenant data, and soft-deleted accounts.
-- Explained in SCHEMA.md and api/history.md.

-- ---------------------------------------------------------------------------
-- Accounts: history privilege, and deletion as a state
-- ---------------------------------------------------------------------------

ALTER TABLE account
    ADD COLUMN history_privilege privilege NOT NULL DEFAULT 'none',
    -- A deleted account keeps its row, so history can still say who did
    -- what. It can't log in, and its email can be used again.
    ADD COLUMN deleted boolean NOT NULL DEFAULT false;

-- Accounts that manage accounts may also read history.
UPDATE account SET history_privilege = 'read_only' WHERE account_privilege = 'read_write';

DROP INDEX account_email_unique;
CREATE UNIQUE INDEX account_email_unique ON account (tenant, lower(email)) WHERE NOT deleted;

-- ---------------------------------------------------------------------------
-- history
-- ---------------------------------------------------------------------------

CREATE TYPE history_operation AS ENUM ('insert', 'update', 'delete');

-- One entry per changed row.
CREATE TABLE history (
    id          bigint            NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant      uuid              NOT NULL REFERENCES tenant (id) ON DELETE CASCADE,
    -- Start of the transaction, so all changes of one API call share it.
    happened_at timestamptz       NOT NULL DEFAULT now(),
    -- Groups the entries of one transaction (e.g. a stock_move).
    transaction xid8              NOT NULL DEFAULT pg_current_xact_id(),
    -- The logged-in account; NULL for changes outside the API ("system").
    account     uuid              NULL,
    table_name  text              NOT NULL,
    operation   history_operation NOT NULL,
    -- The row after the change (before it, for a delete).
    data        jsonb             NOT NULL,
    -- Updates only: {column: {old, new}} for every changed column.
    changes     jsonb             NULL,

    FOREIGN KEY (tenant, account) REFERENCES account (tenant, id) ON DELETE RESTRICT
);

CREATE INDEX history_tenant_id_happened_at_idx ON history (tenant, happened_at);
CREATE INDEX history_account_id_idx ON history (account);

-- Row-level trigger on every tenant data table and on account. Password
-- hashes are never logged (only whether there is one, and that it changed);
-- updates that only touch the lockout counters are not logged at all.
CREATE FUNCTION record_history() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old              jsonb;
    v_new              jsonb;
    v_changes          jsonb;
    v_password_changed boolean := false;
    v_token            text := current_setting('wtf.token', true);
    v_account          uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'account' THEN
        v_password_changed := TG_OP = 'UPDATE'
            AND (v_old ->> 'password_hash') IS DISTINCT FROM (v_new ->> 'password_hash');
        v_old := v_old - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_old ->> 'password_hash') IS NOT NULL);
        v_new := v_new - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_new ->> 'password_hash') IS NOT NULL);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value))
        INTO v_changes
        FROM jsonb_each(v_new) AS n
        WHERE (v_old -> n.key) IS DISTINCT FROM n.value;
        IF v_password_changed THEN
            v_changes := COALESCE(v_changes, '{}'::jsonb) || jsonb_build_object('password', 'changed');
        END IF;
        IF v_changes IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;

    IF v_token IS NOT NULL AND v_token <> '' THEN
        SELECT s.account INTO v_account
        FROM session s
        WHERE s.token_hash = sha256(convert_to(v_token, 'UTF8'));
    END IF;

    INSERT INTO history (tenant, account, table_name, operation, data, changes)
    VALUES (COALESCE(v_new ->> 'tenant', v_old ->> 'tenant')::uuid,
            v_account,
            TG_TABLE_NAME,
            lower(TG_OP)::history_operation,
            COALESCE(v_new, v_old),
            v_changes);
    RETURN NULL;
END;
$$;

DO $$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'class', 'attribute', 'attribute_option', 'class_attribute', 'item', 'value',
        'location', 'stock', 'stock_value', 'attachment', 'account'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION record_history()',
            v_table || '_record_history', v_table);
    END LOOP;
END;
$$;
