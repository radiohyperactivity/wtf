-- Helpers that belong to no area in particular (schema util): label codes,
-- the class and location trees, the pieces every function the API calls
-- starts with, and the dry runs of changes.

CREATE SCHEMA util;

-- ---------------------------------------------------------------------------
-- Codes
-- ---------------------------------------------------------------------------

-- Hands out p_count label codes at once, and returns the first: the codes
-- are that one and the p_count - 1 after it. One counter for items,
-- locations and stock rows, so a code is unique across all three, as only
-- this function hands codes out. One write of the meta row, however many
-- codes. The row stays locked until commit, so the other creating
-- transactions wait their turn, and the codes have no gaps (a rollback
-- undoes the count).
--
-- The caller must give every code it takes to a new item, location or
-- stock row, in the same transaction: then every code up to meta.code
-- belonged to something, and code.resolve can tell a deleted thing's code
-- (410) from one never handed out (404).
CREATE FUNCTION util.take_codes(p_count integer)
RETURNS bigint
LANGUAGE sql AS $$
    UPDATE public.meta m SET code = m.code + p_count
    RETURNING m.code - p_count + 1;
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
-- The class and location trees
-- ---------------------------------------------------------------------------

-- Refuses to move class or location p_id (p_table) below p_parent when
-- p_parent is p_id itself or one of the nodes below it: the walk goes up
-- from p_parent. The move functions call it; they lock the moved node first,
-- and two moves at the same moment of each other's nodes could still make a
-- cycle, which is not locked against.
CREATE FUNCTION util.check_move(p_table text, p_id uuid, p_parent uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cycle boolean;
BEGIN
    IF p_parent IS NULL THEN
        RETURN;
    END IF;
    CASE p_table
        WHEN 'class' THEN
            WITH RECURSIVE ancestor (id) AS (
                SELECT p_parent
                UNION
                SELECT c.parent FROM public.class c JOIN ancestor a ON c.id = a.id
                WHERE c.parent IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM ancestor WHERE id = p_id) INTO v_cycle;
        WHEN 'location' THEN
            WITH RECURSIVE ancestor (id) AS (
                SELECT p_parent
                UNION
                SELECT l.parent FROM public.location l JOIN ancestor a ON l.id = a.id
                WHERE l.parent IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM ancestor WHERE id = p_id) INTO v_cycle;
    END CASE;
    IF v_cycle THEN
        PERFORM error.not_allowed(format('%s can''t be moved below itself', error.row_label(p_table, p_id)));
    END IF;
END;
$$;

-- Moves the class tree or the location tree (p_tree, 'class' or
-- 'location') on to a new version. Every function that changes a tree calls
-- it once, and last: the meta row it writes is also the one that hands out
-- label codes (util.take_codes), and stays locked until commit, so it is
-- written as late as possible, after any rewriting of items and stock rows.
-- The API gives the version with the tree, so that a client holding a copy
-- knows when to fetch it again.
CREATE FUNCTION util.bump_version(p_tree text)
RETURNS void
LANGUAGE sql AS $$
    UPDATE public.meta m
    SET class_version    = m.class_version    + CASE WHEN p_tree = 'class'    THEN 1 ELSE 0 END,
        location_version = m.location_version + CASE WHEN p_tree = 'location' THEN 1 ELSE 0 END;
$$;

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
-- returns it, for an accessor to call once, at its start. No valid session
-- is not logged in (401); a role below p_role ('viewer' < 'user' <
-- 'admin') is not allowed (403).
--
-- A session is valid while it hasn't sat unused for longer than its
-- max_idle (never, when NULL). It is written to at most once a minute, or
-- at once when it is used from an address new to it: last_used becomes
-- now, and its trail keeps the 8 addresses seen most recently. A NULL
-- address adds nothing to the trail.
CREATE FUNCTION util.session(
    p_request   public.request,
    p_role      public.role,
    OUT session bytea,          -- the token's hash: the session row's key
    OUT account uuid,
    OUT role    public.role
)
LANGUAGE plpgsql AS $$
DECLARE
    v_found record;
BEGIN
    SELECT s.token_hash, a.id AS account, a.role, s.last_used,
           (p_request).address IS NULL
           OR (p_request).address IN (SELECT (u).address FROM unnest(s.usage) u) AS known_address
    INTO v_found
    FROM public.session s
    JOIN public.account a ON a.id = s.account
    WHERE s.token_hash = util.token_hash((p_request).token)
      AND (s.max_idle IS NULL OR s.last_used > now() - s.max_idle);
    IF NOT FOUND THEN
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

-- Refuses a page of a list outside 1 to 1000 rows.
CREATE FUNCTION util.check_limit(p_limit integer)
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        PERFORM error.invalid('limit must be between 1 and 1000');
    END IF;
END;
$$;

-- p_values, the values a request gives ({"Length": 100, "Colour": null}),
-- without its JSON null entries: a null gives no value. Refused unless it is
-- a JSON object.
CREATE FUNCTION util.given_values(p_values jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_values IS NULL OR jsonb_typeof(p_values) <> 'object' THEN
        PERFORM error.invalid('values must be a JSON object, by attribute name');
    END IF;
    RETURN jsonb_strip_nulls(p_values);
END;
$$;

-- ---------------------------------------------------------------------------
-- Dry runs
-- ---------------------------------------------------------------------------
-- A change with a dry run does its work in a block of its own, and ends the
-- block with util.end_dry_run(answer): PostgreSQL then undoes everything the
-- block did, and the block's handler returns the answer it carried
-- (util.dry_run_answer). A refusal inside the block is still raised as it
-- is, so a dry run says what the change would refuse too.

-- Undoes the dry run's work, carrying p_answer out with the exception
-- (SQLSTATE WT900, which nothing else raises).
CREATE FUNCTION util.end_dry_run(p_answer jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'dry run' USING ERRCODE = 'WT900', DETAIL = p_answer::text;
END;
$$;

-- The answer a dry run carried, from the exception's detail, with
-- "dry_run": true added.
CREATE FUNCTION util.dry_run_answer(p_detail text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_detail::jsonb || '{"dry_run": true}';
$$;

-- ---------------------------------------------------------------------------
-- Building answers
-- ---------------------------------------------------------------------------

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
