-- API: importing model files: attributes and a tree of classes that use
-- them. The format is in seed/model-format.md.

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
    SELECT array_agg(u.id ORDER BY f.name), array_agg(f.name ORDER BY f.name) INTO v_units, v_families
    FROM unit u
    JOIN unit_family f ON f.id = u.family
    WHERE (u.symbol = v_ref OR lower(u.name) = lower(v_ref))
      AND (u.tenant IS NULL OR u.tenant = p_tenant)
      AND (v_family IS NULL OR lower(f.name) = lower(v_family));
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
        PERFORM util.check_unit_file_object(v_a, v_where,
            ARRAY['name', 'datatype', 'unit', 'unit_lock', 'options'], ARRAY['name']);
        v_name := util.unit_file_text(v_a, 'name', v_where);
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
        v_options := util.unit_file_list(v_a, 'options', v_where);
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
    v_existing  class_attribute;
    v_list      jsonb;
BEGIN
    FOR v_c IN SELECT jsonb_array_elements(p_list) LOOP
        v_where := format('%sclasses[%s]', COALESCE(p_path || ': ', ''), v_i);
        v_i := v_i + 1;
        PERFORM util.check_unit_file_object(v_c, v_where, ARRAY['name', 'container', 'attributes', 'classes'], ARRAY['name']);
        v_name := util.clean_path_name(util.unit_file_text(v_c, 'name', v_where), 'class');
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
        v_list := util.unit_file_list(v_c, 'attributes', v_where);
        v_j := 0;
        FOR v_s IN SELECT jsonb_array_elements(v_list) LOOP
            PERFORM util.check_unit_file_object(v_s, format('%s: attributes[%s]', v_where, v_j),
                ARRAY['attribute', 'per_unit', 'required', 'default'], ARRAY['attribute']);
            v_ref := util.unit_file_text(v_s, 'attribute', format('%s: attributes[%s]', v_where, v_j));
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

            SELECT * INTO v_existing FROM class_attribute WHERE class = v_class.id AND attribute = v_attr_id;
            IF FOUND THEN
                IF v_existing.per_unit <> v_per_unit OR v_existing.required <> v_required
                   OR v_existing.text_default IS DISTINCT FROM v_text
                   OR v_existing.integer_default IS DISTINCT FROM v_integer
                   OR v_existing.float_default IS DISTINCT FROM v_float
                   OR v_existing.date_default IS DISTINCT FROM v_date
                   OR v_existing.boolean_default IS DISTINCT FROM v_boolean
                   OR v_existing.option_default IS DISTINCT FROM v_option
                THEN
                    p_report := util.report_conflict(p_report, format('%s: %s', v_where, v_ref),
                        format('%s has %s already, %s', v_path, v_ref, concat_ws(', ',
                            CASE WHEN v_existing.per_unit THEN 'per unit' ELSE 'per item' END,
                            CASE WHEN v_existing.required THEN 'required' ELSE 'not required' END,
                            CASE WHEN num_nonnulls(v_existing.text_default, v_existing.integer_default, v_existing.float_default,
                                                   v_existing.date_default, v_existing.boolean_default, v_existing.option_default) > 0
                                 THEN 'with another default' ELSE 'without a default' END)
                            || '; the file has it otherwise'));
                ELSE
                    p_report := util.report_add(p_report, ARRAY['assignments', 'existing'],
                                                to_jsonb(format('%s: %s', v_path, v_ref)));
                END IF;
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
            util.unit_file_list(v_c, 'classes', v_where), p_attributes, p_report);
    END LOOP;
    RETURN p_report;
END;
$$;

-- Imports a model file (seed/model-format.md) for the session's tenant: its
-- attributes, and its classes at the top of the class tree or below class
-- p_parent. What is there and the same is used as it is; what isn't is
-- added; what differs is a conflict.
--
-- All or nothing: with any conflict, or with p_dry_run, nothing is kept.
-- Returns what was (or would be) added, what was there already, and the
-- conflicts:
--   {applied, dry_run,
--    attributes:  {added: [name], existing: [name]},
--    options:     {added: ["Attribute: option"]},
--    classes:     {added: [path], existing: [path]},
--    assignments: {added: ["path: attribute"], existing: [...]},
--    conflicts:   [{where, message}]}
-- A file that isn't a valid model file raises 22023, naming where.
CREATE FUNCTION model_import(p_data jsonb, p_parent uuid DEFAULT NULL, p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant     uuid;
    v_dry_run    boolean := COALESCE(p_dry_run, false);
    v_version    numeric;
    v_attributes jsonb;
    v_path       text;
    v_report     jsonb := '{"attributes": {"added": [], "existing": []},
                            "options": {"added": []},
                            "classes": {"added": [], "existing": []},
                            "assignments": {"added": [], "existing": []},
                            "conflicts": []}';
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

    PERFORM util.check_unit_file_object(p_data, 'The file',
        ARRAY['format', 'version', 'name', 'description', 'attributes', 'classes'],
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
    IF p_data ? 'name' AND jsonb_typeof(p_data -> 'name') <> 'string' THEN
        PERFORM util.raise_invalid('"name" must be text');
    END IF;
    IF p_data ? 'description' AND jsonb_typeof(p_data -> 'description') <> 'string' THEN
        PERFORM util.raise_invalid('"description" must be text');
    END IF;

    BEGIN -- a subtransaction, rolled back for a dry run or a conflict
        SELECT a.p_report, a.p_attributes INTO v_report, v_attributes
        FROM util.model_import_attributes(v_tenant, util.unit_file_list(p_data, 'attributes', 'The file'), v_report) a;
        v_report := util.model_import_classes(v_tenant, p_parent, v_path,
            util.unit_file_list(p_data, 'classes', 'The file'), v_attributes, v_report);

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
