-- History (schema history): the rule that records every change to a
-- tenant's data, and the helpers the history pages share. See
-- api/history.md.

CREATE SCHEMA history;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- Records every change to a tenant's data in history: the row after the
-- change (before it, for a delete), which columns changed and how, and the
-- action the change was part of, which says who made it, for which tenant,
-- and when.
--
-- The action is the one named in the setting wtf.action, which
-- util.begin_action sets, and it must have been made in this transaction:
-- the API's database role can set the setting itself, but can't make an
-- action, so it can't hand over another tenant's. A change without one is
-- refused with a plain error, which means a bug in our code. For the
-- tables that have a tenant of their own, it must be the action's.
--
-- The entry records what it is about: the row's own id and those of the
-- rows it belongs to, old and new, read from the row itself (no look-ups),
-- so that an object's history page finds its entries by one index.
--
-- Password hashes are never recorded (only whether there is one, and that
-- it changed), and an update that changes nothing recorded, such as one
-- that only touches the login lockout counters, makes no entry at all.
CREATE FUNCTION history.record()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old              jsonb;
    v_new              jsonb;
    v_changes          jsonb;
    v_password_changed boolean := false;
    v_action           uuid := nullif(current_setting('wtf.action', true), '')::uuid;
    v_tenant           uuid;
    v_about            uuid[];
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'account' THEN
        v_password_changed := TG_OP = 'UPDATE'
            AND (v_old ->> 'password_hash') IS DISTINCT FROM (v_new ->> 'password_hash');
        v_old := v_old - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_old ->> 'password_hash') IS NOT NULL);
        v_new := v_new - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_new ->> 'password_hash') IS NOT NULL);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value))
        INTO v_changes
        FROM jsonb_each(v_new) AS n
        WHERE (v_old -> n.key) IS DISTINCT FROM n.value;
        IF v_password_changed THEN
            v_changes := coalesce(v_changes, '{}'::jsonb) || jsonb_build_object('password', 'changed');
        END IF;
        IF v_changes IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT a.tenant INTO v_tenant
    FROM public.action a
    WHERE a.id = v_action
      AND a.transaction = pg_current_xact_id();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A change to % without an action of this transaction (util.begin_action)', TG_TABLE_NAME;
    END IF;
    IF coalesce(v_new, v_old) ? 'tenant'
       AND (coalesce(v_new, v_old) ->> 'tenant')::uuid <> v_tenant THEN
        RAISE EXCEPTION 'A change to % of another tenant than the action''s', TG_TABLE_NAME;
    END IF;

    -- The ids the entry is about: these columns of the new and the old row,
    -- each id once, in this order, so that about[1] is the row's own id for
    -- the tables that have one (the history pages rely on it).
    SELECT array_agg(x.id ORDER BY x.first) INTO v_about
    FROM (
        SELECT y.id, min(y.position) AS first
        FROM (
            SELECT (r.value ->> k.name)::uuid AS id, k.n * 2 + r.n AS position
            FROM unnest(ARRAY[v_new, v_old]) WITH ORDINALITY AS r (value, n),
                 unnest(CASE TG_TABLE_NAME
                 WHEN 'item'             THEN ARRAY['id', 'class']
                 WHEN 'item_value'       THEN ARRAY['item']
                 WHEN 'stock'            THEN ARRAY['id', 'item', 'location']
                 WHEN 'stock_value'      THEN ARRAY['stock']
                 WHEN 'class'            THEN ARRAY['id', 'parent']
                 WHEN 'location'         THEN ARRAY['id', 'parent']
                 WHEN 'class_attribute'  THEN ARRAY['class', 'attribute']
                 WHEN 'attribute'        THEN ARRAY['id']
                 WHEN 'attribute_option' THEN ARRAY['id', 'attribute']
                 WHEN 'attachment'       THEN ARRAY['id', 'item', 'stock', 'location', 'class']
                 WHEN 'account'          THEN ARRAY['id']
             END) WITH ORDINALITY AS k (name, n)
            WHERE r.value IS NOT NULL
        ) y
        WHERE y.id IS NOT NULL
        GROUP BY y.id
    ) x;

    INSERT INTO public.history (tenant, action, table_name, operation, about, data, changes)
    VALUES (v_tenant,
            v_action,
            TG_TABLE_NAME,
            lower(TG_OP)::public.history_operation,
            v_about,
            coalesce(v_new, v_old) - 'tenant',
            v_changes - 'tenant');
    RETURN NULL;
END;
$$;

-- One trigger per table, written out.
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.class
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.attribute
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.attribute_option
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.class_attribute
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.item
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.item_value
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.location
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.stock
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.stock_value
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.account
    FOR EACH ROW EXECUTE FUNCTION history.record();
CREATE TRIGGER record_history AFTER INSERT OR UPDATE OR DELETE ON public.attachment
    FOR EACH ROW EXECUTE FUNCTION history.record();

-- ---------------------------------------------------------------------------
-- The history pages
-- ---------------------------------------------------------------------------
-- Each page is in the schema of what it is about (item.history,
-- class.list_history, …), and they are all here, as they share how a page
-- is built. A page goes back in time by position: p_before is the id of the
-- oldest entry the client has (NULL: from the newest), and the page is the
-- p_limit entries older than that, with more saying whether there are older
-- ones still. An object's entries are found by what they are about (one
-- index), and also for an object that has been deleted or purged, as
-- history outlives it.

-- A page of history entries: p_ids, newest first, at most p_limit + 1 of
-- them, the one beyond p_limit only saying that there are more. Each entry
-- with its action: when, and who (null for wtfd itself).
CREATE FUNCTION history.page(p_ids bigint[], p_limit integer)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'more', cardinality(p_ids) > p_limit,
        'rows', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',        h.id,
                       'action',    jsonb_build_object(
                                        'id',      x.id,
                                        'at',      x.at,
                                        'account', CASE WHEN a.id IS NOT NULL THEN jsonb_build_object(
                                                       'id', a.id, 'email', a.email,
                                                       'deleted', a.deleted IS NOT NULL) END),
                       'table',     h.table_name,
                       'operation', h.operation,
                       'data',      h.data,
                       'changes',   h.changes)
                   ORDER BY h.id DESC)
            FROM public.history h
            JOIN public.action x       ON x.id = h.action
            LEFT JOIN public.account a ON a.id = x.account
            WHERE h.id = ANY (p_ids[1:p_limit])), '[]'));
$$;

-- A page of an item's history, newest first: the item itself, its values,
-- its stock rows (also those moved to or from it, deleted or purged) with
-- their values, and the attachments of the item and of those rows.
CREATE FUNCTION item.history(
    p_request public.request,
    p_item    uuid,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_stock   uuid[];
BEGIN
    PERFORM util.check_limit(p_limit);
    -- The item's stock rows, ever: from the stock entries about the item
    -- (about[1] is a row's own id).
    v_stock := ARRAY(SELECT DISTINCT h.about[1]
                     FROM public.history h
                     WHERE h.about @> ARRAY[p_item] AND h.tenant = v_session.tenant
                       AND h.table_name = 'stock');

    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND (h.about @> ARRAY[p_item]
                     OR (h.table_name IN ('stock_value', 'attachment') AND h.about && v_stock))
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of a stock row's history: the row itself (moves included), its
-- values and its attachments.
CREATE FUNCTION stock.history(
    p_request public.request,
    p_stock   uuid,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND h.about @> ARRAY[p_stock]
                AND h.table_name IN ('stock', 'stock_value', 'attachment')
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of a location's history: the location itself, the stock rows that
-- were there (including those that arrived or left), its attachments, and
-- the locations directly inside it being added, moved in or out, deleted,
-- restored or purged (so a deleted one can be found from here). For admins.
CREATE FUNCTION location.history(
    p_request  public.request,
    p_location uuid,
    p_before   bigint  DEFAULT NULL,
    p_limit    integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND h.about @> ARRAY[p_location]
                AND h.table_name IN ('location', 'stock', 'attachment')
                -- A location inside it only when it came, went or was
                -- deleted or restored, not for its own other changes.
                AND NOT (h.table_name = 'location' AND h.about[1] <> p_location
                         AND h.operation = 'update'
                         AND NOT h.changes ?| ARRAY['parent', 'deleted'])
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of a class's history: the class itself, its assignments, its
-- attachments, and the classes directly below it and its items being
-- added, moved in or out, deleted, restored or purged. For admins.
CREATE FUNCTION class.history(
    p_request public.request,
    p_class   uuid,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND h.about @> ARRAY[p_class]
                AND h.table_name IN ('class', 'class_attribute', 'attachment', 'item')
                AND NOT (h.table_name = 'class' AND h.about[1] <> p_class
                         AND h.operation = 'update'
                         AND NOT h.changes ?| ARRAY['parent', 'deleted'])
                AND NOT (h.table_name = 'item'
                         AND h.operation = 'update'
                         AND NOT h.changes ?| ARRAY['class', 'deleted'])
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of the top level of the locations: the top-level locations being
-- added, moved to or from the top, deleted, restored or purged (so a
-- deleted one can be found from here, as from a location for what is
-- inside it). For admins.
CREATE FUNCTION location.list_history(
    p_request public.request,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND h.table_name = 'location'
                AND (p_before IS NULL OR h.id < p_before)
                AND (h.data ->> 'parent' IS NULL
                     OR (h.changes ? 'parent' AND h.changes -> 'parent' ->> 'old' IS NULL))
                AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted'])
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of the top level of the classes, as for the locations. For admins.
CREATE FUNCTION class.list_history(
    p_request public.request,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND h.table_name = 'class'
                AND (p_before IS NULL OR h.id < p_before)
                AND (h.data ->> 'parent' IS NULL
                     OR (h.changes ? 'parent' AND h.changes -> 'parent' ->> 'old' IS NULL))
                AND (h.operation <> 'update' OR h.changes ?| ARRAY['parent', 'deleted'])
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of an attribute's history: the attribute itself and its options.
-- For admins.
CREATE FUNCTION attribute.history(
    p_request   public.request,
    p_attribute uuid,
    p_before    bigint  DEFAULT NULL,
    p_limit     integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND h.about @> ARRAY[p_attribute]
                AND h.table_name IN ('attribute', 'attribute_option')
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of the attributes' history: attributes being added, deleted,
-- restored or purged. For admins.
CREATE FUNCTION attribute.list_history(
    p_request public.request,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND h.table_name = 'attribute'
                AND (p_before IS NULL OR h.id < p_before)
                AND (h.operation <> 'update' OR h.changes ? 'deleted')
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;

-- A page of an account's history: changes to the account itself, not what
-- it did. For admins.
CREATE FUNCTION account.history(
    p_request public.request,
    p_account uuid,
    p_before  bigint  DEFAULT NULL,
    p_limit   integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    PERFORM util.check_limit(p_limit);
    RETURN history.page(
        ARRAY(SELECT h.id
              FROM public.history h
              WHERE h.tenant = v_session.tenant
                AND (p_before IS NULL OR h.id < p_before)
                AND h.about @> ARRAY[p_account]
                AND h.table_name = 'account'
              ORDER BY h.id DESC
              LIMIT p_limit + 1),
        p_limit);
END;
$$;
