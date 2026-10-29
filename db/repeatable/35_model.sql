-- API: model files, which hold quantities and units, attributes and a tree
-- of classes that use them: importing one, and exporting a class with
-- everything below it. The format is in seed/model-format.md.

-- ---------------------------------------------------------------------------
-- reading a file
-- ---------------------------------------------------------------------------

-- Raises 22023 unless p_value (at p_where in a model file) is an object
-- whose keys are among p_keys and "meta", and has every key of p_required.
-- What is in "meta" is for people, and is never read.
CREATE FUNCTION util.file_object(
    p_value    jsonb,
    p_where    text,
    p_keys     text[],
    p_required text[]
) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
        PERFORM util.raise_invalid(format('%s must be an object', p_where));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_value) LOOP
        IF NOT v_key = ANY (p_keys) AND v_key <> 'meta' THEN
            PERFORM util.raise_invalid(format(
                '%s: unknown key "%s" (notes of your own go in "meta")', p_where, v_key));
        END IF;
    END LOOP;
    FOREACH v_key IN ARRAY p_required LOOP
        IF jsonb_typeof(p_value -> v_key) IS NULL OR jsonb_typeof(p_value -> v_key) = 'null' THEN
            PERFORM util.raise_invalid(format('%s needs "%s"', p_where, v_key));
        END IF;
    END LOOP;
END;
$$;

-- The text at p_key of a model file object: a string that isn't blank.
CREATE FUNCTION util.file_text(p_value jsonb, p_key text, p_where text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value -> p_key) IS DISTINCT FROM 'string' OR btrim(p_value ->> p_key) = '' THEN
        PERFORM util.raise_invalid(format('%s: "%s" must be text', p_where, p_key));
    END IF;
    RETURN btrim(p_value ->> p_key);
END;
$$;

-- The list at p_key of a model file object; an empty one when it is absent.
CREATE FUNCTION util.file_list(p_value jsonb, p_key text, p_where text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value -> p_key IS NULL OR jsonb_typeof(p_value -> p_key) = 'null' THEN
        RETURN '[]'::jsonb;
    END IF;
    IF jsonb_typeof(p_value -> p_key) <> 'array' THEN
        PERFORM util.raise_invalid(format('%s: "%s" must be a list', p_where, p_key));
    END IF;
    RETURN p_value -> p_key;
END;
$$;

-- A factor or offset of a model file: a decimal, preferably as text so that
-- no digit is lost ("0.55555555555555555556"), or a JSON number.
CREATE FUNCTION util.file_decimal(p_value jsonb, p_where text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value) = 'number'
       OR (jsonb_typeof(p_value) = 'string'
           AND btrim(p_value #>> '{}') ~ '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
    THEN
        RETURN (btrim(p_value #>> '{}'))::numeric;
    END IF;
    PERFORM util.raise_invalid(format('%s must be a decimal number, such as "0.0254"', p_where));
END;
$$;

-- ---------------------------------------------------------------------------
-- importing
-- ---------------------------------------------------------------------------

-- Appends p_value to the list at p_path of an import report.
CREATE FUNCTION util.report_add(p_report jsonb, p_path text[], p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN jsonb_set(p_report, p_path, (p_report #> p_path) || jsonb_build_array(p_value));
END;
$$;

-- Adds a conflict to an import report.
CREATE FUNCTION util.report_conflict(p_report jsonb, p_where text, p_message text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN util.report_add(p_report, ARRAY['conflicts'],
                           jsonb_build_object('where', p_where, 'message', p_message));
END;
$$;

-- Imports the quantities p_list of a model file, with their unit families
-- and units, for tenant p_tenant, or as global units with p_tenant NULL.
-- Things are matched by name among what the tenant sees (only global ones
-- for a global import): quantities and families ignoring case, units by
-- symbol within their family. What is there already must be the same
-- (datatype and base unit; quantity; name, factor and offset), or it is a
-- conflict. Nothing that exists is ever changed. Returns the report with
-- what was added, what existed and the conflicts.
CREATE FUNCTION util.model_import_units(p_tenant uuid, p_list jsonb, p_report jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_families    jsonb;
    v_units       jsonb;
    v_q           jsonb;
    v_f           jsonb;
    v_u           jsonb;
    v_qi          integer := 0;
    v_fi          integer;
    v_ui          integer;
    v_where       text;
    v_qname       text;
    v_datatype    text;
    v_base_symbol text;
    v_base_name   text;
    v_fname       text;
    v_symbol      text;
    v_uname       text;
    v_factor      numeric;
    v_offset      numeric;
    v_quantity    quantity;
    v_family      unit_family;
    v_unit        unit;
BEGIN
    FOR v_q IN SELECT jsonb_array_elements(p_list) LOOP
        v_where := format('quantities[%s]', v_qi);
        v_qi := v_qi + 1;
        PERFORM util.file_object(v_q, v_where,
            ARRAY['name', 'datatype', 'base_unit', 'families'], ARRAY['name', 'base_unit']);
        v_qname := util.file_text(v_q, 'name', v_where);
        v_where := v_qname;
        v_datatype := COALESCE(v_q ->> 'datatype', 'float');
        IF v_datatype NOT IN ('float', 'integer') THEN
            PERFORM util.raise_invalid(format('%s: "datatype" must be "float" or "integer"', v_where));
        END IF;
        PERFORM util.file_object(v_q -> 'base_unit', v_where || ': "base_unit"',
            ARRAY['symbol', 'name'], ARRAY['symbol', 'name']);
        v_base_symbol := util.file_text(v_q -> 'base_unit', 'symbol', v_where || ': "base_unit"');
        v_base_name := util.file_text(v_q -> 'base_unit', 'name', v_where || ': "base_unit"');
        v_families := util.file_list(v_q, 'families', v_where);

        SELECT * INTO v_quantity FROM quantity q
        WHERE lower(q.name) = lower(v_qname)
          AND (q.tenant IS NULL OR q.tenant = p_tenant);
        IF FOUND THEN
            IF v_quantity.datatype::text <> v_datatype OR v_quantity.base_symbol <> v_base_symbol THEN
                p_report := util.report_conflict(p_report, v_where, format(
                    'There is a quantity %s already, with base unit %s and datatype %s; the file has %s and %s',
                    v_quantity.name, v_quantity.base_symbol, v_quantity.datatype, v_base_symbol, v_datatype));
                CONTINUE;
            END IF;
            p_report := util.report_add(p_report, ARRAY['quantities', 'existing'], to_jsonb(v_quantity.name));
        ELSE
            BEGIN
                INSERT INTO quantity (tenant, name, datatype, base_symbol, base_name)
                VALUES (p_tenant, v_qname, v_datatype::datatype, v_base_symbol, v_base_name)
                RETURNING * INTO v_quantity;
            EXCEPTION WHEN unique_violation THEN
                -- A global import: some tenant has a quantity of this name.
                p_report := util.report_conflict(p_report, v_where, SQLERRM);
                CONTINUE;
            END;
            p_report := util.report_add(p_report, ARRAY['quantities', 'added'], to_jsonb(v_quantity.name));
        END IF;

        v_fi := 0;
        FOR v_f IN SELECT jsonb_array_elements(v_families) LOOP
            v_where := format('%s: families[%s]', v_quantity.name, v_fi);
            v_fi := v_fi + 1;
            PERFORM util.file_object(v_f, v_where, ARRAY['name', 'units'], ARRAY['name']);
            v_fname := util.file_text(v_f, 'name', v_where);
            v_where := v_quantity.name || ' › ' || v_fname;
            v_units := util.file_list(v_f, 'units', v_where);

            SELECT * INTO v_family FROM unit_family f
            WHERE lower(f.name) = lower(v_fname)
              AND (f.tenant IS NULL OR f.tenant = p_tenant);
            IF FOUND THEN
                IF v_family.quantity <> v_quantity.id THEN
                    p_report := util.report_conflict(p_report, v_where, format(
                        'There is a unit family %s already, of quantity %s',
                        v_family.name, (SELECT name FROM quantity WHERE id = v_family.quantity)));
                    CONTINUE;
                END IF;
                p_report := util.report_add(p_report, ARRAY['families', 'existing'],
                                            to_jsonb(v_quantity.name || ' › ' || v_family.name));
            ELSE
                BEGIN
                    INSERT INTO unit_family (tenant, quantity, name) VALUES (p_tenant, v_quantity.id, v_fname)
                    RETURNING * INTO v_family;
                EXCEPTION WHEN unique_violation THEN
                    p_report := util.report_conflict(p_report, v_where, SQLERRM);
                    CONTINUE;
                END;
                p_report := util.report_add(p_report, ARRAY['families', 'added'],
                                            to_jsonb(v_quantity.name || ' › ' || v_family.name));
            END IF;

            v_ui := 0;
            FOR v_u IN SELECT jsonb_array_elements(v_units) LOOP
                v_where := format('%s › %s: units[%s]', v_quantity.name, v_family.name, v_ui);
                v_ui := v_ui + 1;
                PERFORM util.file_object(v_u, v_where,
                    ARRAY['symbol', 'name', 'factor', 'offset'], ARRAY['symbol', 'name', 'factor']);
                v_symbol := util.file_text(v_u, 'symbol', v_where);
                v_uname := util.file_text(v_u, 'name', v_where);
                v_where := format('%s › %s › %s', v_quantity.name, v_family.name, v_symbol);
                v_factor := util.file_decimal(v_u -> 'factor', v_where || ': "factor"');
                v_offset := CASE WHEN v_u ? 'offset'
                                 THEN util.file_decimal(v_u -> 'offset', v_where || ': "offset"')
                                 ELSE 0 END;
                IF v_factor <= 0 THEN
                    PERFORM util.raise_invalid(format('%s: "factor" must be more than 0', v_where));
                END IF;
                IF v_symbol = v_quantity.base_symbol AND (v_factor <> 1 OR v_offset <> 0) THEN
                    PERFORM util.raise_invalid(format(
                        '%s is the base unit of %s, so its factor must be 1 and its offset 0', v_where, v_quantity.name));
                END IF;

                SELECT * INTO v_unit FROM unit u
                WHERE u.family = v_family.id AND u.symbol = v_symbol
                  AND (u.tenant IS NULL OR u.tenant = p_tenant);
                IF FOUND THEN
                    IF lower(v_unit.name) <> lower(v_uname)
                       OR v_unit.base_factor <> v_factor OR v_unit.base_offset <> v_offset
                    THEN
                        p_report := util.report_conflict(p_report, v_where, format(
                            'There is a unit %s already: %s, factor %s, offset %s; the file has %s, factor %s, offset %s',
                            v_unit.symbol, v_unit.name, v_unit.base_factor, v_unit.base_offset,
                            v_uname, v_factor, v_offset));
                    ELSE
                        p_report := util.report_add(p_report, ARRAY['units', 'existing'], to_jsonb(v_where));
                    END IF;
                    CONTINUE;
                END IF;
                BEGIN
                    INSERT INTO unit (tenant, family, name, symbol, base_factor, base_offset)
                    VALUES (p_tenant, v_family.id, v_uname, v_symbol, v_factor, v_offset);
                    p_report := util.report_add(p_report, ARRAY['units', 'added'], to_jsonb(v_where));
                EXCEPTION WHEN unique_violation OR check_violation THEN
                    -- Another unit of the family has this name (or, for a
                    -- global import, some tenant's unit has), or the symbol
                    -- means another unit elsewhere in the quantity.
                    p_report := util.report_conflict(p_report, v_where, SQLERRM);
                END;
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN p_report;
END;
$$;

-- The units of tenant p_tenant that a model file's p_ref may mean: by
-- symbol or name, in family p_family (any when NULL).
CREATE FUNCTION util.model_file_units(p_tenant uuid, p_ref text, p_family text)
RETURNS TABLE (unit uuid, family text)
LANGUAGE sql STABLE AS $$
    SELECT u.id, f.name
    FROM unit u
    JOIN unit_family f ON f.id = u.family
    WHERE (u.symbol = p_ref OR lower(u.name) = lower(p_ref))
      AND (u.tenant IS NULL OR u.tenant = p_tenant)
      AND (p_family IS NULL OR lower(f.name) = lower(p_family));
$$;

-- The unit a model file names, among the units tenant p_tenant sees: by
-- symbol or name, with its family in brackets where several families have
-- it ("B (Binary bytes)"). Returns the unit, or NULL and why not; a unit
-- whose family or quantity is turned off isn't available.
CREATE FUNCTION util.model_file_unit(p_tenant uuid, p_ref text, OUT unit uuid, OUT problem text)
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
    SELECT array_agg(m.unit ORDER BY m.family), array_agg(m.family ORDER BY m.family) INTO v_units, v_families
    FROM util.model_file_units(p_tenant, v_ref, v_family) m;
    IF v_units IS NULL THEN
        problem := format('There is no unit %s', p_ref);
    ELSIF cardinality(v_units) > 1 THEN
        problem := format('%s is in several unit families; name one, as in "%s (%s)"', v_ref, v_ref, v_families[1]);
    ELSIF NOT util.family_available(p_tenant, (SELECT family FROM unit WHERE id = v_units[1])) THEN
        problem := format('The unit %s isn''t available: its family or quantity is turned off', p_ref);
    ELSE
        unit := v_units[1];
    END IF;
END;
$$;

-- An assignment's default from a model file as the API takes it: numbers
-- converted from unit p_unit (the file's, else the attribute's) to the base
-- unit; anything else as it is.
CREATE FUNCTION util.model_default(p_unit uuid, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF jsonb_typeof(p_value) = 'number' AND p_unit IS NOT NULL THEN
        RETURN (SELECT to_jsonb(trim_scale(p_value::numeric * u.base_factor + u.base_offset))
                FROM unit u WHERE u.id = p_unit);
    END IF;
    RETURN p_value;
END;
$$;

-- Imports the attributes of a model file for tenant p_tenant. Returns the
-- report with the attributes added, existing and conflicting, and in
-- p_attributes, by lower-case name, {id, unit} of each (id null when it
-- conflicts), for the classes to refer to.
CREATE FUNCTION util.model_import_attributes(
    p_tenant         uuid,
    p_list           jsonb,
    INOUT p_report   jsonb,
    OUT p_attributes jsonb
)
LANGUAGE plpgsql AS $$
DECLARE
    v_a        jsonb;
    v_i        integer := 0;
    v_where    text;
    v_name     text;
    v_datatype text;
    v_unit     uuid;
    v_problem  text;
    v_lock     boolean;
    v_options  jsonb;
    v_option   text;
    v_existing attribute;
    v_id       uuid;
BEGIN
    p_attributes := '{}';
    FOR v_a IN SELECT jsonb_array_elements(p_list) LOOP
        v_where := format('attributes[%s]', v_i);
        v_i := v_i + 1;
        PERFORM util.file_object(v_a, v_where,
            ARRAY['name', 'datatype', 'unit', 'unit_lock', 'options'], ARRAY['name']);
        v_name := util.file_text(v_a, 'name', v_where);
        v_where := format('Attribute %s', v_name);
        IF p_attributes ? lower(v_name) THEN
            PERFORM util.raise_invalid(format('%s appears twice in the file', v_where));
        END IF;
        p_attributes := p_attributes || jsonb_build_object(lower(v_name), jsonb_build_object('id', NULL));

        v_datatype := v_a ->> 'datatype';
        IF v_datatype IS NOT NULL
           AND v_datatype NOT IN ('text', 'integer', 'float', 'date', 'boolean', 'url', 'choice')
        THEN
            PERFORM util.raise_invalid(format('%s: "datatype" must be text, integer, float, date, boolean, url or choice', v_where));
        END IF;
        IF v_a -> 'unit_lock' IS NOT NULL AND jsonb_typeof(v_a -> 'unit_lock') NOT IN ('boolean', 'null') THEN
            PERFORM util.raise_invalid(format('%s: "unit_lock" must be true or false', v_where));
        END IF;
        v_lock := COALESCE((v_a ->> 'unit_lock')::boolean, false);
        v_options := util.file_list(v_a, 'options', v_where);
        IF jsonb_array_length(v_options) > 0 AND v_datatype IS DISTINCT FROM 'choice' THEN
            PERFORM util.raise_invalid(format('%s: only choice attributes have "options"', v_where));
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_options) o
                   WHERE jsonb_typeof(o) <> 'string' OR btrim(o #>> '{}') = '') THEN
            PERFORM util.raise_invalid(format('%s: "options" must be a list of names', v_where));
        END IF;
        IF v_a ->> 'unit' IS NULL THEN
            IF v_datatype IS NULL THEN
                PERFORM util.raise_invalid(format('%s needs "datatype", or a "unit"', v_where));
            END IF;
            IF v_lock THEN
                PERFORM util.raise_invalid(format('%s: "unit_lock" needs a "unit"', v_where));
            END IF;
            v_unit := NULL;
        ELSE
            SELECT unit, problem INTO v_unit, v_problem FROM util.model_file_unit(p_tenant, v_a ->> 'unit');
            IF v_problem IS NOT NULL THEN
                p_report := util.report_conflict(p_report, v_where, v_problem);
                CONTINUE;
            END IF;
            IF v_datatype IS NULL THEN
                v_datatype := (SELECT datatype::text FROM quantity WHERE id = unit_quantity(v_unit));
            ELSIF v_datatype <> (SELECT datatype::text FROM quantity WHERE id = unit_quantity(v_unit)) THEN
                p_report := util.report_conflict(p_report, v_where, format(
                    'With the unit %s the datatype is %s, not %s', v_a ->> 'unit',
                    (SELECT datatype FROM quantity WHERE id = unit_quantity(v_unit)), v_datatype));
                CONTINUE;
            END IF;
        END IF;

        SELECT * INTO v_existing FROM attribute
        WHERE tenant = p_tenant AND lower(name) = lower(v_name) AND NOT deleted;
        IF FOUND THEN
            IF v_existing.datatype::text <> v_datatype THEN
                p_report := util.report_conflict(p_report, v_where, format(
                    'There is an attribute %s already, of datatype %s; the file has %s',
                    v_existing.name, v_existing.datatype, v_datatype));
                CONTINUE;
            END IF;
            IF (v_existing.unit IS NULL) <> (v_unit IS NULL)
               OR unit_quantity(v_existing.unit) IS DISTINCT FROM unit_quantity(v_unit)
            THEN
                p_report := util.report_conflict(p_report, v_where, format(
                    'There is an attribute %s already, %s; the file has %s',
                    v_existing.name,
                    COALESCE('measured in ' || (SELECT q.name FROM quantity q WHERE q.id = unit_quantity(v_existing.unit)), 'without a unit'),
                    COALESCE('a unit of ' || (SELECT q.name FROM quantity q WHERE q.id = unit_quantity(v_unit)), 'no unit')));
                CONTINUE;
            END IF;
            v_id := v_existing.id;
            p_report := util.report_add(p_report, ARRAY['attributes', 'existing'], to_jsonb(v_existing.name));
        ELSE
            BEGIN
                INSERT INTO attribute (tenant, name, datatype, unit, unit_lock)
                VALUES (p_tenant, util.clean_name(v_name), v_datatype::datatype, v_unit, v_lock)
                RETURNING id INTO v_id;
            EXCEPTION WHEN check_violation OR unique_violation THEN
                p_report := util.report_conflict(p_report, v_where, SQLERRM);
                CONTINUE;
            END;
            p_report := util.report_add(p_report, ARRAY['attributes', 'added'], to_jsonb(util.clean_name(v_name)));
        END IF;

        -- Options it lacks.
        FOR v_option IN SELECT btrim(o #>> '{}') FROM jsonb_array_elements(v_options) o LOOP
            IF NOT EXISTS (SELECT 1 FROM attribute_option
                           WHERE attribute = v_id AND lower(name) = lower(v_option) AND NOT deleted)
            THEN
                INSERT INTO attribute_option (tenant, attribute, name) VALUES (p_tenant, v_id, v_option);
                p_report := util.report_add(p_report, ARRAY['options', 'added'],
                                            to_jsonb(format('%s: %s', v_name, v_option)));
            END IF;
        END LOOP;

        p_attributes := p_attributes || jsonb_build_object(lower(v_name),
            jsonb_build_object('id', v_id, 'unit', COALESCE(v_unit, v_existing.unit)));
        v_existing := NULL;
    END LOOP;
END;
$$;

-- An assignment as model import compares them: per_unit, required and the
-- default's columns.
CREATE FUNCTION util.assignment_jsonb(
    p_per_unit boolean, p_required boolean,
    p_text text, p_integer bigint, p_float double precision,
    p_date date, p_boolean boolean, p_option uuid
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('per_unit', p_per_unit, 'required', p_required,
                              'text', p_text, 'integer', p_integer, 'float', p_float,
                              'date', p_date, 'boolean', p_boolean, 'option', p_option);
$$;

-- Imports the classes p_list of a model file below class p_parent (the top
-- when NULL), whose path is p_path, and below them their classes. Returns
-- the report with what was added, what existed and the conflicts.
CREATE FUNCTION util.model_import_classes(
    p_tenant     uuid,
    p_parent     uuid,
    p_path       text,
    p_list       jsonb,
    p_attributes jsonb,
    p_report     jsonb
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_c         jsonb;
    v_s         jsonb;
    v_i         integer := 0;
    v_j         integer;
    v_where     text;
    v_name      text;
    v_path      text;
    v_seen      text[] := '{}';
    v_container boolean;
    v_class     class;
    v_ref       text;
    v_attr      jsonb;
    v_attr_id   uuid;
    v_per_unit  boolean;
    v_required  boolean;
    v_text      text;
    v_integer   bigint;
    v_float     double precision;
    v_date      date;
    v_boolean   boolean;
    v_option    uuid;
    v_want      jsonb;
    v_have      jsonb;
    v_depth     integer;
    v_list      jsonb;
BEGIN
    FOR v_c IN SELECT jsonb_array_elements(p_list) LOOP
        v_where := format('%sclasses[%s]', COALESCE(p_path || ': ', ''), v_i);
        v_i := v_i + 1;
        PERFORM util.file_object(v_c, v_where, ARRAY['name', 'container', 'attributes', 'classes'], ARRAY['name']);
        v_name := util.clean_path_name(util.file_text(v_c, 'name', v_where), 'class');
        v_path := COALESCE(p_path || '/', '') || v_name;
        IF lower(v_name) = ANY (v_seen) THEN
            PERFORM util.raise_invalid(format('Class %s appears twice in the file', v_path));
        END IF;
        v_seen := v_seen || lower(v_name);
        IF v_c -> 'container' IS NOT NULL AND jsonb_typeof(v_c -> 'container') NOT IN ('boolean', 'null') THEN
            PERFORM util.raise_invalid(format('Class %s: "container" must be true or false', v_path));
        END IF;
        v_container := (v_c ->> 'container')::boolean;
        v_where := format('Class %s', v_path);

        SELECT * INTO v_class FROM class
        WHERE tenant = p_tenant AND parent IS NOT DISTINCT FROM p_parent
          AND lower(name) = lower(v_name) AND NOT deleted;
        IF FOUND THEN
            IF v_container IS NOT NULL AND v_container <> v_class.container THEN
                p_report := util.report_conflict(p_report, v_where, format(
                    'There is a class %s already, %s a container; the file has it %s one',
                    v_path, CASE WHEN v_class.container THEN 'which is' ELSE 'which isn''t' END,
                    CASE WHEN v_container THEN 'as' ELSE 'not as' END));
                CONTINUE;
            END IF;
            p_report := util.report_add(p_report, ARRAY['classes', 'existing'], to_jsonb(v_path));
        ELSE
            BEGIN
                INSERT INTO class (tenant, name, parent, container)
                VALUES (p_tenant, v_name, p_parent, COALESCE(v_container, false))
                RETURNING * INTO v_class;
            EXCEPTION WHEN check_violation OR unique_violation THEN
                p_report := util.report_conflict(p_report, v_where, SQLERRM);
                CONTINUE;
            END;
            p_report := util.report_add(p_report, ARRAY['classes', 'added'], to_jsonb(v_path));
        END IF;

        -- Its assignments.
        v_list := util.file_list(v_c, 'attributes', v_where);
        v_j := 0;
        FOR v_s IN SELECT jsonb_array_elements(v_list) LOOP
            PERFORM util.file_object(v_s, format('%s: attributes[%s]', v_where, v_j),
                ARRAY['attribute', 'per_unit', 'required', 'default'], ARRAY['attribute']);
            v_ref := util.file_text(v_s, 'attribute', format('%s: attributes[%s]', v_where, v_j));
            v_j := v_j + 1;
            IF EXISTS (SELECT 1 FROM jsonb_each(v_s) e
                       WHERE e.key IN ('per_unit', 'required') AND jsonb_typeof(e.value) NOT IN ('boolean', 'null')) THEN
                PERFORM util.raise_invalid(format('%s: %s: "per_unit" and "required" must be true or false', v_where, v_ref));
            END IF;
            v_per_unit := COALESCE((v_s ->> 'per_unit')::boolean, false);
            v_required := COALESCE((v_s ->> 'required')::boolean, false);

            -- The file's attribute, or else one the inventory has.
            v_attr := p_attributes -> lower(v_ref);
            IF v_attr IS NULL THEN
                SELECT jsonb_build_object('id', a.id, 'unit', a.unit) INTO v_attr
                FROM attribute a
                WHERE a.tenant = p_tenant AND lower(a.name) = lower(v_ref) AND NOT a.deleted;
                IF v_attr IS NULL THEN
                    p_report := util.report_conflict(p_report, format('%s: %s', v_where, v_ref),
                        format('There is no attribute %s, in the file or in the inventory', v_ref));
                    CONTINUE;
                END IF;
            END IF;
            CONTINUE WHEN v_attr ->> 'id' IS NULL; -- its conflict is reported already
            v_attr_id := (v_attr ->> 'id')::uuid;

            v_text := NULL; v_integer := NULL; v_float := NULL;
            v_date := NULL; v_boolean := NULL; v_option := NULL;
            IF v_s -> 'default' IS NOT NULL AND jsonb_typeof(v_s -> 'default') <> 'null' THEN
                BEGIN
                    SELECT text_v, integer_v, float_v, date_v, boolean_v, option_v
                    INTO v_text, v_integer, v_float, v_date, v_boolean, v_option
                    FROM util.parse_typed_value(v_attr_id,
                        util.model_default((v_attr ->> 'unit')::uuid, v_s -> 'default'));
                EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation
                             OR datetime_field_overflow OR numeric_value_out_of_range THEN
                    p_report := util.report_conflict(p_report, format('%s: %s', v_where, v_ref),
                        (SELECT format('The default %s doesn''t fit %s, a%s %s attribute', v_s -> 'default', v_ref,
                                       CASE WHEN d.datatype::text ~ '^[aeiu]' THEN 'n' ELSE '' END, d.datatype)
                         FROM attribute d WHERE d.id = v_attr_id));
                    CONTINUE;
                END;
            END IF;
            v_want := util.assignment_jsonb(v_per_unit, v_required,
                                            v_text, v_integer, v_float, v_date, v_boolean, v_option);

            -- What the class has now: its own assignment (depth 0), or one
            -- it inherits. Either is used when it is the same; one of its
            -- own that differs is a conflict, an inherited one is overridden.
            v_depth := NULL;
            v_have := NULL;
            SELECT e.inherited_depth,
                   util.assignment_jsonb(e.per_unit, e.required,
                                         e.text_default, e.integer_default, e.float_default,
                                         e.date_default, e.boolean_default, e.option_default)
            INTO v_depth, v_have
            FROM class_effective_attribute e
            WHERE e.class = v_class.id AND e.attribute = v_attr_id;
            IF v_have = v_want THEN
                p_report := util.report_add(p_report, ARRAY['assignments', 'existing'],
                                            to_jsonb(format('%s: %s', v_path, v_ref)));
                CONTINUE;
            END IF;
            IF v_depth = 0 THEN
                p_report := util.report_conflict(p_report, format('%s: %s', v_where, v_ref),
                    format('%s has %s already, %s', v_path, v_ref, concat_ws(', ',
                        CASE WHEN (v_have ->> 'per_unit')::boolean THEN 'per unit' ELSE 'per item' END,
                        CASE WHEN (v_have ->> 'required')::boolean THEN 'required' ELSE 'not required' END,
                        CASE WHEN EXISTS (SELECT 1 FROM jsonb_each(v_have - 'per_unit' - 'required') d
                                          WHERE jsonb_typeof(d.value) <> 'null')
                             THEN 'with another default' ELSE 'without a default' END)
                        || '; the file has it otherwise'));
                CONTINUE;
            END IF;
            BEGIN
                INSERT INTO class_attribute (tenant, class, attribute,
                                             text_default, integer_default, float_default,
                                             date_default, boolean_default, option_default,
                                             per_unit, required)
                VALUES (p_tenant, v_class.id, v_attr_id,
                        v_text, v_integer, v_float,
                        v_date, v_boolean, v_option,
                        v_per_unit, v_required);
            EXCEPTION WHEN check_violation THEN
                p_report := util.report_conflict(p_report, format('%s: %s', v_where, v_ref), SQLERRM);
                CONTINUE;
            END;
            p_report := util.report_add(p_report, ARRAY['assignments', 'added'],
                                        to_jsonb(format('%s: %s', v_path, v_ref)));
        END LOOP;

        p_report := util.model_import_classes(p_tenant, v_class.id, v_path,
            util.file_list(v_c, 'classes', v_where), p_attributes, p_report);
    END LOOP;
    RETURN p_report;
END;
$$;

-- Imports a model file (seed/model-format.md) for tenant p_tenant: its
-- quantities and units, its attributes, and its classes at the top of the
-- class tree or below class p_parent, whose path is p_path. What is there
-- and the same is used as it is; what isn't is added; what differs is a
-- conflict. With p_tenant NULL (the operator's "wtfd unit import --global")
-- the units are imported as global ones, and the file may hold only units.
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
-- A file that isn't a valid model file raises 22023, naming where.
CREATE FUNCTION util.model_import(
    p_tenant  uuid,
    p_data    jsonb,
    p_parent  uuid,
    p_path    text,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_dry_run    boolean := COALESCE(p_dry_run, false);
    v_version    numeric;
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
    PERFORM util.file_object(p_data, 'The file',
        ARRAY['format', 'version', 'quantities', 'attributes', 'classes'],
        ARRAY['format', 'version']);
    IF p_data ->> 'format' IS DISTINCT FROM 'wtf-model' THEN
        PERFORM util.raise_invalid('This is not a WtF model file: "format" must be "wtf-model"');
    END IF;
    IF jsonb_typeof(p_data -> 'version') <> 'number' THEN
        PERFORM util.raise_invalid('"version" must be a number');
    END IF;
    v_version := (p_data ->> 'version')::numeric;
    IF v_version > 1 THEN
        PERFORM util.raise_invalid(format(
            'This model file is version %s, made for a newer WtF; this one reads version 1', v_version));
    END IF;
    IF v_version <> 1 THEN
        PERFORM util.raise_invalid('"version" must be 1');
    END IF;
    IF p_tenant IS NULL AND (jsonb_array_length(util.file_list(p_data, 'attributes', 'The file')) > 0
                             OR jsonb_array_length(util.file_list(p_data, 'classes', 'The file')) > 0) THEN
        PERFORM util.raise_invalid('Global units come from a file of only quantities; this one has attributes or classes');
    END IF;

    BEGIN -- a subtransaction, rolled back for a dry run or a conflict
        v_report := util.model_import_units(p_tenant, util.file_list(p_data, 'quantities', 'The file'), v_report);
        IF p_tenant IS NOT NULL THEN
            SELECT a.p_report, a.p_attributes INTO v_report, v_attributes
            FROM util.model_import_attributes(p_tenant, util.file_list(p_data, 'attributes', 'The file'), v_report) a;
            v_report := util.model_import_classes(p_tenant, p_parent, p_path,
                util.file_list(p_data, 'classes', 'The file'), v_attributes, v_report);
        END IF;

        IF v_dry_run OR jsonb_array_length(v_report -> 'conflicts') > 0 THEN
            RAISE EXCEPTION 'model import rolled back' USING ERRCODE = 'WTF01';
        END IF;
    EXCEPTION WHEN SQLSTATE 'WTF01' THEN
        NULL; -- the report is in the variables, which keep their values
    END;

    RETURN v_report || jsonb_build_object(
        'applied', NOT v_dry_run AND jsonb_array_length(v_report -> 'conflicts') = 0,
        'dry_run', v_dry_run);
END;
$$;

-- Imports a model file for the session's tenant (util.model_import): its
-- classes go at the top of the class tree, or below class p_parent.
CREATE FUNCTION model_import(p_data jsonb, p_parent uuid DEFAULT NULL, p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_path   text;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
    IF p_parent IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_parent AND tenant = v_tenant) THEN
            PERFORM util.raise_bad_reference('class', p_parent);
        END IF;
        PERFORM check_live('class', p_parent);
        v_path := util.path_text(util.class_path(p_parent));
    END IF;
    RETURN util.model_import(v_tenant, p_data, p_parent, v_path, p_dry_run);
END;
$$;

-- ---------------------------------------------------------------------------
-- exporting
-- ---------------------------------------------------------------------------

-- A number of a model file: p_value rounded to 15 significant digits, so
-- that a conversion leaves no tail of nines (15.999999999999999 MHz).
CREATE FUNCTION util.model_number(p_value numeric) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT to_jsonb(CASE WHEN p_value = 0 THEN 0
                         ELSE trim_scale(round(p_value, 14 - floor(log(abs(p_value)))::integer)) END);
$$;

-- How a model file names unit p_unit for tenant p_tenant: by symbol, with
-- its family in brackets when the symbol alone could mean another unit.
CREATE FUNCTION util.model_unit_ref(p_tenant uuid, p_unit uuid) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN (SELECT count(*) FROM util.model_file_units(p_tenant, u.symbol, NULL)) > 1
                THEN format('%s (%s)', u.symbol, f.name)
                ELSE u.symbol END
    FROM unit u JOIN unit_family f ON f.id = u.family
    WHERE u.id = p_unit;
$$;

-- An assignment's default as a model file has it: numbers in the
-- attribute's unit, a date as YYYY-MM-DD, an option by name; NULL for none.
CREATE FUNCTION util.model_export_default(
    p_attribute uuid,
    p_text text, p_integer bigint, p_float double precision,
    p_date date, p_boolean boolean, p_option uuid
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN num_nonnulls(p_integer, p_float) > 0 THEN
            util.model_number(CASE WHEN u.id IS NULL THEN COALESCE(p_integer::numeric, p_float::numeric)
                                   ELSE (COALESCE(p_integer::numeric, p_float::numeric) - u.base_offset) / u.base_factor END)
        WHEN p_text IS NOT NULL THEN to_jsonb(p_text)
        WHEN p_date IS NOT NULL THEN to_jsonb(p_date::text)
        WHEN p_boolean IS NOT NULL THEN to_jsonb(p_boolean)
        WHEN p_option IS NOT NULL THEN (SELECT to_jsonb(o.name) FROM attribute_option o WHERE o.id = p_option)
    END
    FROM attribute a LEFT JOIN unit u ON u.id = a.unit
    WHERE a.id = p_attribute;
$$;

-- Class p_class as a model file has it, with the live classes below it. Its
-- assignments are its own; with p_root, those it inherits too, so that the
-- file stands on its own.
CREATE FUNCTION util.model_export_class(p_class uuid, p_root boolean) RETURNS json
LANGUAGE sql STABLE AS $$
    SELECT json_strip_nulls(json_build_object(
        'name', c.name,
        'container', CASE WHEN c.container THEN true END,
        'attributes', (
            SELECT json_agg(json_strip_nulls(json_build_object(
                       'attribute', a.name,
                       'per_unit', CASE WHEN e.per_unit THEN true END,
                       'required', CASE WHEN e.required THEN true END,
                       'default', util.model_export_default(a.id,
                                      e.text_default, e.integer_default, e.float_default,
                                      e.date_default, e.boolean_default, e.option_default)))
                   ORDER BY lower(a.name), a.id)
            FROM class_effective_attribute e
            JOIN attribute a ON a.id = e.attribute
            WHERE e.class = c.id AND NOT a.deleted
              AND (p_root OR e.inherited_depth = 0)),
        'classes', (
            SELECT json_agg(util.model_export_class(k.id, false) ORDER BY lower(k.name), k.id)
            FROM class k
            WHERE k.parent = c.id AND NOT k.deleted)
    ))
    FROM class c
    WHERE c.id = p_class;
$$;

-- The unit families an export needs for the units of attributes
-- p_attributes: those that are tenant p_tenant's own or have units of its
-- own. Every WtF has the rest.
CREATE FUNCTION util.model_export_families(p_tenant uuid, p_attributes uuid[]) RETURNS SETOF uuid
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.id
    FROM attribute a
    JOIN unit u ON u.id = a.unit
    JOIN unit_family f ON f.id = u.family
    WHERE a.id = ANY (p_attributes)
      AND (f.tenant = p_tenant
           OR EXISTS (SELECT 1 FROM unit x WHERE x.family = f.id AND x.tenant = p_tenant));
$$;

-- Exports class p_class with everything below it as a model file
-- (seed/model-format.md): the classes, their assignments (the top class's
-- inherited ones as its own), every attribute they use, and the tenant's
-- own units those attributes need, with the families they are in: those
-- decide how values are shown. Importing the file where the class is
-- changes nothing; importing it elsewhere sets up the same.
CREATE FUNCTION model_export(p_class uuid) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant     uuid;
    v_attributes uuid[];
    v_families   uuid[];
BEGIN
    PERFORM util.require_model_read();
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_class AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('class', p_class);
    END IF;
    PERFORM check_live('class', p_class);

    -- The attributes the classes use: the top class's own and inherited,
    -- and the others' own.
    SELECT array_agg(DISTINCT a.id) INTO v_attributes
    FROM util.class_subtree(p_class) s(id)
    JOIN class c ON c.id = s.id AND NOT c.deleted
    JOIN class_effective_attribute e ON e.class = s.id
    JOIN attribute a ON a.id = e.attribute
    WHERE NOT a.deleted
      AND (e.inherited_depth = 0 OR s.id = p_class);
    v_families := ARRAY(SELECT util.model_export_families(v_tenant, v_attributes));

    RETURN json_strip_nulls(json_build_object(
        'format', 'wtf-model',
        'version', 1,
        'meta', json_build_object(
            'name', (SELECT name FROM class WHERE id = p_class),
            'class', util.path_text(util.class_path(p_class)),
            'exported_from', (SELECT host FROM tenant WHERE id = v_tenant),
            'exported_at', date_trunc('second', now())),
        'quantities', (
            SELECT json_agg(json_build_object(
                       'name', q.name,
                       'datatype', q.datatype,
                       'base_unit', json_build_object('symbol', q.base_symbol, 'name', q.base_name),
                       'families', (
                           SELECT json_agg(json_build_object(
                                      'name', f.name,
                                      'units', (
                                          SELECT COALESCE(json_agg(json_build_object(
                                                     'symbol', u.symbol,
                                                     'name', u.name,
                                                     'factor', trim_scale(u.base_factor)::text,
                                                     'offset', CASE WHEN u.base_offset <> 0
                                                                    THEN trim_scale(u.base_offset)::text END)
                                                 ORDER BY u.base_factor, u.symbol), '[]'::json)
                                          FROM unit u
                                          WHERE u.family = f.id AND u.tenant = v_tenant))
                                  ORDER BY lower(f.name))
                           FROM unit_family f
                           WHERE f.quantity = q.id AND f.id = ANY (v_families)))
                   ORDER BY lower(q.name))
            FROM quantity q
            WHERE q.id IN (SELECT f.quantity FROM unit_family f WHERE f.id = ANY (v_families))),
        'attributes', (
            SELECT json_agg(json_build_object(
                       'name', a.name,
                       'datatype', a.datatype,
                       'unit', util.model_unit_ref(v_tenant, a.unit),
                       'unit_lock', CASE WHEN a.unit_lock THEN true END,
                       'options', (SELECT json_agg(o.name ORDER BY lower(o.name))
                                   FROM attribute_option o
                                   WHERE o.attribute = a.id AND NOT o.deleted))
                   ORDER BY lower(a.name), a.id)
            FROM attribute a
            WHERE a.id = ANY (v_attributes)),
        'classes', json_build_array(util.model_export_class(p_class, true))
    ));
END;
$$;
