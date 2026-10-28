-- API: locations and stock. Explained in api/location.md.

-- ---------------------------------------------------------------------------
-- location
-- ---------------------------------------------------------------------------

-- The whole location tree: {version, unchanged, tree}. tree is a nested list
-- of {id, code, name, parent, container, photo, children}, alphabetically per level.
-- When p_known_version is the current version, the tree is left out and
-- unchanged is true (the REST layer answers 304 Not Modified).
CREATE FUNCTION location_list(p_known_version bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_version bigint := util.data_version('location');
BEGIN
    PERFORM util.require('data', 'read');
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;

    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'tree',      util.location_tree(NULL)
    );
END;
$$;

-- A deleted location is returned too, with deleted: true.
CREATE FUNCTION location_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'read');
    IF NOT EXISTS (SELECT 1 FROM location WHERE id = p_id) THEN
        PERFORM util.raise_not_found('location', p_id);
    END IF;
    RETURN util.location_json(p_id) || jsonb_build_object(
        'photo',       util.attachment_json('location', (SELECT photo FROM location WHERE id = p_id)),
        'attachments', util.attachments_json(NULL, NULL, p_id, NULL));
END;
$$;

-- Creates a location. p_grid {"columns": C, "rows": R} also creates a
-- compartment below it for every cell of a C × R grid, named like spreadsheet
-- cells: columns A, B, …, Z, AA, AB, … and rows 1 … R, so 8 × 5 gives A1 … H5.
-- A location with a grid is always a container. Nothing about the grid is
-- stored; the compartments are ordinary locations. A grid that creates more
-- than 1000 locations (compartments and the location itself) must be
-- confirmed with "confirm": true, so a typo can't flood the tree.
CREATE FUNCTION location_create(p_name text, p_parent uuid DEFAULT NULL, p_container boolean DEFAULT false,
                                p_grid jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id      uuid;
    v_columns integer;
    v_rows    integer;
    v_total   bigint;
BEGIN
    PERFORM util.require('data', 'write');
    IF p_grid IS NOT NULL AND jsonb_typeof(p_grid) <> 'null' THEN
        IF jsonb_typeof(p_grid) <> 'object'
           OR NOT (p_grid ?& ARRAY['columns', 'rows'])
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_grid) k WHERE k NOT IN ('columns', 'rows', 'confirm'))
           OR jsonb_typeof(p_grid -> 'columns') <> 'number'
           OR jsonb_typeof(p_grid -> 'rows') <> 'number'
           OR jsonb_typeof(COALESCE(p_grid -> 'confirm', 'false')) <> 'boolean'
        THEN
            PERFORM util.raise_invalid('grid must be {"columns": <number>, "rows": <number>, "confirm": <boolean, optional>}');
        END IF;
        v_columns := (p_grid ->> 'columns')::integer;
        v_rows    := (p_grid ->> 'rows')::integer;
        IF v_columns < 1 OR v_rows < 1 THEN
            PERFORM util.raise_invalid('A grid needs at least 1 column and 1 row');
        END IF;
        v_total := v_columns::bigint * v_rows + 1;
        IF v_total > 1000 AND NOT COALESCE((p_grid ->> 'confirm')::boolean, false) THEN
            PERFORM util.raise_invalid(format('This grid creates %s locations; confirm it with "confirm": true in the grid', v_total));
        END IF;
    END IF;

    INSERT INTO location (name, parent, container)
    VALUES (util.clean_path_name(p_name, 'location'), p_parent,
            COALESCE(p_container, false) OR v_columns IS NOT NULL)
    RETURNING id INTO v_id;

    IF v_columns IS NOT NULL THEN
        INSERT INTO location (name, parent)
        SELECT util.column_label(c) || r, v_id
        FROM generate_series(1, v_columns) AS c
        CROSS JOIN generate_series(1, v_rows) AS r
        ORDER BY c, r;
    END IF;

    RETURN util.location_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: name, parent (null = make it a
-- root), container, photo (one of its own image attachments, or null).
-- Moving a location takes everything in and below it along. Moving is
-- rejected if it would create a cycle; becoming a container is rejected
-- while the location has stock.
CREATE FUNCTION location_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM util.check_patch(p_patch, ARRAY['name', 'parent', 'container', 'photo'], ARRAY['name', 'container']);

    UPDATE location
    SET name      = CASE WHEN p_patch ? 'name'
                         THEN util.clean_path_name(p_patch ->> 'name', 'location') ELSE name END,
        parent    = CASE WHEN p_patch ? 'parent'
                         THEN (p_patch ->> 'parent')::uuid ELSE parent END,
        container = CASE WHEN p_patch ? 'container'
                         THEN (p_patch ->> 'container')::boolean ELSE container END
    WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('location', p_id);
    END IF;
    PERFORM util.set_photo('location', p_id, p_patch);
    RETURN util.location_json(p_id);
END;
$$;

-- Marks a location deleted. Fails (23001, restrict_violation) while it has
-- live sublocations or stock.
CREATE FUNCTION location_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    UPDATE location SET deleted = true WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('location', p_id);
    END IF;
END;
$$;

-- Marks a location and every live location below it deleted, in one
-- transaction.
--   p_force    false: nothing is deleted while there is live stock in any of
--              them (23001, naming the locations and their stock row counts);
--              true:  those stock rows are deleted too.
--   p_dry_run  deletes nothing, and only reports.
-- Returns what is (or would be) deleted:
--   {locations: [{id, code, path}],
--    stock: [{id, code, item: {id, code, name}, location, quantity}]}
-- with locations deepest first and stock rows by item name.
CREATE FUNCTION location_delete_tree(p_id uuid, p_force boolean DEFAULT false, p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_locations uuid[];
    v_stock     uuid[];
    v_location  uuid;
    v_in_use    text;
    v_result    jsonb;
BEGIN
    PERFORM util.require('data', 'write');
    IF NOT EXISTS (SELECT 1 FROM location WHERE id = p_id) THEN
        PERFORM util.raise_not_found('location', p_id);
    END IF;
    PERFORM check_live('location', p_id);

    WITH RECURSIVE below (id, depth) AS (
        SELECT p_id, 0
        UNION ALL
        SELECT l.id, b.depth + 1 FROM location l JOIN below b ON l.parent = b.id WHERE NOT l.deleted
    )
    SELECT array_agg(id ORDER BY depth DESC, id) INTO v_locations FROM below;

    SELECT COALESCE(array_agg(s.id), '{}') INTO v_stock
    FROM stock s WHERE s.location = ANY (v_locations) AND NOT s.deleted;

    v_result := jsonb_build_object(
        'locations', (
            SELECT jsonb_agg(jsonb_build_object('id', l.id, 'code', util.code_text(l.code),
                                                'path', util.path_text(util.location_path(l.id)))
                             ORDER BY u.ord)
            FROM unnest(v_locations) WITH ORDINALITY AS u(id, ord)
            JOIN location l ON l.id = u.id
        ),
        'stock', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'id', s.id, 'code', util.code_text(s.code),
                       'item', jsonb_build_object('id', i.id, 'code', util.code_text(i.code), 'name', i.name),
                       'location', s.location, 'quantity', s.quantity)
                   ORDER BY lower(i.name), s.id), '[]'::jsonb)
            FROM stock s JOIN item i ON i.id = s.item
            WHERE s.id = ANY (v_stock)
        )
    );

    IF cardinality(v_stock) > 0 AND NOT p_force THEN
        IF p_dry_run THEN
            RETURN v_result;
        END IF;
        SELECT string_agg(format('%s (%s %s)', t.path, t.n, CASE WHEN t.n = 1 THEN 'stock row' ELSE 'stock rows' END),
                          ', ' ORDER BY t.path)
        INTO v_in_use
        FROM (
            SELECT util.path_text(util.location_path(s.location)) AS path, count(*) AS n
            FROM stock s WHERE s.id = ANY (v_stock)
            GROUP BY s.location
        ) t;
        RAISE EXCEPTION 'These locations still have stock: %', v_in_use
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Move or delete the stock first, or force the delete to delete it too.';
    END IF;

    IF NOT p_dry_run THEN
        UPDATE stock SET deleted = true WHERE id = ANY (v_stock);
        -- Deepest first, so no location is deleted while a live child still refers to it.
        FOREACH v_location IN ARRAY v_locations LOOP
            UPDATE location SET deleted = true WHERE id = v_location;
        END LOOP;
    END IF;
    RETURN v_result;
END;
$$;

-- Restores a deleted location, with the locations below it and the stock
-- rows that were deleted together with it (in the same transaction).
-- p_options, all optional:
--   name          a new name, for when the old one has been taken since
--   parent        where to restore it instead (null: at the top)
--   with_parents  true: also restore the deleted locations it is in
-- Without parent or with_parents, a location inside a deleted one can't be
-- restored (55000).
CREATE FUNCTION location_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_location    location;
    v_parent      uuid;
    v_transaction xid8;
    v_locations   uuid[];
    v_stock       uuid[];
    v_child       uuid;
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM util.check_patch(p_options, ARRAY['name', 'parent', 'with_parents'], ARRAY['name', 'with_parents']);
    SELECT * INTO v_location FROM location WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('location', p_id);
    END IF;
    IF NOT v_location.deleted THEN
        PERFORM util.raise_not_deleted('location', p_id);
    END IF;

    v_parent := CASE WHEN p_options ? 'parent' THEN (p_options ->> 'parent')::uuid ELSE v_location.parent END;
    IF v_parent IS NOT NULL AND (SELECT deleted FROM location WHERE id = v_parent) THEN
        IF p_options ? 'parent' THEN
            PERFORM raise_deleted('location', v_parent);
        ELSIF COALESCE((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM util.restore_location_chain(v_parent);
        ELSE
            PERFORM util.raise_restore_into_deleted(row_label('location', p_id),
                format('"%s"', util.path_text(util.location_path(v_parent))), 'parent');
        END IF;
    END IF;

    -- What was deleted with it.
    v_transaction := util.deletion_transaction('location', p_id);
    WITH RECURSIVE below (id, depth) AS (
        SELECT p_id, 0
        UNION ALL
        SELECT l.id, b.depth + 1
        FROM location l JOIN below b ON l.parent = b.id
        WHERE l.deleted AND l.id IN (SELECT util.deleted_in('location', v_transaction))
    )
    SELECT array_agg(id ORDER BY depth, id) INTO v_locations FROM below;
    v_stock := ARRAY(
        SELECT id FROM stock
        WHERE location = ANY (v_locations) AND deleted
          AND id IN (SELECT util.deleted_in('stock', v_transaction)));

    UPDATE location
    SET deleted = false,
        name    = CASE WHEN p_options ? 'name' THEN util.clean_path_name(p_options ->> 'name', 'location') ELSE name END,
        parent  = v_parent
    WHERE id = p_id;
    FOREACH v_child IN ARRAY v_locations[2:] LOOP
        UPDATE location SET deleted = false WHERE id = v_child;
    END LOOP;
    PERFORM util.restore_stock_rows(v_stock);

    RETURN location_get(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- stock
-- ---------------------------------------------------------------------------

-- Stock rows, ordered by item name. Optional filters:
--   p_item      only this item
--   p_location  only this location or any location below it
CREATE FUNCTION stock_list(
    p_item     uuid    DEFAULT NULL,
    p_location uuid    DEFAULT NULL,
    p_limit    integer DEFAULT 100,
    p_offset   integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'read');
    PERFORM util.check_paging(p_limit, p_offset);

    IF p_item IS NOT NULL AND NOT EXISTS (SELECT 1 FROM item WHERE id = p_item) THEN
        PERFORM util.raise_not_found('item', p_item);
    END IF;
    IF p_location IS NOT NULL AND NOT EXISTS (SELECT 1 FROM location WHERE id = p_location) THEN
        PERFORM util.raise_not_found('location', p_location);
    END IF;

    RETURN (
        WITH matching AS (
            SELECT s.id, i.name AS item_name
            FROM stock s
            JOIN item i ON i.id = s.item
            WHERE NOT s.deleted
              AND (p_item IS NULL OR s.item = p_item)
              AND (p_location IS NULL OR s.location IN (SELECT util.location_subtree(p_location)))
        )
        SELECT util.page(
            (SELECT count(*) FROM matching),
            p_limit, p_offset,
            (
                SELECT jsonb_agg(util.stock_json(m.id) ORDER BY lower(m.item_name), m.id)
                FROM (
                    SELECT id, item_name
                    FROM matching
                    ORDER BY lower(item_name), id
                    LIMIT p_limit OFFSET p_offset
                ) m
            )
        )
    );
END;
$$;

-- The stock row with its per-unit values and missing required attributes.
-- A deleted row is returned too, with deleted: true (and merged_into, when a
-- move merged it into another row).
CREATE FUNCTION stock_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'read');
    IF NOT EXISTS (SELECT 1 FROM stock WHERE id = p_id) THEN
        PERFORM util.raise_not_found('stock', p_id);
    END IF;
    RETURN util.stock_detail_json(p_id);
END;
$$;

-- p_quantity is in the base unit of the item's unit (pieces if none);
-- NULL = present but not counted. p_values sets per-unit values:
-- {"<attribute id>": <value>, ...}. Required per-unit attributes without a
-- default must be given (checked at commit).
CREATE FUNCTION stock_create(
    p_item     uuid,
    p_location uuid,
    p_quantity numeric DEFAULT NULL,
    p_values   jsonb   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     uuid;
BEGIN
    PERFORM util.require('data', 'write');
    INSERT INTO stock (item, location, quantity)
    VALUES (p_item, p_location, p_quantity)
    RETURNING id INTO v_id;

    PERFORM util.values_upsert(true, v_id, p_values);

    RETURN util.stock_detail_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: item, location, quantity
-- (null = not counted), photo (one of its own image attachments, or null). Use stock_move to move things; this is for
-- corrections. Changing the item is rejected if the row's per-unit values
-- don't apply to the new item's class.
CREATE FUNCTION stock_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM util.check_patch(p_patch, ARRAY['item', 'location', 'quantity', 'photo'], ARRAY['item', 'location']);

    UPDATE stock
    SET item     = CASE WHEN p_patch ? 'item'
                        THEN (p_patch ->> 'item')::uuid ELSE item END,
        location = CASE WHEN p_patch ? 'location'
                        THEN (p_patch ->> 'location')::uuid ELSE location END,
        quantity = CASE WHEN p_patch ? 'quantity'
                        THEN (p_patch ->> 'quantity')::numeric ELSE quantity END
    WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('stock', p_id);
    END IF;
    PERFORM util.set_photo('stock', p_id, p_patch);
    RETURN util.stock_detail_json(p_id);
END;
$$;

-- Moves (part of) a stock row to another location.
-- p_quantity NULL moves the whole row; otherwise it is the amount to move
-- (in the base unit of the item's unit), and the row must be counted.
-- If the destination already holds exactly one counted row of the same item
-- with exactly the same per-unit values, and the moved row has no
-- attachments, the moved amount is added to that row (a whole row is then
-- marked deleted, merged_into that row). Otherwise a whole row simply changes
-- location, and a partial amount is split off into a new row at the
-- destination, with copies of the per-unit values, the attachments and the
-- photo.
-- Returns the stock row at the destination.
CREATE FUNCTION stock_move(p_id uuid, p_location uuid, p_quantity numeric DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_stock      stock;
    v_amount     numeric;
    v_whole      boolean;
    v_candidates uuid[];
    v_target     uuid;
    v_attachment stock_attachment;
    v_copy       uuid;
BEGIN
    PERFORM util.require('data', 'write');
    SELECT * INTO v_stock FROM stock WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('stock', p_id);
    END IF;
    IF v_stock.deleted THEN
        PERFORM raise_deleted('stock', p_id);
    END IF;
    PERFORM check_live('location', p_location);

    IF p_quantity IS NOT NULL THEN
        IF v_stock.quantity IS NULL THEN
            PERFORM util.raise_invalid('An uncounted stock row can only be moved as a whole');
        END IF;
        IF p_quantity <= 0 OR p_quantity > v_stock.quantity THEN
            PERFORM util.raise_invalid(format('Quantity to move must be greater than 0 and at most %s',
                                              v_stock.quantity));
        END IF;
    END IF;

    v_amount := COALESCE(p_quantity, v_stock.quantity);
    v_whole  := p_quantity IS NULL OR p_quantity = v_stock.quantity;

    -- Merge target: the single counted row of this item at the destination,
    -- if it has the same per-unit values.
    IF v_amount IS NOT NULL THEN
        v_candidates := ARRAY(
            SELECT id
            FROM stock
            WHERE item = v_stock.item
              AND location = p_location
              AND quantity IS NOT NULL
              AND NOT deleted
              AND id <> p_id
            FOR UPDATE
        );
        IF cardinality(v_candidates) = 1
           AND util.stock_values_equal(p_id, v_candidates[1])
           AND NOT EXISTS (SELECT 1 FROM stock_attachment WHERE stock = p_id)
        THEN
            v_target := v_candidates[1];
        END IF;
    END IF;

    IF v_target IS NOT NULL THEN
        UPDATE stock SET quantity = quantity + v_amount WHERE id = v_target;
        IF v_whole THEN
            UPDATE stock SET deleted = true, merged_into = v_target WHERE id = p_id;
        ELSE
            UPDATE stock SET quantity = quantity - v_amount WHERE id = p_id;
        END IF;
        RETURN util.stock_detail_json(v_target);
    END IF;

    IF v_whole THEN
        UPDATE stock SET location = p_location WHERE id = p_id;
        RETURN util.stock_detail_json(p_id);
    END IF;

    UPDATE stock SET quantity = quantity - v_amount WHERE id = p_id;

    INSERT INTO stock (item, location, quantity)
    VALUES (v_stock.item, p_location, v_amount)
    RETURNING id INTO v_target;

    INSERT INTO stock_value (stock, attribute,
                             text_value, integer_value, float_value,
                             date_value, boolean_value, option_value)
    SELECT v_target, attribute,
           text_value, integer_value, float_value,
           date_value, boolean_value, option_value
    FROM stock_value
    WHERE stock = p_id;

    -- The new row gets copies of the attachments (the same files on disk),
    -- and the copy of the photo as its photo.
    FOR v_attachment IN SELECT * FROM stock_attachment WHERE stock = p_id ORDER BY id LOOP
        INSERT INTO stock_attachment (stock, type, hash, size, title)
        VALUES (v_target, v_attachment.type, v_attachment.hash, v_attachment.size, v_attachment.title)
        RETURNING id INTO v_copy;
        IF v_attachment.id = v_stock.photo THEN
            UPDATE stock SET photo = v_copy WHERE id = v_target;
        END IF;
    END LOOP;

    RETURN util.stock_detail_json(v_target);
END;
$$;

-- Marks a stock row deleted; its per-unit values and attachments stay with it.
CREATE FUNCTION stock_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    UPDATE stock SET deleted = true WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('stock', p_id);
    END IF;
END;
$$;

-- Restores a deleted stock row. Its item must be live, and a row that a move
-- merged into another can't be restored (55000). p_options, all optional:
--   location      where to restore it instead
--   with_parents  true: also restore its deleted location, and the deleted
--                 locations that one is in
-- Without location or with_parents, a row at a deleted location can't be
-- restored (55000).
CREATE FUNCTION stock_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_stock    stock;
    v_location uuid;
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM util.check_patch(p_options, ARRAY['location', 'with_parents'], ARRAY['location', 'with_parents']);
    SELECT * INTO v_stock FROM stock WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('stock', p_id);
    END IF;
    IF NOT v_stock.deleted THEN
        PERFORM util.raise_not_deleted('stock', p_id);
    END IF;
    IF v_stock.merged_into IS NOT NULL THEN
        RAISE EXCEPTION 'This stock row was merged into stock row %, and can''t be restored',
            (SELECT util.code_text(code) FROM stock WHERE id = v_stock.merged_into)
            USING ERRCODE = 'object_not_in_prerequisite_state',
                  HINT = 'Its quantity is in that row now; move part of that row to split it off again.';
    END IF;
    IF (SELECT deleted FROM item WHERE id = v_stock.item) THEN
        RAISE EXCEPTION '% belongs to %, which is deleted', row_label('stock', p_id), row_label('item', v_stock.item)
            USING ERRCODE = 'object_not_in_prerequisite_state',
                  HINT = 'Restore the item first; that also restores the stock rows deleted with it.';
    END IF;

    v_location := COALESCE((p_options ->> 'location')::uuid, v_stock.location);
    IF (SELECT deleted FROM location WHERE id = v_location) THEN
        IF p_options ? 'location' THEN
            PERFORM raise_deleted('location', v_location);
        ELSIF COALESCE((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM util.restore_location_chain(v_location);
        ELSE
            PERFORM util.raise_restore_into_deleted(row_label('stock', p_id),
                format('"%s"', util.path_text(util.location_path(v_location))), 'location');
        END IF;
    END IF;

    UPDATE stock SET location = v_location, deleted = false WHERE id = p_id;
    PERFORM util.restore_stock_rows(ARRAY[p_id]);
    RETURN util.stock_detail_json(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- stock_value
-- ---------------------------------------------------------------------------

-- Sets (inserts or replaces) one per-unit value of a stock row. Numbers of
-- attributes with a unit are given in the base unit. Returns the row.
CREATE FUNCTION stock_value_set(p_stock uuid, p_attribute uuid, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    IF NOT EXISTS (SELECT 1 FROM stock WHERE id = p_stock) THEN
        PERFORM util.raise_not_found('stock', p_stock);
    END IF;

    PERFORM util.stock_value_upsert(p_stock, p_attribute, p_value);
    RETURN util.stock_detail_json(p_stock);
END;
$$;

-- Removes one per-unit value of a stock row. Rejected (at commit) for
-- required attributes without a default. Returns the row.
CREATE FUNCTION stock_value_delete(p_stock uuid, p_attribute uuid) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('data', 'write');
    PERFORM check_live('stock', p_stock);
    DELETE FROM stock_value
    WHERE stock = p_stock
      AND attribute = p_attribute;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock row % has no value for attribute %', p_stock, p_attribute
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN util.stock_detail_json(p_stock);
END;
$$;
