-- Internal helpers (schema util). Explained in api/helpers.md.

CREATE SCHEMA util;

-- ---------------------------------------------------------------------------
-- Errors and paging
-- ---------------------------------------------------------------------------

-- Raises the "not found" error (SQLSTATE P0002) that the REST layer maps to 404.
CREATE FUNCTION util.raise_not_found(p_entity text, p_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% % not found', p_entity, p_id
        USING ERRCODE = 'no_data_found';
END;
$$;

-- Raises the "invalid input" error (SQLSTATE 22023).
CREATE FUNCTION util.raise_invalid(p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message
        USING ERRCODE = 'invalid_parameter_value';
END;
$$;

CREATE FUNCTION util.check_paging(p_limit integer, p_offset integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        PERFORM util.raise_invalid('limit must be between 1 and 1000');
    END IF;
    IF p_offset IS NULL OR p_offset < 0 THEN
        PERFORM util.raise_invalid('offset must be 0 or greater');
    END IF;
END;
$$;

-- Validates a PATCH object: it must be a JSON object, may only contain keys
-- from p_allowed, and keys from p_required (NOT NULL fields) may not be null.
CREATE FUNCTION util.check_patch(p_patch jsonb, p_allowed text[], p_required text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_key text;
BEGIN
    IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
        PERFORM util.raise_invalid('patch must be a JSON object');
    END IF;

    FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
        IF NOT v_key = ANY (p_allowed) THEN
            PERFORM util.raise_invalid(format('Unknown field %L; allowed: %s',
                                          v_key, array_to_string(p_allowed, ', ')));
        END IF;
        IF v_key = ANY (p_required) AND jsonb_typeof(p_patch -> v_key) = 'null' THEN
            PERFORM util.raise_invalid(format('Field %L cannot be null', v_key));
        END IF;
    END LOOP;
END;
$$;

-- Wraps one page of rows in the standard list envelope.
CREATE FUNCTION util.page(p_total bigint, p_limit integer, p_offset integer, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN jsonb_build_object(
        'total',  p_total,
        'limit',  p_limit,
        'offset', p_offset,
        'rows',   COALESCE(p_rows, '[]'::jsonb)
    );
END;
$$;

-- Names are stored trimmed.
CREATE FUNCTION util.clean_name(p_name text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN btrim(p_name);
END;
$$;

-- clean_name for classes and locations, whose names can't contain "/" (it
-- separates them in paths). The table constraints enforce the rule; this
-- gives a clearer error first.
CREATE FUNCTION util.clean_path_name(p_name text, p_kind text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF strpos(p_name, '/') > 0 THEN
        PERFORM util.raise_invalid(format('A %s name can''t contain "/", which separates the names in a path: %L', p_kind, p_name));
    END IF;
    RETURN util.clean_name(p_name);
END;
$$;

-- ---------------------------------------------------------------------------
-- Tree paths
-- ---------------------------------------------------------------------------

-- [{id, name}, ...] from the root class down to and including p_class.
CREATE FUNCTION util.class_path(p_class uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH RECURSIVE ancestors (id, parent, name, depth) AS (
            SELECT c.id, c.parent, c.name, 0
            FROM class c
            WHERE c.id = p_class
            UNION ALL
            SELECT c.id, c.parent, c.name, a.depth + 1
            FROM class c
            JOIN ancestors a ON c.id = a.parent
        )
        SELECT COALESCE(
            jsonb_agg(jsonb_build_object('id', id, 'name', name) ORDER BY depth DESC),
            '[]'::jsonb
        )
        FROM ancestors
    );
END;
$$;

-- The spreadsheet name of column p_n: 1 → A, 26 → Z, 27 → AA, 28 → AB, …
CREATE FUNCTION util.column_label(p_n integer) RETURNS text
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

-- A sort key that orders numbers inside names by their value, ignoring case:
-- "A2" before "A10", "Shelf 2" before "Shelf 10".
CREATE FUNCTION util.natural_key(p_name text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (
        SELECT string_agg(CASE WHEN m.part[1] ~ '^[0-9]' THEN lpad(m.part[1], 20, '0') ELSE lower(m.part[1]) END,
                          '' ORDER BY m.ord)
        FROM regexp_matches(p_name, '([0-9]+|[^0-9]+)', 'g') WITH ORDINALITY AS m(part, ord)
    );
END;
$$;

-- A path from util.class_path or util.location_path as text: "MCU/AVR/Old".
CREATE FUNCTION util.path_text(p_path jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (
        SELECT string_agg(e.value ->> 'name', '/' ORDER BY e.ord)
        FROM jsonb_array_elements(p_path) WITH ORDINALITY AS e(value, ord)
    );
END;
$$;

-- [{id, name}, ...] from the root location down to and including p_location.
CREATE FUNCTION util.location_path(p_location uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH RECURSIVE ancestors (id, parent, name, depth) AS (
            SELECT l.id, l.parent, l.name, 0
            FROM location l
            WHERE l.id = p_location
            UNION ALL
            SELECT l.id, l.parent, l.name, a.depth + 1
            FROM location l
            JOIN ancestors a ON l.id = a.parent
        )
        SELECT COALESCE(
            jsonb_agg(jsonb_build_object('id', id, 'name', name) ORDER BY depth DESC),
            '[]'::jsonb
        )
        FROM ancestors
    );
END;
$$;

-- The classes of p_tenant below p_parent (the roots when NULL) as a nested
-- tree: [{id, name, parent, children: [...]}, ...], alphabetically per level.
CREATE FUNCTION util.class_tree(p_tenant uuid, p_parent uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id',        c.id,
                    'name',      c.name,
                    'parent',    c.parent,
                    'container', c.container,
                    'children',  util.class_tree(p_tenant, c.id)
                )
                ORDER BY util.natural_key(c.name), c.id
            ),
            '[]'::jsonb
        )
        FROM class c
        WHERE c.tenant = p_tenant
          AND ((p_parent IS NULL AND c.parent IS NULL) OR c.parent = p_parent)
    );
END;
$$;

-- The locations of p_tenant below p_parent (the roots when NULL) as a
-- nested tree.
CREATE FUNCTION util.location_tree(p_tenant uuid, p_parent uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id',        l.id,
                    'code',      util.code_text(l.code),
                    'name',      l.name,
                    'parent',    l.parent,
                    'container', l.container,
                    'children',  util.location_tree(p_tenant, l.id)
                )
                ORDER BY util.natural_key(l.name), l.id
            ),
            '[]'::jsonb
        )
        FROM location l
        WHERE l.tenant = p_tenant
          AND ((p_parent IS NULL AND l.parent IS NULL) OR l.parent = p_parent)
    );
END;
$$;

-- Current change counter of a tracked table for a tenant (see data_version
-- in SCHEMA.md); 0 before the first change.
CREATE FUNCTION util.data_version(p_tenant uuid, p_name text) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN COALESCE(
        (SELECT version FROM data_version WHERE tenant = p_tenant AND name = p_name),
        0
    );
END;
$$;

-- Stock summary of an item for lists: the sum of its counted rows (in the
-- base unit, 0 when there are none), and whether any row is uncounted.
CREATE FUNCTION util.item_stock_total_json(p_item uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'total',     t.total,
            'unit',      util.unit_json(util.unit_group_base_unit(i.unit_group)),
            'display',   util.display_json(t.total, i.unit_group),
            'uncounted', t.uncounted
        )
        FROM item i
        CROSS JOIN LATERAL (
            SELECT COALESCE(sum(s.quantity), 0)           AS total,
                   COALESCE(bool_or(s.quantity IS NULL), false) AS uncounted
            FROM stock s
            WHERE s.item = i.id
        ) t
        WHERE i.id = p_item
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Codes (Crockford Base32)
-- ---------------------------------------------------------------------------

-- A code number as Crockford Base32 text, e.g. 32768 -> '1000'.
CREATE FUNCTION util.code_text(p_value bigint) RETURNS text
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

-- The number of a Crockford Base32 code. Case and hyphens are ignored. The
-- excluded letters I, L, O and U are rejected: clients map I/L to 1 and O to 0.
CREATE FUNCTION util.code_value(p_code text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    v_code     text := upper(replace(p_code, '-', ''));
    v_value    bigint := 0;
    v_digit    integer;
BEGIN
    IF v_code IS NULL OR v_code = '' OR length(v_code) > 12 THEN
        PERFORM util.raise_invalid(format('%L is not a valid code', p_code));
    END IF;
    FOR i IN 1 .. length(v_code) LOOP
        v_digit := strpos(v_alphabet, substr(v_code, i, 1)) - 1;
        IF v_digit < 0 THEN
            PERFORM util.raise_invalid(format('%L is not a valid code', p_code));
        END IF;
        v_value := v_value * 32 + v_digit;
    END LOOP;
    RETURN v_value;
END;
$$;

-- The texts item search looks in, lower-cased: the item name, the names of
-- all classes in its class path, its text and url values, the names of its
-- choice values, the text and choice defaults it shows (where it has no
-- value of its own; the nearest class assignment wins, as everywhere), and
-- the text and choice values of its stock rows.
CREATE FUNCTION util.item_search_texts(p_item uuid, p_class uuid) RETURNS SETOF text
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE lineage (id, name, parent, depth) AS (
            SELECT c.id, c.name, c.parent, 0
            FROM class c
            WHERE c.id = p_class
            UNION ALL
            SELECT c.id, c.name, c.parent, l.depth + 1
            FROM class c
            JOIN lineage l ON c.id = l.parent
        ),
        defaults AS (
            SELECT DISTINCT ON (ca.attribute) ca.attribute, ca.text_default, ca.option_default
            FROM lineage l
            JOIN class_attribute ca ON ca.class = l.id
            ORDER BY ca.attribute, l.depth
        ),
        shown_defaults AS (
            SELECT d.*
            FROM defaults d
            WHERE NOT EXISTS (
                SELECT 1 FROM value v WHERE v.item = p_item AND v.attribute = d.attribute
            )
        )
        SELECT lower(i.name) FROM item i WHERE i.id = p_item
        UNION ALL
        SELECT lower(l.name) FROM lineage l
        UNION ALL
        SELECT lower(v.text_value) FROM value v WHERE v.item = p_item AND v.text_value IS NOT NULL
        UNION ALL
        SELECT lower(o.name) FROM value v JOIN attribute_option o ON o.id = v.option_value WHERE v.item = p_item
        UNION ALL
        SELECT lower(d.text_default) FROM shown_defaults d WHERE d.text_default IS NOT NULL
        UNION ALL
        SELECT lower(o.name) FROM shown_defaults d JOIN attribute_option o ON o.id = d.option_default
        UNION ALL
        SELECT lower(sv.text_value)
        FROM stock s JOIN stock_value sv ON sv.stock = s.id
        WHERE s.item = p_item AND sv.text_value IS NOT NULL
        UNION ALL
        SELECT lower(o.name)
        FROM stock s JOIN stock_value sv ON sv.stock = s.id JOIN attribute_option o ON o.id = sv.option_value
        WHERE s.item = p_item;
END;
$$;

-- p_class and all its descendants.
CREATE FUNCTION util.class_subtree(p_class uuid) RETURNS SETOF uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE subtree (id) AS (
            SELECT p_class
            UNION
            SELECT c.id
            FROM class c
            JOIN subtree s ON c.parent = s.id
        )
        SELECT id FROM subtree;
END;
$$;

-- p_location and all its descendants.
CREATE FUNCTION util.location_subtree(p_location uuid) RETURNS SETOF uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE subtree (id) AS (
            SELECT p_location
            UNION
            SELECT l.id
            FROM location l
            JOIN subtree s ON l.parent = s.id
        )
        SELECT id FROM subtree;
END;
$$;

-- ---------------------------------------------------------------------------
-- Typed values (shared by value and class_attribute defaults)
-- ---------------------------------------------------------------------------

-- Converts a JSON value to the typed column matching the attribute's datatype.
-- Numbers of attributes with a unit group are given in the base unit.
-- Exactly one OUT column is set. Accepted JSON per datatype:
--   text, url  string
--   integer    whole number
--   float      number
--   date       string 'YYYY-MM-DD'
--   boolean    true / false
--   choice     string: an option id, or an option name (case-insensitive)
CREATE FUNCTION util.parse_typed_value(
    p_attribute    uuid,
    p_value        jsonb,
    OUT text_v     text,
    OUT integer_v  bigint,
    OUT float_v    double precision,
    OUT date_v     date,
    OUT boolean_v  boolean,
    OUT option_v   uuid
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_datatype datatype;
    v_kind     text := jsonb_typeof(p_value);
    v_string   text;
BEGIN
    SELECT a.datatype INTO v_datatype FROM attribute a WHERE a.id = p_attribute;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;

    IF v_kind IS NULL OR v_kind = 'null' THEN
        PERFORM util.raise_invalid(format('A value is required for attribute %s', p_attribute));
    END IF;

    IF v_kind = 'string' THEN
        v_string := p_value #>> '{}';
    END IF;

    CASE v_datatype
    WHEN 'text', 'url' THEN
        IF v_kind <> 'string' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects a string', p_attribute));
        END IF;
        text_v := v_string;

    WHEN 'integer' THEN
        IF v_kind <> 'number' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects a whole number', p_attribute));
        END IF;
        IF p_value::numeric <> trunc(p_value::numeric) THEN
            PERFORM util.raise_invalid(format('Attribute %s expects a whole number', p_attribute));
        END IF;
        integer_v := p_value::numeric::bigint;

    WHEN 'float' THEN
        IF v_kind <> 'number' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects a number', p_attribute));
        END IF;
        float_v := p_value::numeric::double precision;

    WHEN 'date' THEN
        IF v_kind <> 'string' OR v_string !~ '^\d{4}-\d{2}-\d{2}$' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects a date as YYYY-MM-DD', p_attribute));
        END IF;
        date_v := v_string::date;

    WHEN 'boolean' THEN
        IF v_kind <> 'boolean' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects true or false', p_attribute));
        END IF;
        boolean_v := p_value::boolean;

    WHEN 'choice' THEN
        IF v_kind <> 'string' THEN
            PERFORM util.raise_invalid(format('Attribute %s expects an option id or name', p_attribute));
        END IF;
        -- An exact id match wins over a name match.
        SELECT o.id INTO option_v
        FROM attribute_option o
        WHERE o.attribute = p_attribute
          AND (o.id::text = lower(v_string) OR lower(o.name) = lower(v_string))
        ORDER BY (o.id::text = lower(v_string)) DESC
        LIMIT 1;
        IF option_v IS NULL THEN
            PERFORM util.raise_invalid(format('%L is not an option of attribute %s', v_string, p_attribute));
        END IF;
    END CASE;
END;
$$;

-- Converts typed columns back to JSON for the given datatype.
-- Returns SQL NULL when the matching column is NULL (e.g. no default set).
CREATE FUNCTION util.typed_value_json(
    p_datatype datatype,
    p_text     text,
    p_integer  bigint,
    p_float    double precision,
    p_date     date,
    p_boolean  boolean,
    p_option   uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN CASE p_datatype
        WHEN 'text'    THEN to_jsonb(p_text)
        WHEN 'url'     THEN to_jsonb(p_text)
        WHEN 'integer' THEN to_jsonb(p_integer)
        WHEN 'float'   THEN to_jsonb(p_float)
        WHEN 'date'    THEN to_jsonb(p_date)
        WHEN 'boolean' THEN to_jsonb(p_boolean)
        WHEN 'choice'  THEN (
            SELECT jsonb_build_object('id', o.id, 'name', o.name)
            FROM attribute_option o
            WHERE o.id = p_option
        )
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- JSON representations
-- ---------------------------------------------------------------------------
-- Each returns SQL NULL when the row does not exist.

CREATE FUNCTION util.quantity_json(p_quantity uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object('id', q.id, 'name', q.name, 'datatype', q.datatype)
        FROM quantity q
        WHERE q.id = p_quantity
    );
END;
$$;

-- Includes the conversion to the base unit, so clients can convert themselves.
CREATE FUNCTION util.unit_json(p_unit uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',          u.id,
            'name',        u.name,
            'symbol',      u.symbol,
            'quantity',    util.quantity_json(u.quantity),
            'base_factor', u.base_factor,
            'base_offset', u.base_offset,
            'is_base',     u.base_factor = 1 AND u.base_offset = 0
        )
        FROM unit u
        WHERE u.id = p_unit
    );
END;
$$;

-- The base unit of a quantity.
CREATE FUNCTION util.base_unit(p_quantity uuid) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT u.id
        FROM unit u
        WHERE u.quantity = p_quantity
          AND u.base_factor = 1
          AND u.base_offset = 0
    );
END;
$$;

-- The base unit of a unit group's quantity, in which its numbers are stored.
CREATE FUNCTION util.unit_group_base_unit(p_unit_group uuid) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT util.base_unit(g.quantity) FROM unit_group g WHERE g.id = p_unit_group);
END;
$$;

-- Short form used inside other objects: {id, name, quantity, base_unit}.
CREATE FUNCTION util.unit_group_json(p_unit_group uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',        g.id,
            'name',      g.name,
            'quantity',  util.quantity_json(g.quantity),
            'base_unit', util.unit_json(util.base_unit(g.quantity))
        )
        FROM unit_group g
        WHERE g.id = p_unit_group
    );
END;
$$;

-- p_value (in the base unit) expressed in the unit of the group that scales
-- best: the largest unit in which |value| >= 1, otherwise the smallest unit.
-- Zero is always shown in the base unit.
-- Returns {value, unit}, or SQL NULL when there is no number or no group.
CREATE FUNCTION util.display_json(p_value numeric, p_unit_group uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_unit uuid;
BEGIN
    IF p_value IS NULL OR p_unit_group IS NULL THEN
        RETURN NULL;
    END IF;

    IF p_value = 0 THEN
        v_unit := util.unit_group_base_unit(p_unit_group);
    ELSE
        SELECT u.id INTO v_unit
        FROM unit_group_unit gu
        JOIN unit u ON u.id = gu.unit
        WHERE gu.unit_group = p_unit_group
        ORDER BY
            (abs((p_value - u.base_offset) / u.base_factor) >= 1) DESC,
            CASE WHEN abs((p_value - u.base_offset) / u.base_factor) >= 1
                 THEN u.base_factor END DESC,
            u.base_factor,
            u.id
        LIMIT 1;
    END IF;

    RETURN (
        SELECT jsonb_build_object(
            'value', trim_scale((p_value - u.base_offset) / u.base_factor),
            'unit',  util.unit_json(u.id)
        )
        FROM unit u
        WHERE u.id = v_unit
    );
END;
$$;

CREATE FUNCTION util.attribute_json(p_attribute uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',         a.id,
            'name',       a.name,
            'datatype',   a.datatype,
            'unit_group', util.unit_group_json(a.unit_group)
        )
        FROM attribute a
        WHERE a.id = p_attribute
    );
END;
$$;

CREATE FUNCTION util.option_json(p_option uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object('id', o.id, 'attribute', o.attribute, 'name', o.name)
        FROM attribute_option o
        WHERE o.id = p_option
    );
END;
$$;

CREATE FUNCTION util.class_json(p_class uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',        c.id,
            'name',      c.name,
            'parent',    c.parent,
            'container', c.container,
            'path',      util.class_path(c.id)
        )
        FROM class c
        WHERE c.id = p_class
    );
END;
$$;

-- Effective (own + inherited) attributes of a class, alphabetically.
CREATE FUNCTION util.class_attributes_json(p_class uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'attribute',        util.attribute_json(e.attribute),
                    'defined_on_class', e.defined_on_class,
                    'inherited',        e.inherited_depth > 0,
                    'default',          util.typed_value_json(
                                            a.datatype,
                                            e.text_default, e.integer_default, e.float_default,
                                            e.date_default, e.boolean_default, e.option_default),
                    'default_display',  util.display_json(
                                            COALESCE(e.integer_default::numeric, e.float_default::numeric),
                                            a.unit_group),
                    'per_unit',         e.per_unit,
                    'required',         e.required
                )
                ORDER BY lower(a.name), a.id
            ),
            '[]'::jsonb
        )
        FROM class_effective_attribute e
        JOIN attribute a ON a.id = e.attribute
        WHERE e.class = p_class
    );
END;
$$;

CREATE FUNCTION util.location_json(p_location uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',        l.id,
            'code',      util.code_text(l.code),
            'name',      l.name,
            'parent',    l.parent,
            'container', l.container,
            'path',      util.location_path(l.id)
        )
        FROM location l
        WHERE l.id = p_location
    );
END;
$$;

-- Short form used in lists and inside other objects. class is just the id:
-- the client resolves it from its cached class tree.
CREATE FUNCTION util.item_summary_json(p_item uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',         i.id,
            'code',       util.code_text(i.code),
            'name',       i.name,
            'class',      i.class,
            'unit_group', util.unit_group_json(i.unit_group)
        )
        FROM item i
        WHERE i.id = p_item
    );
END;
$$;

-- quantity is in the base unit of the item's unit group (pieces if none);
-- display is the same quantity in the group's best-scaling unit.
-- location is just the id: the client resolves it from its cached location
-- tree.
CREATE FUNCTION util.stock_json(p_stock uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',       s.id,
            'code',     util.code_text(s.code),
            'item',     util.item_summary_json(s.item),
            'location', s.location,
            'quantity', s.quantity,
            'unit',     util.unit_json(util.unit_group_base_unit(i.unit_group)),
            'display',  util.display_json(s.quantity, i.unit_group)
        )
        FROM stock s
        JOIN item i ON i.id = s.item
        WHERE s.id = p_stock
    );
END;
$$;

-- Values of an item (p_per_unit false, p_owner = item id) or of a stock row
-- (p_per_unit true, p_owner = stock id) in class p_class: the own values,
-- plus the class default (marked is_default) for every effective attribute
-- of that scope that has no value of its own. Alphabetical by attribute.
CREATE FUNCTION util.values_json(p_class uuid, p_per_unit boolean, p_owner uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH own AS (
            SELECT v.attribute, v.text_value, v.integer_value, v.float_value,
                   v.date_value, v.boolean_value, v.option_value
            FROM value v
            WHERE NOT p_per_unit AND v.item = p_owner
            UNION ALL
            SELECT sv.attribute, sv.text_value, sv.integer_value, sv.float_value,
                   sv.date_value, sv.boolean_value, sv.option_value
            FROM stock_value sv
            WHERE p_per_unit AND sv.stock = p_owner
        ),
        shown (attribute, is_default, text_v, integer_v, float_v, date_v, boolean_v, option_v) AS (
            SELECT o.attribute, false, o.text_value, o.integer_value, o.float_value,
                   o.date_value, o.boolean_value, o.option_value
            FROM own o
            UNION ALL
            SELECT e.attribute, true, e.text_default, e.integer_default, e.float_default,
                   e.date_default, e.boolean_default, e.option_default
            FROM class_effective_attribute e
            WHERE e.class = p_class
              AND e.per_unit = p_per_unit
              AND num_nonnulls(e.text_default, e.integer_default, e.float_default,
                               e.date_default, e.boolean_default, e.option_default) = 1
              AND NOT EXISTS (SELECT 1 FROM own o WHERE o.attribute = e.attribute)
        )
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'attribute',  util.attribute_json(x.attribute),
                    'value',      util.typed_value_json(
                                      a.datatype,
                                      x.text_v, x.integer_v, x.float_v,
                                      x.date_v, x.boolean_v, x.option_v),
                    'unit',       util.unit_json(util.unit_group_base_unit(a.unit_group)),
                    'display',    util.display_json(
                                      COALESCE(x.integer_v::numeric, x.float_v::numeric),
                                      a.unit_group),
                    'is_default', x.is_default
                )
                ORDER BY lower(a.name), a.id
            ),
            '[]'::jsonb
        )
        FROM shown x
        JOIN attribute a ON a.id = x.attribute
    );
END;
$$;

-- Attributes as [{id, name}], alphabetically; used for missing required values.
CREATE FUNCTION util.attribute_refs_json(p_attributes uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(
            jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) ORDER BY lower(a.name), a.id),
            '[]'::jsonb
        )
        FROM attribute a
        WHERE a.id = ANY (p_attributes)
    );
END;
$$;

-- True when the item, or any of its stock rows, lacks a required value.
CREATE FUNCTION util.item_incomplete(p_item uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM item_missing_attributes(p_item))
        OR EXISTS (
            SELECT 1
            FROM stock s
            WHERE s.item = p_item
              AND EXISTS (SELECT 1 FROM stock_missing_attributes(s.id))
        );
END;
$$;

-- A stock row with its per-unit values and missing required attributes.
-- stock_get and the functions that change a stock row return this;
-- stock_list uses the lighter util.stock_json.
CREATE FUNCTION util.stock_detail_json(p_stock uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT util.stock_json(s.id) || jsonb_build_object(
            'values',      util.values_json(i.class, true, s.id),
            'missing',     util.attribute_refs_json(ARRAY(SELECT stock_missing_attributes(s.id))),
            'attachments', util.attachments_json(NULL, s.id, NULL, NULL)
        )
        FROM stock s
        JOIN item i ON i.id = s.item
        WHERE s.id = p_stock
    );
END;
$$;

-- Full item: class (with path), values, missing required attributes, and its
-- stock rows with their own values and missing attributes.
CREATE FUNCTION util.item_json(p_item uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',         i.id,
            'code',       util.code_text(i.code),
            'name',       i.name,
            'class',      util.class_json(i.class),
            'unit_group', util.unit_group_json(i.unit_group),
            'values',      util.values_json(i.class, false, i.id),
            'missing',     util.attribute_refs_json(ARRAY(SELECT item_missing_attributes(i.id))),
            'photo',       util.item_photo_json(i.id),
            'attachments', util.attachments_json(i.id, NULL, NULL, NULL),
            -- The client resolves location ids from its cached location tree.
            -- quantity is in the base unit given by unit_group.
            'stock', (
                SELECT COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'id',       s.id,
                            'code',     util.code_text(s.code),
                            'location', s.location,
                            'quantity', s.quantity,
                            'display',  util.display_json(s.quantity, i.unit_group),
                            'values',      util.values_json(i.class, true, s.id),
                            'missing',     util.attribute_refs_json(ARRAY(SELECT stock_missing_attributes(s.id))),
                            'attachments', util.attachments_json(NULL, s.id, NULL, NULL)
                        )
                        ORDER BY lower(l.name), s.id
                    ),
                    '[]'::jsonb
                )
                FROM stock s
                JOIN location l ON l.id = s.location
                WHERE s.item = i.id
            )
        )
        FROM item i
        WHERE i.id = p_item
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Writes shared by several API functions
-- ---------------------------------------------------------------------------

-- Inserts or replaces the value of one attribute for one item.
CREATE FUNCTION util.value_upsert(p_item uuid, p_attribute uuid, p_value jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_parsed record;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM attribute a JOIN item i ON i.tenant = a.tenant
        WHERE a.id = p_attribute AND i.id = p_item
    ) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;
    SELECT * INTO v_parsed FROM util.parse_typed_value(p_attribute, p_value);

    INSERT INTO value (tenant, item, attribute,
                       text_value, integer_value, float_value,
                       date_value, boolean_value, option_value)
    VALUES ((SELECT tenant FROM item WHERE id = p_item), p_item, p_attribute,
            v_parsed.text_v, v_parsed.integer_v, v_parsed.float_v,
            v_parsed.date_v, v_parsed.boolean_v, v_parsed.option_v)
    ON CONFLICT (item, attribute) DO UPDATE SET
        text_value    = EXCLUDED.text_value,
        integer_value = EXCLUDED.integer_value,
        float_value   = EXCLUDED.float_value,
        date_value    = EXCLUDED.date_value,
        boolean_value = EXCLUDED.boolean_value,
        option_value  = EXCLUDED.option_value;
END;
$$;

-- Inserts or replaces the value of one per-unit attribute for one stock row.
CREATE FUNCTION util.stock_value_upsert(p_stock uuid, p_attribute uuid, p_value jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_parsed record;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM attribute a JOIN stock s ON s.tenant = a.tenant
        WHERE a.id = p_attribute AND s.id = p_stock
    ) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;
    SELECT * INTO v_parsed FROM util.parse_typed_value(p_attribute, p_value);

    INSERT INTO stock_value (tenant, stock, attribute,
                             text_value, integer_value, float_value,
                             date_value, boolean_value, option_value)
    VALUES ((SELECT tenant FROM stock WHERE id = p_stock), p_stock, p_attribute,
            v_parsed.text_v, v_parsed.integer_v, v_parsed.float_v,
            v_parsed.date_v, v_parsed.boolean_v, v_parsed.option_v)
    ON CONFLICT (stock, attribute) DO UPDATE SET
        text_value    = EXCLUDED.text_value,
        integer_value = EXCLUDED.integer_value,
        float_value   = EXCLUDED.float_value,
        date_value    = EXCLUDED.date_value,
        boolean_value = EXCLUDED.boolean_value,
        option_value  = EXCLUDED.option_value;
END;
$$;

-- Sets several values from {"<attribute id>": <value>, ...}, on an item
-- (p_per_unit false) or a stock row (p_per_unit true). JSON null entries are
-- skipped.
CREATE FUNCTION util.values_upsert(p_per_unit boolean, p_owner uuid, p_values jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_key   text;
    v_value jsonb;
BEGIN
    IF p_values IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_values) <> 'object' THEN
        PERFORM util.raise_invalid('values must be a JSON object keyed by attribute id');
    END IF;
    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_values) LOOP
        CONTINUE WHEN jsonb_typeof(v_value) = 'null';
        IF p_per_unit THEN
            PERFORM util.stock_value_upsert(p_owner, v_key::uuid, v_value);
        ELSE
            PERFORM util.value_upsert(p_owner, v_key::uuid, v_value);
        END IF;
    END LOOP;
END;
$$;

-- True when two stock rows have exactly the same per-unit values.
CREATE FUNCTION util.stock_values_equal(p_a uuid, p_b uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN NOT EXISTS (
        (SELECT attribute, text_value, integer_value, float_value, date_value, boolean_value, option_value
         FROM stock_value WHERE stock = p_a
         EXCEPT
         SELECT attribute, text_value, integer_value, float_value, date_value, boolean_value, option_value
         FROM stock_value WHERE stock = p_b)
        UNION ALL
        (SELECT attribute, text_value, integer_value, float_value, date_value, boolean_value, option_value
         FROM stock_value WHERE stock = p_b
         EXCEPT
         SELECT attribute, text_value, integer_value, float_value, date_value, boolean_value, option_value
         FROM stock_value WHERE stock = p_a)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Attachments
-- ---------------------------------------------------------------------------

CREATE FUNCTION util.attachment_json(p_attachment uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',            a.id,
            'file_name',     a.file_name,
            'content_type',  a.content_type,
            'size',          f.size,
            'sha256',        encode(a.file, 'hex'),
            'caption',       a.caption,
            'primary_photo', a.primary_photo
        )
        FROM attachment a
        JOIN file f ON f.sha256 = a.file
        WHERE a.id = p_attachment
    );
END;
$$;

-- The attachments of one object (pass its id in the matching parameter and
-- NULL in the others): the primary photo first, then by file name.
CREATE FUNCTION util.attachments_json(p_item uuid, p_stock uuid, p_location uuid, p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(
            jsonb_agg(util.attachment_json(a.id)
                      ORDER BY a.primary_photo DESC, lower(a.file_name), a.id),
            '[]'::jsonb
        )
        FROM attachment a
        WHERE a.item = p_item
           OR a.stock = p_stock
           OR a.location = p_location
           OR a.class = p_class
    );
END;
$$;

-- The primary photo of an item, or SQL NULL.
CREATE FUNCTION util.item_photo_json(p_item uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT util.attachment_json(a.id)
        FROM attachment a
        WHERE a.item = p_item
          AND a.primary_photo
    );
END;
$$;

-- Clears the primary photo of the object an attachment belongs to, except
-- for p_keep.
CREATE FUNCTION util.attachment_clear_primary(p_keep uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE attachment a
    SET primary_photo = false
    FROM attachment k
    WHERE k.id = p_keep
      AND a.id <> k.id
      AND a.primary_photo
      AND (a.item = k.item OR a.stock = k.stock OR a.location = k.location OR a.class = k.class);
END;
$$;

-- ---------------------------------------------------------------------------
-- Sessions and privileges (see TENANTS.md)
-- ---------------------------------------------------------------------------

-- Raises the "not authenticated" error (SQLSTATE 28000) that the REST layer
-- maps to 401.
CREATE FUNCTION util.raise_unauthenticated(p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message
        USING ERRCODE = 'invalid_authorization_specification';
END;
$$;

-- The SHA-256 of a token, as stored in session.token_hash.
CREATE FUNCTION util.token_hash(p_token text) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN sha256(convert_to(p_token, 'UTF8'));
END;
$$;

-- The session of the current transaction (set by session_use): account,
-- tenant and privileges. Raises 28000 without a valid session.
CREATE FUNCTION util.current_session(
    OUT account           uuid,
    OUT tenant            uuid,
    OUT data_privilege    privilege,
    OUT model_privilege   privilege,
    OUT account_privilege privilege,
    OUT history_privilege privilege
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_token text := current_setting('wtf.token', true);
BEGIN
    IF v_token IS NULL OR v_token = '' THEN
        PERFORM util.raise_unauthenticated('Not logged in');
    END IF;

    SELECT a.id, a.tenant, a.data_privilege, a.model_privilege, a.account_privilege, a.history_privilege
    INTO account, tenant, data_privilege, model_privilege, account_privilege, history_privilege
    FROM session s
    JOIN account a ON a.id = s.account
    WHERE s.token_hash = util.token_hash(v_token)
      AND s.last_used > now() - interval '30 days'
      AND NOT a.deleted;

    IF NOT FOUND THEN
        PERFORM util.raise_unauthenticated('Session expired or invalid');
    END IF;
END;
$$;

-- Checks that the session's account has at least p_level ('read' or
-- 'write') in privilege area p_area ('data', 'model', 'account' or
-- 'history'), and returns its tenant. Raises 42501 (403) otherwise.
-- History is read-only: read_write counts as read_only there.
CREATE FUNCTION util.require(p_area text, p_level text) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_session   record;
    v_privilege privilege;
BEGIN
    SELECT * INTO v_session FROM util.current_session();
    v_privilege := CASE p_area
        WHEN 'data'    THEN v_session.data_privilege
        WHEN 'model'   THEN v_session.model_privilege
        WHEN 'account' THEN v_session.account_privilege
        WHEN 'history' THEN v_session.history_privilege
    END;
    IF v_privilege IS NULL THEN
        RAISE EXCEPTION 'Unknown privilege area %', p_area;
    END IF;

    IF v_privilege = 'none'
       OR (p_level = 'write' AND v_privilege <> 'read_write')
    THEN
        RAISE EXCEPTION 'This needs % % privilege',
            CASE p_level WHEN 'write' THEN 'read-write' ELSE 'read' END, p_area
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_session.tenant;
END;
$$;

-- Any logged-in account; returns its tenant. For system data (units, …) and
-- the account's own information.
CREATE FUNCTION util.require_login() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT tenant FROM util.current_session());
END;
$$;

-- Password rules: at least 8 characters, at most 72 bytes (bcrypt's limit).
CREATE FUNCTION util.check_password(p_password text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_password IS NULL OR char_length(p_password) < 8 THEN
        PERFORM util.raise_invalid('A password needs at least 8 characters');
    END IF;
    IF octet_length(p_password) > 72 THEN
        PERFORM util.raise_invalid('A password can be at most 72 bytes long');
    END IF;
END;
$$;

-- bcrypt hash of a password, or NULL for NULL (= can't log in).
CREATE FUNCTION util.password_hash(p_password text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    IF p_password IS NULL THEN
        RETURN NULL;
    END IF;
    PERFORM util.check_password(p_password);
    RETURN extensions.crypt(p_password, extensions.gen_salt('bf'));
END;
$$;

CREATE FUNCTION util.tenant_json(p_tenant uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object('id', t.id, 'name', t.name, 'hostname', t.hostname)
        FROM tenant t
        WHERE t.id = p_tenant
    );
END;
$$;

CREATE FUNCTION util.account_json(p_account uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',                a.id,
            'email',             a.email,
            'has_password',      a.password_hash IS NOT NULL,
            'data_privilege',    a.data_privilege,
            'model_privilege',   a.model_privilege,
            'account_privilege', a.account_privilege,
            'history_privilege', a.history_privilege,
            'deleted',           a.deleted
        )
        FROM account a
        WHERE a.id = p_account
    );
END;
$$;

-- Reading the model (classes, attributes, options) is allowed with the model
-- or the data read privilege: entering data needs to see the model.
-- Returns the tenant.
CREATE FUNCTION util.require_model_read() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_session record;
BEGIN
    SELECT * INTO v_session FROM util.current_session();
    IF v_session.model_privilege = 'none' AND v_session.data_privilege = 'none' THEN
        RAISE EXCEPTION 'This needs read model or read data privilege'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_session.tenant;
END;
$$;
