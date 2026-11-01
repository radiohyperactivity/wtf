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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- An item as the API shows it, from its row, its photo's JSON and what its
-- deleted says (NULL for a live item). Its unit is the unit's id, which
-- clients look up in the unit families they keep.
CREATE FUNCTION item.json(p_item public.item, p_photo jsonb, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_item.id,
        'code',      util.code_text(p_item.code),
        'name',      p_item.name,
        'class',     p_item.class,
        'unit',      p_item.unit,
        'unit_lock', p_item.unit_lock,
        'photo',     p_photo,
        'deleted',   p_deleted
    );
$$;

-- The attribute filters of item.list, p_where, checked once and returned as
-- typed rows: a list of {attribute, op, value}, each attribute one of
-- tenant p_tenant's live ones. What each datatype takes:
--   integer, decimal, date: op =, >, >=, <, <=, with one value, or between
--                           with [low, high]; numbers in the base unit,
--                           dates as YYYY-MM-DD
--   text, url:              op = (letter case ignored) or contains
--   choice:                 op = with one option, or in with a list of
--                           them, each by id or name (deleted options too,
--                           as values may still refer to them)
--   boolean:                op = with true or false
-- A number or date filter's value is in low (and high, for between).
CREATE FUNCTION item.parse_filters(p_tenant uuid, p_where jsonb)
RETURNS TABLE (
    attribute   uuid,
    datatype    public.datatype,
    op          text,
    low_number  numeric,
    high_number numeric,
    low_date    date,
    high_date   date,
    text        text,
    "boolean"   boolean,
    options     uuid[]
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_filter    jsonb;
    v_attribute public.attribute;
    v_op        text;
    v_value     jsonb;
    v_element   jsonb;
    v_option    uuid;
    v_values    jsonb;
BEGIN
    IF p_where IS NULL OR jsonb_typeof(p_where) = 'null' THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_where) <> 'array' THEN
        PERFORM error.invalid('where must be a list of filters {attribute, op, value}');
    END IF;

    FOR v_filter IN SELECT f FROM jsonb_array_elements(p_where) f LOOP
        IF jsonb_typeof(v_filter) IS DISTINCT FROM 'object' THEN
            PERFORM error.invalid('Each filter must be an object {attribute, op, value}');
        END IF;
        IF (v_filter ->> 'attribute') IS NULL
           OR (v_filter ->> 'attribute') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            PERFORM error.invalid('A filter needs the id of an attribute');
        END IF;
        SELECT a.* INTO v_attribute FROM public.attribute a
        WHERE a.id = (v_filter ->> 'attribute')::uuid AND a.tenant = p_tenant AND a.deleted IS NULL;
        IF NOT FOUND THEN
            PERFORM error.not_found('attribute', v_filter ->> 'attribute');
        END IF;
        v_op    := v_filter ->> 'op';
        v_value := v_filter -> 'value';
        IF v_value IS NULL OR jsonb_typeof(v_value) = 'null' THEN
            PERFORM error.invalid(format('The filter on %s needs a value', v_attribute.name));
        END IF;

        attribute := v_attribute.id;
        datatype  := v_attribute.datatype;
        low_number := NULL; high_number := NULL; low_date := NULL; high_date := NULL;
        text := NULL; "boolean" := NULL; options := NULL;

        CASE
        WHEN v_attribute.datatype IN ('integer', 'decimal', 'date') THEN
            IF v_op = 'between' THEN
                IF jsonb_typeof(v_value) <> 'array' OR jsonb_array_length(v_value) <> 2 THEN
                    PERFORM error.invalid(format('between on %s needs [low, high]', v_attribute.name));
                END IF;
                v_values := v_value;
            ELSIF v_op IS NULL OR v_op NOT IN ('=', '>', '>=', '<', '<=') THEN
                PERFORM error.invalid(format('%s can be compared with =, >, >=, <, <= or between', v_attribute.name));
            ELSE
                v_values := jsonb_build_array(v_value);
            END IF;
            FOR v_element IN SELECT e FROM jsonb_array_elements(v_values) e LOOP
                IF v_attribute.datatype = 'date' THEN
                    IF jsonb_typeof(v_element) <> 'string'
                       OR (v_element #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$'
                       OR NOT pg_input_is_valid(v_element #>> '{}', 'date') THEN
                        PERFORM error.invalid(format('%s takes dates as YYYY-MM-DD', v_attribute.name));
                    END IF;
                ELSIF jsonb_typeof(v_element) <> 'number' THEN
                    PERFORM error.invalid(format('%s takes numbers, in the base unit', v_attribute.name));
                END IF;
            END LOOP;
            IF v_attribute.datatype = 'date' THEN
                low_date  := (v_values ->> 0)::date;
                high_date := (v_values ->> 1)::date;
            ELSE
                low_number  := (v_values ->> 0)::numeric;
                high_number := (v_values ->> 1)::numeric;
            END IF;

        WHEN v_attribute.datatype IN ('text', 'url') THEN
            IF v_op IS NULL OR v_op NOT IN ('=', 'contains') THEN
                PERFORM error.invalid(format('%s can be compared with = or contains', v_attribute.name));
            END IF;
            IF jsonb_typeof(v_value) <> 'string' THEN
                PERFORM error.invalid(format('%s takes text', v_attribute.name));
            END IF;
            text := lower(v_value #>> '{}');

        WHEN v_attribute.datatype = 'choice' THEN
            IF v_op = '=' THEN
                v_values := jsonb_build_array(v_value);
            ELSIF v_op IS DISTINCT FROM 'in' OR jsonb_typeof(v_value) <> 'array' THEN
                PERFORM error.invalid(format('%s can be compared with = (one option) or in (a list of them)',
                                             v_attribute.name));
            ELSE
                v_values := v_value;
            END IF;
            options := ARRAY[]::uuid[];
            FOR v_element IN SELECT e FROM jsonb_array_elements(v_values) e LOOP
                SELECT o.id INTO v_option
                FROM public.attribute_option o
                WHERE o.attribute = v_attribute.id
                  AND (o.id::text = lower(v_element #>> '{}') OR lower(o.name) = lower(v_element #>> '{}'))
                ORDER BY o.deleted IS NOT NULL, o.id
                LIMIT 1;
                IF NOT FOUND THEN
                    PERFORM error.invalid(format('%s has no option %s', v_attribute.name, v_element));
                END IF;
                options := options || v_option;
            END LOOP;
            v_op := 'in';

        WHEN v_attribute.datatype = 'boolean' THEN
            IF v_op IS DISTINCT FROM '=' OR jsonb_typeof(v_value) <> 'boolean' THEN
                PERFORM error.invalid(format('%s can be compared with = true or = false', v_attribute.name));
            END IF;
            "boolean" := v_value::boolean;
        END CASE;

        op := v_op;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- Whether a value an item shows (its text, number, date, boolean and
-- option) satisfies one filter of item.parse_filters (its datatype, op and
-- typed operands). Plain SQL that queries nothing, so it is inlined.
CREATE FUNCTION item.filter_matches(
    p_datatype    public.datatype,
    p_op          text,
    p_low_number  numeric,
    p_high_number numeric,
    p_low_date    date,
    p_high_date   date,
    p_text        text,
    p_boolean     boolean,
    p_options     uuid[],
    v_text        text,
    v_number      numeric,
    v_date        date,
    v_boolean     boolean,
    v_option      uuid
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_datatype
        WHEN 'date' THEN CASE p_op
            WHEN '='       THEN v_date =  p_low_date
            WHEN '>'       THEN v_date >  p_low_date
            WHEN '>='      THEN v_date >= p_low_date
            WHEN '<'       THEN v_date <  p_low_date
            WHEN '<='      THEN v_date <= p_low_date
            WHEN 'between' THEN v_date BETWEEN p_low_date AND p_high_date
            END
        WHEN 'text' THEN CASE p_op
            WHEN '='        THEN lower(v_text) = p_text
            WHEN 'contains' THEN strpos(lower(v_text), p_text) > 0
            END
        WHEN 'url' THEN CASE p_op
            WHEN '='        THEN lower(v_text) = p_text
            WHEN 'contains' THEN strpos(lower(v_text), p_text) > 0
            END
        WHEN 'choice'  THEN v_option = ANY (p_options)
        WHEN 'boolean' THEN v_boolean = p_boolean
        ELSE CASE p_op -- integer and decimal
            WHEN '='       THEN v_number =  p_low_number
            WHEN '>'       THEN v_number >  p_low_number
            WHEN '>='      THEN v_number >= p_low_number
            WHEN '<'       THEN v_number <  p_low_number
            WHEN '<='      THEN v_number <= p_low_number
            WHEN 'between' THEN v_number BETWEEN p_low_number AND p_high_number
            END
        END;
$$;

-- Sets item p_item's values from {"<attribute id>": <value>, ...}, in one
-- statement: each attribute must be one of tenant p_tenant's (422
-- otherwise); JSON null entries are left out. A value already there is
-- replaced. The rules check each value as it is written.
CREATE FUNCTION item.values_set(p_tenant uuid, p_item uuid, p_values jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_values(p_tenant, p_values);
    INSERT INTO public.item_value (item, attribute, text, number, date, boolean, option)
    SELECT p_item, a.id, v.text, v.number, v.date, v.boolean, v.option
    FROM jsonb_each(p_values) e
    JOIN public.attribute a ON a.id = e.key::uuid
    CROSS JOIN LATERAL attribute.parse_value(a, e.value) v
    WHERE jsonb_typeof(e.value) <> 'null'
    ON CONFLICT (item, attribute) DO UPDATE SET
        text = EXCLUDED.text, number = EXCLUDED.number, date = EXCLUDED.date,
        boolean = EXCLUDED.boolean, option = EXCLUDED.option;
END;
$$;

-- An item as item.get shows it: its class (with its path), its values (its
-- own, and the class defaults it shows where it has none), the required
-- values it lacks, its photo and attachments, and its stock rows, each with
-- its values, what it lacks, its photo and attachments. A live item lists
-- its live stock rows; a deleted one the rows deleted together with it,
-- which restoring it brings back. One walk up the class tree for the
-- attributes, shared by the item's values and every stock row's.
CREATE FUNCTION item.detail_json(p_tenant uuid, p_item public.item, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH effective AS (
        SELECT e.*, a AS attribute_row
        FROM class.effective_attributes(ARRAY[p_item.class]) e
        JOIN public.attribute a ON a.id = e.attribute
    ),
    rows AS (
        SELECT s.* FROM public.stock s
        WHERE s.item = p_item.id
          AND (CASE WHEN p_item.deleted IS NULL THEN s.deleted IS NULL
                    ELSE s.deleted = p_item.deleted AND s.merged_into IS NULL END)
    ),
    -- Every value shown, of the item (stock NULL) and of each stock row:
    -- its own, or the default where it has none.
    shown AS (
        SELECT NULL::uuid AS stock, e.attribute_row AS a, v.item IS NULL AS is_default,
               coalesce(v.text, e.default_text) AS text, coalesce(v.number, e.default_number) AS number,
               coalesce(v.date, e.default_date) AS date, coalesce(v.boolean, e.default_boolean) AS boolean,
               coalesce(v.option, e.default_option) AS option
        FROM effective e
        LEFT JOIN public.item_value v ON v.item = p_item.id AND v.attribute = e.attribute
        WHERE e.scope = 'item'
          AND (v.item IS NOT NULL OR num_nonnulls(e.default_text, e.default_number, e.default_date,
                                             e.default_boolean, e.default_option) = 1)
        UNION ALL
        SELECT r.id, e.attribute_row, sv.stock IS NULL,
               coalesce(sv.text, e.default_text), coalesce(sv.number, e.default_number),
               coalesce(sv.date, e.default_date), coalesce(sv.boolean, e.default_boolean),
               coalesce(sv.option, e.default_option)
        FROM rows r
        JOIN effective e ON e.scope = 'stock'
        LEFT JOIN public.stock_value sv ON sv.stock = r.id AND sv.attribute = e.attribute
        WHERE sv.stock IS NOT NULL OR num_nonnulls(e.default_text, e.default_number, e.default_date,
                                             e.default_boolean, e.default_option) = 1
    ),
    values_json AS (
        SELECT x.stock,
               jsonb_agg(jsonb_build_object(
                   'attribute',  attribute.json(x.a, NULL),
                   'value',      util.typed_value_json((x.a).datatype, x.text, x.number, x.date, x.boolean, o),
                   'display',    CASE WHEN d.unit IS NOT NULL
                                      THEN jsonb_build_object('value', d.value, 'unit', d.unit) END,
                   'is_default', x.is_default)
                   ORDER BY (x.a).name COLLATE public.natural, (x.a).id) AS list
        FROM shown x
        LEFT JOIN public.attribute_option o ON o.id = x.option
        LEFT JOIN LATERAL unit.display(p_tenant, x.number, (x.a).unit, (x.a).unit_lock) d ON true
        GROUP BY x.stock
    ),
    missing AS (
        SELECT NULL::uuid AS stock, m.attribute FROM item.missing_attributes(ARRAY[p_item.id]) m
        UNION ALL
        SELECT m.stock, m.attribute FROM stock.missing_attributes(ARRAY(SELECT id FROM rows)) m
    ),
    missing_json AS (
        SELECT m.stock, jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name)
                                  ORDER BY a.name COLLATE public.natural, a.id) AS list
        FROM missing m JOIN public.attribute a ON a.id = m.attribute
        GROUP BY m.stock
    ),
    attachments AS (
        SELECT a.stock, array_agg(a ORDER BY a.title COLLATE public.natural, a.id) AS list
        FROM public.attachment a
        WHERE (a.item = p_item.id OR a.stock IN (SELECT id FROM rows)) AND a.deleted IS NULL
        GROUP BY a.stock
    )
    SELECT item.json(p_item, attachment.json(ph, NULL), p_deleted) || jsonb_build_object(
        'class',       class.json(c, NULL, NULL) || jsonb_build_object('path', class.path_json(c.id)),
        'values',      coalesce((SELECT list FROM values_json WHERE stock IS NULL), '[]'),
        'missing',     coalesce((SELECT list FROM missing_json WHERE stock IS NULL), '[]'),
        'attachments', attachment.list_json(p_item.photo,
                           (SELECT list FROM attachments WHERE stock IS NULL)),
        'stock', coalesce((
            SELECT jsonb_agg(stock.json(r::public.stock, attachment.json(rp, NULL),
                                        CASE WHEN r.deleted IS NOT NULL THEN p_deleted END)
                             || jsonb_build_object(
                                    'display',     CASE WHEN d.unit IS NOT NULL
                                                        THEN jsonb_build_object('value', d.value, 'unit', d.unit) END,
                                    'values',      coalesce(v.list, '[]'),
                                    'missing',     coalesce(m.list, '[]'),
                                    'attachments', attachment.list_json(r.photo, at.list))
                             ORDER BY l.name COLLATE public.natural, r.id)
            FROM rows r
            JOIN public.location l          ON l.id = r.location
            LEFT JOIN public.attachment rp  ON rp.id = r.photo
            LEFT JOIN values_json v         ON v.stock = r.id
            LEFT JOIN missing_json m        ON m.stock = r.id
            LEFT JOIN attachments at        ON at.stock = r.id
            LEFT JOIN LATERAL unit.display(p_tenant, r.amount, p_item.unit, p_item.unit_lock) d ON true),
            '[]'))
    FROM public.class c
    LEFT JOIN public.attachment ph ON ph.id = p_item.photo
    WHERE c.id = p_item.class;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- A page of the tenant's live items, by name, each with its stock total (in
-- the unit that suits it), whether it lacks a required value, and its
-- photo; with the number of items that match. Optional:
--   p_class   only items in this class or the classes below it
--   p_search  words; each must occur (letter case ignored) in the item's
--             name, a class in its class path, or a text, url or choice
--             value it shows (its own, or the class default), on the item
--             or on a live stock row; the words may match in different places
--   p_where   attribute filters, all of which must match (item.parse_filters
--             says which ops each datatype takes); an attribute with values
--             on each stock row matches when any live stock row does
-- The page is built in one query: the candidates' classes are worked out
-- once, what they show is joined for only the attributes needed, and the
-- stock totals and what is missing are worked out for the page at once.
CREATE FUNCTION item.list(
    p_request public.request,
    p_class   uuid    DEFAULT NULL,
    p_search  text    DEFAULT NULL,
    p_where   jsonb   DEFAULT NULL,
    p_limit   integer DEFAULT 100,
    p_offset  integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session   record := util.session(p_request, 'viewer');
    v_words     text[] := ARRAY(SELECT DISTINCT w
                                FROM regexp_split_to_table(lower(btrim(coalesce(p_search, ''))), '\s+') w
                                WHERE w <> '');
    v_filtering boolean;
BEGIN
    PERFORM util.check_paging(p_limit, p_offset);
    IF p_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.class c
                                           WHERE c.id = p_class AND c.tenant = v_session.tenant) THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    -- The filters, checked once and kept as typed rows. Dropped first, so
    -- that a second call in one transaction works.
    DROP TABLE IF EXISTS pg_temp.filter;
    CREATE TEMPORARY TABLE pg_temp.filter ON COMMIT DROP AS
    SELECT * FROM item.parse_filters(v_session.tenant, p_where);
    v_filtering := EXISTS (SELECT 1 FROM pg_temp.filter);

    RETURN (
        WITH RECURSIVE subtree (id) AS (
            SELECT p_class WHERE p_class IS NOT NULL
            UNION
            SELECT c.id FROM public.class c JOIN subtree s ON c.parent = s.id
        ),
        candidates AS (
            SELECT i.id, i.class, i.name FROM public.item i
            JOIN public.class c ON c.id = i.class
            WHERE c.tenant = v_session.tenant AND i.deleted IS NULL
              AND (p_class IS NULL OR i.class IN (SELECT id FROM subtree))
        ),
        -- What the candidates show, for the attributes the filters and the
        -- search need, only when there are filters or words.
        effective AS (
            SELECT e.* FROM class.effective_attributes(
                       ARRAY(SELECT DISTINCT x.class FROM candidates x)) e
            JOIN public.attribute a ON a.id = e.attribute
            WHERE (v_filtering AND e.attribute IN (SELECT f.attribute FROM pg_temp.filter f))
               OR (cardinality(v_words) > 0 AND a.datatype IN ('text', 'url', 'choice'))
        ),
        shown AS (
            SELECT c.id AS item, e.attribute,
                   coalesce(v.text, e.default_text) AS text, coalesce(v.number, e.default_number) AS number,
                   coalesce(v.date, e.default_date) AS date, coalesce(v.boolean, e.default_boolean) AS boolean,
                   coalesce(v.option, e.default_option) AS option
            FROM candidates c
            JOIN effective e ON e.class = c.class AND e.scope = 'item'
            LEFT JOIN public.item_value v ON v.item = c.id AND v.attribute = e.attribute
            UNION ALL
            SELECT c.id, e.attribute,
                   coalesce(sv.text, e.default_text), coalesce(sv.number, e.default_number),
                   coalesce(sv.date, e.default_date), coalesce(sv.boolean, e.default_boolean),
                   coalesce(sv.option, e.default_option)
            FROM candidates c
            JOIN effective e ON e.class = c.class AND e.scope = 'stock'
            JOIN public.stock s ON s.item = c.id AND s.deleted IS NULL
            LEFT JOIN public.stock_value sv ON sv.stock = s.id AND sv.attribute = e.attribute
        ),
        -- Each candidate class's path names, once per class.
        path_names (class, ancestor, name) AS (
            SELECT c.id, c.id, lower(c.name) FROM public.class c
            WHERE cardinality(v_words) > 0 AND c.id IN (SELECT DISTINCT x.class FROM candidates x)
            UNION ALL
            SELECT p.class, c.parent, lower(a.name)
            FROM path_names p
            JOIN public.class c ON c.id = p.ancestor
            JOIN public.class a ON a.id = c.parent
        ),
        matching AS (
            SELECT i.id, i.name FROM candidates i
            WHERE NOT EXISTS (
                      SELECT 1 FROM pg_temp.filter f
                      WHERE NOT EXISTS (SELECT 1 FROM shown s
                                        WHERE s.item = i.id AND s.attribute = f.attribute
                                          AND item.filter_matches(f.datatype, f.op, f.low_number, f.high_number,
                                                                  f.low_date, f.high_date, f.text, f."boolean",
                                                                  f.options, s.text, s.number, s.date,
                                                                  s.boolean, s.option)))
              AND NOT EXISTS (
                      SELECT 1 FROM unnest(v_words) w
                      WHERE strpos(lower(i.name), w) = 0
                        AND NOT EXISTS (SELECT 1 FROM path_names p
                                        WHERE p.class = i.class AND strpos(p.name, w) > 0)
                        AND NOT EXISTS (SELECT 1 FROM shown s
                                        LEFT JOIN public.attribute_option o ON o.id = s.option
                                        WHERE s.item = i.id
                                          AND (strpos(lower(s.text), w) > 0
                                               OR strpos(lower(o.name), w) > 0)))
        ),
        page AS (
            SELECT m.id, row_number() OVER (ORDER BY m.name COLLATE public.natural, m.id) AS position
            FROM matching m
            ORDER BY m.name COLLATE public.natural, m.id
            LIMIT p_limit OFFSET p_offset
        ),
        -- What each row shows.
        totals AS (
            SELECT s.item, sum(s.amount) AS total, bool_or(s.amount IS NULL) AS uncounted
            FROM public.stock s
            WHERE s.item IN (SELECT id FROM page) AND s.deleted IS NULL
            GROUP BY s.item
        ),
        incomplete AS (
            SELECT m.item FROM item.missing_attributes(ARRAY(SELECT id FROM page)) m
            UNION
            SELECT s.item
            FROM stock.missing_attributes(ARRAY(SELECT s.id FROM public.stock s
                                                WHERE s.item IN (SELECT id FROM page)
                                                  AND s.deleted IS NULL)) m
            JOIN public.stock s ON s.id = m.stock
        )
        SELECT jsonb_build_object(
            'total',  (SELECT count(*) FROM matching),
            'limit',  p_limit,
            'offset', p_offset,
            'rows',   coalesce((
                SELECT jsonb_agg(item.json(i, attachment.json(ph, NULL), NULL) || jsonb_build_object(
                           'stock', jsonb_build_object(
                                        'total',     coalesce(t.total, 0),
                                        'display',   CASE WHEN d.unit IS NOT NULL THEN
                                                         jsonb_build_object('value', d.value, 'unit', d.unit) END,
                                        'uncounted', coalesce(t.uncounted, false)),
                           'incomplete', p.id IN (SELECT x.item FROM incomplete x))
                       ORDER BY p.position)
                FROM page p
                JOIN public.item i ON i.id = p.id
                LEFT JOIN public.attachment ph ON ph.id = i.photo
                LEFT JOIN totals t ON t.item = p.id
                LEFT JOIN LATERAL unit.display(v_session.tenant, coalesce(t.total, 0),
                                               i.unit, i.unit_lock) d ON true), '[]'))
    );
END;
$$;

-- One of the tenant's items, as item.detail_json shows it. A deleted item
-- is returned too, saying when and by whom it was deleted.
CREATE FUNCTION item.get(p_request public.request, p_item uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT item.detail_json(v_session.tenant, i, util.deleted_json(d, db)) INTO v_result
    FROM public.item i
    JOIN public.class c         ON c.id = i.class
    LEFT JOIN public.action d   ON d.id = i.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE i.id = p_item AND c.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates an item in one of the tenant's classes, with values for its
-- attributes, p_values: {"<attribute id>": <value>, ...} ({} for none; an
-- attribute given as JSON null gets no value). Numbers of an attribute with
-- a unit are in the base unit. Only attributes with their values on the
-- item; values on each stock row go on the stock rows. Class defaults are
-- never stored on the item: it shows them where it has no value of its
-- own. Required values without a default must be given, by the end of the
-- transaction. p_unit is what its stock is measured in (NULL: counted), and
-- must be available; with p_unit_lock its stock is always shown in that
-- unit. Returns the item as item.get does.
CREATE FUNCTION item.create(
    p_request   public.request,
    p_class     uuid,
    p_name      text,
    p_unit      uuid,
    p_unit_lock boolean,
    p_values    jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_name    text := util.trim_and_check(p_name);
    v_item    public.item;
BEGIN
    IF p_unit_lock IS NULL THEN
        PERFORM error.invalid('Say whether the item''s unit is locked');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.class c WHERE c.id = p_class AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('class', p_class);
    END IF;
    PERFORM unit.check_choosable(v_session.tenant, p_unit);

    PERFORM util.begin_action(v_session);
    INSERT INTO public.item (code, class, name, unit, unit_lock)
    VALUES (tenant.take_codes(v_session.tenant, 1), p_class, v_name, p_unit, p_unit_lock)
    RETURNING * INTO v_item;
    PERFORM item.values_set(v_session.tenant, v_item.id, p_values);
    RETURN item.detail_json(v_session.tenant, v_item, NULL);
END;
$$;

-- Changes the fields of one of the tenant's live items that p_patch has:
-- class, name, unit, unit_lock, and photo (the id of one of its own image
-- attachments, or null). The rules refuse a class whose attributes don't
-- fit the item's values (naming them), a class that is a container, and a
-- unit of another quantity; a unit can't be added or removed, and a new one
-- must be available. Nothing is converted: numbers are stored in the base
-- unit. Returns the item as item.get does.
CREATE FUNCTION item.patch(p_request public.request, p_item uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_item    public.item;
    v_class   uuid;
    v_unit    uuid;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['class', 'name', 'unit', 'unit_lock', 'photo'],
                             ARRAY['class', 'name', 'unit_lock']);
    SELECT i.* INTO v_item
    FROM public.item i
    JOIN public.class c ON c.id = i.class
    WHERE i.id = p_item AND c.tenant = v_session.tenant
    FOR UPDATE OF i;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF v_item.deleted IS NOT NULL THEN
        PERFORM error.deleted('item', p_item);
    END IF;

    v_class := coalesce((p_patch ->> 'class')::uuid, v_item.class);
    IF v_class <> v_item.class AND NOT EXISTS (
        SELECT 1 FROM public.class c WHERE c.id = v_class AND c.tenant = v_session.tenant
    ) THEN
        PERFORM error.bad_reference('class', v_class);
    END IF;
    v_unit := CASE WHEN p_patch ? 'unit' THEN (p_patch ->> 'unit')::uuid ELSE v_item.unit END;
    IF v_unit IS DISTINCT FROM v_item.unit THEN
        PERFORM unit.check_choosable(v_session.tenant, v_unit);
    END IF;
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') NOT IN ('string', 'null') THEN
        PERFORM error.invalid('photo must be the id of an attachment, or null');
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.item i
    SET class     = v_class,
        name      = CASE WHEN p_patch ? 'name' THEN util.trim_and_check(p_patch ->> 'name') ELSE i.name END,
        unit      = v_unit,
        unit_lock = coalesce((p_patch ->> 'unit_lock')::boolean, i.unit_lock),
        photo     = CASE WHEN p_patch ? 'photo' THEN (p_patch ->> 'photo')::uuid ELSE i.photo END
    WHERE i.id = p_item
    RETURNING * INTO v_item;
    RETURN item.detail_json(v_session.tenant, v_item, NULL);
END;
$$;

-- Deletes one of the tenant's items: it is marked deleted, by this call's
-- action, with its values and attachments as they are. An item with live
-- stock rows can't be deleted (409; the rule item.check_deletable says so):
-- its stock goes first.
CREATE FUNCTION item.delete(p_request public.request, p_item uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.item i
    SET deleted = v_action
    FROM public.class c
    WHERE i.id = p_item AND c.id = i.class AND c.tenant = v_session.tenant
      AND i.deleted IS NULL;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM public.item i JOIN public.class c ON c.id = i.class
                   WHERE i.id = p_item AND c.tenant = v_session.tenant) THEN
            PERFORM error.deleted('item', p_item);
        END IF;
        PERFORM error.not_found('item', p_item::text);
    END IF;
END;
$$;

-- Restores a deleted item of the tenant, with the stock rows deleted
-- together with it, by the same action (never rows merged into another).
-- p_options, each optional:
--   name          a new name
--   class         a class to restore it in instead
--   with_parents  true: also restore its deleted class, and the deleted
--                 classes above that, from the top down (for admins)
-- An item whose class is deleted can't be restored without class or
-- with_parents (409, naming both ways out). Returns the item as item.get
-- does.
CREATE FUNCTION item.restore(p_request public.request, p_item uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_item    public.item;
    v_action  uuid;              -- the action that deleted the item
    v_class   uuid;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name', 'class', 'with_parents'],
                             ARRAY['name', 'class', 'with_parents']);
    SELECT i.* INTO v_item
    FROM public.item i
    JOIN public.class c ON c.id = i.class
    WHERE i.id = p_item AND c.tenant = v_session.tenant
    FOR UPDATE OF i;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF v_item.deleted IS NULL THEN
        PERFORM error.not_deleted('item', p_item);
    END IF;
    v_action := v_item.deleted;

    v_class := coalesce((p_options ->> 'class')::uuid, v_item.class);
    IF NOT EXISTS (SELECT 1 FROM public.class c WHERE c.id = v_class AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('class', v_class);
    END IF;

    PERFORM util.begin_action(v_session);
    IF (SELECT c.deleted FROM public.class c WHERE c.id = v_class) IS NOT NULL THEN
        IF p_options ? 'class' THEN
            PERFORM error.deleted('class', v_class);
        ELSIF NOT coalesce((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM error.restore_into_deleted(error.row_label('item', p_item),
                format('class "%s"', util.path_text(class.path_json(v_class))), 'class');
        ELSIF v_session.role < 'admin' THEN
            PERFORM error.forbidden('Restoring the classes it is in needs the role admin');
        END IF;
        PERFORM class.restore_parents(v_class);
    END IF;

    UPDATE public.item i
    SET deleted = NULL,
        name    = CASE WHEN p_options ? 'name' THEN util.trim_and_check(p_options ->> 'name') ELSE i.name END,
        class   = v_class
    WHERE i.id = p_item
    RETURNING * INTO v_item;
    UPDATE public.stock s SET deleted = NULL
    WHERE s.item = p_item AND s.deleted = v_action AND s.merged_into IS NULL;
    RETURN item.detail_json(v_session.tenant, v_item, NULL);
END;
$$;

-- Sets one value of one of the tenant's live items: inserts it, or replaces
-- the one there. Numbers of an attribute with a unit are in the base unit;
-- a JSON null is refused (remove a value with value delete). The rules
-- refuse a value that doesn't fit the attribute's datatype, or whose
-- attribute doesn't apply to the item's class with its values on the item.
-- Returns the item as item.get does.
CREATE FUNCTION item.value_set(p_request public.request, p_item uuid, p_attribute uuid, p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_item    public.item;
BEGIN
    SELECT i.* INTO v_item
    FROM public.item i
    JOIN public.class c ON c.id = i.class
    WHERE i.id = p_item AND c.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF v_item.deleted IS NOT NULL THEN
        PERFORM error.deleted('item', p_item);
    END IF;
    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        PERFORM error.invalid('Remove a value with value delete');
    END IF;

    PERFORM util.begin_action(v_session);
    PERFORM item.values_set(v_session.tenant, p_item, jsonb_build_object(p_attribute::text, p_value));
    RETURN item.detail_json(v_session.tenant, v_item, NULL);
END;
$$;

-- Removes one value of one of the tenant's live items. A required value
-- without a default can't be removed (checked at the end of the
-- transaction). Returns the item as item.get does, which then shows the
-- class default, if there is one.
CREATE FUNCTION item.value_delete(p_request public.request, p_item uuid, p_attribute uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_item    public.item;
BEGIN
    SELECT i.* INTO v_item
    FROM public.item i
    JOIN public.class c ON c.id = i.class
    WHERE i.id = p_item AND c.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF v_item.deleted IS NOT NULL THEN
        PERFORM error.deleted('item', p_item);
    END IF;

    PERFORM util.begin_action(v_session);
    DELETE FROM public.item_value v WHERE v.item = p_item AND v.attribute = p_attribute;
    IF NOT FOUND THEN
        PERFORM error.not_found('value', format('of attribute %s on item "%s"', p_attribute, v_item.name));
    END IF;
    RETURN item.detail_json(v_session.tenant, v_item, NULL);
END;
$$;
