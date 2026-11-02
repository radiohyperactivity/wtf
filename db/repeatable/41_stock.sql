-- Stock rows (schema stock): the functions the API calls for them, and
-- their helpers. A stock row's values are checked against its item's
-- class's stock attributes here, as it is written (class.check_values), not
-- by triggers.

CREATE SCHEMA stock;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A stock row as the API shows it. Its amount is in its item's unit;
-- location is the id, which clients look up in the location tree they
-- keep; photo is its file's hash, or null.
CREATE FUNCTION stock.json(p_stock public.stock)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_stock.id,
        'code',      util.code_text(p_stock.code),
        'item',      p_stock.item,
        'location',  p_stock.location,
        'amount',    p_stock.amount,
        'reference', p_stock.reference,
        'serial',    p_stock.serial,
        'photo',     p_stock.photo
    );
$$;

-- A stock row as stock.get shows it: with its item, its values and those
-- of them that follow the class's defaults. (PL/pgSQL, as it uses
-- item.json, which is made after this script.)
CREATE FUNCTION stock.detail_json(p_stock public.stock)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT stock.json(p_stock) || jsonb_build_object(
            'item',      item.json(i),
            'values',    p_stock.values,
            'defaulted', to_jsonb(p_stock.defaulted))
        FROM public.item i
        WHERE i.id = p_stock.item
    );
END;
$$;

-- Stock row p_stock, for a change: its item's
-- class first, locked for sharing, then the row, locked for the change, as
-- item.lock_for_write does it and for the same reason. With it, its item.
-- Not found (404) when there is none; refused (409) when it was
-- given another item in between, which a second try gets right.
CREATE FUNCTION stock.lock_for_write(
    p_stock    uuid,
    OUT stock_row public.stock,
    OUT item_row  public.item,
    OUT class_row public.class
)
LANGUAGE plpgsql AS $$
DECLARE
    v_item uuid;
BEGIN
    SELECT s.item INTO v_item FROM public.stock s WHERE s.id = p_stock;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    SELECT i.* INTO item_row FROM public.item i WHERE i.id = v_item;
    SELECT c.* INTO class_row FROM public.class c WHERE c.id = item_row.class FOR SHARE;
    SELECT s.* INTO stock_row FROM public.stock s WHERE s.id = p_stock FOR UPDATE;
    IF stock_row.item <> v_item THEN
        PERFORM error.wrong_state(format('%s was given another item just now; try again',
                                         error.row_label('stock', p_stock)));
    END IF;
END;
$$;

-- Item p_item, that a stock row is created
-- for or given, with its class locked for sharing (as for any write of a
-- stock row's values). A reference to an item that isn't there is
-- bad (422).
CREATE FUNCTION stock.item_for_write(p_item uuid, OUT item_row public.item, OUT class_row public.class)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT i.* INTO item_row FROM public.item i WHERE i.id = p_item;
    IF NOT FOUND THEN
        PERFORM error.bad_reference('item', p_item);
    END IF;
    SELECT c.* INTO class_row FROM public.class c WHERE c.id = item_row.class FOR SHARE;
END;
$$;

-- Location p_location, that stock is put in,
-- locked for sharing until commit, so that it can't become a container
-- meanwhile (location.patch). A reference to a location that isn't the
-- there is bad (422); a container holds only other locations.
CREATE FUNCTION stock.location_for_write(p_location uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_location public.location;
BEGIN
    SELECT l.* INTO v_location
    FROM public.location l
    WHERE l.id = p_location
    FOR SHARE;
    IF NOT FOUND THEN
        PERFORM error.bad_reference('location', p_location);
    END IF;
    IF v_location.container THEN
        PERFORM error.not_allowed(format('Location "%s" is a container: it holds only other locations, not stock',
                                         v_location.name));
    END IF;
END;
$$;

-- Refuses amount p_amount for a stock row of item p_item: it can't be
-- below 0, and must be whole when the item is counted in pieces (it has no
-- unit). NULL is "present, but not counted".
CREATE FUNCTION stock.check_amount(p_item public.item, p_amount numeric)
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_amount < 0 THEN
        PERFORM error.invalid('An amount can''t be below 0');
    END IF;
    IF p_item.unit IS NULL AND p_amount <> trunc(p_amount) THEN
        PERFORM error.not_allowed(format('Item "%s" is counted in pieces, so its amounts are whole', p_item.name));
    END IF;
END;
$$;

-- p_text as a stock row's reference or serial: trimmed, and NULL when
-- empty.
CREATE FUNCTION stock.clean_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(p_text), '');
$$;

-- Writes stock row p_stock's values, p_values and p_defaulted, after
-- checking them against class p_class, its item's (class.check_values;
-- refused with what is wrong). Returns the row as it is now.
CREATE FUNCTION stock.store_values(p_stock public.stock, p_class public.class, p_values jsonb, p_defaulted text[])
RETURNS public.stock
LANGUAGE plpgsql AS $$
DECLARE
    v_checked record;
    v_stock   public.stock;
BEGIN
    v_checked := class.check_values(p_values, p_defaulted, p_class.attributes, 'stock', false);
    IF v_checked.problem IS NOT NULL THEN
        PERFORM error.not_allowed(format('%s %s', error.row_label('stock', p_stock.id), v_checked.problem));
    END IF;
    UPDATE public.stock s
    SET values = v_checked.new_values, defaulted = v_checked.new_defaulted
    WHERE s.id = p_stock.id
    RETURNING * INTO v_stock;
    RETURN v_stock;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- A page of the stock rows, by item name, each with its item.
-- Lists page by key, as item.list does: p_after is the last stock row of
-- the page before, and the answer is {rows, more, next}. Optional: p_item,
-- only that item's rows; p_location, only the rows in that location or the
-- locations below it; p_search, words that must each occur, letter case
-- ignored, in the row's reference or serial.
CREATE FUNCTION stock.list(
    p_request  public.request,
    p_item     uuid    DEFAULT NULL,
    p_location uuid    DEFAULT NULL,
    p_search   text    DEFAULT NULL,
    p_limit    integer DEFAULT 100,
    p_after    uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_words   text[] := ARRAY(SELECT DISTINCT w
                              FROM regexp_split_to_table(lower(btrim(coalesce(p_search, ''))), '\s+') w
                              WHERE w <> '');
    v_after   text;
BEGIN
    PERFORM util.check_limit(p_limit);
    IF p_item IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.item i WHERE i.id = p_item
    ) THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    IF p_location IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.location l WHERE l.id = p_location
    ) THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;
    IF p_after IS NOT NULL THEN
        SELECT i.name INTO v_after
        FROM public.stock s JOIN public.item i ON i.id = s.item
        WHERE s.id = p_after;
        IF NOT FOUND THEN
            PERFORM error.invalid('The stock row to list after isn''t there any more; start from the first page');
        END IF;
    END IF;

    RETURN (
        WITH RECURSIVE subtree (id) AS (
            SELECT p_location WHERE p_location IS NOT NULL
            UNION ALL
            SELECT l.id FROM public.location l JOIN subtree s ON l.parent = s.id
        ),
        page AS (
            SELECT x.*, row_number() OVER (ORDER BY x.name COLLATE public.natural, x.id) AS n
            FROM (SELECT s.id, i.name
                  FROM public.stock s
                  JOIN public.item i ON i.id = s.item
                  WHERE (p_item IS NULL OR s.item = p_item)
                    AND (p_location IS NULL OR s.location IN (SELECT id FROM subtree))
                    AND (p_after IS NULL
                         OR i.name COLLATE public.natural >= v_after
                            AND (i.name COLLATE public.natural > v_after OR s.id > p_after))
                    AND NOT EXISTS (SELECT 1 FROM unnest(v_words) w
                                    WHERE strpos(lower(concat_ws(' ', s.reference, s.serial)), w) = 0)
                  ORDER BY i.name COLLATE public.natural, s.id
                  LIMIT p_limit + 1) x
        )
        SELECT jsonb_build_object(
            'rows', coalesce((
                SELECT jsonb_agg(stock.json(s) || jsonb_build_object('item', item.json(i)) ORDER BY p.n)
                FROM page p
                JOIN public.stock s ON s.id = p.id
                JOIN public.item i  ON i.id = s.item
                WHERE p.n <= p_limit), '[]'),
            'more', EXISTS (SELECT 1 FROM page WHERE n > p_limit),
            'next', CASE WHEN EXISTS (SELECT 1 FROM page WHERE n > p_limit)
                         THEN (SELECT id FROM page WHERE n = p_limit) END)
    );
END;
$$;

-- A stock row, as stock.detail_json shows it.
CREATE FUNCTION stock.get(p_request public.request, p_stock uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT stock.detail_json(s) INTO v_result
    FROM public.stock s
    WHERE s.id = p_stock;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates a stock row of an item in a location,
-- with a code for its label. p_amount is in the item's unit (whole for
-- pieces), and NULL means present but not counted. p_reference and
-- p_serial are optional texts. p_values sets its stock values, as
-- item.create does an item's: {"Bought": "2026-11-02", ...}; the others get
-- their defaults, and follow them. Returns the row as stock.get does.
CREATE FUNCTION stock.create(
    p_request   public.request,
    p_item      uuid,
    p_location  uuid,
    p_amount    numeric,
    p_reference text,
    p_serial    text,
    p_values    jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_values  jsonb := util.given_values(p_values);
    v_for     record := stock.item_for_write(p_item);
    v_item    public.item := v_for.item_row;
    v_class   public.class := v_for.class_row;
    v_checked record;
    v_stock   public.stock;
BEGIN
    PERFORM stock.location_for_write(p_location);
    PERFORM stock.check_amount(v_item, p_amount);
    PERFORM item.refuse_files(v_class, 'stock', v_values);
    v_checked := class.check_values(v_values, '{}', v_class.attributes, 'stock', true);
    IF v_checked.problem IS NOT NULL THEN
        PERFORM error.not_allowed(format('A stock row of item "%s" %s', v_item.name, v_checked.problem));
    END IF;

    INSERT INTO public.stock (code, item, location, amount, reference, serial, values, defaulted)
    VALUES (util.take_codes(1), p_item, p_location, p_amount,
            stock.clean_text(p_reference), stock.clean_text(p_serial),
            v_checked.new_values, v_checked.new_defaulted)
    RETURNING * INTO v_stock;
    RETURN stock.detail_json(v_stock);
END;
$$;

-- Changes the fields of a stock row that p_patch has: item, location,
-- amount (null: not counted), reference, serial (null: none), photo (null
-- only: a photo is uploaded), and its values, as item.patch does an item's.
-- To move things, use stock.move; a location here is for corrections.
-- Given another item, its values are checked against that item's class. Returns the row as stock.get does.
CREATE FUNCTION stock.patch(p_request public.request, p_stock uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_locked  record;
    v_stock   public.stock;
    v_item    public.item;
    v_class   public.class;
    v_for     record;
    v_amount  numeric;
    v_changed record;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['item', 'location', 'amount', 'reference', 'serial', 'photo',
                                            'values', 'default'],
                             ARRAY['item', 'location']);
    IF p_patch ? 'amount' AND jsonb_typeof(p_patch -> 'amount') NOT IN ('number', 'null') THEN
        PERFORM error.invalid('amount must be a number, or null for not counted');
    END IF;
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') <> 'null' THEN
        PERFORM error.invalid('A photo is uploaded; photo can only be set to null here, which removes it');
    END IF;
    v_locked := stock.lock_for_write(p_stock);
    v_stock := v_locked.stock_row;
    v_item := v_locked.item_row;
    v_class := v_locked.class_row;
    IF p_patch ? 'item' AND (p_patch ->> 'item')::uuid <> v_stock.item THEN
        v_for := stock.item_for_write((p_patch ->> 'item')::uuid);
        v_item := v_for.item_row;
        v_class := v_for.class_row;
    END IF;
    IF p_patch ? 'location' AND (p_patch ->> 'location')::uuid <> v_stock.location THEN
        PERFORM stock.location_for_write((p_patch ->> 'location')::uuid);
    END IF;
    v_amount := CASE WHEN p_patch ? 'amount' THEN (p_patch ->> 'amount')::numeric ELSE v_stock.amount END;
    PERFORM stock.check_amount(v_item, v_amount);

    UPDATE public.stock s
    SET item      = v_item.id,
        location  = coalesce((p_patch ->> 'location')::uuid, s.location),
        amount    = v_amount,
        reference = CASE WHEN p_patch ? 'reference' THEN stock.clean_text(p_patch ->> 'reference') ELSE s.reference END,
        serial    = CASE WHEN p_patch ? 'serial' THEN stock.clean_text(p_patch ->> 'serial') ELSE s.serial END,
        photo     = CASE WHEN p_patch ? 'photo' THEN NULL ELSE s.photo END
    WHERE s.id = p_stock
    RETURNING * INTO v_stock;
    v_changed := class.patch_values(v_stock.values, v_stock.defaulted, v_class, 'stock',
                                    p_patch -> 'values', p_patch -> 'default');
    v_stock := stock.store_values(v_stock, v_class, v_changed.new_values, v_changed.new_defaulted);
    RETURN stock.detail_json(v_stock);
END;
$$;

-- Moves a stock row, or part of it, to another
-- location. p_amount NULL moves the whole row; otherwise it is the amount
-- to move, and the row must be counted. A whole row changes location and
-- keeps its code; a part is split off into a new row at the destination,
-- with a code of its own and everything else the row has: its reference,
-- serial, photo and values. It never merges into a row at the destination:
-- stock.merge does that, when the user asks. Returns the row at the
-- destination, as stock.get does.
CREATE FUNCTION stock.move(p_request public.request, p_stock uuid, p_location uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_locked  record := stock.lock_for_write(p_stock);
    v_stock   public.stock := v_locked.stock_row;
    v_split   public.stock;
BEGIN
    PERFORM stock.location_for_write(p_location);
    IF p_amount IS NOT NULL THEN
        IF v_stock.amount IS NULL THEN
            PERFORM error.invalid('A stock row that isn''t counted can only be moved as a whole');
        END IF;
        IF p_amount <= 0 OR p_amount > v_stock.amount THEN
            PERFORM error.invalid(format('The amount to move must be more than 0 and at most %s',
                                         v_stock.amount));
        END IF;
        PERFORM stock.check_amount(v_locked.item_row, p_amount);
    END IF;

    IF p_amount IS NULL OR p_amount = v_stock.amount THEN
        UPDATE public.stock s SET location = p_location WHERE s.id = p_stock RETURNING * INTO v_stock;
        RETURN stock.detail_json(v_stock);
    END IF;

    -- A part, split off into a new row.
    UPDATE public.stock s SET amount = s.amount - p_amount WHERE s.id = p_stock;
    INSERT INTO public.stock (code, item, location, amount, reference, serial, values, defaulted, photo)
    VALUES (util.take_codes(1), v_stock.item, p_location, p_amount,
            v_stock.reference, v_stock.serial, v_stock.values, v_stock.defaulted, v_stock.photo)
    RETURNING * INTO v_split;
    RETURN stock.detail_json(v_split);
END;
$$;

-- What differs between stock rows p_a and p_b: "reference", "serial" and
-- "photo" when they do, and each value one row has and the other hasn't,
-- or has with another value, as "values.<name>". Empty when they are the
-- same.
CREATE FUNCTION stock.differences(p_a public.stock, p_b public.stock)
RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY(
        SELECT f FROM (
            SELECT 'reference' AS f WHERE p_a.reference IS DISTINCT FROM p_b.reference
            UNION ALL
            SELECT 'serial' WHERE p_a.serial IS DISTINCT FROM p_b.serial
            UNION ALL
            SELECT 'photo' WHERE p_a.photo IS DISTINCT FROM p_b.photo
            UNION ALL
            SELECT 'values.' || k
            FROM (SELECT jsonb_object_keys(p_a.values) UNION SELECT jsonb_object_keys(p_b.values)) n (k)
            WHERE p_a.values -> k IS DISTINCT FROM p_b.values -> k
        ) d ORDER BY f);
$$;

-- Adds p_amount of a stock row (NULL: all of it) to
-- another row, p_into, which may be at another location. Both rows
-- must be of the same item and counted. Where they differ (their
-- reference, serial, photo, or a value), p_resolve must say which row's to
-- keep, for each difference: {"reference": "from" | "into", "serial": …,
-- "photo": …, "values": {"<name>": "from" | "into"}}, where "from" is
-- p_stock's and "into" is p_into's. Without one for every difference, the
-- merge is refused (422, naming the differences), so that the client can
-- ask the user. p_into takes what is resolved "from". Merging all of it
-- deletes the row, whose label then answers "gone" (code.resolve); merging
-- part of it leaves the row with the rest, as it was. Returns p_into as
-- stock.get does.
CREATE FUNCTION stock.merge(
    p_request public.request,
    p_stock   uuid,
    p_into    uuid,
    p_amount  numeric,
    p_resolve jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session     record := util.session(p_request, 'user');
    v_resolve     jsonb := coalesce(p_resolve, '{}');
    v_stock       public.stock;
    v_into        public.stock;
    v_class       public.class;
    v_amount      numeric;
    v_differences text[];
    v_open        text[];
    v_field       text;
    v_name        text;
    v_values      jsonb;
    v_defaulted   text[];
BEGIN
    IF jsonb_typeof(v_resolve) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_each(v_resolve) e
                  WHERE e.key NOT IN ('reference', 'serial', 'photo', 'values')
                     OR e.key <> 'values' AND e.value NOT IN ('"from"', '"into"')
                     OR e.key = 'values' AND (jsonb_typeof(e.value) <> 'object'
                                              OR EXISTS (SELECT 1 FROM jsonb_each(e.value) v
                                                         WHERE v.value NOT IN ('"from"', '"into"')))) THEN
        PERFORM error.invalid('resolve must be {"reference": "from" or "into", "serial": …, "photo": …, '
                              '"values": {"<name>": "from" or "into"}}');
    END IF;
    -- Both rows, the class first and then the rows in the order of their
    -- ids, so that two merges of the same rows the other way round can't
    -- wait for each other.
    SELECT s.* INTO v_stock FROM public.stock s WHERE s.id = p_stock;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
    SELECT s.* INTO v_into FROM public.stock s WHERE s.id = p_into;
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
    SELECT c.* INTO v_class FROM public.class c JOIN public.item i ON i.class = c.id
    WHERE i.id = v_stock.item FOR SHARE OF c;
    PERFORM 1 FROM public.stock s WHERE s.id IN (p_stock, p_into) ORDER BY s.id FOR UPDATE;
    SELECT s.* INTO v_stock FROM public.stock s WHERE s.id = p_stock;
    SELECT s.* INTO v_into FROM public.stock s WHERE s.id = p_into;
    IF v_into.item <> v_stock.item THEN
        PERFORM error.wrong_state('One of the rows was given another item just now; try again');
    END IF;

    IF v_stock.amount IS NULL OR v_into.amount IS NULL THEN
        PERFORM error.not_allowed('Only counted stock rows can be merged; give both an amount first');
    END IF;
    IF p_amount IS NOT NULL AND (p_amount <= 0 OR p_amount > v_stock.amount) THEN
        PERFORM error.invalid(format('The amount to merge must be more than 0 and at most %s',
                                     v_stock.amount));
    END IF;
    v_amount := coalesce(p_amount, v_stock.amount);

    v_differences := stock.differences(v_stock, v_into);
    v_open := ARRAY(SELECT d FROM unnest(v_differences) d
                    WHERE CASE WHEN d LIKE 'values.%' THEN NOT coalesce(v_resolve -> 'values', '{}') ? substr(d, 8)
                               ELSE NOT v_resolve ? d END);
    IF cardinality(v_open) > 0 THEN
        PERFORM error.not_allowed(format('%s and %s differ in %s; say for each which row''s to keep',
                                         error.row_label('stock', p_stock), error.row_label('stock', p_into),
                                         array_to_string(v_open, ', ')));
    END IF;

    -- What p_into takes from p_stock.
    v_values := v_into.values;
    v_defaulted := v_into.defaulted;
    FOREACH v_field IN ARRAY v_differences LOOP
        IF v_field LIKE 'values.%' THEN
            v_name := substr(v_field, 8);
            IF v_resolve -> 'values' ->> v_name = 'from' THEN
                v_values := (v_values - v_name) || CASE WHEN v_stock.values ? v_name
                                                        THEN jsonb_build_object(v_name, v_stock.values -> v_name)
                                                        ELSE '{}' END;
                v_defaulted := array_remove(v_defaulted, v_name)
                               || CASE WHEN v_name = ANY (v_stock.defaulted) THEN ARRAY[v_name] ELSE '{}' END;
            END IF;
        END IF;
    END LOOP;
    UPDATE public.stock s
    SET amount    = s.amount + v_amount,
        reference = CASE WHEN v_resolve ->> 'reference' = 'from' THEN v_stock.reference ELSE s.reference END,
        serial    = CASE WHEN v_resolve ->> 'serial' = 'from' THEN v_stock.serial ELSE s.serial END,
        photo     = CASE WHEN v_resolve ->> 'photo' = 'from' THEN v_stock.photo ELSE s.photo END
    WHERE s.id = p_into
    RETURNING * INTO v_into;
    v_into := stock.store_values(v_into, v_class, v_values, v_defaulted);

    IF v_amount = v_stock.amount THEN
        DELETE FROM public.stock s WHERE s.id = p_stock;
    ELSE
        UPDATE public.stock s SET amount = s.amount - v_amount WHERE s.id = p_stock;
    END IF;
    RETURN stock.detail_json(v_into);
END;
$$;

-- Deletes a stock row. Its files stay until "wtfd gc"
-- finds that nothing has them.
CREATE FUNCTION stock.delete(p_request public.request, p_stock uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
BEGIN
    DELETE FROM public.stock s WHERE s.id = p_stock;
    IF NOT FOUND THEN
        PERFORM error.not_found('stock row', p_stock::text);
    END IF;
END;
$$;

