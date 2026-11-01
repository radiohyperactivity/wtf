-- Model files (schema model), which hold quantities and units, attributes
-- and a tree of classes that use them: importing one, and exporting a class
-- with everything below it. The format is in seed/model-format.md.

CREATE SCHEMA model;

-- ---------------------------------------------------------------------------
-- Reading a file
-- ---------------------------------------------------------------------------

-- Raises "invalid" unless p_value (at p_where in a model file) is an object
-- whose keys are among p_keys and "meta", and has every key of p_required.
-- What is in "meta" is for people, and is never read.
CREATE FUNCTION model.file_object(p_value jsonb, p_where text, p_keys text[], p_required text[])
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
        PERFORM error.invalid(format('%s must be an object', p_where));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_value) LOOP
        IF NOT v_key = ANY (p_keys) AND v_key <> 'meta' THEN
            PERFORM error.invalid(format(
                '%s: unknown key "%s" (notes of your own go in "meta")', p_where, v_key));
        END IF;
    END LOOP;
    FOREACH v_key IN ARRAY p_required LOOP
        IF jsonb_typeof(p_value -> v_key) IS NULL OR jsonb_typeof(p_value -> v_key) = 'null' THEN
            PERFORM error.invalid(format('%s needs "%s"', p_where, v_key));
        END IF;
    END LOOP;
END;
$$;

-- The text at p_key of a model file object: a string that isn't blank,
-- trimmed.
CREATE FUNCTION model.file_text(p_value jsonb, p_key text, p_where text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value -> p_key) IS DISTINCT FROM 'string' OR btrim(p_value ->> p_key) = '' THEN
        PERFORM error.invalid(format('%s: "%s" must be text', p_where, p_key));
    END IF;
    RETURN btrim(p_value ->> p_key);
END;
$$;

-- The list at p_key of a model file object; an empty one when it is absent.
CREATE FUNCTION model.file_list(p_value jsonb, p_key text, p_where text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value -> p_key IS NULL OR jsonb_typeof(p_value -> p_key) = 'null' THEN
        RETURN '[]'::jsonb;
    END IF;
    IF jsonb_typeof(p_value -> p_key) <> 'array' THEN
        PERFORM error.invalid(format('%s: "%s" must be a list', p_where, p_key));
    END IF;
    RETURN p_value -> p_key;
END;
$$;

-- A factor or offset of a model file: a decimal, preferably as text so that
-- no digit is lost ("0.55555555555555555556"), or a JSON number.
CREATE FUNCTION model.file_decimal(p_value jsonb, p_where text)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value) = 'number'
       OR (jsonb_typeof(p_value) = 'string'
           AND btrim(p_value #>> '{}') ~ '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
    THEN
        RETURN (btrim(p_value #>> '{}'))::numeric;
    END IF;
    PERFORM error.invalid(format('%s must be a decimal number, such as "0.0254"', p_where));
END;
$$;

-- The units of tenant p_tenant that a model file's p_ref may mean: by
-- symbol or name, in family p_family (any when NULL).
CREATE FUNCTION model.file_units(p_tenant uuid, p_ref text, p_family text)
RETURNS TABLE (unit uuid, family text)
LANGUAGE sql STABLE AS $$
    SELECT u.id, f.name
    FROM public.unit u
    JOIN public.unit_family f ON f.id = u.family
    WHERE (u.symbol = p_ref OR lower(u.name) = lower(p_ref))
      AND (u.tenant IS NULL OR u.tenant = p_tenant)
      AND (p_family IS NULL OR lower(f.name) = lower(p_family));
$$;

-- The unit a model file names, among the units tenant p_tenant sees: by
-- symbol or name, with its family in brackets where several families have
-- it ("B (Binary bytes)"). Returns the unit, or NULL and why not; a unit
-- whose family or quantity the tenant has turned off isn't available.
CREATE FUNCTION model.file_unit(p_tenant uuid, p_ref text, OUT unit uuid, OUT problem text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ref      text := btrim(p_ref);
    v_family   text;
    v_units    uuid[];
    v_families text[];
BEGIN
    IF v_ref ~ '^.+ \([^()]+\)$' THEN
        v_family := substring(v_ref FROM '\(([^()]+)\)$');
        v_ref := btrim(substring(v_ref FROM '^(.+) \([^()]+\)$'));
    END IF;
    SELECT array_agg(m.unit ORDER BY m.family), array_agg(m.family ORDER BY m.family)
    INTO v_units, v_families
    FROM model.file_units(p_tenant, v_ref, v_family) m;
    IF v_units IS NULL THEN
        problem := format('There is no unit %s', p_ref);
    ELSIF cardinality(v_units) > 1 THEN
        problem := format('%s is in several unit families; name one, as in "%s (%s)"', v_ref, v_ref, v_families[1]);
    ELSIF NOT (
        SELECT coalesce(qc.available, q.standard, true) AND coalesce(fc.available, f.standard, true)
        FROM public.unit u
        JOIN public.unit_family f ON f.id = u.family
        JOIN public.quantity q    ON q.id = f.quantity
        LEFT JOIN public.tenant_quantity qc    ON qc.quantity = q.id AND qc.tenant = p_tenant
        LEFT JOIN public.tenant_unit_family fc ON fc.family = f.id AND fc.tenant = p_tenant
        WHERE u.id = v_units[1]
    ) THEN
        problem := format('The unit %s isn''t available: its family or quantity is turned off', p_ref);
    ELSE
        unit := v_units[1];
    END IF;
END;
$$;

-- An assignment's default from a model file as the API takes it: numbers
-- converted from unit p_unit (the attribute's) to the base unit; anything
-- else as it is.
CREATE FUNCTION model.default_value(p_unit uuid, p_value jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN jsonb_typeof(p_value) = 'number' AND p_unit IS NOT NULL
                THEN (SELECT to_jsonb(trim_scale(p_value::numeric * u.base_factor + u.base_offset))
                      FROM public.unit u WHERE u.id = p_unit)
                ELSE p_value END;
$$;

-- ---------------------------------------------------------------------------
-- Importing
-- ---------------------------------------------------------------------------
-- Everything is matched by name: what is there and the same is used, what
-- is missing is added, and what differs is a conflict; nothing that exists
-- is ever changed. What could conflict is checked with plain queries before
-- each insert, rather than by catching a rule's refusal (which would cost a
-- subtransaction per insert); a refusal a check missed aborts the import
-- with that rule's message. All or nothing either way.

-- Appends p_value to the list at p_path of an import report.
CREATE FUNCTION model.report_add(p_report jsonb, p_path text[], p_value jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_set(p_report, p_path, (p_report #> p_path) || jsonb_build_array(p_value));
$$;

-- Adds a conflict to an import report.
CREATE FUNCTION model.report_conflict(p_report jsonb, p_where text, p_message text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT model.report_add(p_report, ARRAY['conflicts'],
                            jsonb_build_object('where', p_where, 'message', p_message));
$$;

-- Imports the quantities p_list of a model file, with their unit families
-- and units, for tenant p_tenant, or as global units with p_tenant NULL.
-- Matched by name among what the tenant sees (only the global ones for a
-- global import): quantities and families with letter case ignored, units
-- by symbol within their family. What is there already must be the same
-- (datatype and base unit; quantity; name, factor and offset), or it is a
-- conflict. A new quantity's base unit is the unit of its families with the
-- file's base symbol; one the file never gives is a conflict. Returns
-- p_report with what was added, what existed, and the conflicts.
CREATE FUNCTION model.import_units(p_tenant uuid, p_list jsonb, p_report jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_q        record;   -- a quantity of the file: its position and object
    v_f        record;
    v_u        record;
    v_where    text;
    v_name     text;
    v_datatype public.datatype;
    v_base     text;     -- the file's base unit symbol
    v_base_id  uuid;     -- a new quantity's base unit's id, made beforehand
    v_quantity public.quantity;
    v_family   public.unit_family;
    v_unit     public.unit;
    v_symbol   text;
    v_uname    text;
    v_factor   numeric;
    v_offset   numeric;
    v_taken    text;
BEGIN
    FOR v_q IN SELECT n - 1 AS i, q FROM jsonb_array_elements(p_list) WITH ORDINALITY t (q, n) LOOP
        v_where := format('quantities[%s]', v_q.i);
        PERFORM model.file_object(v_q.q, v_where, ARRAY['name', 'datatype', 'base_unit', 'families'],
                                  ARRAY['name', 'base_unit']);
        v_name := model.file_text(v_q.q, 'name', v_where);
        v_where := v_name;
        IF coalesce(v_q.q ->> 'datatype', 'decimal') NOT IN ('decimal', 'integer') THEN
            PERFORM error.invalid(format('%s: "datatype" must be "decimal" or "integer"', v_where));
        END IF;
        v_datatype := coalesce(v_q.q ->> 'datatype', 'decimal')::public.datatype;
        PERFORM model.file_object(v_q.q -> 'base_unit', v_where || ': "base_unit"',
                                  ARRAY['symbol', 'name'], ARRAY['symbol', 'name']);
        v_base := model.file_text(v_q.q -> 'base_unit', 'symbol', v_where || ': "base_unit"');

        SELECT q.* INTO v_quantity FROM public.quantity q
        WHERE lower(q.name) = lower(v_name) AND (q.tenant IS NULL OR q.tenant = p_tenant);
        IF FOUND THEN
            IF v_quantity.datatype <> v_datatype
               OR (SELECT b.symbol FROM public.unit b WHERE b.id = v_quantity.base_unit) <> v_base THEN
                p_report := model.report_conflict(p_report, v_where, format(
                    'There is a quantity %s already, with base unit %s and datatype %s; the file has %s and %s',
                    v_quantity.name, (SELECT b.symbol FROM public.unit b WHERE b.id = v_quantity.base_unit),
                    v_quantity.datatype, v_base, v_datatype));
                CONTINUE;
            END IF;
            v_base_id := NULL;
            p_report := model.report_add(p_report, ARRAY['quantities', 'existing'], to_jsonb(v_quantity.name));
        ELSE
            -- A global quantity's name must be no tenant's (unit.check_quantity).
            SELECT string_agg(t.host, ', ') INTO v_taken FROM public.quantity q
            JOIN public.tenant t ON t.id = q.tenant
            WHERE p_tenant IS NULL AND lower(q.name) = lower(v_name);
            IF v_taken IS NOT NULL THEN
                p_report := model.report_conflict(p_report, v_where,
                    format('Tenants have a quantity named %s already (%s)', v_name, v_taken));
                CONTINUE;
            END IF;
            v_base_id := uuidv7();
            INSERT INTO public.quantity (tenant, name, datatype, base_unit, standard)
            VALUES (p_tenant, v_name, v_datatype, v_base_id, CASE WHEN p_tenant IS NULL THEN true END)
            RETURNING * INTO v_quantity;
            p_report := model.report_add(p_report, ARRAY['quantities', 'added'], to_jsonb(v_quantity.name));
        END IF;

        FOR v_f IN SELECT n - 1 AS i, f
                   FROM jsonb_array_elements(model.file_list(v_q.q, 'families', v_where)) WITH ORDINALITY t (f, n) LOOP
            v_where := format('%s: families[%s]', v_quantity.name, v_f.i);
            PERFORM model.file_object(v_f.f, v_where, ARRAY['name', 'units'], ARRAY['name']);
            v_name := model.file_text(v_f.f, 'name', v_where);
            v_where := v_quantity.name || ' › ' || v_name;

            SELECT f.* INTO v_family FROM public.unit_family f
            WHERE lower(f.name) = lower(v_name) AND (f.tenant IS NULL OR f.tenant = p_tenant);
            IF FOUND THEN
                IF v_family.quantity <> v_quantity.id THEN
                    p_report := model.report_conflict(p_report, v_where, format(
                        'There is a unit family %s already, of quantity %s',
                        v_family.name, (SELECT q.name FROM public.quantity q WHERE q.id = v_family.quantity)));
                    CONTINUE;
                END IF;
                p_report := model.report_add(p_report, ARRAY['families', 'existing'],
                                             to_jsonb(v_quantity.name || ' › ' || v_family.name));
            ELSE
                -- A global family's name must be no tenant's (unit.check_family).
                SELECT string_agg(t.host, ', ') INTO v_taken FROM public.unit_family f
                JOIN public.tenant t ON t.id = f.tenant
                WHERE p_tenant IS NULL AND lower(f.name) = lower(v_name);
                IF v_taken IS NOT NULL THEN
                    p_report := model.report_conflict(p_report, v_where,
                        format('Tenants have a unit family named %s already (%s)', v_name, v_taken));
                    CONTINUE;
                END IF;
                INSERT INTO public.unit_family (tenant, quantity, name, standard)
                VALUES (p_tenant, v_quantity.id, v_name, CASE WHEN p_tenant IS NULL THEN true END)
                RETURNING * INTO v_family;
                p_report := model.report_add(p_report, ARRAY['families', 'added'],
                                             to_jsonb(v_quantity.name || ' › ' || v_family.name));
            END IF;

            FOR v_u IN SELECT n - 1 AS i, u
                       FROM jsonb_array_elements(model.file_list(v_f.f, 'units', v_where)) WITH ORDINALITY t (u, n) LOOP
                v_where := format('%s › %s: units[%s]', v_quantity.name, v_family.name, v_u.i);
                PERFORM model.file_object(v_u.u, v_where, ARRAY['symbol', 'name', 'factor', 'offset'],
                                          ARRAY['symbol', 'name', 'factor']);
                v_symbol := model.file_text(v_u.u, 'symbol', v_where);
                v_uname  := model.file_text(v_u.u, 'name', v_where);
                v_where  := format('%s › %s › %s', v_quantity.name, v_family.name, v_symbol);
                v_factor := model.file_decimal(v_u.u -> 'factor', v_where || ': "factor"');
                v_offset := CASE WHEN v_u.u ? 'offset'
                                 THEN model.file_decimal(v_u.u -> 'offset', v_where || ': "offset"')
                                 ELSE 0 END;
                IF v_factor <= 0 THEN
                    PERFORM error.invalid(format('%s: "factor" must be more than 0', v_where));
                END IF;

                SELECT u.* INTO v_unit FROM public.unit u
                WHERE u.family = v_family.id AND u.symbol = v_symbol
                  AND (u.tenant IS NULL OR u.tenant = p_tenant);
                IF FOUND THEN
                    IF lower(v_unit.name) <> lower(v_uname)
                       OR v_unit.base_factor <> v_factor OR v_unit.base_offset <> v_offset THEN
                        p_report := model.report_conflict(p_report, v_where, format(
                            'There is a unit %s already: %s, factor %s, offset %s; the file has %s, factor %s, offset %s',
                            v_unit.symbol, v_unit.name, v_unit.base_factor, v_unit.base_offset,
                            v_uname, v_factor, v_offset));
                    ELSE
                        p_report := model.report_add(p_report, ARRAY['units', 'existing'], to_jsonb(v_where));
                    END IF;
                    CONTINUE;
                END IF;

                -- What the unit rules would refuse, checked first: its name
                -- taken in the family, among what the tenant sees (or by any
                -- tenant, for a global import) …
                IF EXISTS (SELECT 1 FROM public.unit x
                           WHERE x.family = v_family.id
                             AND (x.symbol = v_symbol OR lower(x.name) = lower(v_uname))
                             AND (p_tenant IS NULL OR x.tenant IS NULL OR x.tenant = p_tenant)) THEN
                    p_report := model.report_conflict(p_report, v_where, format(
                        'The family %s has a unit named %s or %s already', v_family.name, v_uname, v_symbol));
                    CONTINUE;
                END IF;
                -- … and its symbol meaning another unit in the quantity.
                IF EXISTS (SELECT 1 FROM public.unit x JOIN public.unit_family f ON f.id = x.family
                           WHERE f.quantity = v_quantity.id AND x.symbol = v_symbol
                             AND (p_tenant IS NULL OR x.tenant IS NULL OR x.tenant = p_tenant)
                             AND (x.base_factor <> v_factor OR x.base_offset <> v_offset)) THEN
                    p_report := model.report_conflict(p_report, v_where, format(
                        'The symbol %s means another unit in %s already', v_symbol, v_quantity.name));
                    CONTINUE;
                END IF;

                -- A new quantity's base unit is the first unit with its
                -- symbol; it gets the id the quantity already refers to. Its
                -- factor must be 1 and its offset 0 (the rule
                -- unit.check_base_unit's, at commit); a file that says
                -- otherwise is refused here, as other malformed files are.
                IF v_symbol = v_base AND v_base_id IS NOT NULL AND (v_factor <> 1 OR v_offset <> 0) THEN
                    PERFORM error.invalid(format('The base unit of %s (%s) must have factor 1 and offset 0',
                                                 v_quantity.name, v_base));
                END IF;
                INSERT INTO public.unit (id, tenant, family, name, symbol, base_factor, base_offset)
                VALUES (CASE WHEN v_symbol = v_base AND v_base_id IS NOT NULL THEN v_base_id ELSE uuidv7() END,
                        p_tenant, v_family.id, v_uname, v_symbol, v_factor, v_offset)
                RETURNING * INTO v_unit;
                IF v_unit.id = v_base_id THEN
                    v_base_id := NULL;   -- found; a second unit with the symbol is an ordinary unit
                END IF;
                p_report := model.report_add(p_report, ARRAY['units', 'added'], to_jsonb(v_where));
            END LOOP;
        END LOOP;

        -- A new quantity whose base unit the file never gave.
        IF v_base_id IS NOT NULL THEN
            p_report := model.report_conflict(p_report, v_quantity.name, format(
                'The base unit %s must be one of %s''s units, with factor 1 and offset 0', v_base, v_quantity.name));
        END IF;
    END LOOP;
    RETURN p_report;
END;
$$;

-- Imports the attributes of a model file for tenant p_tenant. Returns the
-- report with the attributes added, existing and conflicting, and in
-- p_attributes, by lower-case name, {id, unit} of each (id null when it
-- conflicts), for the classes to refer to.
CREATE FUNCTION model.import_attributes(
    p_tenant         uuid,
    p_list           jsonb,
    INOUT p_report   jsonb,
    OUT p_attributes jsonb
)
LANGUAGE plpgsql AS $$
DECLARE
    v_a        record;
    v_where    text;
    v_name     text;
    v_datatype text;
    v_unit     uuid;
    v_problem  text;
    v_unit_type public.datatype;
    v_lock     boolean;
    v_options  jsonb;
    v_existing public.attribute;
    v_id       uuid;
    v_added    text[];
BEGIN
    p_attributes := '{}';
    FOR v_a IN SELECT n - 1 AS i, a FROM jsonb_array_elements(p_list) WITH ORDINALITY t (a, n) LOOP
        v_where := format('attributes[%s]', v_a.i);
        PERFORM model.file_object(v_a.a, v_where, ARRAY['name', 'datatype', 'unit', 'unit_lock', 'options'],
                                  ARRAY['name']);
        v_name := model.file_text(v_a.a, 'name', v_where);
        v_where := format('Attribute %s', v_name);
        IF p_attributes ? lower(v_name) THEN
            PERFORM error.invalid(format('%s appears twice in the file', v_where));
        END IF;
        p_attributes := p_attributes || jsonb_build_object(lower(v_name), jsonb_build_object('id', NULL));

        v_datatype := v_a.a ->> 'datatype';
        IF v_datatype IS NOT NULL
           AND v_datatype NOT IN ('text', 'integer', 'decimal', 'date', 'boolean', 'url', 'choice') THEN
            PERFORM error.invalid(format(
                '%s: "datatype" must be text, integer, decimal, date, boolean, url or choice', v_where));
        END IF;
        IF v_a.a -> 'unit_lock' IS NOT NULL AND jsonb_typeof(v_a.a -> 'unit_lock') NOT IN ('boolean', 'null') THEN
            PERFORM error.invalid(format('%s: "unit_lock" must be true or false', v_where));
        END IF;
        v_lock := coalesce((v_a.a ->> 'unit_lock')::boolean, false);
        v_options := model.file_list(v_a.a, 'options', v_where);
        IF jsonb_array_length(v_options) > 0 AND v_datatype IS DISTINCT FROM 'choice' THEN
            PERFORM error.invalid(format('%s: only choice attributes have "options"', v_where));
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_options) o
                   WHERE jsonb_typeof(o) <> 'string' OR btrim(o #>> '{}') = '') THEN
            PERFORM error.invalid(format('%s: "options" must be a list of names', v_where));
        END IF;
        IF v_a.a ->> 'unit' IS NULL THEN
            IF v_datatype IS NULL THEN
                PERFORM error.invalid(format('%s needs "datatype", or a "unit"', v_where));
            END IF;
            IF v_lock THEN
                PERFORM error.invalid(format('%s: "unit_lock" needs a "unit"', v_where));
            END IF;
            v_unit := NULL;
        ELSE
            SELECT m.unit, m.problem INTO v_unit, v_problem FROM model.file_unit(p_tenant, v_a.a ->> 'unit') m;
            IF v_problem IS NOT NULL THEN
                p_report := model.report_conflict(p_report, v_where, v_problem);
                CONTINUE;
            END IF;
            -- Its datatype is its quantity's.
            SELECT q.datatype INTO v_unit_type
            FROM public.unit u
            JOIN public.unit_family f ON f.id = u.family
            JOIN public.quantity q    ON q.id = f.quantity
            WHERE u.id = v_unit;
            IF v_datatype IS NULL THEN
                v_datatype := v_unit_type::text;
            ELSIF v_datatype <> v_unit_type::text THEN
                p_report := model.report_conflict(p_report, v_where, format(
                    'With the unit %s the datatype is %s, not %s', v_a.a ->> 'unit', v_unit_type, v_datatype));
                CONTINUE;
            END IF;
        END IF;

        SELECT a.* INTO v_existing FROM public.attribute a
        WHERE a.tenant = p_tenant AND lower(a.name) = lower(v_name);
        IF FOUND THEN
            IF v_existing.datatype::text <> v_datatype THEN
                p_report := model.report_conflict(p_report, v_where, format(
                    'There is an attribute %s already, of datatype %s; the file has %s',
                    v_existing.name, v_existing.datatype, v_datatype));
                CONTINUE;
            END IF;
            -- A unit of the same quantity, or none, as the file's.
            IF (v_existing.unit IS NULL) <> (v_unit IS NULL)
               OR (SELECT f.quantity FROM public.unit u JOIN public.unit_family f ON f.id = u.family
                   WHERE u.id = v_existing.unit)
                  IS DISTINCT FROM
                  (SELECT f.quantity FROM public.unit u JOIN public.unit_family f ON f.id = u.family
                   WHERE u.id = v_unit) THEN
                p_report := model.report_conflict(p_report, v_where, format(
                    'There is an attribute %s already, %s; the file has %s',
                    v_existing.name,
                    coalesce('measured in ' || (SELECT q.name FROM public.unit u
                                                JOIN public.unit_family f ON f.id = u.family
                                                JOIN public.quantity q ON q.id = f.quantity
                                                WHERE u.id = v_existing.unit), 'without a unit'),
                    coalesce('a unit of ' || (SELECT q.name FROM public.unit u
                                              JOIN public.unit_family f ON f.id = u.family
                                              JOIN public.quantity q ON q.id = f.quantity
                                              WHERE u.id = v_unit), 'no unit')));
                CONTINUE;
            END IF;
            v_id := v_existing.id;
            v_unit := v_existing.unit;
            p_report := model.report_add(p_report, ARRAY['attributes', 'existing'], to_jsonb(v_existing.name));
        ELSE
            -- Matched by name, so no attribute has it, and its datatype
            -- was checked against its unit just above: nothing is left for a
            -- rule to refuse.
            INSERT INTO public.attribute (tenant, name, datatype, unit, unit_lock)
            VALUES (p_tenant, v_name, v_datatype::public.datatype, v_unit, v_lock)
            RETURNING id INTO v_id;
            p_report := model.report_add(p_report, ARRAY['attributes', 'added'], to_jsonb(v_name));
        END IF;

        -- The options it lacks, in one statement; the file's own repeats
        -- counted once.
        WITH added AS (
            INSERT INTO public.attribute_option (attribute, name)
            SELECT DISTINCT ON (lower(btrim(o #>> '{}'))) v_id, btrim(o #>> '{}')
            FROM jsonb_array_elements(v_options) o
            WHERE NOT EXISTS (SELECT 1 FROM public.attribute_option x
                              WHERE x.attribute = v_id AND lower(x.name) = lower(btrim(o #>> '{}')))
            RETURNING name
        )
        SELECT array_agg(a.name ORDER BY a.name) INTO v_added FROM added a;
        p_report := jsonb_set(p_report, ARRAY['options', 'added'],
                              (p_report #> ARRAY['options', 'added'])
                              || coalesce((SELECT jsonb_agg(format('%s: %s', v_name, n)) FROM unnest(v_added) n),
                                          '[]'));

        p_attributes := p_attributes || jsonb_build_object(lower(v_name),
            jsonb_build_object('id', v_id, 'unit', v_unit));
    END LOOP;
END;
$$;

-- Imports the classes p_list of a model file below class p_parent (the top
-- when NULL), whose path is p_path, and below them their classes. Returns
-- the report with what was added, what existed and the conflicts.
CREATE FUNCTION model.import_classes(
    p_tenant     uuid,
    p_parent     uuid,
    p_path       text,
    p_list       jsonb,
    p_attributes jsonb,
    p_report     jsonb
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_c         record;
    v_s         record;
    v_where     text;
    v_at        text;
    v_name      text;
    v_path      text;
    v_seen      text[] := '{}';
    v_container boolean;
    v_class     public.class;
    v_applies   jsonb;
    v_ref       text;
    v_attr      jsonb;
    v_attribute public.attribute;
    v_scope     text;
    v_required  boolean;
    v_default   record;
    v_want      jsonb;
    v_have      jsonb;
BEGIN
    FOR v_c IN SELECT n - 1 AS i, c FROM jsonb_array_elements(p_list) WITH ORDINALITY t (c, n) LOOP
        v_where := format('%sclasses[%s]', coalesce(p_path || ': ', ''), v_c.i);
        PERFORM model.file_object(v_c.c, v_where, ARRAY['name', 'container', 'attributes', 'classes'], ARRAY['name']);
        v_name := util.trim_and_check_path_name(model.file_text(v_c.c, 'name', v_where), 'class');
        v_path := coalesce(p_path || '/', '') || v_name;
        IF lower(v_name) = ANY (v_seen) THEN
            PERFORM error.invalid(format('Class %s appears twice in the file', v_path));
        END IF;
        v_seen := v_seen || lower(v_name);
        IF v_c.c -> 'container' IS NOT NULL AND jsonb_typeof(v_c.c -> 'container') NOT IN ('boolean', 'null') THEN
            PERFORM error.invalid(format('Class %s: "container" must be true or false', v_path));
        END IF;
        v_container := (v_c.c ->> 'container')::boolean;
        v_where := format('Class %s', v_path);

        SELECT c.* INTO v_class FROM public.class c
        WHERE c.tenant = p_tenant AND c.parent IS NOT DISTINCT FROM p_parent
          AND lower(c.name) = lower(v_name);
        IF FOUND THEN
            IF v_container IS NOT NULL AND v_container <> v_class.container THEN
                p_report := model.report_conflict(p_report, v_where, format(
                    'There is a class %s already, %s a container; the file has it %s one',
                    v_path, CASE WHEN v_class.container THEN 'which is' ELSE 'which isn''t' END,
                    CASE WHEN v_container THEN 'as' ELSE 'not as' END));
                CONTINUE;
            END IF;
            p_report := model.report_add(p_report, ARRAY['classes', 'existing'], to_jsonb(v_path));
        ELSE
            -- Matched by name among its siblings, so the sibling rule
            -- has nothing to refuse.
            INSERT INTO public.class (tenant, name, parent, container)
            VALUES (p_tenant, v_name, p_parent, coalesce(v_container, false))
            RETURNING * INTO v_class;
            p_report := model.report_add(p_report, ARRAY['classes', 'added'], to_jsonb(v_path));
        END IF;

        -- What applies to the class now, own and inherited, worked out once:
        -- {attribute: {depth, scope, required, default_…}}.
        SELECT coalesce(jsonb_object_agg(e.attribute, jsonb_build_object(
                   'depth', e.depth, 'scope', e.scope, 'required', e.required,
                   'text', e.default_text, 'number', e.default_number, 'date', e.default_date,
                   'boolean', e.default_boolean, 'option', e.default_option)), '{}')
        INTO v_applies
        FROM class.effective_attributes(ARRAY[v_class.id]) e;

        FOR v_s IN SELECT n - 1 AS i, s
                   FROM jsonb_array_elements(model.file_list(v_c.c, 'attributes', v_where)) WITH ORDINALITY t (s, n) LOOP
            PERFORM model.file_object(v_s.s, format('%s: attributes[%s]', v_where, v_s.i),
                                      ARRAY['attribute', 'scope', 'required', 'default'], ARRAY['attribute']);
            v_ref := model.file_text(v_s.s, 'attribute', format('%s: attributes[%s]', v_where, v_s.i));
            v_at := format('%s: %s', v_where, v_ref);
            IF v_s.s ? 'scope' AND coalesce(v_s.s ->> 'scope', '') NOT IN ('item', 'stock') THEN
                PERFORM error.invalid(format('%s: "scope" must be "item" or "stock"', v_at));
            END IF;
            IF v_s.s -> 'required' IS NOT NULL AND jsonb_typeof(v_s.s -> 'required') NOT IN ('boolean', 'null') THEN
                PERFORM error.invalid(format('%s: "required" must be true or false', v_at));
            END IF;
            v_scope    := coalesce(v_s.s ->> 'scope', 'item');
            v_required := coalesce((v_s.s ->> 'required')::boolean, false);

            -- The file's attribute, or else one the inventory has.
            v_attr := p_attributes -> lower(v_ref);
            IF v_attr IS NULL THEN
                SELECT jsonb_build_object('id', a.id, 'unit', a.unit) INTO v_attr
                FROM public.attribute a
                WHERE a.tenant = p_tenant AND lower(a.name) = lower(v_ref);
                IF v_attr IS NULL THEN
                    p_report := model.report_conflict(p_report, v_at,
                        format('There is no attribute %s, in the file or in the inventory', v_ref));
                    CONTINUE;
                END IF;
            END IF;
            CONTINUE WHEN v_attr ->> 'id' IS NULL; -- its conflict is reported already
            SELECT a.* INTO v_attribute FROM public.attribute a WHERE a.id = (v_attr ->> 'id')::uuid;

            -- The default, parsed without raising: a value that doesn't fit
            -- is a conflict, not an error.
            IF v_s.s -> 'default' IS NOT NULL AND jsonb_typeof(v_s.s -> 'default') <> 'null' THEN
                SELECT * INTO v_default
                FROM attribute.try_parse_value(v_attribute, model.default_value(v_attribute.unit, v_s.s -> 'default'));
                IF v_default.problem IS NOT NULL THEN
                    p_report := model.report_conflict(p_report, v_at, v_default.problem);
                    CONTINUE;
                END IF;
            ELSE
                SELECT NULL::text AS text, NULL::numeric AS number, NULL::date AS date,
                       NULL::boolean AS boolean, NULL::uuid AS option, NULL::text AS problem
                INTO v_default;
            END IF;
            v_want := jsonb_build_object('scope', v_scope, 'required', v_required,
                                         'text', v_default.text, 'number', v_default.number,
                                         'date', v_default.date, 'boolean', v_default.boolean,
                                         'option', v_default.option);

            -- What the class has now: its own assignment (depth 0), or one it
            -- inherits. Either is used when it is the same; one of its own
            -- that differs is a conflict, an inherited one is overridden by a
            -- new own assignment.
            v_have := v_applies -> v_attribute.id::text;
            IF (v_have - 'depth') = v_want THEN
                p_report := model.report_add(p_report, ARRAY['assignments', 'existing'],
                                             to_jsonb(format('%s: %s', v_path, v_ref)));
                CONTINUE;
            END IF;
            IF (v_have ->> 'depth')::integer = 0 THEN
                p_report := model.report_conflict(p_report, v_at,
                    format('%s has %s already, %s', v_path, v_ref, concat_ws(', ',
                        CASE WHEN v_have ->> 'scope' = 'stock' THEN 'on each stock row' ELSE 'on the item' END,
                        CASE WHEN (v_have ->> 'required')::boolean THEN 'required' ELSE 'not required' END,
                        CASE WHEN EXISTS (SELECT 1 FROM jsonb_each(v_have - 'depth' - 'scope' - 'required') d
                                          WHERE jsonb_typeof(d.value) <> 'null')
                             THEN 'with another default' ELSE 'without a default' END)
                        || '; the file has it otherwise'));
                CONTINUE;
            END IF;
            INSERT INTO public.class_attribute (class, attribute, scope, required,
                                                default_text, default_number, default_date,
                                                default_boolean, default_option)
            VALUES (v_class.id, v_attribute.id, v_scope::public.scope, v_required,
                    v_default.text, v_default.number, v_default.date,
                    v_default.boolean, v_default.option);
            p_report := model.report_add(p_report, ARRAY['assignments', 'added'],
                                         to_jsonb(format('%s: %s', v_path, v_ref)));
        END LOOP;

        p_report := model.import_classes(p_tenant, v_class.id, v_path,
            model.file_list(v_c.c, 'classes', v_where), p_attributes, p_report);
    END LOOP;
    RETURN p_report;
END;
$$;

-- Imports a model file (seed/model-format.md) for tenant p_tenant: its
-- quantities and units, its attributes, and its classes at the top of the
-- class tree or below class p_parent, whose path is p_path. With p_tenant
-- NULL (the operator's "wtfd unit import --global") the units are imported
-- as global ones, and the file may hold only units.
--
-- All or nothing: with any conflict, or with p_dry_run, nothing is kept.
-- Returns what was (or would be) added, what was there already, and the
-- conflicts:
--   {applied, dry_run,
--    quantities:  {added: [name], existing: [name]},
--    families:    {added: ["Quantity › Family"], existing: [...]},
--    units:       {added: ["Quantity › Family › symbol"], existing: [...]},
--    attributes:  {added: [name], existing: [name]},
--    options:     {added: ["Attribute: option"]},
--    classes:     {added: [path], existing: [path]},
--    assignments: {added: ["path: attribute"], existing: [...]},
--    conflicts:   [{where, message}]}
-- A file that isn't a valid model file raises "invalid", naming where.
CREATE FUNCTION model.import_file(
    p_tenant  uuid,
    p_data    jsonb,
    p_parent  uuid,
    p_path    text,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_attributes jsonb;
    v_report     jsonb := '{"quantities": {"added": [], "existing": []},
                            "families": {"added": [], "existing": []},
                            "units": {"added": [], "existing": []},
                            "attributes": {"added": [], "existing": []},
                            "options": {"added": []},
                            "classes": {"added": [], "existing": []},
                            "assignments": {"added": [], "existing": []},
                            "conflicts": []}';
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether the import is a dry run');
    END IF;
    PERFORM model.file_object(p_data, 'The file', ARRAY['format', 'version', 'quantities', 'attributes', 'classes'],
                              ARRAY['format', 'version']);
    IF p_data ->> 'format' IS DISTINCT FROM 'wtf-model' THEN
        PERFORM error.invalid('This is not a WtF model file: "format" must be "wtf-model"');
    END IF;
    IF jsonb_typeof(p_data -> 'version') <> 'number' THEN
        PERFORM error.invalid('"version" must be a number');
    END IF;
    IF (p_data ->> 'version')::numeric > 1 THEN
        PERFORM error.invalid(format(
            'This model file is version %s, made for a newer WtF; this one reads version 1', p_data ->> 'version'));
    END IF;
    IF (p_data ->> 'version')::numeric <> 1 THEN
        PERFORM error.invalid('"version" must be 1');
    END IF;
    IF p_tenant IS NULL AND (jsonb_array_length(model.file_list(p_data, 'attributes', 'The file')) > 0
                             OR jsonb_array_length(model.file_list(p_data, 'classes', 'The file')) > 0) THEN
        PERFORM error.invalid('Global units come from a file of only quantities; this one has attributes or classes');
    END IF;

    BEGIN -- a subtransaction, rolled back for a dry run or a conflict
        v_report := model.import_units(p_tenant, model.file_list(p_data, 'quantities', 'The file'), v_report);
        IF p_tenant IS NOT NULL THEN
            SELECT a.p_report, a.p_attributes INTO v_report, v_attributes
            FROM model.import_attributes(p_tenant, model.file_list(p_data, 'attributes', 'The file'), v_report) a;
            v_report := model.import_classes(p_tenant, p_parent, p_path,
                model.file_list(p_data, 'classes', 'The file'), v_attributes, v_report);
        END IF;
        -- The rules that run at commit (a quantity's base unit, required
        -- values) run now, so that a dry run is refused as the import would
        -- be. Not when there are conflicts: nothing is kept then anyway.
        IF jsonb_array_length(v_report -> 'conflicts') = 0 THEN
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
        END IF;

        IF p_dry_run OR jsonb_array_length(v_report -> 'conflicts') > 0 THEN
            RAISE EXCEPTION 'model import rolled back' USING ERRCODE = 'WTF01';
        END IF;
    EXCEPTION WHEN SQLSTATE 'WTF01' THEN
        NULL; -- the report is in the variables, which keep their values
    END;

    RETURN v_report || jsonb_build_object(
        'applied', NOT p_dry_run AND jsonb_array_length(v_report -> 'conflicts') = 0,
        'dry_run', p_dry_run);
END;
$$;

-- ---------------------------------------------------------------------------
-- Exporting
-- ---------------------------------------------------------------------------

-- A number of a model file: p_value rounded to 15 significant digits, so
-- that a conversion leaves no tail of nines (15.999999999999999 MHz).
CREATE FUNCTION model.number(p_value numeric)
RETURNS json
LANGUAGE sql IMMUTABLE AS $$
    SELECT to_json(CASE WHEN p_value = 0 THEN 0
                         ELSE trim_scale(round(p_value, 14 - floor(log(abs(p_value)))::integer)) END);
$$;

-- How a model file names unit p_unit for tenant p_tenant: by symbol, with
-- its family in brackets when the symbol alone could mean another unit.
CREATE FUNCTION model.unit_ref(p_tenant uuid, p_unit uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN (SELECT count(*) FROM model.file_units(p_tenant, u.symbol, NULL)) > 1
                THEN format('%s (%s)', u.symbol, f.name)
                ELSE u.symbol END
    FROM public.unit u JOIN public.unit_family f ON f.id = u.family
    WHERE u.id = p_unit;
$$;

-- An assignment as a model file has it: the attribute's name, where its
-- values live (left out for the item), whether required, and the default:
-- numbers in the attribute's unit, a date as YYYY-MM-DD, an option by name.
-- Built from the rows it is given (the attribute, its unit or NULL, and
-- the default's option or NULL), so it queries nothing.
CREATE FUNCTION model.assignment_json(
    p_attribute public.attribute,
    p_unit      public.unit,
    p_option    public.attribute_option,
    p_scope     public.scope,
    p_required  boolean,
    p_text      text,
    p_number    numeric,
    p_date      date,
    p_boolean   boolean
) RETURNS json
LANGUAGE sql IMMUTABLE AS $$
    SELECT json_strip_nulls(json_build_object(
        'attribute', p_attribute.name,
        'scope',     CASE WHEN p_scope = 'stock' THEN 'stock' END,
        'required',  CASE WHEN p_required THEN true END,
        'default',   CASE
            WHEN p_number IS NOT NULL THEN
                model.number(CASE WHEN p_unit.id IS NULL THEN p_number
                                  ELSE (p_number - p_unit.base_offset) / p_unit.base_factor END)
            WHEN p_text IS NOT NULL THEN to_json(p_text)
            WHEN p_date IS NOT NULL THEN to_json(p_date::text)
            WHEN p_boolean IS NOT NULL THEN to_json(p_boolean)
            WHEN p_option.id IS NOT NULL THEN to_json(p_option.name)
        END));
$$;

-- Class p_class as a model file has it, with the classes below it, one
-- class at a time: its own assignments, from class_attribute by its class;
-- with p_inherited (for the top class of an export, so that the file stands
-- on its own) also those it inherits, from class.effective_attributes.
CREATE FUNCTION model.export_class(p_class uuid, p_inherited boolean)
RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT json_strip_nulls(json_build_object(
            'name',       c.name,
            'container',  CASE WHEN c.container THEN true END,
            'attributes', CASE WHEN p_inherited THEN (
                SELECT json_agg(model.assignment_json(a, u, o, e.scope, e.required,
                                                      e.default_text, e.default_number,
                                                      e.default_date, e.default_boolean)
                                ORDER BY a.name COLLATE public.natural, a.id)
                FROM class.effective_attributes(ARRAY[c.id]) e
                JOIN public.attribute a             ON a.id = e.attribute
                LEFT JOIN public.unit u             ON u.id = a.unit
                LEFT JOIN public.attribute_option o ON o.id = e.default_option)
            ELSE (
                SELECT json_agg(model.assignment_json(a, u, o, ca.scope, ca.required,
                                                      ca.default_text, ca.default_number,
                                                      ca.default_date, ca.default_boolean)
                                ORDER BY a.name COLLATE public.natural, a.id)
                FROM public.class_attribute ca
                JOIN public.attribute a             ON a.id = ca.attribute
                LEFT JOIN public.unit u             ON u.id = a.unit
                LEFT JOIN public.attribute_option o ON o.id = ca.default_option
                WHERE ca.class = c.id) END,
            'classes',    (
                SELECT json_agg(model.export_class(k.id, false) ORDER BY k.name COLLATE public.natural, k.id)
                FROM public.class k
                WHERE k.parent = c.id)
        ))
        FROM public.class c
        WHERE c.id = p_class
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- Imports a model file for the session's tenant (model.import_file): its
-- classes go at the top of the class tree (p_parent NULL), or below class
-- p_parent. With p_dry_run nothing is kept, and the report says what would
-- be. For admins.
CREATE FUNCTION model.import(p_request public.request, p_data jsonb, p_parent uuid, p_dry_run boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_path    text;
BEGIN
    IF p_parent IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.class c
                       WHERE c.id = p_parent AND c.tenant = v_session.tenant) THEN
            PERFORM error.bad_reference('class', p_parent);
        END IF;
        v_path := util.path_text(class.path_json(p_parent));
    END IF;
    RETURN model.import_file(v_session.tenant, p_data, p_parent, v_path, p_dry_run);
END;
$$;

-- Exports one of the tenant's classes with everything below it as a
-- model file (seed/model-format.md): the classes, their assignments (the
-- top class's inherited ones as its own), every attribute they use, and
-- the tenant's own units those attributes need, with the families they are
-- in: those decide how values are shown. Importing the file where the class
-- is changes nothing; importing it elsewhere sets up the same. Reads
-- without locking. For admins.
CREATE FUNCTION model.export(p_request public.request, p_class uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session    record := util.session(p_request, 'admin');
    v_attributes uuid[];
    v_families   uuid[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.class c
                   WHERE c.id = p_class AND c.tenant = v_session.tenant) THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;

    -- The attributes the classes use: the top class's own and inherited,
    -- and the others' own.
    v_attributes := ARRAY(
        WITH RECURSIVE subtree (id) AS (
            SELECT p_class
            UNION
            SELECT c.id FROM public.class c JOIN subtree s ON c.parent = s.id
        )
        SELECT ca.attribute FROM public.class_attribute ca WHERE ca.class IN (SELECT id FROM subtree)
        UNION
        SELECT e.attribute FROM class.effective_attributes(ARRAY[p_class]) e);
    -- The unit families an export needs: those that are the tenant's own or
    -- have units of its own. Every WtF has the rest.
    v_families := ARRAY(
        SELECT DISTINCT f.id
        FROM public.attribute a
        JOIN public.unit u        ON u.id = a.unit
        JOIN public.unit_family f ON f.id = u.family
        WHERE a.id = ANY (v_attributes)
          AND (f.tenant = v_session.tenant
               OR EXISTS (SELECT 1 FROM public.unit x WHERE x.family = f.id AND x.tenant = v_session.tenant)));
    -- And for a quantity of the tenant's own among them, the family of its
    -- base unit, which importing the file needs to set the quantity up.
    v_families := v_families || ARRAY(
        SELECT DISTINCT b.family
        FROM public.unit_family f
        JOIN public.quantity q ON q.id = f.quantity
        JOIN public.unit b     ON b.id = q.base_unit
        WHERE f.id = ANY (v_families) AND q.tenant = v_session.tenant
          AND b.family <> ALL (v_families));

    RETURN json_strip_nulls(json_build_object(
        'format',  'wtf-model',
        'version', 1,
        'meta',    json_build_object(
                       'name',          (SELECT c.name FROM public.class c WHERE c.id = p_class),
                       'class',         util.path_text(class.path_json(p_class)),
                       'exported_from', (SELECT t.host FROM public.tenant t WHERE t.id = v_session.tenant),
                       'exported_at',   date_trunc('second', now())),
        'quantities', (
            SELECT json_agg(json_build_object(
                       'name',      q.name,
                       'datatype',  q.datatype,
                       'base_unit', json_build_object('symbol', b.symbol, 'name', b.name),
                       'families',  (
                           SELECT json_agg(json_build_object(
                                      'name',  f.name,
                                      'units', (
                                          SELECT coalesce(json_agg(json_strip_nulls(json_build_object(
                                                     'symbol', u.symbol,
                                                     'name',   u.name,
                                                     'factor', trim_scale(u.base_factor)::text,
                                                     'offset', CASE WHEN u.base_offset <> 0
                                                                    THEN trim_scale(u.base_offset)::text END))
                                                 ORDER BY u.base_factor, u.symbol), '[]')
                                          FROM public.unit u
                                          WHERE u.family = f.id AND u.tenant = v_session.tenant))
                                  ORDER BY f.name COLLATE public.natural)
                           FROM public.unit_family f
                           WHERE f.quantity = q.id AND f.id = ANY (v_families)))
                   ORDER BY q.name COLLATE public.natural)
            FROM public.quantity q
            JOIN public.unit b ON b.id = q.base_unit
            WHERE q.id IN (SELECT f.quantity FROM public.unit_family f WHERE f.id = ANY (v_families))),
        'attributes', (
            SELECT json_agg(json_strip_nulls(json_build_object(
                       'name',      a.name,
                       'datatype',  a.datatype,
                       'unit',      model.unit_ref(v_session.tenant, a.unit),
                       'unit_lock', CASE WHEN a.unit_lock THEN true END,
                       'options',   (SELECT json_agg(o.name ORDER BY o.name COLLATE public.natural)
                                     FROM public.attribute_option o
                                     WHERE o.attribute = a.id)))
                   ORDER BY a.name COLLATE public.natural, a.id)
            FROM public.attribute a
            WHERE a.id = ANY (v_attributes)),
        'classes', json_build_array(model.export_class(p_class, true))
    ));
END;
$$;
