-- Classes and their attributes (schema class): what an attribute is, how
-- values are checked against a class, how a change of a class reaches the
-- classes, items and stock rows below it, and the functions the API calls.
-- See 2026-11-02-attributes-in-json.md.
--
-- A class's attributes column holds every attribute it has, by name: its
-- own, and those it inherits, each naming the class that defines it. A
-- class's own attributes are the entries that name it. Every change of a
-- class's attributes rebuilds the column of the classes below it
-- (class.rebuild), and then checks, and where needed rewrites, the values
-- of the items and stock rows below it (class.rewrite_rows).

CREATE SCHEMA class;

-- ---------------------------------------------------------------------------
-- Attributes and values
-- ---------------------------------------------------------------------------

-- Whether p_value fits attribute definition p_def: a JSON string for text
-- (not blank), url (http or https), date (YYYY-MM-DD), choice (one of its
-- choices) and attachment (a file's hash); a JSON number for decimal, a
-- JSON integer for integer; true or false for boolean.
CREATE FUNCTION class.value_fits(p_def jsonb, p_value jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE jsonb_typeof(p_value)
        WHEN 'string' THEN CASE p_def ->> 'type'
            WHEN 'text'       THEN btrim(p_value #>> '{}') <> ''
            WHEN 'url'        THEN (p_value #>> '{}') ~* '^https?://\S+$'
            WHEN 'date'       THEN (p_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
                                   AND pg_input_is_valid(p_value #>> '{}', 'date')
            WHEN 'choice'     THEN (p_def -> 'choices') ? (p_value #>> '{}')
            WHEN 'attachment' THEN (p_value #>> '{}') ~ '^[0-9a-f]{64}$'
            ELSE false END
        WHEN 'number' THEN CASE p_def ->> 'type'
            WHEN 'decimal' THEN true
            WHEN 'integer' THEN p_value::numeric = trunc(p_value::numeric)
            ELSE false END
        WHEN 'boolean' THEN p_def ->> 'type' = 'boolean'
        ELSE false
    END;
$$;

-- What a value of attribute definition p_def must be, for messages: "an
-- integer", "one of Red, Green, Blue", ….
CREATE FUNCTION class.type_words(p_def jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_def ->> 'type'
        WHEN 'text'       THEN 'text'
        WHEN 'url'        THEN 'a web address (http or https)'
        WHEN 'integer'    THEN 'an integer'
        WHEN 'decimal'    THEN 'a number'
        WHEN 'date'       THEN 'a date (YYYY-MM-DD)'
        WHEN 'boolean'    THEN 'true or false'
        WHEN 'choice'     THEN 'one of ' || (SELECT string_agg(c, ', ' ORDER BY n)
                                             FROM jsonb_array_elements_text(p_def -> 'choices')
                                                  WITH ORDINALITY AS x (c, n))
        WHEN 'attachment' THEN 'a file'
    END;
$$;

-- p_name trimmed, as an attribute's name: not empty, at most 100
-- characters, and not the name of one of the fixed fields of items and
-- stock rows, letter case ignored, so that a name means one thing in the
-- JSON, in filters, in file routes and as a CLI flag.
CREATE FUNCTION class.check_attribute_name(p_name text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        PERFORM error.invalid('An attribute''s name can''t be empty');
    END IF;
    IF length(btrim(p_name)) > 100 THEN
        PERFORM error.invalid('An attribute''s name can be at most 100 characters');
    END IF;
    IF lower(btrim(p_name)) = ANY (ARRAY['id', 'code', 'name', 'class', 'unit', 'photo', 'item', 'location',
                                         'amount', 'reference', 'serial']) THEN
        PERFORM error.invalid(format('"%s" is the name of a fixed field of items or stock rows; '
                                     'an attribute needs another name', btrim(p_name)));
    END IF;
    RETURN btrim(p_name);
END;
$$;

-- Attribute definition p_def of attribute p_name, checked, as it is
-- stored, without the class that defines it and its order (the callers add
-- those). It takes:
--   scope     "item" or "stock", where the values live (needed)
--   type      text, integer, decimal, date, boolean, url, choice or
--             attachment (needed)
--   required  true or false (false when left out)
--   unit      a label for the values ("mm"), or null
--   default   a value that fits, or null; not for attachments
--   choices   for a choice only, and needed: its texts, at least one, each
--             once
--   media     for an attachment only, optional: the media types it takes
--             ("application/pdf", "image/*")
--   order     its place on screen among the class's attributes of its scope
CREATE FUNCTION class.check_definition(p_name text, p_def jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key  text;
    v_type text;
    v_def  jsonb;
BEGIN
    IF p_def IS NULL OR jsonb_typeof(p_def) <> 'object' THEN
        PERFORM error.invalid(format('The definition of "%s" must be a JSON object', p_name));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_def) LOOP
        IF NOT v_key = ANY (ARRAY['scope', 'type', 'required', 'unit', 'default', 'choices', 'media', 'order']) THEN
            PERFORM error.invalid(format('Unknown field %L in the definition of "%s"; allowed: '
                                         'scope, type, required, unit, default, choices, media, order',
                                         v_key, p_name));
        END IF;
    END LOOP;
    IF NOT coalesce(p_def ->> 'scope', '') = ANY (enum_range(NULL::public.scope)::text[]) THEN
        PERFORM error.invalid(format('"%s" needs its scope: item or stock', p_name));
    END IF;
    v_type := p_def ->> 'type';
    IF NOT coalesce(v_type, '') = ANY (enum_range(NULL::public.datatype)::text[]) THEN
        PERFORM error.invalid(format('"%s" needs its type: %s', p_name,
                                     array_to_string(enum_range(NULL::public.datatype)::text[], ', ')));
    END IF;
    IF jsonb_typeof(p_def -> 'required') NOT IN ('boolean', 'null') THEN
        PERFORM error.invalid(format('required of "%s" must be true or false', p_name));
    END IF;
    IF jsonb_typeof(p_def -> 'unit') = 'string' AND btrim(p_def ->> 'unit') = ''
       OR jsonb_typeof(p_def -> 'unit') NOT IN ('string', 'null') THEN
        PERFORM error.invalid(format('The unit of "%s" must be a label ("mm"), or null', p_name));
    END IF;
    IF p_def ? 'order' AND NOT (CASE jsonb_typeof(p_def -> 'order')
                                    WHEN 'number' THEN (p_def ->> 'order')::numeric = trunc((p_def ->> 'order')::numeric)
                                    ELSE jsonb_typeof(p_def -> 'order') = 'null' END) THEN
        PERFORM error.invalid(format('The order of "%s" must be an integer', p_name));
    END IF;

    IF v_type = 'choice' THEN
        IF jsonb_typeof(p_def -> 'choices') IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_def -> 'choices') = 0
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_def -> 'choices') c
                      WHERE jsonb_typeof(c) <> 'string' OR btrim(c #>> '{}') = '') THEN
            PERFORM error.invalid(format('The choice "%s" needs its choices: a list of texts', p_name));
        END IF;
        IF (SELECT count(DISTINCT c) <> count(*) FROM jsonb_array_elements_text(p_def -> 'choices') c) THEN
            PERFORM error.invalid(format('The choices of "%s" must each be there once', p_name));
        END IF;
    ELSIF p_def ? 'choices' THEN
        PERFORM error.invalid(format('Only a choice has choices, and "%s" is of type %s', p_name, v_type));
    END IF;

    IF v_type = 'attachment' THEN
        IF p_def ? 'media' AND jsonb_typeof(p_def -> 'media') <> 'null'
           AND (jsonb_typeof(p_def -> 'media') <> 'array'
                OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_def -> 'media') m
                           WHERE jsonb_typeof(m) <> 'string' OR (m #>> '{}') !~ '^[a-z0-9.+-]+/([a-z0-9.+-]+|\*)$')) THEN
            PERFORM error.invalid(format('The media types of "%s" must be a list like ["application/pdf", "image/*"]',
                                         p_name));
        END IF;
        IF jsonb_typeof(p_def -> 'default') IS DISTINCT FROM 'null' AND p_def ? 'default' THEN
            PERFORM error.invalid(format('An attachment has no default, and "%s" is one', p_name));
        END IF;
    ELSIF p_def ? 'media' THEN
        PERFORM error.invalid(format('Only an attachment has media types, and "%s" is of type %s', p_name, v_type));
    END IF;

    v_def := jsonb_strip_nulls(jsonb_build_object(
        'scope',    p_def -> 'scope',
        'type',     p_def -> 'type',
        'required', CASE WHEN jsonb_typeof(p_def -> 'required') = 'boolean' THEN p_def -> 'required'
                         ELSE 'false' END,
        'unit',     CASE WHEN jsonb_typeof(p_def -> 'unit') = 'string' THEN to_jsonb(btrim(p_def ->> 'unit')) END,
        'choices',  p_def -> 'choices',
        'media',    p_def -> 'media',
        'order',    p_def -> 'order',
        'default',  p_def -> 'default'));
    IF v_def ? 'default' AND NOT class.value_fits(v_def, v_def -> 'default') THEN
        PERFORM error.invalid(format('The default of "%s" must be %s', p_name, class.type_words(v_def)));
    END IF;
    RETURN v_def;
END;
$$;

-- Values p_values of one item or stock row (p_scope) checked against
-- p_attributes, a class's attributes, with p_defaulted, the names of those
-- that follow the class's default. Returns them as they are to be stored
-- (new_values, new_defaulted), or problem, what is wrong ("needs a value for "Colour", which is
-- required"), for the caller's message.
--   - Every value must be of one of the class's attributes of the scope,
--     and fit it.
--   - A value that follows the default takes the class's default; when the
--     attribute has no default any more, it has no value.
--   - An attribute without a value gets its default when it has one and
--     the row is new (p_new), or when it is required; a required one
--     without a default is a problem.
-- new_defaulted comes back sorted, so that two lists of the same names are
-- equal.
CREATE FUNCTION class.check_values(
    p_values      jsonb,
    p_defaulted   text[],
    p_attributes  jsonb,
    p_scope       public.scope,
    p_new         boolean,
    OUT new_values    jsonb,
    OUT new_defaulted text[],
    OUT problem       text
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key   text;
    v_value jsonb;
    v_def   jsonb;
BEGIN
    new_values := '{}';
    new_defaulted := '{}';
    FOR v_key, v_value IN SELECT e.key, e.value FROM jsonb_each(p_values) e ORDER BY e.key LOOP
        v_def := p_attributes -> v_key;
        IF v_def IS NULL OR v_def ->> 'scope' <> p_scope::text THEN
            problem := format('has a value for "%s", which isn''t one of its class''s %s attributes', v_key,
                              CASE p_scope WHEN 'item' THEN 'item' ELSE 'stock' END);
            RETURN;
        END IF;
        IF v_key = ANY (p_defaulted) THEN
            IF v_def ? 'default' THEN
                new_values := new_values || jsonb_build_object(v_key, v_def -> 'default');
                new_defaulted := new_defaulted || v_key;
            END IF;
            CONTINUE;
        END IF;
        IF NOT class.value_fits(v_def, v_value) THEN
            problem := format('has a value for "%s" that isn''t %s: %s', v_key, class.type_words(v_def), v_value);
            RETURN;
        END IF;
        new_values := new_values || jsonb_build_object(v_key, v_value);
    END LOOP;

    FOR v_key, v_def IN SELECT e.key, e.value FROM jsonb_each(p_attributes) e
                        WHERE e.value ->> 'scope' = p_scope::text AND NOT new_values ? e.key
                        ORDER BY e.key LOOP
        IF v_def ? 'default' AND (p_new OR (v_def ->> 'required')::boolean) THEN
            new_values := new_values || jsonb_build_object(v_key, v_def -> 'default');
            new_defaulted := new_defaulted || v_key;
        ELSIF (v_def ->> 'required')::boolean THEN
            problem := format('needs a value for "%s", which is required', v_key);
            RETURN;
        END IF;
    END LOOP;
    new_defaulted := ARRAY(SELECT d FROM unnest(new_defaulted) d ORDER BY d);
END;
$$;

-- Applies the value changes of a patch of an item or stock row (p_scope)
-- of class p_class to its values p_values and p_defaulted, and returns
-- them, to be checked as they are stored (class.check_values):
--   p_set      {"<name>": <value>, ...}: sets each, or removes it with
--              null; either way it no longer follows the default. A file
--              is uploaded, not set here.
--   p_default  ["<name>", ...]: gives each its class's default, and makes it
--              follow it.
CREATE FUNCTION class.patch_values(
    p_values          jsonb,
    p_defaulted       text[],
    p_class           public.class,
    p_scope           public.scope,
    p_set             jsonb,
    p_default         jsonb,
    OUT new_values    jsonb,
    OUT new_defaulted text[]
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key   text;
    v_value jsonb;
    v_def   jsonb;
BEGIN
    new_values := p_values;
    new_defaulted := p_defaulted;
    IF p_set IS NOT NULL AND jsonb_typeof(p_set) <> 'null' THEN
        IF jsonb_typeof(p_set) <> 'object' THEN
            PERFORM error.invalid('values must be a JSON object, by attribute name; null removes a value');
        END IF;
        FOR v_key, v_value IN SELECT e.key, e.value FROM jsonb_each(p_set) e LOOP
            v_def := p_class.attributes -> v_key;
            IF v_def ->> 'type' = 'attachment' AND v_def ->> 'scope' = p_scope::text
               AND jsonb_typeof(v_value) <> 'null' THEN
                PERFORM error.invalid(format('"%s" is a file: upload it', v_key));
            END IF;
            new_values := CASE WHEN jsonb_typeof(v_value) = 'null' THEN new_values - v_key
                               ELSE new_values || jsonb_build_object(v_key, v_value) END;
            new_defaulted := array_remove(new_defaulted, v_key);
        END LOOP;
    END IF;
    IF p_default IS NOT NULL AND jsonb_typeof(p_default) <> 'null' THEN
        IF jsonb_typeof(p_default) <> 'array'
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_default) d WHERE jsonb_typeof(d) <> 'string') THEN
            PERFORM error.invalid('default must be a list of attribute names');
        END IF;
        FOR v_key IN SELECT jsonb_array_elements_text(p_default) LOOP
            v_def := p_class.attributes -> v_key;
            IF v_def ->> 'scope' IS DISTINCT FROM p_scope::text THEN
                PERFORM error.not_found('attribute', format('"%s" of class "%s"', v_key, p_class.name));
            END IF;
            IF NOT v_def ? 'default' THEN
                PERFORM error.not_allowed(format('"%s" has no default', v_key));
            END IF;
            new_values := new_values || jsonb_build_object(v_key, v_def -> 'default');
            new_defaulted := array_remove(new_defaulted, v_key) || v_key;
        END LOOP;
    END IF;
END;
$$;

-- The names of the classes from the top down to p_class, separated by
-- spaces: what an item's search text has of its class.
CREATE FUNCTION class.path_text(p_class uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up (id, parent, name, depth) AS (
        SELECT c.id, c.parent, c.name, 0 FROM public.class c WHERE c.id = p_class
        UNION ALL
        SELECT c.id, c.parent, c.name, u.depth + 1
        FROM public.class c JOIN up u ON c.id = u.parent
    )
    SELECT string_agg(name, ' ' ORDER BY depth DESC) FROM up;
$$;

-- An item's search text (item.search): in lower case, its name p_name,
-- the names of the classes in its path p_path, and its text, url and choice
-- values p_values, as its class's attributes p_attributes say which they
-- are.
CREATE FUNCTION class.search_text(p_name text, p_path text, p_values jsonb, p_attributes jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(concat_ws(' ', p_name, p_path,
                           (SELECT string_agg(e.value #>> '{}', ' ' ORDER BY e.key)
                            FROM jsonb_each(p_values) e
                            WHERE p_attributes -> e.key ->> 'type' IN ('text', 'url', 'choice'))));
$$;

-- ---------------------------------------------------------------------------
-- Changes that reach the classes, items and stock below
-- ---------------------------------------------------------------------------

-- The attributes class p_class defines itself.
CREATE FUNCTION class.own(p_class public.class)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}')
    FROM jsonb_each(p_class.attributes) e
    WHERE e.value ->> 'class' = p_class.id::text;
$$;

-- Class p_class, locked with every class below it, so that no item or
-- stock row below it is written while it changes (an item's or stock
-- row's write locks its class row for sharing). Not found (404) when there
-- is none.
CREATE FUNCTION class.lock_subtree(p_class uuid)
RETURNS public.class
LANGUAGE plpgsql AS $$
DECLARE
    v_class public.class;
BEGIN
    SELECT c.* INTO v_class
    FROM public.class c
    WHERE c.id = p_class
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    PERFORM 1 FROM public.class c
    WHERE c.id IN (WITH RECURSIVE below (id) AS (
                       SELECT p_class
                       UNION ALL
                       SELECT x.id FROM public.class x JOIN below b ON x.parent = b.id
                   )
                   SELECT id FROM below)
    ORDER BY c.id
    FOR UPDATE;
    RETURN v_class;
END;
$$;

-- The attribute definition of p_name that class p_class defines itself.
-- Refused when it has none of that name, or inherits it: an attribute is
-- changed in the class that defines it.
CREATE FUNCTION class.own_definition(p_class public.class, p_name text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_def jsonb := p_class.attributes -> p_name;
BEGIN
    IF v_def IS NULL THEN
        PERFORM error.not_found('attribute', format('"%s" of class "%s"', p_name, p_class.name));
    END IF;
    IF v_def ->> 'class' <> p_class.id::text THEN
        PERFORM error.not_allowed(format('Class "%s" inherits "%s" from %s; change it there',
                                         p_class.name, p_name,
                                         error.row_label('class', (v_def ->> 'class')::uuid)));
    END IF;
    RETURN v_def;
END;
$$;

-- Makes the attributes of class p_class, and of every class below it, its
-- parent's attributes and its own again, from the top down, one level of
-- the tree per statement. Refused when a class would inherit an attribute
-- of the same name as one of its own: a class can't define a name it
-- inherits.
CREATE FUNCTION class.rebuild(p_class uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_level    uuid[] := ARRAY[p_class];
    v_conflict record;
BEGIN
    WHILE cardinality(v_level) > 0 LOOP
        SELECT c.name, e.key, (p.attributes -> e.key ->> 'class')::uuid AS definer INTO v_conflict
        FROM public.class c
        JOIN public.class p ON p.id = c.parent
        CROSS JOIN LATERAL jsonb_each(c.attributes) e
        WHERE c.id = ANY (v_level)
          AND e.value ->> 'class' = c.id::text
          AND p.attributes ? e.key
        LIMIT 1;
        IF FOUND THEN
            PERFORM error.not_allowed(format(
                'Class "%s" has an attribute "%s" of its own, and would also inherit one from %s',
                v_conflict.name, v_conflict.key, error.row_label('class', v_conflict.definer)));
        END IF;
        UPDATE public.class c
        SET attributes = coalesce((SELECT p.attributes FROM public.class p WHERE p.id = c.parent), '{}')
                         || class.own(c)
        WHERE c.id = ANY (v_level);
        v_level := ARRAY(SELECT c.id FROM public.class c WHERE c.parent = ANY (v_level));
    END LOOP;
END;
$$;

-- Checks the values of every item and stock row of class p_class and the
-- classes below it against their class's attributes as they are now
-- (class.check_values), and writes those that change: a default that
-- changed, a required value that gets its default. Writes each item's
-- search text too, where it changed (a class renamed or moved, a choice
-- renamed). Refused, with how many and one of them, when any row's values
-- don't fit. Returns how many rows it wrote: {items, stock}.
CREATE FUNCTION class.rewrite_rows(p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_problem record;
    v_items   bigint;
    v_stock   bigint;
BEGIN
    DROP TABLE IF EXISTS pg_temp.subtree;
    CREATE TEMPORARY TABLE pg_temp.subtree ON COMMIT DROP AS
    WITH RECURSIVE below (id) AS (
        SELECT p_class
        UNION ALL
        SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
    )
    SELECT c.id, c.attributes, class.path_text(c.id) AS path
    FROM public.class c WHERE c.id IN (SELECT id FROM below);

    DROP TABLE IF EXISTS pg_temp.checked;
    CREATE TEMPORARY TABLE pg_temp.checked ON COMMIT DROP AS
    SELECT i.id, i.name, n.new_values AS values, n.new_defaulted AS defaulted, n.problem,
           class.search_text(i.name, t.path, n.new_values, t.attributes) AS search,
           i.values AS old_values, i.defaulted AS old_defaulted, i.search AS old_search
    FROM public.item i
    JOIN pg_temp.subtree t ON t.id = i.class
    CROSS JOIN LATERAL class.check_values(i.values, i.defaulted, t.attributes, 'item', false) n;
    SELECT c.name, c.problem, count(*) OVER () AS count INTO v_problem
    FROM pg_temp.checked c WHERE c.problem IS NOT NULL
    ORDER BY c.name COLLATE public.natural, c.id LIMIT 1;
    IF FOUND THEN
        PERFORM error.not_allowed(format('%s item(s) wouldn''t fit; item "%s" %s',
                                         v_problem.count, v_problem.name, v_problem.problem));
    END IF;
    UPDATE public.item i
    SET values = c.values, defaulted = c.defaulted, search = c.search
    FROM pg_temp.checked c
    WHERE i.id = c.id
      AND (c.values <> c.old_values OR c.defaulted <> c.old_defaulted OR c.search <> c.old_search);
    GET DIAGNOSTICS v_items = ROW_COUNT;

    DROP TABLE IF EXISTS pg_temp.checked;
    CREATE TEMPORARY TABLE pg_temp.checked ON COMMIT DROP AS
    SELECT s.id, i.name, n.new_values AS values, n.new_defaulted AS defaulted, n.problem,
           s.values AS old_values, s.defaulted AS old_defaulted
    FROM public.stock s
    JOIN public.item i ON i.id = s.item
    JOIN pg_temp.subtree t ON t.id = i.class
    CROSS JOIN LATERAL class.check_values(s.values, s.defaulted, t.attributes, 'stock', false) n;
    SELECT c.id, c.problem, count(*) OVER () AS count INTO v_problem
    FROM pg_temp.checked c WHERE c.problem IS NOT NULL
    ORDER BY c.name COLLATE public.natural, c.id LIMIT 1;
    IF FOUND THEN
        PERFORM error.not_allowed(format('%s stock row(s) wouldn''t fit; %s %s',
                                         v_problem.count, error.row_label('stock', v_problem.id), v_problem.problem));
    END IF;
    UPDATE public.stock s
    SET values = c.values, defaulted = c.defaulted
    FROM pg_temp.checked c
    WHERE s.id = c.id
      AND (c.values <> c.old_values OR c.defaulted <> c.old_defaulted);
    GET DIAGNOSTICS v_stock = ROW_COUNT;

    RETURN jsonb_build_object('items', v_items, 'stock', v_stock);
END;
$$;

-- Renames, or with p_new NULL removes, value p_name in every item (p_scope
-- 'item') or stock row ('stock') of class p_class and the classes below it,
-- and in their lists of values that follow the default. Returns how many
-- rows it wrote.
CREATE FUNCTION class.rename_values(p_class uuid, p_scope public.scope, p_name text, p_new text)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_rows bigint;
BEGIN
    IF p_scope = 'item' THEN
        UPDATE public.item i
        SET values    = (i.values - p_name)
                        || CASE WHEN p_new IS NULL THEN '{}' ELSE jsonb_build_object(p_new, i.values -> p_name) END,
            defaulted = ARRAY(SELECT d FROM unnest(array_remove(i.defaulted, p_name)
                                                   || CASE WHEN p_name = ANY (i.defaulted) AND p_new IS NOT NULL
                                                           THEN ARRAY[p_new] ELSE '{}' END) d ORDER BY d)
        WHERE i.class IN (WITH RECURSIVE below (id) AS (
                              SELECT p_class
                              UNION ALL
                              SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
                          )
                          SELECT id FROM below)
          AND i.values ? p_name;
    ELSE
        UPDATE public.stock s
        SET values    = (s.values - p_name)
                        || CASE WHEN p_new IS NULL THEN '{}' ELSE jsonb_build_object(p_new, s.values -> p_name) END,
            defaulted = ARRAY(SELECT d FROM unnest(array_remove(s.defaulted, p_name)
                                                   || CASE WHEN p_name = ANY (s.defaulted) AND p_new IS NOT NULL
                                                           THEN ARRAY[p_new] ELSE '{}' END) d ORDER BY d)
        FROM public.item i
        WHERE i.id = s.item
          AND i.class IN (WITH RECURSIVE below (id) AS (
                              SELECT p_class
                              UNION ALL
                              SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
                          )
                          SELECT id FROM below)
          AND s.values ? p_name;
    END IF;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- How many items (p_scope 'item') or stock rows ('stock') of class p_class
-- and the classes below it have value p_value for p_name.
CREATE FUNCTION class.count_value(p_class uuid, p_scope public.scope, p_name text, p_value jsonb)
RETURNS bigint
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE below (id) AS (
        SELECT p_class
        UNION ALL
        SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
    )
    SELECT CASE p_scope
        WHEN 'item' THEN (SELECT count(*) FROM public.item i
                          WHERE i.class IN (SELECT id FROM below) AND i.values -> p_name = p_value)
        ELSE (SELECT count(*) FROM public.stock s JOIN public.item i ON i.id = s.item
              WHERE i.class IN (SELECT id FROM below) AND s.values -> p_name = p_value)
    END;
$$;

-- ---------------------------------------------------------------------------
-- Answers
-- ---------------------------------------------------------------------------

-- A class as the API shows it.
CREATE FUNCTION class.json(p_class public.class)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_class.id,
        'name',      p_class.name,
        'parent',    p_class.parent,
        'container', p_class.container
    );
$$;

-- [{id, name}, ...] from the top class down to and including p_class: one
-- walk up the tree.
CREATE FUNCTION class.path_json(p_class uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up (id, parent, name, depth) AS (
        SELECT c.id, c.parent, c.name, 0 FROM public.class c WHERE c.id = p_class
        UNION ALL
        SELECT c.id, c.parent, c.name, u.depth + 1
        FROM public.class c JOIN up u ON c.id = u.parent
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) ORDER BY depth DESC), '[]')
    FROM up;
$$;

-- Class p_class's attributes as a list, in their order on screen: the item
-- attributes, then the stock attributes, each by order, then name. Each is
-- its definition with its name, and whether it is inherited.
CREATE FUNCTION class.attributes_json(p_class public.class)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(jsonb_agg(e.value || jsonb_build_object(
                                  'name',      e.key,
                                  'inherited', e.value ->> 'class' <> p_class.id::text)
                              ORDER BY e.value ->> 'scope', (e.value ->> 'order')::integer,
                                       e.key COLLATE public.natural), '[]')
    FROM jsonb_each(p_class.attributes) e;
$$;

-- A class as class.get shows it: its path from the top, and its attributes.
CREATE FUNCTION class.detail_json(p_class public.class)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT class.json(p_class) || jsonb_build_object(
        'path',       class.path_json(p_class.id),
        'attributes', class.attributes_json(p_class));
$$;

-- What a change of a class's attributes answers: the class as class.get
-- shows it, and how many items and stock rows it wrote (p_rows, {items,
-- stock}).
CREATE FUNCTION class.change_json(p_class uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('class', class.detail_json(c),
                              'items', p_rows -> 'items', 'stock', p_rows -> 'stock',
                              'dry_run', false)
    FROM public.class c WHERE c.id = p_class;
$$;

-- Refuses p_name for a class below p_parent (NULL: at the top) when a
-- sibling has it already, letter case ignored; p_class is the class being
-- renamed or moved, which doesn't count (NULL when creating). The unique
-- index class_parent_name_unique refuses the same; this says it
-- clearly.
CREATE FUNCTION class.check_sibling_name(p_parent uuid, p_name text, p_class uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.class c
               WHERE c.parent IS NOT DISTINCT FROM p_parent
                 AND lower(c.name) = lower(p_name)
                 AND c.id IS DISTINCT FROM p_class) THEN
        PERFORM error.duplicate(format('There is a class "%s" there already', p_name));
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls: classes
-- ---------------------------------------------------------------------------

-- The class tree, flat: every class with its parent, by name.
-- p_known_version is the tree's version the client has, if any; when
-- nothing has changed since, only {version, unchanged: true} comes back.
-- wtfd nests the classes into a tree.
CREATE FUNCTION class.list(p_request public.request, p_known_version bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_version bigint;
BEGIN
    v_version := (SELECT m.class_version FROM public.meta m);
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;

    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'nodes', (
            SELECT coalesce(jsonb_agg(class.json(c) ORDER BY c.name COLLATE public.natural, c.id), '[]')
            FROM public.class c));
END;
$$;

-- A class: its path from the top, and every attribute
-- it has, its own and those it inherits.
CREATE FUNCTION class.get(p_request public.request, p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT class.detail_json(c) INTO v_result
    FROM public.class c
    WHERE c.id = p_class;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates a class below p_parent (NULL: at the top), with
-- the parent's attributes. Its name can't contain "/" (it separates the
-- names in a path), and must not be one of its siblings' already (letter
-- case ignored). A container holds only other classes, never items. For
-- admins.
CREATE FUNCTION class.create(
    p_request   public.request,
    p_name      text,
    p_parent    uuid,
    p_container boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session    record := util.session(p_request, 'admin');
    v_name       text := util.trim_and_check_path_name(p_name, 'class');
    v_attributes jsonb := '{}';
    v_class      public.class;
BEGIN
    IF p_container IS NULL THEN
        PERFORM error.invalid('Say whether the class is a container');
    END IF;
    IF p_parent IS NOT NULL THEN
        SELECT c.attributes INTO v_attributes
        FROM public.class c
        WHERE c.id = p_parent
        FOR SHARE;
        IF NOT FOUND THEN
            PERFORM error.bad_reference('class', p_parent);
        END IF;
    END IF;
    PERFORM class.check_sibling_name(p_parent, v_name, NULL);

    INSERT INTO public.class (name, parent, container, attributes)
    VALUES (v_name, p_parent, p_container, v_attributes)
    RETURNING * INTO v_class;
    PERFORM util.bump_version('class');
    RETURN class.detail_json(v_class);
END;
$$;

-- Changes the fields of a class that p_patch has:
-- name, parent (null: to the top) and container. A move into one of its
-- own subclasses is refused, and so is becoming a container while it has
-- items. Moving it gives it and the classes below it what they inherit from
-- their new place, which is checked against every item and stock row below
-- it, and refused if one doesn't fit (class.rewrite_rows); renaming it
-- rewrites the search texts of the items below it. Returns the class as
-- class.get does. For admins.
CREATE FUNCTION class.patch(p_request public.request, p_class uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session   record := util.session(p_request, 'admin');
    v_class     public.class;
    v_name      text;
    v_parent    uuid;
    v_container boolean;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['name', 'parent', 'container'], ARRAY['name', 'container']);
    v_class := class.lock_subtree(p_class);

    v_name      := CASE WHEN p_patch ? 'name'
                        THEN util.trim_and_check_path_name(p_patch ->> 'name', 'class')
                        ELSE v_class.name END;
    v_parent    := CASE WHEN p_patch ? 'parent' THEN (p_patch ->> 'parent')::uuid ELSE v_class.parent END;
    v_container := coalesce((p_patch ->> 'container')::boolean, v_class.container);
    IF v_parent IS DISTINCT FROM v_class.parent AND v_parent IS NOT NULL THEN
        PERFORM 1 FROM public.class c
        WHERE c.id = v_parent
        FOR SHARE;
        IF NOT FOUND THEN
            PERFORM error.bad_reference('class', v_parent);
        END IF;
        PERFORM util.check_move('class', p_class, v_parent);
    END IF;
    IF v_name IS DISTINCT FROM v_class.name OR v_parent IS DISTINCT FROM v_class.parent THEN
        PERFORM class.check_sibling_name(v_parent, v_name, p_class);
    END IF;
    IF v_container AND NOT v_class.container AND EXISTS (SELECT 1 FROM public.item i WHERE i.class = p_class) THEN
        PERFORM error.not_allowed(format('Class "%s" can''t become a container: it has %s item(s)',
                                         v_class.name, (SELECT count(*) FROM public.item i WHERE i.class = p_class)));
    END IF;

    UPDATE public.class c
    SET name = v_name, parent = v_parent, container = v_container
    WHERE c.id = p_class;
    IF v_parent IS DISTINCT FROM v_class.parent THEN
        PERFORM class.rebuild(p_class);
    END IF;
    IF v_name IS DISTINCT FROM v_class.name OR v_parent IS DISTINCT FROM v_class.parent THEN
        PERFORM class.rewrite_rows(p_class);
    END IF;
    PERFORM util.bump_version('class');
    SELECT c.* INTO v_class FROM public.class c WHERE c.id = p_class;
    RETURN class.detail_json(v_class);
END;
$$;

-- Deletes a class on its own. A class with subclasses
-- or items can't be deleted this way (409, saying which): class.delete_tree
-- deletes a class with everything below it. The foreign keys refuse the
-- same; this says what is in the way. For admins.
CREATE FUNCTION class.delete(p_request public.request, p_class uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
BEGIN
    SELECT c.* INTO v_class
    FROM public.class c
    WHERE c.id = p_class
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    IF EXISTS (SELECT 1 FROM public.class c WHERE c.parent = p_class) THEN
        PERFORM error.in_use(format('Class "%s" still has subclasses', v_class.name),
                             'Delete them first, or delete the class with everything below it (recursive).');
    END IF;
    IF EXISTS (SELECT 1 FROM public.item i WHERE i.class = p_class) THEN
        PERFORM error.in_use(format('Class "%s" still has items', v_class.name),
                             'Delete them first, or delete the class with everything below it (recursive, forced).');
    END IF;
    DELETE FROM public.class c WHERE c.id = p_class;
    PERFORM util.bump_version('class');
END;
$$;

-- Deletes a class with every class below it. While any
-- of them has items, nothing is deleted (409, naming the classes and how
-- many items each has), unless p_force: then those items are deleted too,
-- with their stock rows. With p_dry_run nothing is deleted, and only what
-- would be is returned:
--   {classes: [{id, path}], items: [{id, code, name, class}], stock: <count>}
-- the classes deepest first, the items by name. The stock rows, the items
-- and the classes each go in one statement: the classes' parent key is
-- checked after the statement, so a class and the classes below it can go
-- together. For admins.
CREATE FUNCTION class.delete_tree(
    p_request public.request,
    p_class   uuid,
    p_force   boolean,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_items   uuid[];
    v_result  jsonb;
BEGIN
    IF p_force IS NULL OR p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether to force the delete, and whether it is a dry run');
    END IF;
    PERFORM class.lock_subtree(p_class);

    -- The class and its subtree, each with its path and depth: the top's
    -- path is worked out once, and each class below adds its name. Dropped
    -- first, so that a second call in one transaction works.
    DROP TABLE IF EXISTS pg_temp.tree;
    CREATE TEMPORARY TABLE pg_temp.tree ON COMMIT DROP AS
    WITH RECURSIVE below (id, name, path, depth) AS (
        SELECT c.id, c.name, util.path_text(class.path_json(c.id)), 0
        FROM public.class c WHERE c.id = p_class
        UNION ALL
        SELECT c.id, c.name, b.path || '/' || c.name, b.depth + 1
        FROM public.class c JOIN below b ON c.parent = b.id
    )
    SELECT * FROM below;

    v_items := ARRAY(SELECT i.id FROM public.item i
                     WHERE i.class IN (SELECT t.id FROM pg_temp.tree t));

    v_result := jsonb_build_object(
        'classes', (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'path', t.path)
                                     ORDER BY t.depth DESC, t.id)
                    FROM pg_temp.tree t),
        'items',   (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                'id', i.id, 'code', util.code_text(i.code), 'name', i.name, 'class', i.class)
                            ORDER BY i.name COLLATE public.natural, i.id), '[]')
                    FROM public.item i WHERE i.id = ANY (v_items)),
        'stock',   (SELECT count(*) FROM public.stock s WHERE s.item = ANY (v_items)));

    IF p_dry_run THEN
        RETURN v_result;
    END IF;
    IF cardinality(v_items) > 0 AND NOT p_force THEN
        PERFORM error.in_use(
            'These classes still have items: ' || (
                SELECT string_agg(format('%s (%s %s)', t.path, n.count,
                                         CASE WHEN n.count = 1 THEN 'item' ELSE 'items' END),
                                  ', ' ORDER BY t.path COLLATE public.natural)
                FROM (SELECT i.class, count(*) FROM public.item i
                      WHERE i.id = ANY (v_items) GROUP BY i.class) n
                JOIN pg_temp.tree t ON t.id = n.class),
            'Delete the items first, or force the delete to delete them too.');
    END IF;

    DELETE FROM public.stock s WHERE s.item = ANY (v_items);
    DELETE FROM public.item i WHERE i.id = ANY (v_items);
    DELETE FROM public.class c WHERE c.id IN (SELECT t.id FROM pg_temp.tree t);
    PERFORM util.bump_version('class');
    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls: attributes
-- ---------------------------------------------------------------------------
-- Each changes one attribute of a class: one the class
-- defines itself (an inherited one is changed where it is defined). Each
-- reaches the classes below, and what each costs in items and stock rows is
-- in the plan's decision 12. Each answers {class, items, stock, dry_run}:
-- the class as class.get shows it, and how many items and stock rows it
-- wrote. With p_dry_run nothing changes, and the answer says what would
-- have; a dry run is refused as the change would be. For admins.

-- Adds attribute p_name to class p_class, defined by p_definition (see
-- class.check_definition); it goes last in its scope's order unless the
-- definition says where. Refused when the class has an attribute of that
-- name already, or a class below it has one of its own. A required one gets
-- its default on every item (or stock row) below it, and is refused without
-- a default while there are any.
CREATE FUNCTION class.attribute_add(
    p_request    public.request,
    p_class      uuid,
    p_name       text,
    p_definition jsonb,
    p_dry_run    boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_name    text := class.check_attribute_name(p_name);
    v_def     jsonb := class.check_definition(v_name, p_definition);
    v_rows    jsonb := '{"items": 0, "stock": 0}';
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    IF v_class.attributes ? v_name THEN
        PERFORM error.duplicate(format('Class "%s" has an attribute "%s" already', v_class.name, v_name));
    END IF;
    v_def := v_def || jsonb_build_object(
        'class', p_class,
        'order', coalesce(v_def -> 'order', to_jsonb(1 + coalesce((
                     SELECT max((e.value ->> 'order')::integer) FROM jsonb_each(v_class.attributes) e
                     WHERE e.value ->> 'scope' = v_def ->> 'scope'), 0))));

    BEGIN
        UPDATE public.class c SET attributes = c.attributes || jsonb_build_object(v_name, v_def)
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        IF (v_def ->> 'required')::boolean THEN
            v_rows := class.rewrite_rows(p_class);
        END IF;
        v_answer := class.change_json(p_class, v_rows);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Changes the fields of attribute p_name of class p_class that p_patch
-- has: required, default, unit, order, and media (for an attachment). null
-- removes a default, a unit or media types. Its type and scope never change:
-- remove the attribute and add it again. Its choices change with
-- class.choice_add and the others. A changed default reaches every value
-- below that follows it; making it required gives the default to every
-- row below without a value, and is refused without a default while there
-- are such rows.
CREATE FUNCTION class.attribute_change(
    p_request public.request,
    p_class   uuid,
    p_name    text,
    p_patch   jsonb,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_old     jsonb;
    v_def     jsonb;
    v_key     text;
    v_rows    jsonb := '{"items": 0, "stock": 0}';
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    PERFORM util.check_patch(p_patch, ARRAY['required', 'default', 'unit', 'order', 'media', 'type', 'scope', 'choices'],
                             ARRAY['required', 'order']);
    IF p_patch ? 'type' OR p_patch ? 'scope' THEN
        PERFORM error.not_allowed(format('The type and scope of "%s" can''t change; remove it and add it again', p_name));
    END IF;
    IF p_patch ? 'choices' THEN
        PERFORM error.invalid('Change the choices one at a time: add, rename or remove a choice');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_old := class.own_definition(v_class, p_name);

    v_def := v_old - 'class';
    FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
        v_def := CASE WHEN jsonb_typeof(p_patch -> v_key) = 'null' THEN v_def - v_key
                      ELSE v_def || jsonb_build_object(v_key, p_patch -> v_key) END;
    END LOOP;
    v_def := class.check_definition(p_name, v_def) || jsonb_build_object('class', p_class);

    BEGIN
        UPDATE public.class c SET attributes = c.attributes || jsonb_build_object(p_name, v_def)
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        IF v_def -> 'default' IS DISTINCT FROM v_old -> 'default'
           OR v_def -> 'required' IS DISTINCT FROM v_old -> 'required' THEN
            v_rows := class.rewrite_rows(p_class);
        END IF;
        v_answer := class.change_json(p_class, v_rows);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Renames attribute p_name of class p_class to p_new_name, in the class,
-- the classes below it, and every item (or stock row) below it that has a
-- value for it. Refused when the class has an attribute of the new name
-- already, or a class below it has one of its own.
CREATE FUNCTION class.attribute_rename(
    p_request  public.request,
    p_class    uuid,
    p_name     text,
    p_new_name text,
    p_dry_run  boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_def     jsonb;
    v_new     text := class.check_attribute_name(p_new_name);
    v_count   bigint;
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_def := class.own_definition(v_class, p_name);
    IF v_new = p_name THEN
        PERFORM error.invalid(format('"%s" has that name already', p_name));
    END IF;
    IF v_class.attributes ? v_new THEN
        PERFORM error.duplicate(format('Class "%s" has an attribute "%s" already', v_class.name, v_new));
    END IF;

    BEGIN
        v_count := class.rename_values(p_class, (v_def ->> 'scope')::public.scope, p_name, v_new);
        UPDATE public.class c
        SET attributes = (c.attributes - p_name) || jsonb_build_object(v_new, v_def)
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        v_answer := class.change_json(p_class, CASE v_def ->> 'scope'
            WHEN 'item' THEN jsonb_build_object('items', v_count, 'stock', 0)
            ELSE jsonb_build_object('items', 0, 'stock', v_count) END);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Removes attribute p_name from class p_class and the classes below it,
-- and its values from every item (or stock row) below it.
CREATE FUNCTION class.attribute_remove(
    p_request public.request,
    p_class   uuid,
    p_name    text,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_def     jsonb;
    v_count   bigint;
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_def := class.own_definition(v_class, p_name);

    BEGIN
        v_count := class.rename_values(p_class, (v_def ->> 'scope')::public.scope, p_name, NULL);
        UPDATE public.class c SET attributes = c.attributes - p_name WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        IF v_def ->> 'scope' = 'item' AND v_def ->> 'type' IN ('text', 'url', 'choice') THEN
            PERFORM class.rewrite_rows(p_class);
        END IF;
        v_answer := class.change_json(p_class, CASE v_def ->> 'scope'
            WHEN 'item' THEN jsonb_build_object('items', v_count, 'stock', 0)
            ELSE jsonb_build_object('items', 0, 'stock', v_count) END);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Adds choice p_choice to choice attribute p_name of class p_class, last.
-- Nothing below changes.
CREATE FUNCTION class.choice_add(
    p_request public.request,
    p_class   uuid,
    p_name    text,
    p_choice  text,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_def     jsonb;
    v_choice  text := util.trim_and_check(p_choice);
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_def := class.own_definition(v_class, p_name);
    IF v_def ->> 'type' <> 'choice' THEN
        PERFORM error.not_allowed(format('"%s" is not a choice', p_name));
    END IF;
    IF (v_def -> 'choices') ? v_choice THEN
        PERFORM error.duplicate(format('"%s" has the choice "%s" already', p_name, v_choice));
    END IF;

    BEGIN
        UPDATE public.class c
        SET attributes = jsonb_set(c.attributes, ARRAY[p_name, 'choices'],
                                   (v_def -> 'choices') || to_jsonb(v_choice))
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        v_answer := class.change_json(p_class, '{"items": 0, "stock": 0}');
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Renames choice p_choice of choice attribute p_name of class p_class to
-- p_new_choice, in its place: in the class, the classes below it, the
-- default, and every item (or stock row) below it that has it.
CREATE FUNCTION class.choice_rename(
    p_request    public.request,
    p_class      uuid,
    p_name       text,
    p_choice     text,
    p_new_choice text,
    p_dry_run    boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_def     jsonb;
    v_new     text := util.trim_and_check(p_new_choice);
    v_count   bigint;
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_def := class.own_definition(v_class, p_name);
    IF v_def ->> 'type' <> 'choice' THEN
        PERFORM error.not_allowed(format('"%s" is not a choice', p_name));
    END IF;
    IF NOT (v_def -> 'choices') ? p_choice THEN
        PERFORM error.not_found('choice', format('"%s" of "%s"', p_choice, p_name));
    END IF;
    IF (v_def -> 'choices') ? v_new THEN
        PERFORM error.duplicate(format('"%s" has the choice "%s" already', p_name, v_new));
    END IF;

    BEGIN
        v_def := jsonb_set(v_def, '{choices}', (
                     SELECT jsonb_agg(CASE WHEN c = p_choice THEN v_new ELSE c END ORDER BY n)
                     FROM jsonb_array_elements_text(v_def -> 'choices') WITH ORDINALITY AS x (c, n)));
        IF v_def ->> 'default' = p_choice THEN
            v_def := jsonb_set(v_def, '{default}', to_jsonb(v_new));
        END IF;
        IF v_def ->> 'scope' = 'item' THEN
            UPDATE public.item i
            SET values = jsonb_set(i.values, ARRAY[p_name], to_jsonb(v_new))
            WHERE i.class IN (WITH RECURSIVE below (id) AS (
                                  SELECT p_class
                                  UNION ALL
                                  SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
                              )
                              SELECT id FROM below)
              AND i.values ->> p_name = p_choice;
        ELSE
            UPDATE public.stock s
            SET values = jsonb_set(s.values, ARRAY[p_name], to_jsonb(v_new))
            FROM public.item i
            WHERE i.id = s.item
              AND i.class IN (WITH RECURSIVE below (id) AS (
                                  SELECT p_class
                                  UNION ALL
                                  SELECT c.id FROM public.class c JOIN below b ON c.parent = b.id
                              )
                              SELECT id FROM below)
              AND s.values ->> p_name = p_choice;
        END IF;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        UPDATE public.class c SET attributes = c.attributes || jsonb_build_object(p_name, v_def)
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        IF v_def ->> 'scope' = 'item' THEN
            PERFORM class.rewrite_rows(p_class);
        END IF;
        v_answer := class.change_json(p_class, CASE v_def ->> 'scope'
            WHEN 'item' THEN jsonb_build_object('items', v_count, 'stock', 0)
            ELSE jsonb_build_object('items', 0, 'stock', v_count) END);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;

-- Removes choice p_choice from choice attribute p_name of class p_class.
-- Refused while it is the default, or any item (or stock row) below the
-- class has it (409, saying how many), and when it is the last choice.
CREATE FUNCTION class.choice_remove(
    p_request public.request,
    p_class   uuid,
    p_name    text,
    p_choice  text,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_def     jsonb;
    v_count   bigint;
    v_answer  jsonb;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    v_class := class.lock_subtree(p_class);
    v_def := class.own_definition(v_class, p_name);
    IF v_def ->> 'type' <> 'choice' THEN
        PERFORM error.not_allowed(format('"%s" is not a choice', p_name));
    END IF;
    IF NOT (v_def -> 'choices') ? p_choice THEN
        PERFORM error.not_found('choice', format('"%s" of "%s"', p_choice, p_name));
    END IF;
    IF jsonb_array_length(v_def -> 'choices') = 1 THEN
        PERFORM error.not_allowed(format('"%s" is the last choice of "%s"; a choice needs at least one',
                                         p_choice, p_name));
    END IF;
    IF v_def ->> 'default' = p_choice THEN
        PERFORM error.in_use(format('"%s" is the default of "%s"', p_choice, p_name),
                             'Change the default first.');
    END IF;
    v_count := class.count_value(p_class, (v_def ->> 'scope')::public.scope, p_name, to_jsonb(p_choice));
    IF v_count > 0 THEN
        PERFORM error.in_use(format('%s %s below class "%s" %s "%s" for "%s"', v_count,
                                    CASE WHEN v_def ->> 'scope' = 'item' THEN 'item(s)' ELSE 'stock row(s)' END,
                                    v_class.name, CASE WHEN v_count = 1 THEN 'has' ELSE 'have' END,
                                    p_choice, p_name),
                             'Give them another value first.');
    END IF;

    BEGIN
        UPDATE public.class c
        SET attributes = jsonb_set(c.attributes, ARRAY[p_name, 'choices'], (
                             SELECT jsonb_agg(x.c ORDER BY x.n)
                             FROM jsonb_array_elements_text(v_def -> 'choices') WITH ORDINALITY AS x (c, n)
                             WHERE x.c <> p_choice))
        WHERE c.id = p_class;
        PERFORM class.rebuild(p_class);
        v_answer := class.change_json(p_class, '{"items": 0, "stock": 0}');
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_answer);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    PERFORM util.bump_version('class');
    RETURN v_answer;
END;
$$;
