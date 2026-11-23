-- Model files (schema model): a tree of classes with their attributes, as
-- seed/model-format.md describes, imported or exported.

CREATE SCHEMA model;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A class's rule for counting stock in a model file, {counting, unit}, at
-- p_path (for messages), checked: counting none, optional or required; unit
-- a label or null (pieces), and null when nothing is counted.
CREATE FUNCTION model.stock_rule(p_path text, p_stock jsonb, OUT counting public.counting, OUT unit text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF jsonb_typeof(p_stock) <> 'object' THEN
        PERFORM error.invalid(format('%s: stock must be an object {counting, unit}', p_path));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_stock) LOOP
        IF NOT v_key = ANY (ARRAY['counting', 'unit']) THEN
            PERFORM error.invalid(format('%s: unknown field %L in stock; allowed: counting, unit', p_path, v_key));
        END IF;
    END LOOP;
    IF NOT coalesce(p_stock ->> 'counting' IN ('none', 'optional', 'required'), false) THEN
        PERFORM error.invalid(format('%s: stock''s counting must be none, optional or required', p_path));
    END IF;
    IF jsonb_typeof(p_stock -> 'unit') NOT IN ('string', 'null') THEN
        PERFORM error.invalid(format('%s: stock''s unit must be a label, or null for pieces', p_path));
    END IF;
    counting := (p_stock ->> 'counting')::public.counting;
    unit := nullif(btrim(p_stock ->> 'unit'), '');
    IF counting = 'none' AND unit IS NOT NULL THEN
        PERFORM error.invalid(format('%s: stock that isn''t counted has no unit', p_path));
    END IF;
END;
$$;

-- Imports p_nodes, a list of classes of a model file, below class p_parent
-- (NULL: at the top). p_path names where they are, for
-- messages ("MCU/ARM"). A class that is there already, by name (letter case
-- ignored), is imported into: it gets the attributes it hasn't got; an
-- attribute it has already must be the same, or the import is refused, and
-- so must its rule for counting stock, when the file gives one. A class
-- that is added gets the file's rule as its own, or inherits.
-- Counts what it adds and what was there already in p_report, {classes:
-- {added, existing}, attributes: {added, existing}}, and adds every class
-- that was there already and got attributes to p_changed, whose items and
-- stock rows are checked at the end (model.import_file).
CREATE FUNCTION model.import_classes(
    p_parent        uuid,
    p_nodes         jsonb,
    p_path          text,
    INOUT p_report  jsonb,
    INOUT p_changed uuid[]
)
LANGUAGE plpgsql AS $$
DECLARE
    v_node    jsonb;
    v_key     text;
    v_name    text;
    v_path    text;
    v_class   public.class;
    v_added   boolean;
    v_grew    boolean;
    v_attr    text;
    v_def     jsonb;
    v_order   integer;
    v_counting public.counting;
    v_unit     text;
BEGIN
    IF p_nodes IS NULL OR jsonb_typeof(p_nodes) = 'null' THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_nodes) <> 'array' THEN
        PERFORM error.invalid(format('%sclasses must be a list', coalesce(p_path || ': ', '')));
    END IF;
    FOR v_node IN SELECT n FROM jsonb_array_elements(p_nodes) n LOOP
        IF jsonb_typeof(v_node) <> 'object' THEN
            PERFORM error.invalid(format('%sa class must be an object {name, container, stock, attributes, classes}',
                                         coalesce(p_path || ': ', '')));
        END IF;
        FOR v_key IN SELECT jsonb_object_keys(v_node) LOOP
            IF NOT v_key = ANY (ARRAY['name', 'container', 'stock', 'attributes', 'classes']) THEN
                PERFORM error.invalid(format('%sunknown field %L in a class; allowed: name, container, stock, attributes, classes',
                                             coalesce(p_path || ': ', ''), v_key));
            END IF;
        END LOOP;
        IF jsonb_typeof(v_node -> 'name') IS DISTINCT FROM 'string' THEN
            PERFORM error.invalid(format('%sa class needs its name', coalesce(p_path || ': ', '')));
        END IF;
        v_name := util.trim_and_check_path_name(v_node ->> 'name', 'class');
        v_path := concat_ws('/', p_path, v_name);
        IF jsonb_typeof(v_node -> 'container') NOT IN ('boolean', 'null') THEN
            PERFORM error.invalid(format('%s: container must be true or false', v_path));
        END IF;
        IF jsonb_typeof(v_node -> 'attributes') NOT IN ('object', 'null') THEN
            PERFORM error.invalid(format('%s: attributes must be an object, by name', v_path));
        END IF;
        v_counting := NULL;
        v_unit := NULL;
        IF v_node ? 'stock' AND jsonb_typeof(v_node -> 'stock') <> 'null' THEN
            SELECT r.counting, r.unit INTO v_counting, v_unit FROM model.stock_rule(v_path, v_node -> 'stock') r;
        END IF;

        SELECT c.* INTO v_class
        FROM public.class c
        WHERE c.parent IS NOT DISTINCT FROM p_parent AND lower(c.name) = lower(v_name)
        FOR UPDATE;
        v_added := NOT FOUND;
        IF v_added THEN
            INSERT INTO public.class (parent, name, container, attributes, counting, unit, stock_from)
            SELECT p_parent, v_name, coalesce((v_node ->> 'container')::boolean, false),
                   coalesce(p.attributes, '{}'), coalesce(p.counting, 'optional'), p.unit, p.stock_from
            FROM (SELECT 1) one
            LEFT JOIN public.class p ON p.id = p_parent
            RETURNING * INTO v_class;
            IF v_counting IS NOT NULL THEN
                UPDATE public.class c
                SET counting = v_counting, unit = v_unit, stock_from = c.id
                WHERE c.id = v_class.id
                RETURNING * INTO v_class;
            END IF;
        ELSIF v_counting IS NOT NULL
              AND (v_class.counting <> v_counting OR v_class.unit IS DISTINCT FROM v_unit) THEN
            PERFORM error.duplicate(format(
                '%s: the class counts its stock %s already, and the file says %s',
                v_path, model.rule_words(v_class.counting, v_class.unit), model.rule_words(v_counting, v_unit)));
        END IF;
        p_report := jsonb_set(p_report, ARRAY['classes', CASE WHEN v_added THEN 'added' ELSE 'existing' END],
                              to_jsonb((p_report -> 'classes' ->> CASE WHEN v_added THEN 'added' ELSE 'existing' END)::integer + 1));

        v_grew := false;
        FOR v_attr, v_def IN
            SELECT e.key, e.value FROM jsonb_each(coalesce(v_node -> 'attributes', '{}')) e
            ORDER BY (e.value ->> 'order')::numeric NULLS LAST, e.key LOOP
            v_attr := class.check_attribute_name(v_attr);
            v_def := class.check_definition(v_attr, CASE WHEN jsonb_typeof(v_def) = 'object' THEN v_def - 'class'
                                                         ELSE v_def END);
            IF v_class.attributes ? v_attr THEN
                IF (v_class.attributes -> v_attr) - 'class' - 'order' <> v_def - 'order' THEN
                    PERFORM error.duplicate(format('%s: the class has an attribute "%s" already, and it is different',
                                                   v_path, v_attr));
                END IF;
                p_report := jsonb_set(p_report, '{attributes,existing}',
                                      to_jsonb((p_report -> 'attributes' ->> 'existing')::integer + 1));
                CONTINUE;
            END IF;
            v_order := coalesce((v_def ->> 'order')::integer, 1 + coalesce((
                           SELECT max((e.value ->> 'order')::integer) FROM jsonb_each(v_class.attributes) e
                           WHERE e.value ->> 'scope' = v_def ->> 'scope'), 0));
            UPDATE public.class c
            SET attributes = c.attributes || jsonb_build_object(v_attr, v_def || jsonb_build_object(
                                                                    'class', v_class.id, 'order', v_order))
            WHERE c.id = v_class.id
            RETURNING * INTO v_class;
            v_grew := true;
            p_report := jsonb_set(p_report, '{attributes,added}',
                                  to_jsonb((p_report -> 'attributes' ->> 'added')::integer + 1));
        END LOOP;
        IF v_grew THEN
            PERFORM class.rebuild(v_class.id);
            IF NOT v_added THEN
                p_changed := p_changed || v_class.id;
            END IF;
        END IF;

        SELECT * INTO p_report, p_changed
        FROM model.import_classes(v_class.id, v_node -> 'classes', v_path, p_report, p_changed);
    END LOOP;
END;
$$;

-- A rule for counting stock in words, for messages: "not counted",
-- "counted, optional, in pieces", "counted, required, in m".
CREATE FUNCTION model.rule_words(p_counting public.counting, p_unit text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_counting WHEN 'none' THEN 'not counted'
                ELSE format('counted, %s, in %s', p_counting, coalesce(p_unit, 'pieces')) END;
$$;

-- Imports model file p_data (seed/model-format.md) below class p_parent (NULL: at the top), and returns what it added and
-- what was there already: {classes: {added, existing}, attributes: {added,
-- existing}, items, stock, dry_run}, items and stock being how many rows
-- below classes that were there already it wrote, as a class change does
-- (class.rewrite_rows). With p_dry_run nothing changes, and the answer says
-- what would have.
CREATE FUNCTION model.import_file(p_data jsonb, p_parent uuid, p_dry_run boolean)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_key     text;
    v_report  jsonb := '{"classes": {"added": 0, "existing": 0}, "attributes": {"added": 0, "existing": 0}}';
    v_changed uuid[] := '{}';
    v_rows    jsonb;
    v_items   bigint := 0;
    v_stock   bigint := 0;
    v_class   uuid;
    v_detail  text;
BEGIN
    IF p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether it is a dry run');
    END IF;
    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' OR p_data ->> 'format' IS DISTINCT FROM 'wtf-model' THEN
        PERFORM error.invalid('This is not a model file: it needs "format": "wtf-model"');
    END IF;
    -- Version 2 had no rules for counting stock, as units were the items';
    -- it reads as version 3 without them.
    IF p_data -> 'version' IS DISTINCT FROM '3' AND p_data -> 'version' IS DISTINCT FROM '2' THEN
        PERFORM error.invalid(format('This model file is of version %s; this WtF reads versions 2 and 3',
                                     coalesce(p_data ->> 'version', '(none)')));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_data) LOOP
        IF NOT v_key = ANY (ARRAY['format', 'version', 'meta', 'classes']) THEN
            PERFORM error.invalid(format('Unknown field %L in the model file; allowed: format, version, meta, classes',
                                         v_key));
        END IF;
    END LOOP;

    BEGIN
        SELECT * INTO v_report, v_changed
        FROM model.import_classes(p_parent, p_data -> 'classes',
                                  CASE WHEN p_parent IS NOT NULL THEN util.path_text(class.path_json(p_parent)) END,
                                  v_report, v_changed);
        FOREACH v_class IN ARRAY v_changed LOOP
            v_rows := class.rewrite_rows(v_class);
            v_items := v_items + (v_rows ->> 'items')::bigint;
            v_stock := v_stock + (v_rows ->> 'stock')::bigint;
        END LOOP;
        v_report := v_report || jsonb_build_object('items', v_items, 'stock', v_stock, 'dry_run', false);
        IF p_dry_run THEN
            PERFORM util.end_dry_run(v_report);
        END IF;
    EXCEPTION WHEN SQLSTATE 'WT900' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN util.dry_run_answer(v_detail);
    END;
    IF (v_report -> 'classes' ->> 'added')::integer + (v_report -> 'attributes' ->> 'added')::integer > 0 THEN
        PERFORM util.bump_version('class');
    END IF;
    RETURN v_report;
END;
$$;

-- Class p_class with the classes below it, as a model file has them: {name,
-- container, stock, attributes, classes}, its attributes by name without
-- the class that defines them, and stock its rule for counting stock,
-- {counting, unit}, when its own. With p_all, all the class's attributes,
-- the inherited ones too, and its rule when inherited too (for the top of
-- an export); otherwise its own.
CREATE FUNCTION model.class_json(p_class uuid, p_all boolean)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_class public.class;
BEGIN
    SELECT c.* INTO v_class FROM public.class c WHERE c.id = p_class;
    RETURN jsonb_strip_nulls(jsonb_build_object(
        'name',       v_class.name,
        'container',  v_class.container,
        'stock',      CASE WHEN v_class.stock_from = v_class.id OR p_all AND v_class.stock_from IS NOT NULL
                           THEN jsonb_build_object('counting', v_class.counting, 'unit', v_class.unit) END,
        'attributes', (SELECT coalesce(jsonb_object_agg(e.key, e.value - 'class'), '{}')
                       FROM jsonb_each(v_class.attributes) e
                       WHERE p_all OR e.value ->> 'class' = v_class.id::text),
        'classes',    (SELECT jsonb_agg(model.class_json(c.id, false) ORDER BY c.name COLLATE public.natural, c.id)
                       FROM public.class c WHERE c.parent = p_class)));
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- Imports model file p_data below class p_parent (NULL:
-- at the top), as model.import_file says. For admins.
CREATE FUNCTION model.import(p_request public.request, p_data jsonb, p_parent uuid, p_dry_run boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    IF p_parent IS NOT NULL THEN
        PERFORM class.lock_subtree(p_parent);
    END IF;
    RETURN model.import_file(p_data, p_parent, p_dry_run);
END;
$$;

-- Exports a class with everything below it as a model
-- file (seed/model-format.md): the top class with all its attributes, its
-- inherited ones as its own, and the classes below it with their own.
-- Importing the file where the class is changes nothing; importing it
-- elsewhere sets up the same. For admins.
CREATE FUNCTION model.export(p_request public.request, p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_name    text;
BEGIN
    SELECT c.name INTO v_name FROM public.class c WHERE c.id = p_class;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    RETURN jsonb_build_object(
        'format',  'wtf-model',
        'version', 3,
        'meta',    jsonb_build_object('name', v_name),
        'classes', jsonb_build_array(model.class_json(p_class, true)));
END;
$$;
