-- API: history. Explained in api/history.md.
--
-- Every function needs the history privilege, returns the entries newest
-- first, and is paged (p_limit, p_offset). Objects that have been deleted
-- still have their history.

-- One history entry as JSON.
CREATE FUNCTION util.history_json(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'id',          h.id,
            'happened_at', h.happened_at,
            'transaction', h.transaction::text,
            'account',     CASE WHEN a.id IS NULL THEN NULL
                                ELSE jsonb_build_object('id', a.id, 'email', a.email, 'deleted', a.deleted) END,
            'table',       h.table_name,
            'operation',   h.operation,
            'data',        h.data,
            'changes',     h.changes
        )
        FROM history h
        LEFT JOIN account a ON a.id = h.account
        WHERE h.id = p_id
    );
END;
$$;

-- A page of the session's tenant's history entries that p_match selects.
-- p_match is a SQL condition on the history row "h", built only by the
-- functions below.
CREATE FUNCTION util.history_page(p_match text, p_limit integer, p_offset integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tenant uuid := util.tenant();
    v_total  bigint;
    v_rows   jsonb;
BEGIN
    PERFORM util.check_paging(p_limit, p_offset);
    EXECUTE format('SELECT count(*) FROM history h WHERE h.tenant = $1 AND (%s)', p_match)
        INTO v_total USING v_tenant;
    EXECUTE format($q$
        SELECT jsonb_agg(util.history_json(page.id) ORDER BY page.id DESC)
        FROM (
            SELECT h.id
            FROM history h
            WHERE h.tenant = $3 AND (%s)
            ORDER BY h.id DESC
            LIMIT $1 OFFSET $2
        ) page
    $q$, p_match) INTO v_rows USING p_limit, p_offset, v_tenant;
    RETURN util.page(v_total, p_limit, p_offset, v_rows);
END;
$$;

-- An item: the item itself, its values, its stock rows and their per-unit
-- values, and the attachments of the item and of its stock rows.
CREATE FUNCTION item_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     text := quote_literal(p_id);
    v_stock  text;
BEGIN
    PERFORM util.require('history', 'read');
    -- The item's stock rows, including deleted ones.
    v_stock := format($q$(
        SELECT s.data ->> 'id' FROM history s
        WHERE s.tenant = h.tenant AND s.table_name = 'stock' AND s.data ->> 'item' = %s
    )$q$, v_id);
    RETURN util.history_page(format($q$
           (h.table_name = 'item'        AND h.data ->> 'id'    = %1$s)
        OR (h.table_name = 'value'       AND h.data ->> 'item'  = %1$s)
        OR (h.table_name = 'stock'       AND h.data ->> 'item'  = %1$s)
        OR (h.table_name = 'stock_value' AND h.data ->> 'stock' IN %2$s)
        OR (h.table_name = 'item_attachment'  AND h.data ->> 'item'  = %1$s)
        OR (h.table_name = 'stock_attachment' AND h.data ->> 'stock' IN %2$s)
    $q$, v_id, v_stock), p_limit, p_offset);
END;
$$;

-- A stock row: the row, its per-unit values and its attachments.
CREATE FUNCTION stock_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page(format($q$
           (h.table_name = 'stock'       AND h.data ->> 'id'    = %1$s)
        OR (h.table_name = 'stock_value' AND h.data ->> 'stock' = %1$s)
        OR (h.table_name = 'stock_attachment' AND h.data ->> 'stock' = %1$s)
    $q$, quote_literal(p_id)), p_limit, p_offset);
END;
$$;

-- A location: the location itself, stock rows that were there (including
-- those that arrived or left), its attachments, and the locations directly
-- inside it being added, moved in or out, deleted, restored or purged (so a
-- deleted one can be found from here).
CREATE FUNCTION location_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page(format($q$
           (h.table_name = 'location'   AND h.data ->> 'id' = %1$s)
        OR (h.table_name = 'stock'      AND (h.data ->> 'location' = %1$s
                                             OR h.changes -> 'location' ->> 'old' = %1$s))
        OR (h.table_name = 'location_attachment' AND h.data ->> 'location' = %1$s)
        OR (h.table_name = 'location'   AND (h.data ->> 'parent' = %1$s
                                             OR h.changes -> 'parent' ->> 'old' = %1$s)
                                        AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted']))
    $q$, quote_literal(p_id)), p_limit, p_offset);
END;
$$;

-- A class: the class itself, its attribute assignments, its attachments,
-- and the classes directly below it and its items being added, moved in or
-- out, deleted, restored or purged.
CREATE FUNCTION class_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page(format($q$
           (h.table_name = 'class'           AND h.data ->> 'id'    = %1$s)
        OR (h.table_name = 'class_attribute' AND h.data ->> 'class' = %1$s)
        OR (h.table_name = 'class_attachment' AND h.data ->> 'class' = %1$s)
        OR (h.table_name = 'class'           AND (h.data ->> 'parent' = %1$s
                                                  OR h.changes -> 'parent' ->> 'old' = %1$s)
                                             AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted']))
        OR (h.table_name = 'item'            AND (h.data ->> 'class' = %1$s
                                                  OR h.changes -> 'class' ->> 'old' = %1$s)
                                             AND (h.operation <> 'update' OR h.changes ?| ARRAY['class', 'deleted']))
    $q$, quote_literal(p_id)), p_limit, p_offset);
END;
$$;

-- The top level of the locations: the top-level locations being added,
-- moved to or from the top, deleted, restored or purged (so a deleted one
-- can be found from here, as from a location for what is inside it).
CREATE FUNCTION location_list_history(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page($q$
        h.table_name = 'location'
        AND (h.data ->> 'parent' IS NULL
             OR (h.changes ? 'parent' AND h.changes -> 'parent' ->> 'old' IS NULL))
        AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted'])
    $q$, p_limit, p_offset);
END;
$$;

-- The top level of the classes, as for the locations.
CREATE FUNCTION class_list_history(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page($q$
        h.table_name = 'class'
        AND (h.data ->> 'parent' IS NULL
             OR (h.changes ? 'parent' AND h.changes -> 'parent' ->> 'old' IS NULL))
        AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted'])
    $q$, p_limit, p_offset);
END;
$$;

-- An attribute: the attribute itself and its options.
CREATE FUNCTION attribute_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page(format($q$
           (h.table_name = 'attribute'        AND h.data ->> 'id'        = %1$s)
        OR (h.table_name = 'attribute_option' AND h.data ->> 'attribute' = %1$s)
    $q$, quote_literal(p_id)), p_limit, p_offset);
END;
$$;

-- The attributes: attributes being added, deleted, restored or purged.
CREATE FUNCTION attribute_list_history(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page($q$
        h.table_name = 'attribute' AND (h.operation <> 'update' OR h.changes ? 'deleted')
    $q$, p_limit, p_offset);
END;
$$;

-- An account: changes to the account itself (not what it did).
CREATE FUNCTION account_history(p_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('history', 'read');
    RETURN util.history_page(format($q$
        h.table_name = 'account' AND h.data ->> 'id' = %s
    $q$, quote_literal(p_id)), p_limit, p_offset);
END;
$$;
