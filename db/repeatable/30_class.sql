-- API: classes and class attributes. Explained in api/class.md.

-- ---------------------------------------------------------------------------
-- class
-- ---------------------------------------------------------------------------

-- The whole class tree: {version, unchanged, tree}. tree is a nested list of
-- {id, name, parent, children}, alphabetically per level.
-- When p_known_version is the current version, the tree is left out and
-- unchanged is true (the REST layer answers 304 Not Modified).
CREATE FUNCTION class_list(p_known_version bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_version bigint := util.data_version('class');
BEGIN
    PERFORM util.require_model_read();
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;

    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'tree',      util.class_tree(NULL)
    );
END;
$$;

-- The class with its path and all effective (own + inherited) attributes.
-- A deleted class is returned too, with deleted: true.
CREATE FUNCTION class_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_model_read();
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_id) THEN
        PERFORM util.raise_not_found('class', p_id);
    END IF;
    RETURN util.class_json(p_id) || jsonb_build_object(
        'attributes',  util.class_attributes_json(p_id),
        'photo',       util.attachment_json((SELECT photo FROM class WHERE id = p_id)),
        'attachments', util.attachments_json(NULL, NULL, NULL, p_id)
    );
END;
$$;

CREATE FUNCTION class_create(p_name text, p_parent uuid DEFAULT NULL, p_container boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     uuid;
BEGIN
    PERFORM util.require('model', 'write');
    INSERT INTO class (name, parent, container)
    VALUES (util.clean_path_name(p_name, 'class'), p_parent, COALESCE(p_container, false))
    RETURNING id INTO v_id;

    RETURN class_get(v_id);
END;
$$;

-- Changes the fields present in p_patch: name, parent (null = make it a
-- root), container, photo (one of its own image attachments, or null).
-- Moving is rejected if it would create a cycle or leave item values without
-- a matching attribute; becoming a container is rejected while the class has
-- items.
CREATE FUNCTION class_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_patch, ARRAY['name', 'parent', 'container', 'photo'], ARRAY['name', 'container']);

    UPDATE class
    SET name      = CASE WHEN p_patch ? 'name'
                         THEN util.clean_path_name(p_patch ->> 'name', 'class') ELSE name END,
        parent    = CASE WHEN p_patch ? 'parent'
                         THEN (p_patch ->> 'parent')::uuid ELSE parent END,
        container = CASE WHEN p_patch ? 'container'
                         THEN (p_patch ->> 'container')::boolean ELSE container END
    WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('class', p_id);
    END IF;
    PERFORM util.set_photo('class', p_id, p_patch);
    RETURN class_get(p_id);
END;
$$;

-- Marks a class deleted. Fails (23001, restrict_violation) while it has live
-- subclasses or items.
CREATE FUNCTION class_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    UPDATE class SET deleted = true WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('class', p_id);
    END IF;
END;
$$;

-- Marks a class and every live class below it deleted, in one transaction.
--   p_force    false: nothing is deleted while any of them has live items
--              (23001, naming the classes and their item counts);
--              true:  those items are deleted too, with their live stock
--              rows (this needs data write as well).
--   p_dry_run  deletes nothing, and only reports.
-- Returns what is (or would be) deleted:
--   {classes: [{id, path}], items: [{id, code, name, class}], stock: <count>}
-- with classes deepest first and items alphabetically.
CREATE FUNCTION class_delete_tree(p_id uuid, p_force boolean DEFAULT false, p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_classes uuid[];
    v_items   uuid[];
    v_class   uuid;
    v_in_use  text;
    v_result  jsonb;
BEGIN
    PERFORM util.require('model', 'write');
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_id) THEN
        PERFORM util.raise_not_found('class', p_id);
    END IF;
    PERFORM check_live('class', p_id);

    WITH RECURSIVE below (id, depth) AS (
        SELECT p_id, 0
        UNION ALL
        SELECT c.id, b.depth + 1 FROM class c JOIN below b ON c.parent = b.id WHERE NOT c.deleted
    )
    SELECT array_agg(id ORDER BY depth DESC, id) INTO v_classes FROM below;

    SELECT COALESCE(array_agg(i.id), '{}') INTO v_items
    FROM item i WHERE i.class = ANY (v_classes) AND NOT i.deleted;

    v_result := jsonb_build_object(
        'classes', (
            SELECT jsonb_agg(jsonb_build_object('id', u.id, 'path', util.path_text(util.class_path(u.id)))
                             ORDER BY u.ord)
            FROM unnest(v_classes) WITH ORDINALITY AS u(id, ord)
        ),
        'items', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'code', util.code_text(i.code),
                                                         'name', i.name, 'class', i.class)
                                      ORDER BY lower(i.name), i.id), '[]'::jsonb)
            FROM item i WHERE i.id = ANY (v_items)
        ),
        'stock', (SELECT count(*) FROM stock s WHERE s.item = ANY (v_items) AND NOT s.deleted)
    );

    IF cardinality(v_items) > 0 THEN
        IF NOT p_force THEN
            IF p_dry_run THEN
                RETURN v_result;
            END IF;
            SELECT string_agg(format('%s (%s %s)', t.path, t.n, CASE WHEN t.n = 1 THEN 'item' ELSE 'items' END),
                              ', ' ORDER BY t.path)
            INTO v_in_use
            FROM (
                SELECT util.path_text(util.class_path(i.class)) AS path, count(*) AS n
                FROM item i WHERE i.id = ANY (v_items)
                GROUP BY i.class
            ) t;
            RAISE EXCEPTION 'These classes still have items: %', v_in_use
                USING ERRCODE = 'restrict_violation',
                      HINT = 'Delete the items first, or force the delete to delete them too.';
        END IF;
        PERFORM util.require('data', 'write');
    END IF;

    IF NOT p_dry_run THEN
        UPDATE stock SET deleted = true WHERE item = ANY (v_items) AND NOT deleted;
        UPDATE item SET deleted = true WHERE id = ANY (v_items);
        -- Deepest first, so no class is deleted while a live child still refers to it.
        FOREACH v_class IN ARRAY v_classes LOOP
            UPDATE class SET deleted = true WHERE id = v_class;
        END LOOP;
    END IF;
    RETURN v_result;
END;
$$;

-- Restores a deleted class, with the classes below it, the items and the
-- stock rows that were deleted together with it (in the same transaction).
-- p_options, all optional:
--   name          a new name, for when the old one has been taken since
--   parent        where to restore it instead (null: at the top)
--   with_parents  true: also restore the deleted classes it is in
-- Without parent or with_parents, a class whose parent is deleted can't be
-- restored (55000). Restoring items needs data write as well.
CREATE FUNCTION class_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_class       class;
    v_parent      uuid;
    v_transaction xid8;
    v_classes     uuid[];
    v_items       uuid[];
    v_stock       uuid[];
    v_child       uuid;
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_options, ARRAY['name', 'parent', 'with_parents'], ARRAY['name', 'with_parents']);
    SELECT * INTO v_class FROM class WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('class', p_id);
    END IF;
    IF NOT v_class.deleted THEN
        PERFORM util.raise_not_deleted('class', p_id);
    END IF;

    v_parent := CASE WHEN p_options ? 'parent' THEN (p_options ->> 'parent')::uuid ELSE v_class.parent END;
    IF v_parent IS NOT NULL AND (SELECT deleted FROM class WHERE id = v_parent) THEN
        IF p_options ? 'parent' THEN
            PERFORM raise_deleted('class', v_parent);
        ELSIF COALESCE((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM util.restore_class_chain(v_parent);
        ELSE
            PERFORM util.raise_restore_into_deleted(row_label('class', p_id),
                format('"%s"', util.path_text(util.class_path(v_parent))), 'parent');
        END IF;
    END IF;

    -- What was deleted with it.
    v_transaction := util.deletion_transaction('class', p_id);
    WITH RECURSIVE below (id, depth) AS (
        SELECT p_id, 0
        UNION ALL
        SELECT c.id, b.depth + 1
        FROM class c JOIN below b ON c.parent = b.id
        WHERE c.deleted AND c.id IN (SELECT util.deleted_in('class', v_transaction))
    )
    SELECT array_agg(id ORDER BY depth, id) INTO v_classes FROM below;
    v_items := ARRAY(
        SELECT id FROM item
        WHERE class = ANY (v_classes) AND deleted AND id IN (SELECT util.deleted_in('item', v_transaction)));
    v_stock := ARRAY(
        SELECT id FROM stock
        WHERE item = ANY (v_items) AND deleted AND id IN (SELECT util.deleted_in('stock', v_transaction)));
    IF cardinality(v_items) > 0 THEN
        PERFORM util.require('data', 'write');
    END IF;

    UPDATE class
    SET deleted = false,
        name    = CASE WHEN p_options ? 'name' THEN util.clean_path_name(p_options ->> 'name', 'class') ELSE name END,
        parent  = v_parent
    WHERE id = p_id;
    UPDATE class_attribute SET attribute = attribute WHERE class = p_id;
    FOREACH v_child IN ARRAY v_classes[2:] LOOP
        PERFORM util.restore_class_row(v_child);
    END LOOP;
    PERFORM util.restore_item_rows(v_items);
    PERFORM util.restore_stock_rows(v_stock);

    RETURN class_get(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- class_attribute
-- ---------------------------------------------------------------------------

-- Assigns an attribute to a class, or replaces the assignment if it exists.
-- p_default NULL (or JSON null) means no default. p_per_unit makes it a
-- per-unit attribute (values on stock rows instead of the item). p_required
-- makes new items (or stock rows, for per-unit attributes) need a value,
-- unless there is a default. Changing p_per_unit is rejected while values
-- exist. Returns the class.
CREATE FUNCTION class_attribute_set(
    p_class     uuid,
    p_attribute uuid,
    p_default   jsonb   DEFAULT NULL,
    p_per_unit  boolean DEFAULT false,
    p_required  boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_text    text;
    v_integer bigint;
    v_float   double precision;
    v_date    date;
    v_boolean boolean;
    v_option  uuid;
BEGIN
    PERFORM util.require('model', 'write');
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_class) THEN
        PERFORM util.raise_not_found('class', p_class);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;

    IF p_default IS NOT NULL AND jsonb_typeof(p_default) <> 'null' THEN
        SELECT text_v, integer_v, float_v, date_v, boolean_v, option_v
        INTO v_text, v_integer, v_float, v_date, v_boolean, v_option
        FROM util.parse_typed_value(p_attribute, p_default);
    END IF;

    INSERT INTO class_attribute (class, attribute,
                                 text_default, integer_default, float_default,
                                 date_default, boolean_default, option_default,
                                 per_unit, required)
    VALUES (p_class, p_attribute,
            v_text, v_integer, v_float,
            v_date, v_boolean, v_option,
            p_per_unit, p_required)
    ON CONFLICT (class, attribute) DO UPDATE SET
        text_default    = EXCLUDED.text_default,
        integer_default = EXCLUDED.integer_default,
        float_default   = EXCLUDED.float_default,
        date_default    = EXCLUDED.date_default,
        boolean_default = EXCLUDED.boolean_default,
        option_default  = EXCLUDED.option_default,
        per_unit        = EXCLUDED.per_unit,
        required        = EXCLUDED.required;

    RETURN class_get(p_class);
END;
$$;

-- Removes an attribute assignment. Rejected while items in the class (or its
-- subclasses) still have values that depend on it. Returns the class.
CREATE FUNCTION class_attribute_remove(p_class uuid, p_attribute uuid) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM check_live('class', p_class);
    DELETE FROM class_attribute
    WHERE class = p_class
      AND attribute = p_attribute;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Attribute % is not assigned to class %', p_attribute, p_class
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN class_get(p_class);
END;
$$;
