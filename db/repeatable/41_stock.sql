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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A stock row as the API shows it, from its row, its photo's JSON and what
-- its deleted says (NULL for a live row). Its amount is in the base unit of
-- its item's unit. location is the id: clients look it up in the location
-- tree they keep. merged_into, for a row a move merged into another, is the
-- row it went into.
CREATE FUNCTION stock.json(p_stock public.stock, p_photo jsonb, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',          p_stock.id,
        'code',        util.code_text(p_stock.code),
        'item',        p_stock.item,
        'location',    p_stock.location,
        'amount',      p_stock.amount,
        'photo',       p_photo,
        'deleted',     p_deleted,
        'merged_into', p_stock.merged_into
    );
$$;

-- Sets stock row p_stock's values from {"<attribute id>": <value>, ...}, in
-- one statement, as item.values_set does for an item.
CREATE FUNCTION stock.values_set(p_tenant uuid, p_stock uuid, p_values jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_values(p_tenant, p_values);
    INSERT INTO public.stock_value (stock, attribute, text, number, date, boolean, option)
    SELECT p_stock, a.id, v.text, v.number, v.date, v.boolean, v.option
    FROM jsonb_each(p_values) e
    JOIN public.attribute a ON a.id = e.key::uuid
    CROSS JOIN LATERAL attribute.parse_value(a, e.value) v
    WHERE jsonb_typeof(e.value) <> 'null'
    ON CONFLICT (stock, attribute) DO UPDATE SET
        text = EXCLUDED.text, number = EXCLUDED.number, date = EXCLUDED.date,
        boolean = EXCLUDED.boolean, option = EXCLUDED.option;
END;
$$;

-- A stock row as stock.get shows it: its item, its amount and how it is
-- shown, its values (its own, and the class defaults it shows where it has
-- none), the required values it lacks, its photo and attachments, and for a
-- row a move merged into another, that row's id and code. One walk up the
-- item's class tree for the values, one for what is missing. Shared by the
-- functions that return a stock row after changing it. (PL/pgSQL, as it
-- uses item.json, which is made after this script.)
CREATE FUNCTION stock.detail_json(p_tenant uuid, p_stock public.stock, p_deleted jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH effective AS (
            SELECT e.*, a AS attribute_row
            FROM public.item i
            CROSS JOIN LATERAL class.effective_attributes(ARRAY[i.class]) e
            JOIN public.attribute a ON a.id = e.attribute
            WHERE i.id = p_stock.item AND e.scope = 'stock'
        ),
        shown AS (
            SELECT e.attribute_row AS a, sv IS NULL AS is_default,
                   coalesce(sv.text, e.default_text) AS text, coalesce(sv.number, e.default_number) AS number,
                   coalesce(sv.date, e.default_date) AS date, coalesce(sv.boolean, e.default_boolean) AS boolean,
                   coalesce(sv.option, e.default_option) AS option
            FROM effective e
            LEFT JOIN public.stock_value sv ON sv.stock = p_stock.id AND sv.attribute = e.attribute
            WHERE sv IS NOT NULL OR num_nonnulls(e.default_text, e.default_number, e.default_date,
                                                 e.default_boolean, e.default_option) = 1
        )
        SELECT stock.json(p_stock, attachment.json(ph, NULL), p_deleted) || jsonb_build_object(
            'item',        item.json(i, attachment.json(iph, NULL), NULL),
            'display',     CASE WHEN d.unit IS NOT NULL
                                THEN jsonb_build_object('value', d.value, 'unit', d.unit) END,
            'merged_into', CASE WHEN m.id IS NOT NULL
                                THEN jsonb_build_object('id', m.id, 'code', util.code_text(m.code)) END,
            'values',      coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                           'attribute',  attribute.json(x.a, NULL),
                           'value',      util.typed_value_json((x.a).datatype, x.text, x.number, x.date, x.boolean, o),
                           'display',    CASE WHEN vd.unit IS NOT NULL
                                              THEN jsonb_build_object('value', vd.value, 'unit', vd.unit) END,
                           'is_default', x.is_default)
                       ORDER BY (x.a).name COLLATE public.natural, (x.a).id)
                FROM shown x
                LEFT JOIN public.attribute_option o ON o.id = x.option
                LEFT JOIN LATERAL unit.display(p_tenant, x.number, (x.a).unit, (x.a).unit_lock) vd ON true), '[]'),
            'missing',     coalesce((
                SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name)
                                 ORDER BY a.name COLLATE public.natural, a.id)
                FROM stock.missing_attributes(ARRAY[p_stock.id]) mi
                JOIN public.attribute a ON a.id = mi.attribute), '[]'),
            'attachments', attachment.list_json(p_stock.photo, (
                SELECT array_agg(a ORDER BY a.title COLLATE public.natural, a.id)
                FROM public.attachment a
                WHERE a.stock = p_stock.id AND a.deleted IS NULL)))
        FROM public.item i
        LEFT JOIN public.attachment ph  ON ph.id = p_stock.photo
        LEFT JOIN public.attachment iph ON iph.id = i.photo
        LEFT JOIN public.stock m        ON m.id = p_stock.merged_into
        LEFT JOIN LATERAL unit.display(p_tenant, p_stock.amount, i.unit, i.unit_lock) d ON true
        WHERE i.id = p_stock.item
    );
END;
$$;

-- Whether stock rows p_a and p_b have exactly the same values: the same
-- attributes, with the same value each.
CREATE FUNCTION stock.values_equal(p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM (SELECT * FROM public.stock_value WHERE stock = p_a) a
        FULL JOIN (SELECT * FROM public.stock_value WHERE stock = p_b) b ON b.attribute = a.attribute
        WHERE a.attribute IS NULL OR b.attribute IS NULL
           OR (a.text, a.number, a.date, a.boolean, a.option)
              IS DISTINCT FROM (b.text, b.number, b.date, b.boolean, b.option)
    );
$$;

-- Copies stock row p_from's live attachments to stock row p_to (the same
-- files: an attachment's content is found by its hash), and makes the copy
-- of p_photo, p_from's photo, p_to's photo. The copies' ids are made first,
-- so that the photo can refer to its copy.
CREATE FUNCTION stock.copy_attachments(p_from uuid, p_photo uuid, p_to uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.copied;
    CREATE TEMPORARY TABLE pg_temp.copied ON COMMIT DROP AS
    SELECT a.id AS old, uuidv7() AS new
    FROM public.attachment a WHERE a.stock = p_from AND a.deleted IS NULL;
    INSERT INTO public.attachment (id, stock, media_type, hash, size, title)
    SELECT c.new, p_to, a.media_type, a.hash, a.size, a.title
    FROM pg_temp.copied c JOIN public.attachment a ON a.id = c.old;
    UPDATE public.stock s SET photo = (SELECT c.new FROM pg_temp.copied c WHERE c.old = p_photo)
    WHERE s.id = p_to AND p_photo IS NOT NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- A page of the tenant's live stock rows, by item name, each with its item,
-- its amount and how it is shown, and its photo; with the number that
-- match. Optional: p_item, only that item's rows; p_location, only the rows
-- in that location or the locations below it.
CREATE FUNCTION stock.list(
    p_request  public.request,
    p_item     uuid    DEFAULT NULL,
    p_location uuid    DEFAULT NULL,
    p_limit    integer DEFAULT 100,
    p_offset   integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    PERFORM util.check_paging(p_limit, p_offset);
    IF p_item IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.item i JOIN public.class c ON c.id = i.class
        WHERE i.id = p_item AND c.tenant = v_session.tenant
    ) THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF p_location IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.location l WHERE l.id = p_location AND l.tenant = v_session.tenant
    ) THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;

    RETURN (
        WITH RECURSIVE subtree (id) AS (
            SELECT p_location WHERE p_location IS NOT NULL
            UNION
            SELECT l.id FROM public.location l JOIN subtree s ON l.parent = s.id
        ),
        matching AS (
            SELECT s AS row, i AS item
            FROM public.stock s
            JOIN public.location l ON l.id = s.location
            JOIN public.item i     ON i.id = s.item
            WHERE l.tenant = v_session.tenant AND s.deleted IS NULL
              AND (p_item IS NULL OR s.item = p_item)
              AND (p_location IS NULL OR s.location IN (SELECT id FROM subtree))
        ),
        page AS (
            SELECT m.*, row_number() OVER (ORDER BY (m.item).name COLLATE public.natural, (m.row).id) AS position
            FROM matching m
            ORDER BY (m.item).name COLLATE public.natural, (m.row).id
            LIMIT p_limit OFFSET p_offset
        )
        SELECT jsonb_build_object(
            'total',  (SELECT count(*) FROM matching),
            'limit',  p_limit,
            'offset', p_offset,
            'rows',   coalesce((
                SELECT jsonb_agg(stock.json(p.row, attachment.json(ph, NULL), NULL)
                                 || jsonb_build_object(
                                        'item',    item.json(p.item, attachment.json(iph, NULL), NULL),
                                        'display', CASE WHEN d.unit IS NOT NULL
                                                        THEN jsonb_build_object('value', d.value, 'unit', d.unit) END)
                                 ORDER BY p.position)
                FROM page p
                LEFT JOIN public.attachment ph  ON ph.id = (p.row).photo
                LEFT JOIN public.attachment iph ON iph.id = (p.item).photo
                LEFT JOIN LATERAL unit.display(v_session.tenant, (p.row).amount,
                                               (p.item).unit, (p.item).unit_lock) d ON true), '[]'))
    );
END;
$$;

-- One of the tenant's stock rows, as stock.detail_json shows it. A deleted
-- row is returned too, saying when and by whom it was deleted.
CREATE FUNCTION stock.get(p_request public.request, p_stock uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT stock.detail_json(v_session.tenant, s, util.deleted_json(d, db)) INTO v_result
    FROM public.stock s
    JOIN public.location l      ON l.id = s.location
    LEFT JOIN public.action d   ON d.id = s.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE s.id = p_stock AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates a stock row of one of the tenant's items in one of its locations,
-- with a code for its label. p_amount is in the base unit of the item's
-- unit (counted if it has none), and NULL means present but not counted.
-- p_values sets the values that are on each stock row, {"<attribute id>":
-- <value>, ...} ({} for none); required ones without a default must be
-- given, by the end of the transaction. Returns the row as stock.get does.
CREATE FUNCTION stock.create(
    p_request  public.request,
    p_item     uuid,
    p_location uuid,
    p_amount   numeric,
    p_values   jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.item i JOIN public.class c ON c.id = i.class
                   WHERE i.id = p_item AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('item', p_item);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.location l
                   WHERE l.id = p_location AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', p_location);
    END IF;

    PERFORM util.begin_action(v_session);
    INSERT INTO public.stock (code, item, location, amount)
    VALUES (tenant.take_codes(v_session.tenant, 1), p_item, p_location, p_amount)
    RETURNING * INTO v_stock;
    PERFORM stock.values_set(v_session.tenant, v_stock.id, p_values);
    RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
END;
$$;

-- Corrects the fields of one of the tenant's live stock rows that p_patch
-- has: item, location, amount (null: not counted), and photo (the id of one
-- of its own image attachments, or null). To move things, use stock.move,
-- which keeps the history of a move as a move; this is for corrections. The
-- rules refuse an item whose class doesn't take the row's values, and a
-- location that is a container. Returns the row as stock.get does.
CREATE FUNCTION stock.patch(p_request public.request, p_stock uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
    v_item    uuid;
    v_place   uuid;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['item', 'location', 'amount', 'photo'],
                             ARRAY['item', 'location']);
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant AND s.deleted IS NULL
    FOR UPDATE OF s;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;

    v_item  := coalesce((p_patch ->> 'item')::uuid, v_stock.item);
    v_place := coalesce((p_patch ->> 'location')::uuid, v_stock.location);
    IF v_item <> v_stock.item AND NOT EXISTS (
        SELECT 1 FROM public.item i JOIN public.class c ON c.id = i.class
        WHERE i.id = v_item AND c.tenant = v_session.tenant
    ) THEN
        PERFORM error.bad_reference('item', v_item);
    END IF;
    IF v_place <> v_stock.location AND NOT EXISTS (
        SELECT 1 FROM public.location l WHERE l.id = v_place AND l.tenant = v_session.tenant
    ) THEN
        PERFORM error.bad_reference('location', v_place);
    END IF;
    IF p_patch ? 'amount' AND jsonb_typeof(p_patch -> 'amount') NOT IN ('number', 'null') THEN
        PERFORM error.invalid('amount must be a number, or null for not counted');
    END IF;
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') NOT IN ('string', 'null') THEN
        PERFORM error.invalid('photo must be the id of an attachment, or null');
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.stock s
    SET item     = v_item,
        location = v_place,
        amount   = CASE WHEN p_patch ? 'amount' THEN (p_patch ->> 'amount')::numeric ELSE s.amount END,
        photo    = CASE WHEN p_patch ? 'photo' THEN (p_patch ->> 'photo')::uuid ELSE s.photo END
    WHERE s.id = p_stock
    RETURNING * INTO v_stock;
    RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
END;
$$;

-- Moves one of the tenant's live stock rows, or part of it, to another of
-- its locations. p_amount NULL moves the whole row; otherwise it is the
-- amount to move (in the base unit of the item's unit), and the row must be
-- counted.
--
-- If the destination holds exactly one live counted row of the same item,
-- with exactly the same values, and the moved row has no attachments, the
-- moved amount is added to that row: a whole row is then marked deleted, by
-- this call's action, with merged_into that row. Otherwise a whole row
-- changes location, and a part is split off into a new row at the
-- destination, with a code of its own, copies of the values and of the
-- live attachments (the same files), and the copy of the photo as its
-- photo. Returns the row at the destination, as stock.get does.
CREATE FUNCTION stock.move(p_request public.request, p_stock uuid, p_location uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
    v_amount  numeric;
    v_whole   boolean;
    v_target  public.stock;
    v_action  uuid;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant
    FOR UPDATE OF s;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    IF v_stock.deleted IS NOT NULL THEN
        PERFORM error.deleted('stock', p_stock);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.location l
                   WHERE l.id = p_location AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', p_location);
    END IF;
    IF p_amount IS NOT NULL THEN
        IF v_stock.amount IS NULL THEN
            PERFORM error.invalid('A stock row that isn''t counted can only be moved as a whole');
        END IF;
        IF p_amount <= 0 OR p_amount > v_stock.amount THEN
            PERFORM error.invalid(format('The amount to move must be more than 0 and at most %s',
                                         v_stock.amount));
        END IF;
    END IF;
    v_amount := coalesce(p_amount, v_stock.amount);
    v_whole  := p_amount IS NULL OR p_amount = v_stock.amount;

    v_action := util.begin_action(v_session);

    -- The row to merge into: the destination's one live counted row of this
    -- item, if it has the same values and the moved row no attachments.
    -- Locked, so that two moves into it add up.
    IF v_amount IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.attachment a
                       WHERE a.stock = p_stock AND a.deleted IS NULL) THEN
        SELECT t.* INTO v_target
        FROM public.stock t
        WHERE t.item = v_stock.item AND t.location = p_location
          AND t.amount IS NOT NULL AND t.deleted IS NULL AND t.id <> p_stock
        FOR UPDATE;
        IF NOT FOUND OR (SELECT count(*) FROM public.stock t
                         WHERE t.item = v_stock.item AND t.location = p_location
                           AND t.amount IS NOT NULL AND t.deleted IS NULL AND t.id <> p_stock) <> 1
           OR NOT stock.values_equal(p_stock, v_target.id) THEN
            v_target := NULL;
        END IF;
    END IF;

    IF v_target.id IS NOT NULL THEN
        UPDATE public.stock t SET amount = t.amount + v_amount
        WHERE t.id = v_target.id RETURNING * INTO v_target;
        IF v_whole THEN
            UPDATE public.stock s SET deleted = v_action, merged_into = v_target.id WHERE s.id = p_stock;
        ELSE
            UPDATE public.stock s SET amount = s.amount - v_amount WHERE s.id = p_stock;
        END IF;
        RETURN stock.detail_json(v_session.tenant, v_target, NULL);
    END IF;

    IF v_whole THEN
        UPDATE public.stock s SET location = p_location WHERE s.id = p_stock RETURNING * INTO v_stock;
        RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
    END IF;

    -- A part, split off into a new row.
    UPDATE public.stock s SET amount = s.amount - v_amount WHERE s.id = p_stock;
    INSERT INTO public.stock (code, item, location, amount)
    VALUES (tenant.take_codes(v_session.tenant, 1), v_stock.item, p_location, v_amount)
    RETURNING * INTO v_target;
    INSERT INTO public.stock_value (stock, attribute, text, number, date, boolean, option)
    SELECT v_target.id, v.attribute, v.text, v.number, v.date, v.boolean, v.option
    FROM public.stock_value v WHERE v.stock = p_stock;
    PERFORM stock.copy_attachments(p_stock, v_stock.photo, v_target.id);
    SELECT t.* INTO v_target FROM public.stock t WHERE t.id = v_target.id;
    RETURN stock.detail_json(v_session.tenant, v_target, NULL);
END;
$$;

-- Deletes one of the tenant's stock rows: it is marked deleted, by this
-- call's action, with its values and attachments as they are.
CREATE FUNCTION stock.delete(p_request public.request, p_stock uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.stock s
    SET deleted = v_action
    FROM public.location l
    WHERE s.id = p_stock AND l.id = s.location AND l.tenant = v_session.tenant
      AND s.deleted IS NULL;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
END;
$$;

-- Restores a deleted stock row of the tenant. A row a move merged into
-- another can't be restored (409): its amount is in that row now. A row
-- whose item is deleted can't either: restoring the item brings back the
-- rows deleted with it. p_options, each optional:
--   location      a location to restore it in instead
--   with_parents  true: also restore its deleted location, and the deleted
--                 locations above that, from the top down (for admins)
-- A row at a deleted location can't be restored without location or
-- with_parents (409, naming both ways out). Returns the row as stock.get
-- does.
CREATE FUNCTION stock.restore(p_request public.request, p_stock uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'user');
    v_stock    public.stock;
    v_location uuid;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['location', 'with_parents'],
                             ARRAY['location', 'with_parents']);
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant
    FOR UPDATE OF s;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    IF v_stock.deleted IS NULL THEN
        PERFORM error.not_deleted('stock', p_stock);
    END IF;
    IF v_stock.merged_into IS NOT NULL THEN
        PERFORM error.wrong_state(format(
            'This stock row was merged into stock row %s, and can''t be restored; '
            'move part of that row to split it off again',
            (SELECT util.code_text(m.code) FROM public.stock m WHERE m.id = v_stock.merged_into)));
    END IF;
    IF (SELECT i.deleted FROM public.item i WHERE i.id = v_stock.item) IS NOT NULL THEN
        PERFORM error.wrong_state(format(
            '%s belongs to %s, which is deleted; restoring the item also restores the stock rows deleted with it',
            error.row_label('stock', p_stock), error.row_label('item', v_stock.item)));
    END IF;

    v_location := coalesce((p_options ->> 'location')::uuid, v_stock.location);
    IF NOT EXISTS (SELECT 1 FROM public.location l
                   WHERE l.id = v_location AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', v_location);
    END IF;

    PERFORM util.begin_action(v_session);
    IF (SELECT l.deleted FROM public.location l WHERE l.id = v_location) IS NOT NULL THEN
        IF p_options ? 'location' THEN
            PERFORM error.deleted('location', v_location);
        ELSIF NOT coalesce((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM error.restore_into_deleted(error.row_label('stock', p_stock),
                format('"%s"', util.path_text(location.path_json(v_location))), 'location');
        ELSIF v_session.role < 'admin' THEN
            PERFORM error.forbidden('Restoring the locations it is in needs the role admin');
        END IF;
        PERFORM location.restore_parents(v_location);
    END IF;

    UPDATE public.stock s SET deleted = NULL, location = v_location
    WHERE s.id = p_stock
    RETURNING * INTO v_stock;
    RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
END;
$$;

-- Sets one value of one of the tenant's live stock rows: inserts it, or
-- replaces the one there. Numbers of an attribute with a unit are in the
-- base unit; a JSON null is refused (remove a value with value delete). The
-- rules refuse a value that doesn't fit, or whose attribute doesn't apply to
-- the class of the row's item with its values on each stock row. Returns
-- the row as stock.get does.
CREATE FUNCTION stock.value_set(p_request public.request, p_stock uuid, p_attribute uuid, p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant AND s.deleted IS NULL;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        PERFORM error.invalid('Remove a value with value delete');
    END IF;

    PERFORM util.begin_action(v_session);
    PERFORM stock.values_set(v_session.tenant, p_stock, jsonb_build_object(p_attribute::text, p_value));
    RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
END;
$$;

-- Removes one value of one of the tenant's live stock rows. A required
-- value without a default can't be removed (checked at the end of the
-- transaction). Returns the row as stock.get does, which then shows the
-- class default, if there is one.
CREATE FUNCTION stock.value_delete(p_request public.request, p_stock uuid, p_attribute uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant AND s.deleted IS NULL;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;

    PERFORM util.begin_action(v_session);
    DELETE FROM public.stock_value v WHERE v.stock = p_stock AND v.attribute = p_attribute;
    IF NOT FOUND THEN
        PERFORM error.not_found('value', format('of attribute %s on %s',
                                                p_attribute, error.row_label('stock', p_stock)));
    END IF;
    RETURN stock.detail_json(v_session.tenant, v_stock, NULL);
END;
$$;
