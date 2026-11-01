-- Stock rows and their values (schema stock): their rules, and the
-- functions the API calls for them.

CREATE SCHEMA stock;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- For each of the stock rows p_stock: the required attributes it has no
-- value for. Required means: assigned as required by the class of the
-- row's item (or a class above it), with its values on each stock row, and
-- without a default value. One walk up the class tree for all the rows.
CREATE FUNCTION stock.missing_attributes(p_stock uuid[])
RETURNS TABLE (stock uuid, attribute uuid)
LANGUAGE sql STABLE AS $$
    WITH row_class AS (
        SELECT s.id AS stock, i.class
        FROM public.stock s
        JOIN public.item i ON i.id = s.item
        WHERE s.id = ANY (p_stock)
    )
    SELECT r.stock, e.attribute
    FROM row_class r
    JOIN class.effective_attributes(
             ARRAY(SELECT DISTINCT x.class FROM row_class x)
         ) e ON e.class = r.class
    WHERE e.scope = 'stock'
      AND e.required
      AND num_nonnulls(e.default_text, e.default_number, e.default_date,
                       e.default_boolean, e.default_option) = 0
      AND NOT EXISTS (
          SELECT 1 FROM public.stock_value sv
          WHERE sv.stock = r.stock AND sv.attribute = e.attribute
      );
$$;

-- A stock amount must be a whole number when the item is counted (it has no
-- unit), or when its unit measures a quantity whose numbers are whole
-- (datatype integer, such as Count). Other amounts may have decimals: 2.5
-- metres of cable. An item's unit only changes within its quantity, so an
-- amount that was whole stays whole.
CREATE FUNCTION stock.check_whole()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item text;
BEGIN
    SELECT i.name INTO v_item
    FROM public.item i
    LEFT JOIN public.unit u        ON u.id = i.unit
    LEFT JOIN public.unit_family f ON f.id = u.family
    LEFT JOIN public.quantity q    ON q.id = f.quantity
    WHERE i.id = NEW.item
      AND (i.unit IS NULL OR q.datatype = 'integer');
    IF FOUND THEN
        RAISE EXCEPTION 'The amount of "%" must be a whole number', v_item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Only when the amount has decimals at all: a whole amount (or none, NULL)
-- is fine for every item, so the function isn't even called then.
CREATE TRIGGER check_whole
    BEFORE INSERT OR UPDATE OF item, amount ON public.stock
    FOR EACH ROW
    WHEN (NEW.amount <> trunc(NEW.amount))
    EXECUTE FUNCTION stock.check_whole();

-- A stock row's location must not be a container. A container location
-- holds only other locations, never stock. The location row is locked for
-- sharing until commit, for the same reason as in item.check_container; the
-- other half of this is location.check_container.
CREATE FUNCTION stock.check_container()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_location record;
BEGIN
    SELECT l.name, l.container INTO v_location
    FROM public.location l
    WHERE l.id = NEW.location
    FOR SHARE;
    IF v_location.container THEN
        RAISE EXCEPTION 'Location "%" is a container: it holds only other locations, not stock',
            v_location.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_container
    BEFORE INSERT ON public.stock
    FOR EACH ROW EXECUTE FUNCTION stock.check_container();

CREATE TRIGGER check_container_change
    BEFORE UPDATE OF location, deleted ON public.stock
    FOR EACH ROW
    WHEN (OLD.location <> NEW.location
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION stock.check_container();

-- A stock value's attribute must apply to the class of the stock row's
-- item, with its values on each stock row: the nearest assignment of the
-- attribute, on that class or a class above it, must have the scope
-- 'stock'. An attribute that isn't assigned at all, or whose values are on
-- the item (scope 'item'), can't have a stock value.
CREATE FUNCTION stock.check_value_applies()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item record;
BEGIN
    SELECT i.name, i.class INTO v_item
    FROM public.stock s
    JOIN public.item i ON i.id = s.item
    WHERE s.id = NEW.stock;
    IF class.attribute_scope(v_item.class, NEW.attribute) IS DISTINCT FROM 'stock' THEN
        RAISE EXCEPTION 'The class of item "%" has no attribute "%" with its values on each stock row',
            v_item.name, (SELECT a.name FROM public.attribute a WHERE a.id = NEW.attribute)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_value_applies
    BEFORE INSERT ON public.stock_value
    FOR EACH ROW EXECUTE FUNCTION stock.check_value_applies();

CREATE TRIGGER check_value_applies_change
    BEFORE UPDATE OF stock, attribute ON public.stock_value
    FOR EACH ROW
    WHEN (OLD.stock <> NEW.stock OR OLD.attribute <> NEW.attribute)
    EXECUTE FUNCTION stock.check_value_applies();

-- When a stock row moves to another item, or is restored, all its values
-- must still apply: each value's attribute must apply to the class of the
-- row's item, with its values on each stock row. The class's attributes
-- are worked out once, and all the row's values are checked against them
-- in one query.
--
-- On restore this closes the same gap as item.check_values_still_apply:
-- while a stock row is deleted, its item's class can lose an assignment,
-- and the restored row would otherwise bring back a value that no longer
-- applies.
CREATE FUNCTION stock.check_values_still_apply()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item  record;
    v_wrong uuid[];
BEGIN
    SELECT i.name, i.class INTO v_item
    FROM public.item i
    WHERE i.id = NEW.item;

    SELECT array_agg(sv.attribute) INTO v_wrong
    FROM public.stock_value sv
    LEFT JOIN class.effective_attributes(ARRAY[v_item.class]) e
           ON e.attribute = sv.attribute
    WHERE sv.stock = NEW.id
      AND e.scope IS DISTINCT FROM 'stock';
    IF v_wrong IS NOT NULL THEN
        RAISE EXCEPTION 'A stock row of item "%" has values that don''t apply to it: %',
            v_item.name, error.attribute_names(v_wrong)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_values_still_apply
    BEFORE UPDATE OF item, deleted ON public.stock
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION stock.check_values_still_apply();

-- A new or restored stock row, or one moved to another item, must have a
-- value for each attribute that is required for it: assigned as required
-- to the class of the row's item (or a class above it), with its values on
-- each stock row, and without a default value (stock.missing_attributes
-- says which).
--
-- It runs at commit, so a stock row can be created first and its values
-- added afterwards, in the same transaction; a partial move, which creates
-- a stock row and then copies the values to it, relies on this. By then
-- the row may have been deleted again, or purged; it is then left alone.
CREATE FUNCTION stock.check_required()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item    text;
    v_missing uuid[];
BEGIN
    SELECT i.name INTO v_item
    FROM public.stock s
    JOIN public.item i ON i.id = s.item
    WHERE s.id = NEW.id AND s.deleted IS NULL;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_missing := ARRAY(SELECT m.attribute
                       FROM stock.missing_attributes(ARRAY[NEW.id]) m);
    IF cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION 'A stock row of item "%" is missing required attributes: %',
            v_item, error.attribute_names(v_missing)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_required
    AFTER INSERT ON public.stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION stock.check_required();

CREATE CONSTRAINT TRIGGER check_required_change
    AFTER UPDATE OF item, deleted ON public.stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION stock.check_required();

-- A required stock value can't be removed from a live stock row. It runs at
-- commit, so a value can be removed and set again in the same transaction.
-- A stock row that has been deleted or purged by then is left alone, and is
-- looked up first, so that purging a stock row costs one look-up per value.
CREATE FUNCTION stock.check_required_value_removal()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item text;
BEGIN
    SELECT i.name INTO v_item
    FROM public.stock s
    JOIN public.item i ON i.id = s.item
    WHERE s.id = OLD.stock AND s.deleted IS NULL;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF EXISTS (SELECT 1 FROM stock.missing_attributes(ARRAY[OLD.stock]) m
               WHERE m.attribute = OLD.attribute) THEN
        RAISE EXCEPTION 'The value for "%" on a stock row of item "%" is required, so it can''t be removed',
            (SELECT a.name FROM public.attribute a WHERE a.id = OLD.attribute), v_item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_required_value_removal
    AFTER DELETE ON public.stock_value
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION stock.check_required_value_removal();

-- A live stock row's item and location must be live. When a stock row is
-- restored, its values come back with it, so they must refer to live
-- attributes and options too; see item.check_live for why, and for the
-- locks.
CREATE FUNCTION stock.check_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted uuid[];
BEGIN
    PERFORM util.check_live('item', NEW.item);
    PERFORM util.check_live('location', NEW.location);

    IF TG_OP = 'UPDATE' AND OLD.deleted IS NOT NULL THEN
        PERFORM 1 FROM public.attribute a
        WHERE a.id IN (SELECT sv.attribute FROM public.stock_value sv WHERE sv.stock = NEW.id)
        FOR SHARE;
        PERFORM 1 FROM public.attribute_option o
        WHERE o.id IN (SELECT sv.option FROM public.stock_value sv WHERE sv.stock = NEW.id)
        FOR SHARE;

        SELECT array_agg(sv.attribute) INTO v_deleted
        FROM public.stock_value sv
        JOIN public.attribute a             ON a.id = sv.attribute
        LEFT JOIN public.attribute_option o ON o.id = sv.option
        WHERE sv.stock = NEW.id
          AND (a.deleted IS NOT NULL OR o.deleted IS NOT NULL);
        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION '% can''t be restored: its values for % refer to deleted attributes or options',
                error.row_label('stock', NEW.id), error.attribute_names(v_deleted)
                USING ERRCODE = 'object_not_in_prerequisite_state',
                      HINT = 'Restore those attributes or options first.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_live
    BEFORE INSERT ON public.stock
    FOR EACH ROW EXECUTE FUNCTION stock.check_live();

CREATE TRIGGER check_live_change
    BEFORE UPDATE OF item, location, deleted ON public.stock
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item
          OR OLD.location <> NEW.location
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION stock.check_live();

-- A stock value's stock row, attribute and option must be live. A value has
-- no deleted of its own: it belongs to its stock row, and comes back with
-- it (stock.check_live checks it then).
CREATE FUNCTION stock.check_value_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('stock', NEW.stock);
    PERFORM util.check_live('attribute', NEW.attribute);
    PERFORM util.check_live('attribute_option', NEW.option);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_value_live
    BEFORE INSERT ON public.stock_value
    FOR EACH ROW EXECUTE FUNCTION stock.check_value_live();

CREATE TRIGGER check_value_live_change
    BEFORE UPDATE OF stock, attribute, option ON public.stock_value
    FOR EACH ROW
    WHEN (OLD.stock <> NEW.stock
          OR OLD.attribute <> NEW.attribute
          OR OLD.option IS DISTINCT FROM NEW.option)
    EXECUTE FUNCTION stock.check_value_live();
