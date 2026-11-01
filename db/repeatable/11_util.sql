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

-- ---------------------------------------------------------------------------
-- What every function the API calls starts with
-- ---------------------------------------------------------------------------

-- The SHA-256 of a session token, as session.token_hash stores it. Plain
-- SQL, so it is inlined where it is used.
CREATE FUNCTION util.token_hash(p_token text)
RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
    SELECT sha256(convert_to(p_token, 'UTF8'));
$$;

-- The session the call is made with: checks it, keeps it in use, and
-- returns it, for an accessor to call once, at its start. An unknown host
-- is not found (404); no valid session is not logged in (401); a role
-- below p_role ('viewer' < 'user' < 'admin') is not allowed (403).
--
-- A session is valid while its account is live and of the host's tenant,
-- and it hasn't sat unused for longer than its max_idle (never, when
-- NULL). It is written to at most once a minute, or at once when it is
-- used from an address new to it: last_used becomes now, and its trail
-- keeps the 8 addresses seen most recently. A NULL address adds nothing to
-- the trail.
CREATE FUNCTION util.session(
    p_request   public.request,
    p_role      public.role,
    OUT session bytea,          -- the token's hash: the session row's key
    OUT tenant  uuid,
    OUT account uuid,
    OUT role    public.role
)
LANGUAGE plpgsql AS $$
DECLARE
    v_found record;
BEGIN
    SELECT s.token_hash, a.tenant, a.id AS account, a.role, s.last_used,
           (p_request).address IS NULL
           OR (p_request).address IN (SELECT (u).address FROM unnest(s.usage) u) AS known_address
    INTO v_found
    FROM public.tenant t
    LEFT JOIN (public.session s
               JOIN public.account a ON a.id = s.account AND a.deleted IS NULL)
           ON a.tenant = t.id
          AND s.token_hash = util.token_hash((p_request).token)
          AND (s.max_idle IS NULL OR s.last_used > now() - s.max_idle)
    WHERE t.host = lower((p_request).host);
    IF NOT FOUND THEN
        PERFORM error.unknown_host((p_request).host);
    END IF;
    IF v_found.token_hash IS NULL THEN
        PERFORM error.unauthenticated('Not logged in, or the session has expired');
    END IF;

    IF v_found.last_used < now() - interval '1 minute' OR NOT v_found.known_address THEN
        UPDATE public.session s
        SET last_used = now(),
            usage = CASE WHEN (p_request).address IS NULL THEN s.usage ELSE ARRAY(
                        SELECT t.u FROM (
                            SELECT ((p_request).address, now())::public.session_usage AS u
                            UNION ALL
                            SELECT x FROM unnest(s.usage) x WHERE (x).address <> (p_request).address
                        ) t
                        ORDER BY (t.u).seen DESC
                        LIMIT 8) END
        WHERE s.token_hash = v_found.token_hash;
    END IF;

    IF v_found.role < p_role THEN
        PERFORM error.forbidden(format('This needs the role %s; you are %s', p_role, v_found.role));
    END IF;

    session := v_found.token_hash;
    tenant  := v_found.tenant;
    account := v_found.account;
    role    := v_found.role;
END;
$$;

-- ---------------------------------------------------------------------------
-- Checking requests
-- ---------------------------------------------------------------------------

-- p_name without the spaces around it. An empty name is refused here, with
-- a clear message, before the domain name_text would refuse it with its
-- own.
CREATE FUNCTION util.trim_and_check(p_name text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        PERFORM error.invalid('A name can''t be empty');
    END IF;
    RETURN btrim(p_name);
END;
$$;

-- p_name trimmed and checked as util.trim_and_check does, and without "/",
-- which separates the names in a path. p_kind ('class' or 'location')
-- words the message. The tables' domain path_name refuses the same; this
-- says it clearly first.
CREATE FUNCTION util.trim_and_check_path_name(p_name text, p_kind text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF strpos(p_name, '/') > 0 THEN
        PERFORM error.invalid(format(
            'A %s name can''t contain "/", which separates the names in a path: %L', p_kind, p_name));
    END IF;
    RETURN util.trim_and_check(p_name);
END;
$$;

-- Refuses a patch (a change of some fields of an object) unless it is a
-- JSON object with only keys from p_allowed, and none of the keys in
-- p_required (fields that can't be empty) set to null.
CREATE FUNCTION util.check_patch(p_patch jsonb, p_allowed text[], p_required text[])
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
        PERFORM error.invalid('A patch must be a JSON object');
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
        IF NOT v_key = ANY (p_allowed) THEN
            PERFORM error.invalid(format('Unknown field %L; allowed: %s',
                                         v_key, array_to_string(p_allowed, ', ')));
        END IF;
        IF v_key = ANY (p_required) AND jsonb_typeof(p_patch -> v_key) = 'null' THEN
            PERFORM error.invalid(format('Field %L can''t be null', v_key));
        END IF;
    END LOOP;
END;
$$;

-- Refuses a page of a list outside 1 to 1000 rows, or before the start.
CREATE FUNCTION util.check_paging(p_limit integer, p_offset integer)
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        PERFORM error.invalid('limit must be between 1 and 1000');
    END IF;
    IF p_offset IS NULL OR p_offset < 0 THEN
        PERFORM error.invalid('offset must be 0 or greater');
    END IF;
END;
$$;

-- Refuses a page size outside 1 to 1000, for the history pages, which go
-- by position (before) rather than by offset.
CREATE FUNCTION util.check_limit(p_limit integer)
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        PERFORM error.invalid('limit must be between 1 and 1000');
    END IF;
END;
$$;

-- Refuses p_values unless it is a JSON object whose keys are the ids of
-- tenant p_tenant's attributes: "invalid" (400) for a key that isn't an
-- id, a bad reference (422) for an id that isn't one of its attributes.
CREATE FUNCTION util.check_values(p_tenant uuid, p_values jsonb)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF p_values IS NULL OR jsonb_typeof(p_values) <> 'object' THEN
        PERFORM error.invalid('values must be a JSON object keyed by attribute id');
    END IF;
    SELECT e.key INTO v_key FROM jsonb_object_keys(p_values) e(key)
    WHERE e.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    LIMIT 1;
    IF FOUND THEN
        PERFORM error.invalid(format('%L is not an attribute id', v_key));
    END IF;
    SELECT e.key INTO v_key FROM jsonb_object_keys(p_values) e(key)
    WHERE NOT EXISTS (SELECT 1 FROM public.attribute a
                      WHERE a.id = e.key::uuid AND a.tenant = p_tenant)
    LIMIT 1;
    IF FOUND THEN
        PERFORM error.bad_reference('attribute', v_key::uuid);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Building answers
-- ---------------------------------------------------------------------------

-- A typed value as JSON for datatype p_datatype: the value of the column
-- that datatype uses, and for a choice its option, {id, name}, from the
-- option's row. NULL when that column is NULL.
CREATE FUNCTION util.typed_value_json(
    p_datatype public.datatype,
    p_text     text,
    p_number   numeric,
    p_date     date,
    p_boolean  boolean,
    p_option   public.attribute_option
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_datatype
        WHEN 'text'    THEN to_jsonb(p_text)
        WHEN 'url'     THEN to_jsonb(p_text)
        WHEN 'integer' THEN to_jsonb(p_number)
        WHEN 'decimal' THEN to_jsonb(p_number)
        WHEN 'date'    THEN to_jsonb(p_date)
        WHEN 'boolean' THEN to_jsonb(p_boolean)
        WHEN 'choice'  THEN CASE WHEN p_option.id IS NOT NULL
                                 THEN jsonb_build_object('id', p_option.id, 'name', p_option.name) END
    END;
$$;

-- What an object's deleted says: null while it is not deleted, and for a
-- deleted one the action that deleted it, when, and by whom ({id, email},
-- or null when wtfd itself did it). Built from the action's row and its
-- account's (NULL rows for a live object), so it queries nothing.
CREATE FUNCTION util.deleted_json(p_action public.action, p_by public.account)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_action.id IS NOT NULL THEN jsonb_build_object(
        'action',  p_action.id,
        'at',      p_action.at,
        'account', CASE WHEN p_by.id IS NOT NULL
                        THEN jsonb_build_object('id', p_by.id, 'email', p_by.email) END
    ) END;
$$;

-- A path, [{id, name}, …] from the top down, as text: "Garage/Shelf 2".
CREATE FUNCTION util.path_text(p_path jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT string_agg(e.value ->> 'name', '/' ORDER BY e.n)
    FROM jsonb_array_elements(p_path) WITH ORDINALITY AS e (value, n);
$$;

-- A column's label in a grid of compartments: 1 → A, 26 → Z, 27 → AA.
CREATE FUNCTION util.column_label(p_n integer)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n     integer := p_n;
    v_label text    := '';
BEGIN
    WHILE v_n > 0 LOOP
        v_n := v_n - 1;
        v_label := chr(ascii('A') + v_n % 26) || v_label;
        v_n := v_n / 26;
    END LOOP;
    RETURN v_label;
END;
$$;
