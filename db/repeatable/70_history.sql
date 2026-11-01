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

    -- The ids the entry is about: these columns of the old and the new row.
    SELECT array_agg(DISTINCT x.id) INTO v_about
    FROM (
        SELECT (r ->> k)::uuid AS id
        FROM unnest(ARRAY[v_old, v_new]) AS r,
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
             END) AS k
        WHERE r IS NOT NULL
    ) x
    WHERE x.id IS NOT NULL;

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
