-- Items and their values (schema item): their rules, and the functions the
-- API calls for them.

CREATE SCHEMA item;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- For each of the items p_items: the required attributes it has no value
-- for. Required means: assigned as required by the item's class (or a class
-- above it), with its values on the item, and without a default value.
-- One walk up the class tree for all the items' classes.
CREATE FUNCTION item.missing_attributes(p_items uuid[])
RETURNS TABLE (item uuid, attribute uuid)
LANGUAGE sql STABLE AS $$
    SELECT i.id, e.attribute
    FROM public.item i
    JOIN class.effective_attributes(
             ARRAY(SELECT DISTINCT x.class FROM public.item x WHERE x.id = ANY (p_items))
         ) e ON e.class = i.class
    WHERE i.id = ANY (p_items)
      AND e.scope = 'item'
      AND e.required
      AND num_nonnulls(e.default_text, e.default_number, e.default_date,
                       e.default_boolean, e.default_option) = 0
      AND NOT EXISTS (
          SELECT 1 FROM public.item_value v
          WHERE v.item = i.id AND v.attribute = e.attribute
      );
$$;

-- An item's class must not be a container. A container class holds only
-- other classes, never items.
--
-- The class row is locked for sharing until commit. Without the lock,
-- putting an item in a class and, at the same time, making that class a
-- container could both pass: each would check before the other committed.
-- With it, whichever comes second waits for the first and then sees what
-- it did. (The foreign key's own lock doesn't block a change of the
-- container column.) The other half of this is class.check_container.
CREATE FUNCTION item.check_container()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_class record;
BEGIN
    SELECT c.name, c.container INTO v_class
    FROM public.class c
    WHERE c.id = NEW.class
    FOR SHARE;
    IF v_class.container THEN
        RAISE EXCEPTION 'Class "%" is a container: it holds only other classes, not items',
            v_class.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_container
    BEFORE INSERT ON public.item
    FOR EACH ROW EXECUTE FUNCTION item.check_container();

CREATE TRIGGER check_container_change
    BEFORE UPDATE OF class, deleted ON public.item
    FOR EACH ROW
    WHEN (OLD.class <> NEW.class
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION item.check_container();

-- An item value's attribute must apply to the item's class, with its values
-- on the item: the nearest assignment of the attribute, on the item's class
-- or a class above it, must have the scope 'item'. An attribute that isn't
-- assigned at all, or whose values are on each stock row (scope 'stock'),
-- can't have an item value.
CREATE FUNCTION item.check_value_applies()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item record;
BEGIN
    SELECT i.name, i.class INTO v_item
    FROM public.item i
    WHERE i.id = NEW.item;
    IF class.attribute_scope(v_item.class, NEW.attribute) IS DISTINCT FROM 'item' THEN
        RAISE EXCEPTION 'The class of item "%" has no attribute "%" with its values on the item',
            v_item.name, (SELECT a.name FROM public.attribute a WHERE a.id = NEW.attribute)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_value_applies
    BEFORE INSERT ON public.item_value
    FOR EACH ROW EXECUTE FUNCTION item.check_value_applies();

CREATE TRIGGER check_value_applies_change
    BEFORE UPDATE OF item, attribute ON public.item_value
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item OR OLD.attribute <> NEW.attribute)
    EXECUTE FUNCTION item.check_value_applies();

-- When an item changes class, or is restored, all its values must still
-- apply: each item value's attribute must apply to the class with its
-- values on the item, and each value on its live stock rows must apply
-- with its values on each stock row. The class's attributes are worked out
-- once, and all the values are checked against them in one query.
--
-- On restore this closes a gap: while an item is deleted, its class can
-- lose an assignment (class.check_values_still_apply only checks live
-- items), and the restored item would otherwise bring back a value that no
-- longer applies. Its stock rows, restored after it, are checked by
-- stock.check_values_still_apply.
CREATE FUNCTION item.check_values_still_apply()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_wrong uuid[];
BEGIN
    WITH applies AS (
        SELECT e.attribute, e.scope
        FROM class.effective_attributes(ARRAY[NEW.class]) e
    )
    SELECT array_agg(DISTINCT w.attribute) INTO v_wrong
    FROM (
        SELECT v.attribute
        FROM public.item_value v
        LEFT JOIN applies a ON a.attribute = v.attribute
        WHERE v.item = NEW.id
          AND a.scope IS DISTINCT FROM 'item'
        UNION ALL
        SELECT sv.attribute
        FROM public.stock s
        JOIN public.stock_value sv ON sv.stock = s.id
        LEFT JOIN applies a ON a.attribute = sv.attribute
        WHERE s.item = NEW.id
          AND s.deleted IS NULL
          AND a.scope IS DISTINCT FROM 'stock'
    ) w;
    IF v_wrong IS NOT NULL THEN
        RAISE EXCEPTION 'Item "%" has values that don''t apply in class "%": %',
            NEW.name,
            (SELECT c.name FROM public.class c WHERE c.id = NEW.class),
            error.attribute_names(v_wrong)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_values_still_apply
    BEFORE UPDATE OF class, deleted ON public.item
    FOR EACH ROW
    WHEN (OLD.class <> NEW.class
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION item.check_values_still_apply();

-- A new or restored item, or one moved to another class, must have a value
-- for each attribute that is required for it: assigned as required to its
-- class (or a class above it), with its values on the item, and without a
-- default value (item.missing_attributes says which). When it moved to
-- another class, its live stock rows must have the values the new class
-- requires of each stock row too.
--
-- It runs at commit, so an item can be created first and its values added
-- afterwards, in the same transaction. By then the item may have been
-- deleted again, or purged; it is then left alone.
--
-- Making an attribute required later never blocks anything: items that
-- already exist without a value are reported as missing it, through the
-- API.
CREATE FUNCTION item.check_required()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_name    text;
    v_missing uuid[];
BEGIN
    SELECT i.name INTO v_name
    FROM public.item i
    WHERE i.id = NEW.id AND i.deleted IS NULL;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_missing := ARRAY(SELECT m.attribute
                       FROM item.missing_attributes(ARRAY[NEW.id]) m);
    IF cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION 'Item "%" is missing required attributes: %',
            v_name, error.attribute_names(v_missing)
            USING ERRCODE = 'check_violation';
    END IF;

    -- New and restored stock rows are checked by stock.check_required, so
    -- this is only needed when the item changed class: all its live stock
    -- rows, in one call.
    IF TG_OP = 'UPDATE' AND OLD.class <> NEW.class THEN
        v_missing := ARRAY(
            SELECT DISTINCT m.attribute
            FROM stock.missing_attributes(ARRAY(
                     SELECT s.id FROM public.stock s
                     WHERE s.item = NEW.id AND s.deleted IS NULL)) m);
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'Stock rows of item "%" are missing required attributes: %',
                v_name, error.attribute_names(v_missing)
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_required
    AFTER INSERT ON public.item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION item.check_required();

CREATE CONSTRAINT TRIGGER check_required_change
    AFTER UPDATE OF class, deleted ON public.item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.class <> NEW.class
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION item.check_required();

-- A required item value can't be removed from a live item: one whose
-- attribute is assigned as required to the item's class (or a class above
-- it), with its values on the item, and without a default value.
--
-- It runs at commit, so a value can be removed and set again in the same
-- transaction. An item that has been deleted or purged by then is left
-- alone, and is looked up first, so that purging an item, which removes
-- its values with it, costs one look-up per value.
CREATE FUNCTION item.check_required_value_removal()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item text;
BEGIN
    SELECT i.name INTO v_item
    FROM public.item i
    WHERE i.id = OLD.item AND i.deleted IS NULL;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF EXISTS (SELECT 1 FROM item.missing_attributes(ARRAY[OLD.item]) m
               WHERE m.attribute = OLD.attribute) THEN
        RAISE EXCEPTION 'The value for "%" on item "%" is required, so it can''t be removed',
            (SELECT a.name FROM public.attribute a WHERE a.id = OLD.attribute), v_item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_required_value_removal
    AFTER DELETE ON public.item_value
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION item.check_required_value_removal();

-- A live item's class must be live: an item can't be created in, moved
-- into or restored into a deleted class.
--
-- When an item is restored, its values come back with it, so they must
-- refer to live attributes and options too: while the item was deleted,
-- an attribute or option it uses may have been deleted as well (their
-- deletable rules only count values on live items). The attributes and
-- options are locked for sharing first, so that they can't be deleted
-- while this transaction restores the item.
CREATE FUNCTION item.check_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted uuid[];
BEGIN
    PERFORM util.check_live('class', NEW.class);

    IF TG_OP = 'UPDATE' AND OLD.deleted IS NOT NULL THEN
        PERFORM 1 FROM public.attribute a
        WHERE a.id IN (SELECT v.attribute FROM public.item_value v WHERE v.item = NEW.id)
        FOR SHARE;
        PERFORM 1 FROM public.attribute_option o
        WHERE o.id IN (SELECT v.option FROM public.item_value v WHERE v.item = NEW.id)
        FOR SHARE;

        SELECT array_agg(v.attribute) INTO v_deleted
        FROM public.item_value v
        JOIN public.attribute a             ON a.id = v.attribute
        LEFT JOIN public.attribute_option o ON o.id = v.option
        WHERE v.item = NEW.id
          AND (a.deleted IS NOT NULL OR o.deleted IS NOT NULL);
        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'Item "%" can''t be restored: its values for % refer to deleted attributes or options',
                NEW.name, error.attribute_names(v_deleted)
                USING ERRCODE = 'object_not_in_prerequisite_state',
                      HINT = 'Restore those attributes or options first.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_live
    BEFORE INSERT ON public.item
    FOR EACH ROW EXECUTE FUNCTION item.check_live();

CREATE TRIGGER check_live_change
    BEFORE UPDATE OF class, deleted ON public.item
    FOR EACH ROW
    WHEN (OLD.class <> NEW.class
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION item.check_live();

-- An item value's item, attribute and option must be live. A value has no
-- deleted of its own: it belongs to its item, and comes back with it
-- (item.check_live checks it then).
CREATE FUNCTION item.check_value_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('item', NEW.item);
    PERFORM util.check_live('attribute', NEW.attribute);
    PERFORM util.check_live('attribute_option', NEW.option);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_value_live
    BEFORE INSERT ON public.item_value
    FOR EACH ROW EXECUTE FUNCTION item.check_value_live();

CREATE TRIGGER check_value_live_change
    BEFORE UPDATE OF item, attribute, option ON public.item_value
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item
          OR OLD.attribute <> NEW.attribute
          OR OLD.option IS DISTINCT FROM NEW.option)
    EXECUTE FUNCTION item.check_value_live();

-- An item can only be deleted while it has no live stock rows. Its values
-- and attachments stay as they are, and come back with it.
CREATE FUNCTION item.check_deletable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.stock s
               WHERE s.item = NEW.id AND s.deleted IS NULL) THEN
        RAISE EXCEPTION 'Item "%" still has stock', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_deletable
    BEFORE UPDATE OF deleted ON public.item
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION item.check_deletable();
