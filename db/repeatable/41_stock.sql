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
    BEFORE UPDATE OF location ON public.stock
    FOR EACH ROW
    WHEN (OLD.location <> NEW.location)
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

-- When a stock row moves to another item, all its values must still apply:
-- each value's attribute must apply to the class of the row's item, with
-- its values on each stock row. The class's attributes are worked out once,
-- and all the row's values are checked against them in one query.
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
    BEFORE UPDATE OF item ON public.stock
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item)
    EXECUTE FUNCTION stock.check_values_still_apply();

-- A new stock row, or one moved to another item, must have a
-- value for each attribute that is required for it: assigned as required
-- to the class of the row's item (or a class above it), with its values on
-- each stock row, and without a default value (stock.missing_attributes
-- says which).
--
-- It runs at commit, so a stock row can be created first and its values
-- added afterwards, in the same transaction; a partial move, which creates
-- a stock row and then copies the values to it, relies on this. By then
-- the row may have been deleted again; it is then left alone.
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
    WHERE s.id = NEW.id;
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
    AFTER UPDATE OF item ON public.stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.item <> NEW.item)
    EXECUTE FUNCTION stock.check_required();

-- A required stock value can't be removed from a stock row. It runs at
-- commit, so a value can be removed and set again in the same transaction.
-- A stock row that has been deleted by then (its values go with it) is left
-- alone, and is looked up first, so that deleting a stock row costs one
-- look-up per value.
CREATE FUNCTION stock.check_required_value_removal()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item text;
BEGIN
    SELECT i.name INTO v_item
    FROM public.stock s
    JOIN public.item i ON i.id = s.item
    WHERE s.id = OLD.stock;
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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A stock row as the API shows it, from its row and its photo's JSON. Its
-- amount is in the base unit of its item's unit. location is the id:
-- clients look it up in the location tree they keep.
CREATE FUNCTION stock.json(p_stock public.stock, p_photo jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',       p_stock.id,
        'code',     util.code_text(p_stock.code),
        'item',     p_stock.item,
        'location', p_stock.location,
        'amount',   p_stock.amount,
        'photo',    p_photo
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
-- none), the required values it lacks, and its photo and attachments. One
-- walk up the item's class tree for the values, one for what is missing.
-- Shared by the functions that return a stock row after changing it.
-- (PL/pgSQL, as it uses item.json, which is made after this script.)
CREATE FUNCTION stock.detail_json(p_tenant uuid, p_stock public.stock)
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
            SELECT e.attribute_row AS a, sv.stock IS NULL AS is_default,
                   coalesce(sv.text, e.default_text) AS text, coalesce(sv.number, e.default_number) AS number,
                   coalesce(sv.date, e.default_date) AS date, coalesce(sv.boolean, e.default_boolean) AS boolean,
                   coalesce(sv.option, e.default_option) AS option
            FROM effective e
            LEFT JOIN public.stock_value sv ON sv.stock = p_stock.id AND sv.attribute = e.attribute
            WHERE sv.stock IS NOT NULL OR num_nonnulls(e.default_text, e.default_number, e.default_date,
                                                 e.default_boolean, e.default_option) = 1
        )
        SELECT stock.json(p_stock, attachment.json(ph)) || jsonb_build_object(
            'item',        item.json(i, attachment.json(iph)),
            'display',     CASE WHEN d.unit IS NOT NULL
                                THEN jsonb_build_object('value', d.value, 'unit', d.unit) END,
            'values',      coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                           'attribute',  attribute.json(x.a),
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
                WHERE a.stock = p_stock.id)))
        FROM public.item i
        LEFT JOIN public.attachment ph  ON ph.id = p_stock.photo
        LEFT JOIN public.attachment iph ON iph.id = i.photo
        LEFT JOIN LATERAL unit.display(p_tenant, p_stock.amount, i.unit, i.unit_lock) d ON true
        WHERE i.id = p_stock.item
    );
END;
$$;

-- The attributes whose values differ between stock rows p_a and p_b: those
-- one row has and the other hasn't, and those with another value. Empty
-- when the rows have exactly the same values.
CREATE FUNCTION stock.values_differing(p_a uuid, p_b uuid)
RETURNS uuid[]
LANGUAGE sql STABLE AS $$
    SELECT coalesce(array_agg(coalesce(a.attribute, b.attribute)), '{}')
    FROM (SELECT * FROM public.stock_value WHERE stock = p_a) a
    FULL JOIN (SELECT * FROM public.stock_value WHERE stock = p_b) b ON b.attribute = a.attribute
    WHERE a.attribute IS NULL OR b.attribute IS NULL
       OR (a.text, a.number, a.date, a.boolean, a.option)
          IS DISTINCT FROM (b.text, b.number, b.date, b.boolean, b.option);
$$;

-- Copies stock row p_from's attachments to stock row p_to (the same files:
-- an attachment's content is found by its hash), and makes the copy of
-- p_photo, p_from's photo, p_to's photo. The copies' ids are made first, so
-- that the photo can refer to its copy.
CREATE FUNCTION stock.copy_attachments(p_from uuid, p_photo uuid, p_to uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.copied;
    CREATE TEMPORARY TABLE pg_temp.copied ON COMMIT DROP AS
    SELECT a.id AS old, uuidv7() AS new
    FROM public.attachment a WHERE a.stock = p_from;
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

-- A page of the tenant's stock rows, by item name, each with its item, its
-- amount and how it is shown, and its photo; with the number that match.
-- Optional: p_item, only that item's rows; p_location, only the rows in
-- that location or the locations below it.
CREATE FUNCTION stock.list(
    p_request  public.request,
    p_item     uuid    DEFAULT NULL,
    p_location uuid    DEFAULT NULL,
    p_limit    integer DEFAULT 100,
    p_offset   integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
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
        -- Only what is sorted by and counted: the rows themselves are read
        -- for the page alone.
        matching AS (
            SELECT s.id, i.name
            FROM public.stock s
            JOIN public.location l ON l.id = s.location
            JOIN public.item i     ON i.id = s.item
            WHERE l.tenant = v_session.tenant
              AND (p_item IS NULL OR s.item = p_item)
              AND (p_location IS NULL OR s.location IN (SELECT id FROM subtree))
        ),
        -- A plain ORDER BY with LIMIT, sorted as a top-N (see item.list).
        page AS (
            SELECT s AS row, i AS item
            FROM (SELECT m.id FROM matching m
                  ORDER BY m.name COLLATE public.natural, m.id
                  LIMIT p_limit OFFSET p_offset) x
            JOIN public.stock s ON s.id = x.id
            JOIN public.item i  ON i.id = s.item
        )
        SELECT jsonb_build_object(
            'total',  (SELECT count(*) FROM matching),
            'limit',  p_limit,
            'offset', p_offset,
            'rows',   coalesce((
                SELECT jsonb_agg(stock.json(p.row, attachment.json(ph))
                                 || jsonb_build_object(
                                        'item',    item.json(p.item, attachment.json(iph)),
                                        'display', CASE WHEN d.unit IS NOT NULL
                                                        THEN jsonb_build_object('value', d.value, 'unit', d.unit) END)
                                 ORDER BY (p.item).name COLLATE public.natural, (p.row).id)
                FROM page p
                LEFT JOIN public.attachment ph  ON ph.id = (p.row).photo
                LEFT JOIN public.attachment iph ON iph.id = (p.item).photo
                LEFT JOIN LATERAL unit.display(v_session.tenant, (p.row).amount,
                                               (p.item).unit, (p.item).unit_lock) d ON true), '[]'))
    );
END;
$$;

-- One of the tenant's stock rows, as stock.detail_json shows it.
CREATE FUNCTION stock.get(p_request public.request, p_stock uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT stock.detail_json(v_session.tenant, s) INTO v_result
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
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
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
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

    INSERT INTO public.stock (code, item, location, amount)
    VALUES (tenant.take_codes(v_session.tenant, 1), p_item, p_location, p_amount)
    RETURNING * INTO v_stock;
    PERFORM stock.values_set(v_session.tenant, v_stock.id, p_values);
    RETURN stock.detail_json(v_session.tenant, v_stock);
END;
$$;

-- Corrects the fields of one of the tenant's stock rows that p_patch has:
-- item, location, amount (null: not counted), and photo (the id of one of
-- its own image attachments, or null). To move things, use stock.move; this
-- is for corrections. The rules refuse an item whose class doesn't take the
-- row's values, and a location that is a container. Returns the row as
-- stock.get does.
CREATE FUNCTION stock.patch(p_request public.request, p_stock uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
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
    WHERE s.id = p_stock AND l.tenant = v_session.tenant
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

    UPDATE public.stock s
    SET item     = v_item,
        location = v_place,
        amount   = CASE WHEN p_patch ? 'amount' THEN (p_patch ->> 'amount')::numeric ELSE s.amount END,
        photo    = CASE WHEN p_patch ? 'photo' THEN (p_patch ->> 'photo')::uuid ELSE s.photo END
    WHERE s.id = p_stock
    RETURNING * INTO v_stock;
    RETURN stock.detail_json(v_session.tenant, v_stock);
END;
$$;

-- Moves one of the tenant's stock rows, or part of it, to another of its
-- locations. p_amount NULL moves the whole row; otherwise it is the amount
-- to move (in the base unit of the item's unit), and the row must be
-- counted. A whole row changes location and keeps its code; a part is split
-- off into a new row at the destination, with a code of its own, copies of
-- the values and of the attachments (the same files), and the copy of the
-- photo as its photo. It never merges into a row at the destination:
-- stock.merge does that, when the user asks. Returns the row at the
-- destination, as stock.get does.
CREATE FUNCTION stock.move(p_request public.request, p_stock uuid, p_location uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
    v_split   public.stock;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant
    FOR UPDATE OF s;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
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

    IF p_amount IS NULL OR p_amount = v_stock.amount THEN
        UPDATE public.stock s SET location = p_location WHERE s.id = p_stock RETURNING * INTO v_stock;
        RETURN stock.detail_json(v_session.tenant, v_stock);
    END IF;

    -- A part, split off into a new row.
    UPDATE public.stock s SET amount = s.amount - p_amount WHERE s.id = p_stock;
    INSERT INTO public.stock (code, item, location, amount)
    VALUES (tenant.take_codes(v_session.tenant, 1), v_stock.item, p_location, p_amount)
    RETURNING * INTO v_split;
    INSERT INTO public.stock_value (stock, attribute, text, number, date, boolean, option)
    SELECT v_split.id, v.attribute, v.text, v.number, v.date, v.boolean, v.option
    FROM public.stock_value v WHERE v.stock = p_stock;
    PERFORM stock.copy_attachments(p_stock, v_stock.photo, v_split.id);
    SELECT s.* INTO v_split FROM public.stock s WHERE s.id = v_split.id;
    RETURN stock.detail_json(v_session.tenant, v_split);
END;
$$;

-- Adds p_amount of one of the tenant's stock rows (NULL: all of it) to
-- another of its rows, p_into, which may be at another location. Both rows
-- must be of the same item and counted, and have exactly the same values
-- (422 otherwise, naming the attributes that differ), as nothing about a
-- row may be lost by merging. Merging all of it deletes the row, whose
-- label then answers "gone" (code.resolve), and its attachments move to
-- p_into, which keeps its own photo; merging part of it leaves the row with
-- the rest, and its attachments with it. Returns p_into as stock.get does.
CREATE FUNCTION stock.merge(p_request public.request, p_stock uuid, p_into uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session   record := util.session(p_request, 'user');
    v_stock     public.stock;
    v_into      public.stock;
    v_amount    numeric;
    v_differing uuid[];
BEGIN
    -- Both rows locked, in the order of their ids, so that two merges of
    -- the same rows the other way round can't wait for each other.
    PERFORM 1 FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id IN (p_stock, p_into) AND l.tenant = v_session.tenant
    ORDER BY s.id
    FOR UPDATE OF s;
    SELECT s.* INTO v_stock
    FROM public.stock s JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    SELECT s.* INTO v_into
    FROM public.stock s JOIN public.location l ON l.id = s.location
    WHERE s.id = p_into AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.bad_reference('stock row', p_into);
    END IF;

    IF p_into = p_stock THEN
        PERFORM error.not_allowed('A stock row can''t be merged into itself');
    END IF;
    IF v_into.item <> v_stock.item THEN
        PERFORM error.not_allowed(format('%s and %s are of different items, so they can''t be merged',
                                         error.row_label('stock', p_stock), error.row_label('stock', p_into)));
    END IF;
    IF v_stock.amount IS NULL OR v_into.amount IS NULL THEN
        PERFORM error.not_allowed('Only counted stock rows can be merged; give both an amount first');
    END IF;
    v_differing := stock.values_differing(p_stock, p_into);
    IF cardinality(v_differing) > 0 THEN
        PERFORM error.not_allowed(format('%s and %s have different values for %s, so they can''t be merged',
                                         error.row_label('stock', p_stock), error.row_label('stock', p_into),
                                         error.attribute_names(v_differing)));
    END IF;
    IF p_amount IS NOT NULL AND (p_amount <= 0 OR p_amount > v_stock.amount) THEN
        PERFORM error.invalid(format('The amount to merge must be more than 0 and at most %s',
                                     v_stock.amount));
    END IF;
    v_amount := coalesce(p_amount, v_stock.amount);

    UPDATE public.stock s SET amount = s.amount + v_amount WHERE s.id = p_into RETURNING * INTO v_into;
    IF v_amount = v_stock.amount THEN
        -- The photo first, as it refers to one of the attachments that move.
        UPDATE public.stock s SET photo = NULL WHERE s.id = p_stock;
        UPDATE public.attachment a SET stock = p_into WHERE a.stock = p_stock;
        DELETE FROM public.stock s WHERE s.id = p_stock;
    ELSE
        UPDATE public.stock s SET amount = s.amount - v_amount WHERE s.id = p_stock;
    END IF;
    RETURN stock.detail_json(v_session.tenant, v_into);
END;
$$;

-- Deletes one of the tenant's stock rows, with its values and attachments.
CREATE FUNCTION stock.delete(p_request public.request, p_stock uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
BEGIN
    DELETE FROM public.stock s
    USING public.location l
    WHERE s.id = p_stock AND l.id = s.location AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
END;
$$;

-- Sets one value of one of the tenant's stock rows: inserts it, or replaces
-- the one there. Numbers of an attribute with a unit are in the base unit;
-- a JSON null is refused (remove a value with value delete). The rules
-- refuse a value that doesn't fit, or whose attribute doesn't apply to the
-- class of the row's item with its values on each stock row. Returns the
-- row as stock.get does.
CREATE FUNCTION stock.value_set(p_request public.request, p_stock uuid, p_attribute uuid, p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        PERFORM error.invalid('Remove a value with value delete');
    END IF;

    PERFORM stock.values_set(v_session.tenant, p_stock, jsonb_build_object(p_attribute::text, p_value));
    RETURN stock.detail_json(v_session.tenant, v_stock);
END;
$$;

-- Removes one value of one of the tenant's stock rows. A required value
-- without a default can't be removed (checked at the end of the
-- transaction). Returns the row as stock.get does, which then shows the
-- class default, if there is one.
CREATE FUNCTION stock.value_delete(p_request public.request, p_stock uuid, p_attribute uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_stock   public.stock;
BEGIN
    SELECT s.* INTO v_stock
    FROM public.stock s
    JOIN public.location l ON l.id = s.location
    WHERE s.id = p_stock AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;

    DELETE FROM public.stock_value v WHERE v.stock = p_stock AND v.attribute = p_attribute;
    IF NOT FOUND THEN
        PERFORM error.not_found('value', format('of attribute %s on %s',
                                                p_attribute, error.row_label('stock', p_stock)));
    END IF;
    RETURN stock.detail_json(v_session.tenant, v_stock);
END;
$$;
