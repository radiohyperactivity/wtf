-- Helpers that belong to no area in particular (schema util): the generic
-- rules that several tables share, typed values, label codes, and the
-- pieces every function the API calls starts with.

CREATE SCHEMA util;

-- ---------------------------------------------------------------------------
-- Typed values and codes
-- ---------------------------------------------------------------------------

-- True when the column matching p_datatype is the one that is set, and its
-- value is valid for it: an integer is whole, a url looks like http(s).
-- Shared by the datatype rules of item_value, stock_value and
-- class_attribute. That only one column is set is each table's own CHECK.
CREATE FUNCTION util.typed_value_fits(
    p_datatype public.datatype,
    p_text     text,
    p_number   numeric,
    p_date     date,
    p_boolean  boolean,
    p_option   uuid
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_datatype
        WHEN 'text'    THEN p_text    IS NOT NULL
        WHEN 'integer' THEN p_number  IS NOT NULL AND p_number = trunc(p_number)
        WHEN 'decimal' THEN p_number  IS NOT NULL
        WHEN 'date'    THEN p_date    IS NOT NULL
        WHEN 'boolean' THEN p_boolean IS NOT NULL
        WHEN 'url'     THEN p_text    IS NOT NULL AND p_text ~* '^https?://\S+$'
        WHEN 'choice'  THEN p_option  IS NOT NULL
        ELSE false
    END;
$$;

-- A label code's number as Crockford Base32 text, e.g. 32768 -> '1000'.
CREATE FUNCTION util.code_text(p_value bigint)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    v_rest     bigint := p_value;
    v_text     text := '';
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    LOOP
        v_text := substr(v_alphabet, (v_rest % 32)::integer + 1, 1) || v_text;
        v_rest := v_rest / 32;
        EXIT WHEN v_rest = 0;
    END LOOP;
    RETURN v_text;
END;
$$;

-- The number of a Crockford Base32 code. Letter case and hyphens are
-- ignored. The excluded letters I, L, O and U are refused: clients map I
-- and L to 1, and O to 0.
CREATE FUNCTION util.code_value(p_code text)
RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    v_code     text := upper(replace(p_code, '-', ''));
    v_value    bigint := 0;
    v_digit    integer;
BEGIN
    IF v_code IS NULL OR v_code = '' OR length(v_code) > 12 THEN
        PERFORM error.invalid(format('%L is not a valid code', p_code));
    END IF;
    FOR i IN 1 .. length(v_code) LOOP
        v_digit := strpos(v_alphabet, substr(v_code, i, 1)) - 1;
        IF v_digit < 0 THEN
            PERFORM error.invalid(format('%L is not a valid code', p_code));
        END IF;
        v_value := v_value * 32 + v_digit;
    END LOOP;
    RETURN v_value;
END;
$$;

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- Starts the action of a call that changes something: one row of
-- public.action, with the tenant and the account of the session the call is
-- made with (util.session), whose id is kept for the rest of this
-- transaction in the setting wtf.action, where history finds it. Returns
-- the id, which a deleting call sets as deleted on what it deletes.
CREATE FUNCTION util.begin_action(p_session record)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_action uuid;
BEGIN
    INSERT INTO public.action (tenant, account)
    VALUES (p_session.tenant, p_session.account)
    RETURNING id INTO v_action;
    PERFORM set_config('wtf.action', v_action::text, true);
    RETURN v_action;
END;
$$;

-- The same for wtfd's own maintenance of tenant p_tenant (purging deleted
-- objects, a tenant's first account): an action with no account.
CREATE FUNCTION util.begin_action(p_tenant uuid)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_action uuid;
BEGIN
    INSERT INTO public.action (tenant, account)
    VALUES (p_tenant, NULL)
    RETURNING id INTO v_action;
    PERFORM set_config('wtf.action', v_action::text, true);
    RETURN v_action;
END;
$$;

-- ---------------------------------------------------------------------------
-- Deleted rows (see api/deleting.md)
-- ---------------------------------------------------------------------------
-- Items, stock rows, locations, classes, attributes, options, attachments
-- and accounts are deleted by setting deleted to the action that deleted
-- them. Rules apply between rows that are not deleted ("live" rows); a
-- deleted row is frozen until it is restored or purged.

-- Raises error.deleted when row p_id of p_table is deleted, and locks it
-- for sharing until commit, so that it can't be deleted until this
-- transaction ends. NULL is fine: no reference. For the rules of writes
-- only, as the lock writes to the row; reads that care whether something
-- is deleted read its deleted column themselves.
CREATE FUNCTION util.check_live(p_table text, p_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted uuid;
BEGIN
    IF p_id IS NULL THEN
        RETURN;
    END IF;
    CASE p_table
        WHEN 'class'            THEN SELECT deleted INTO v_deleted FROM public.class            WHERE id = p_id FOR SHARE;
        WHEN 'location'         THEN SELECT deleted INTO v_deleted FROM public.location         WHERE id = p_id FOR SHARE;
        WHEN 'item'             THEN SELECT deleted INTO v_deleted FROM public.item             WHERE id = p_id FOR SHARE;
        WHEN 'stock'            THEN SELECT deleted INTO v_deleted FROM public.stock            WHERE id = p_id FOR SHARE;
        WHEN 'attribute'        THEN SELECT deleted INTO v_deleted FROM public.attribute        WHERE id = p_id FOR SHARE;
        WHEN 'attribute_option' THEN SELECT deleted INTO v_deleted FROM public.attribute_option WHERE id = p_id FOR SHARE;
    END CASE;
    IF v_deleted IS NOT NULL THEN
        PERFORM error.deleted(p_table, p_id);
    END IF;
END;
$$;

-- A deleted row can only be restored (deleted back to NULL, possibly with a
-- new name or place) or purged. One exception: merged_into is cleared when
-- the stock row it points to is purged.
CREATE FUNCTION util.block_change_when_deleted()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.deleted IS NOT NULL
       AND (to_jsonb(NEW) - 'merged_into') IS DISTINCT FROM (to_jsonb(OLD) - 'merged_into')
    THEN
        PERFORM error.deleted(TG_TABLE_NAME, OLD.id);
    END IF;
    RETURN NEW;
END;
$$;

-- Only for rows that are deleted, so updates of live rows cost nothing. The
-- name sorts before the other rules' (check_…), so it runs first.
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.class
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.location
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.item
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.stock
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.attribute
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.attribute_option
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.attachment
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();
CREATE TRIGGER block_change_when_deleted BEFORE UPDATE ON public.account
    FOR EACH ROW WHEN (OLD.deleted IS NOT NULL)
    EXECUTE FUNCTION util.block_change_when_deleted();

-- ---------------------------------------------------------------------------
-- The class and location trees
-- ---------------------------------------------------------------------------

-- Refuses a parent change that would make a class or location its own
-- ancestor, by walking up from the new parent. An insert can't make a
-- cycle, since nothing refers to a new row yet, and a row as its own parent
-- is the tables' CHECK (parent <> id). Two moves at the same moment of each
-- other's nodes could still make one; that is not locked against.
CREATE FUNCTION util.prevent_tree_cycle()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_cycle boolean;
BEGIN
    CASE TG_TABLE_NAME
        WHEN 'class' THEN
            WITH RECURSIVE ancestor (id) AS (
                SELECT NEW.parent
                UNION
                SELECT c.parent FROM public.class c JOIN ancestor a ON c.id = a.id
                WHERE c.parent IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM ancestor WHERE id = NEW.id) INTO v_cycle;
        WHEN 'location' THEN
            WITH RECURSIVE ancestor (id) AS (
                SELECT NEW.parent
                UNION
                SELECT l.parent FROM public.location l JOIN ancestor a ON l.id = a.id
                WHERE l.parent IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM ancestor WHERE id = NEW.id) INTO v_cycle;
    END CASE;
    IF v_cycle THEN
        RAISE EXCEPTION '% can''t be moved below itself', error.row_label(TG_TABLE_NAME, NEW.id)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER prevent_tree_cycle BEFORE UPDATE OF parent ON public.class
    FOR EACH ROW WHEN (NEW.parent IS NOT NULL AND NEW.parent IS DISTINCT FROM OLD.parent)
    EXECUTE FUNCTION util.prevent_tree_cycle();
CREATE TRIGGER prevent_tree_cycle BEFORE UPDATE OF parent ON public.location
    FOR EACH ROW WHEN (NEW.parent IS NOT NULL AND NEW.parent IS DISTINCT FROM OLD.parent)
    EXECUTE FUNCTION util.prevent_tree_cycle();

-- Moves a tenant's class tree or location tree on to a new version, once
-- per statement that changes it. The API gives the version with the tree,
-- so that a client holding a copy knows when to fetch it again. A tenant's
-- row appears with its first change; until then the version is 1, so the
-- first change makes it 2 (the column's default).
--
-- This one is for the class and location tables themselves: the table's
-- name is also the tree's name. It runs once per statement, with all the
-- changed rows in a transition table (new_rows, or old_rows for a delete),
-- and bumps each affected tenant once, however many rows changed.
CREATE FUNCTION util.bump_tree_version()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.data_version (tenant, name)
        SELECT DISTINCT r.tenant, TG_TABLE_NAME FROM old_rows r
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    ELSE
        INSERT INTO public.data_version (tenant, name)
        SELECT DISTINCT r.tenant, TG_TABLE_NAME FROM new_rows r
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    END IF;
    RETURN NULL;
END;
$$;

-- Three triggers per table, one per kind of change: a trigger with
-- transition tables only has the ones its change makes.
CREATE TRIGGER bump_tree_version_insert AFTER INSERT ON public.class
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();
CREATE TRIGGER bump_tree_version_update AFTER UPDATE ON public.class
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();
CREATE TRIGGER bump_tree_version_delete AFTER DELETE ON public.class
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();

CREATE TRIGGER bump_tree_version_insert AFTER INSERT ON public.location
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();
CREATE TRIGGER bump_tree_version_update AFTER UPDATE ON public.location
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();
CREATE TRIGGER bump_tree_version_delete AFTER DELETE ON public.location
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION util.bump_tree_version();
