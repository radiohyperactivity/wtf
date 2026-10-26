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
CREATE FUNCTION item_list(
    p_class  uuid    DEFAULT NULL,
    p_search text    DEFAULT NULL,
    p_limit  integer DEFAULT 100,
    p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'read');
BEGIN
    PERFORM util.check_paging(p_limit, p_offset);

    IF p_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM class WHERE id = p_class AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('class', p_class);
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
                           ORDER BY lower(m.name), m.id)
                FROM (
                    SELECT id, name
                    FROM matching
                    ORDER BY lower(name), id
                    LIMIT p_limit OFFSET p_offset
                ) m
            )
        )
    );
END;
$$;

-- The item with its class, values and stock rows (where it is).
CREATE FUNCTION item_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'read');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_id AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
    RETURN util.item_json(p_id);
END;
$$;

-- Creates an item, optionally with values: {"<attribute id>": <value>, ...}.
-- Numbers of attributes with a unit group are given in the base unit.
-- Only per-kind attributes; per-unit values go on stock rows. An attribute
-- given as JSON null gets no value. Class defaults are never stored on the
-- item; item_get shows them for attributes without a value. Required
-- attributes without a default must be given (checked at commit).
-- p_unit_group is the unit group stock is measured in; NULL = pieces.
CREATE FUNCTION item_create(
    p_class      uuid,
    p_name       text,
    p_unit_group uuid  DEFAULT NULL,
    p_values     jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'write');
    v_id     uuid;
BEGIN
    INSERT INTO item (tenant, class, name, unit_group)
    VALUES (v_tenant, p_class, util.clean_name(p_name), p_unit_group)
    RETURNING id INTO v_id;

    PERFORM util.values_upsert(false, v_id, p_values);

    RETURN util.item_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: class, name, unit_group.
-- Changing the class is rejected if existing values would no longer have a
-- matching attribute. The unit group can only change to another group of the
-- same quantity; nothing is converted. A group can't be added or removed
-- (see SCHEMA.md).
CREATE FUNCTION item_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'write');
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['class', 'name', 'unit_group'], ARRAY['class', 'name']);

    UPDATE item
    SET class      = CASE WHEN p_patch ? 'class'
                          THEN (p_patch ->> 'class')::uuid ELSE class END,
        name       = CASE WHEN p_patch ? 'name'
                          THEN util.clean_name(p_patch ->> 'name') ELSE name END,
        unit_group = CASE WHEN p_patch ? 'unit_group'
                          THEN (p_patch ->> 'unit_group')::uuid ELSE unit_group END
    WHERE id = p_id
      AND tenant = v_tenant;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
    RETURN util.item_json(p_id);
END;
$$;

-- Deletes an item and its values. Fails (23001, restrict_violation) while stock rows exist.
CREATE FUNCTION item_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'write');
BEGIN
    DELETE FROM item WHERE id = p_id AND tenant = v_tenant;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('item', p_id);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- value
-- ---------------------------------------------------------------------------

-- Sets (inserts or replaces) one value of an item. Numbers of attributes with
-- a unit group are given in the base unit. Returns the item.
CREATE FUNCTION value_set(p_item uuid, p_attribute uuid, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('data', 'write');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM item WHERE id = p_item AND tenant = v_tenant) THEN
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
DECLARE
    v_tenant uuid := util.require('data', 'write');
BEGIN
    DELETE FROM value
    WHERE item = p_item
      AND attribute = p_attribute
      AND tenant = v_tenant;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % has no value for attribute %', p_item, p_attribute
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN util.item_json(p_item);
END;
$$;
