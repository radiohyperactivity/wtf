-- API: items and values. Explained in api/item.md.

-- ---------------------------------------------------------------------------
-- item
-- ---------------------------------------------------------------------------

-- Items, alphabetically, each with its stock total. Optional filters:
--   p_class   only items in this class or any of its subclasses
--   p_search  words separated by spaces; every word must occur (case-insensitive
--             substring) in the item name, a class in its class path, a text or
--             url value, or a choice value, including the defaults it shows.
--             The words may match in different places.
--   p_where   attribute filters, all of which must match: a list of
--             {attribute, op, value}, matched against the values the item
--             shows (class defaults included; per-unit attributes against
--             each live stock row). See util.check_item_filter and
--             api/item.md.
CREATE FUNCTION item_list(
    p_class  uuid    DEFAULT NULL,
    p_search text    DEFAULT NULL,
    p_limit  integer DEFAULT 100,
    p_offset integer DEFAULT 0,
    p_where  jsonb   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_where  jsonb := '[]'::jsonb;
BEGIN
    PERFORM util.require('data', 'read');
    v_tenant := util.tenant();
    PERFORM util.check_paging(p_limit, p_offset);

    IF p_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM class WHERE id = p_class AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('class', p_class);
    END IF;
    IF p_where IS NOT NULL THEN
        IF jsonb_typeof(p_where) <> 'array' THEN
            PERFORM util.raise_invalid('where must be a list of filters');
        END IF;
        SELECT COALESCE(jsonb_agg(util.check_item_filter(v_tenant, f)), '[]'::jsonb) INTO v_where
        FROM jsonb_array_elements(p_where) AS f;
    END IF;

    RETURN (
        WITH words AS (
            SELECT DISTINCT w
            FROM regexp_split_to_table(lower(btrim(COALESCE(p_search, ''))), '\s+') AS w
            WHERE w <> ''
        ),
        matching AS (
            SELECT i.id, i.name
            FROM item i
            WHERE i.tenant = v_tenant
              AND NOT i.deleted
              AND (p_class IS NULL OR i.class IN (SELECT util.class_subtree(p_class)))
              -- every word occurs in at least one of the item's search texts
              AND NOT EXISTS (
                  SELECT 1
                  FROM words
                  WHERE NOT EXISTS (
                      SELECT 1
                      FROM util.item_search_texts(i.id, i.class) AS t (text)
                      WHERE strpos(t.text, words.w) > 0
                  )
              )
              -- and every filter matches
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(v_where) AS f
                  WHERE NOT util.item_matches(i.id, i.class, f)
              )
        )
        SELECT util.page(
            (SELECT count(*) FROM matching),
            p_limit, p_offset,
            (
                SELECT jsonb_agg(
                           util.item_summary_json(m.id)
                           || jsonb_build_object('stock',      util.item_stock_total_json(m.id),
                                                 'incomplete', util.item_incomplete(m.id),
                                                 'photo',      util.item_photo_json(m.id))
                           ORDER BY util.natural_key(m.name), m.id)
                FROM (
                    SELECT id, name
                    FROM matching
                    ORDER BY util.natural_key(name), id
                    LIMIT p_limit OFFSET p_offset
                ) m
            )
        )
    );
END;
$$;

-- The item with its class, values and stock rows (where it is). A deleted
-- item is returned too, with deleted: true.
CREATE FUNCTION item_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'read');
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_id AND tenant = util.tenant()) THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
    RETURN util.item_json(p_id);
END;
$$;

-- Creates an item, optionally with values: {"<attribute id>": <value>, ...}.
-- Numbers of attributes with a unit are given in the base unit.
-- Only per-kind attributes; per-unit values go on stock rows. An attribute
-- given as JSON null gets no value. Class defaults are never stored on the
-- item; item_get shows them for attributes without a value. Required
-- attributes without a default must be given (checked at commit).
-- p_unit is the unit stock is measured in (NULL = pieces), and must be
-- available; with p_unit_lock, stock is always shown in it, as for
-- attributes.
CREATE FUNCTION item_create(
    p_class     uuid,
    p_name      text,
    p_unit      uuid    DEFAULT NULL,
    p_unit_lock boolean DEFAULT false,
    p_values    jsonb   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_id     uuid;
BEGIN
    PERFORM util.require('data', 'write');
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = p_class AND tenant = v_tenant) THEN
        PERFORM util.raise_bad_reference('class', p_class);
    END IF;
    PERFORM util.check_unit_choosable(v_tenant, p_unit);
    INSERT INTO item (tenant, code, class, name, unit, unit_lock)
    VALUES (v_tenant, next_code(v_tenant), p_class, util.clean_name(p_name), p_unit, COALESCE(p_unit_lock, false))
    RETURNING id INTO v_id;

    PERFORM util.values_upsert(false, v_id, p_values);

    RETURN util.item_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: class, name, unit, unit_lock, photo
-- (one of its own image attachments, or null).
-- Changing the class is rejected if existing values would no longer have a
-- matching attribute. The unit can only change to another unit of the same
-- quantity, and an available one; nothing is converted. A unit can't be
-- added or removed (see SCHEMA.md).
CREATE FUNCTION item_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require('data', 'write');
    v_tenant := util.tenant();
    PERFORM util.check_patch(p_patch, ARRAY['class', 'name', 'unit', 'unit_lock', 'photo'], ARRAY['class', 'name', 'unit_lock']);
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_id AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
    IF p_patch ? 'class'
       AND NOT EXISTS (SELECT 1 FROM class WHERE id = (p_patch ->> 'class')::uuid AND tenant = v_tenant)
    THEN
        PERFORM util.raise_bad_reference('class', (p_patch ->> 'class')::uuid);
    END IF;
    IF p_patch ? 'unit'
       AND (p_patch ->> 'unit')::uuid IS DISTINCT FROM (SELECT unit FROM item WHERE id = p_id)
    THEN
        PERFORM util.check_unit_choosable(v_tenant, (p_patch ->> 'unit')::uuid);
    END IF;

    UPDATE item
    SET class     = CASE WHEN p_patch ? 'class'
                         THEN (p_patch ->> 'class')::uuid ELSE class END,
        name      = CASE WHEN p_patch ? 'name'
                         THEN util.clean_name(p_patch ->> 'name') ELSE name END,
        unit      = CASE WHEN p_patch ? 'unit'
                         THEN (p_patch ->> 'unit')::uuid ELSE unit END,
        unit_lock = CASE WHEN p_patch ? 'unit_lock'
                         THEN (p_patch ->> 'unit_lock')::boolean ELSE unit_lock END
    WHERE id = p_id AND tenant = v_tenant;
    PERFORM util.set_photo('item', p_id, p_patch);
    RETURN util.item_json(p_id);
END;
$$;

-- Marks an item deleted; its values stay with it. Fails (23001,
-- restrict_violation) while it has live stock rows.
CREATE FUNCTION item_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    UPDATE item SET deleted = true WHERE id = p_id AND tenant = util.tenant();

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
END;
$$;

-- Restores a deleted item, with the stock rows deleted together with it.
-- p_options, all optional:
--   name          a new name
--   class         the class to restore it in instead
--   with_parents  true: also restore its deleted class, and the deleted
--                 classes that class is in (needs model write)
-- Without class or with_parents, an item whose class is deleted can't be
-- restored (55000).
CREATE FUNCTION item_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_item   item;
    v_class  uuid;
    v_stock  uuid[];
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM util.check_patch(p_options, ARRAY['name', 'class', 'with_parents'], ARRAY['name', 'class', 'with_parents']);
    SELECT * INTO v_item FROM item WHERE id = p_id AND tenant = util.tenant() FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
    IF NOT v_item.deleted THEN
        PERFORM util.raise_not_deleted('item', p_id);
    END IF;

    v_class := COALESCE((p_options ->> 'class')::uuid, v_item.class);
    IF NOT EXISTS (SELECT 1 FROM class WHERE id = v_class AND tenant = v_item.tenant) THEN
        PERFORM util.raise_bad_reference('class', v_class);
    END IF;
    IF (SELECT deleted FROM class WHERE id = v_class) THEN
        IF p_options ? 'class' THEN
            PERFORM raise_deleted('class', v_class);
        ELSIF COALESCE((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM util.require('model', 'write');
            PERFORM util.restore_class_chain(v_class);
        ELSE
            PERFORM util.raise_restore_into_deleted(row_label('item', p_id),
                format('class "%s"', util.path_text(util.class_path(v_class))), 'class');
        END IF;
    END IF;

    v_stock := ARRAY(
        SELECT id FROM stock
        WHERE item = p_id AND deleted
          AND id IN (SELECT util.deleted_in('stock', util.deletion_transaction('item', p_id))));

    UPDATE item
    SET deleted = false,
        name    = CASE WHEN p_options ? 'name' THEN util.clean_name(p_options ->> 'name') ELSE name END,
        class   = v_class
    WHERE id = p_id;
    UPDATE value SET item = item, attribute = attribute WHERE item = p_id;
    PERFORM util.restore_stock_rows(v_stock);

    RETURN util.item_json(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- value
-- ---------------------------------------------------------------------------

-- Sets (inserts or replaces) one value of an item. Numbers of attributes with
-- a unit are given in the base unit. Returns the item.
CREATE FUNCTION value_set(p_item uuid, p_attribute uuid, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_item AND tenant = util.tenant()) THEN
        PERFORM util.raise_not_found('item', p_item);
    END IF;

    PERFORM util.value_upsert(p_item, p_attribute, p_value);
    RETURN util.item_json(p_item);
END;
$$;

-- Removes one value of an item. Returns the item.
CREATE FUNCTION value_delete(p_item uuid, p_attribute uuid) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_item AND tenant = util.tenant()) THEN
        PERFORM util.raise_not_found('item', p_item);
    END IF;
    PERFORM check_live('item', p_item);
    DELETE FROM value
    WHERE item = p_item
      AND attribute = p_attribute;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % has no value for attribute %', p_item, p_attribute
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN util.item_json(p_item);
END;
$$;
