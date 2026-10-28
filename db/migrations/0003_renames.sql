-- Renames (TENANTS.md): a tenant's next label code is its "code", and a
-- global quantity's or family's availability without a choice is its
-- "standard".

ALTER TABLE tenant RENAME COLUMN next_code TO code;
ALTER TABLE quantity RENAME COLUMN default_available TO standard;
ALTER TABLE unit_family RENAME COLUMN default_available TO standard;

-- Takes the next code of a tenant, for a new item, location or stock row.
-- One counter for all three tables, so a code is unique across them within
-- the tenant. The row lock makes concurrent inserts of one tenant wait for
-- each other until commit.
CREATE OR REPLACE FUNCTION next_code(p_tenant uuid) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_code bigint;
BEGIN
    UPDATE tenant SET code = code + 1 WHERE id = p_tenant
    RETURNING code - 1 INTO v_code;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'Tenant % doesn''t exist', p_tenant
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN v_code;
END;
$$;
