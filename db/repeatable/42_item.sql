-- Items (schema item): the functions the API calls for them, and their
-- helpers. An item's values are checked against its class's attributes
-- here, as it is written (class.check_values), not by triggers.

CREATE SCHEMA item;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- An item as the API shows it. photo is its file's hash, or null.
CREATE FUNCTION item.json(p_item public.item)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',    p_item.id,
        'code',  util.code_text(p_item.code),
        'name',  p_item.name,
        'class', p_item.class,
        'unit',  p_item.unit,
        'photo', p_item.photo
    );
$$;

-- An item as item.get shows it: its class with its path, its values and
-- those of them that follow the class's defaults, and its stock rows, by
-- location name, each with its values.
CREATE FUNCTION item.detail_json(p_item public.item)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT item.json(p_item) || jsonb_build_object(
        'class',     jsonb_build_object('id', c.id, 'name', c.name, 'path', class.path_json(c.id)),
        'values',    p_item.values,
        'defaulted', to_jsonb(p_item.defaulted),
        'stock',     coalesce((
            SELECT jsonb_agg(stock.json(s) || jsonb_build_object('values', s.values,
                                                                  'defaulted', to_jsonb(s.defaulted))
                             ORDER BY l.name COLLATE public.natural, s.id)
            FROM public.stock s
            JOIN public.location l ON l.id = s.location
            WHERE s.item = p_item.id), '[]'))
    FROM public.class c
    WHERE c.id = p_item.class;
$$;

-- Item p_item, locked for the change the caller makes; not found (404)
-- when there is none.
CREATE FUNCTION item.find(p_item uuid)
RETURNS public.item
LANGUAGE plpgsql AS $$
DECLARE
    v_item public.item;
BEGIN
    SELECT i.* INTO v_item
    FROM public.item i
    WHERE i.id = p_item
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    RETURN v_item;
END;
$$;

-- Class p_class, which an item is put in or written in,
-- locked for sharing until commit: a change of the class's attributes then
-- waits for the write, or the write for the change (class.lock_subtree). A
-- reference to a class that isn't there is bad (422); so is a
-- container, which holds only other classes.
CREATE FUNCTION item.class_for_write(p_class uuid)
RETURNS public.class
LANGUAGE plpgsql AS $$
DECLARE
    v_class public.class;
BEGIN
    SELECT c.* INTO v_class
    FROM public.class c
    WHERE c.id = p_class
    FOR SHARE;
    IF NOT FOUND THEN
        PERFORM error.bad_reference('class', p_class);
    END IF;
    IF v_class.container THEN
        PERFORM error.not_allowed(format('Class "%s" is a container: it holds only other classes, not items',
                                         v_class.name));
    END IF;
    RETURN v_class;
END;
$$;

-- Item p_item, for a change of its values:
-- its class first, locked for sharing (item.class_for_write), then the
-- item, locked for the change. In that order, as a change of a class locks
-- the class and then writes its items: the other way round, the two could
-- wait for each other. Not found (404) when there is none; refused
-- (409) when it was moved to another class in between, which a second try
-- gets right.
CREATE FUNCTION item.lock_for_write(
    p_item     uuid,
    OUT item_row  public.item,
    OUT class_row public.class
)
LANGUAGE plpgsql AS $$
DECLARE
    v_class uuid;
BEGIN
    SELECT i.class INTO v_class FROM public.item i WHERE i.id = p_item;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    class_row := item.class_for_write(v_class);
    SELECT i.* INTO item_row FROM public.item i WHERE i.id = p_item FOR UPDATE;
    IF item_row.class <> v_class THEN
        PERFORM error.wrong_state(format('Item "%s" was moved to another class just now; try again',
                                         item_row.name));
    END IF;
END;
$$;

-- p_unit as an item's unit: trimmed, and NULL when empty.
CREATE FUNCTION item.clean_unit(p_unit text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(p_unit), '');
$$;

-- Refuses values p_values that an item or stock row of class p_class
-- (p_scope) is given in a request when one of them is an attachment: a
-- file is uploaded, not given as a value.
CREATE FUNCTION item.refuse_files(p_class public.class, p_scope public.scope, p_values jsonb)
RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_name text;
BEGIN
    SELECT e.key INTO v_name FROM jsonb_each(p_values) e
    WHERE p_class.attributes -> e.key ->> 'type' = 'attachment'
      AND p_class.attributes -> e.key ->> 'scope' = p_scope::text
    LIMIT 1;
    IF FOUND THEN
        PERFORM error.invalid(format('"%s" is a file: upload it', v_name));
    END IF;
END;
$$;

-- Writes item p_item's values, p_values and p_defaulted, after checking
-- them against its class p_class (class.check_values; refused with what is
-- wrong), with its search text. Returns the item as it is now.
CREATE FUNCTION item.store_values(p_item public.item, p_class public.class, p_values jsonb, p_defaulted text[])
RETURNS public.item
LANGUAGE plpgsql AS $$
DECLARE
    v_checked record;
    v_item    public.item;
BEGIN
    v_checked := class.check_values(p_values, p_defaulted, p_class.attributes, 'item', false);
    IF v_checked.problem IS NOT NULL THEN
        PERFORM error.not_allowed(format('Item "%s" %s', p_item.name, v_checked.problem));
    END IF;
    UPDATE public.item i
    SET values    = v_checked.new_values,
        defaulted = v_checked.new_defaulted,
        search    = class.search_text(i.name, class.path_text(p_class.id), v_checked.new_values, p_class.attributes)
    WHERE i.id = p_item.id
    RETURNING * INTO v_item;
    RETURN v_item;
END;
$$;

-- The attribute filters of item.list, p_where, checked: a list of
-- {attribute, op, value}, the attribute by name. What each op takes:
--   =                    a number, a text (letter case ignored), true or
--                        false
--   >, >=, <, <=         a number, or a date as YYYY-MM-DD
--   between              [low, high], both numbers or both dates
--   contains             a text (letter case ignored)
--   in                   a list of texts (choices; letter case ignored)
-- Returns the filters with their texts in lower case, as item.matches
-- takes them.
CREATE FUNCTION item.check_filters(p_where jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_filter jsonb;
    v_name   text;
    v_op     text;
    v_value  jsonb;
    v_result jsonb := '[]';
BEGIN
    IF p_where IS NULL OR jsonb_typeof(p_where) = 'null' THEN
        RETURN v_result;
    END IF;
    IF jsonb_typeof(p_where) <> 'array' THEN
        PERFORM error.invalid('where must be a list of filters {attribute, op, value}');
    END IF;
    FOR v_filter IN SELECT f FROM jsonb_array_elements(p_where) f LOOP
        IF jsonb_typeof(v_filter) IS DISTINCT FROM 'object' OR jsonb_typeof(v_filter -> 'attribute') IS DISTINCT FROM 'string' THEN
            PERFORM error.invalid('Each filter must be an object {attribute, op, value}, with the attribute''s name');
        END IF;
        v_name  := v_filter ->> 'attribute';
        v_op    := v_filter ->> 'op';
        v_value := v_filter -> 'value';
        IF NOT (CASE v_op
            WHEN '='        THEN jsonb_typeof(v_value) IN ('number', 'string', 'boolean')
            WHEN 'contains' THEN jsonb_typeof(v_value) = 'string'
            WHEN 'in'       THEN jsonb_typeof(v_value) = 'array' AND jsonb_array_length(v_value) > 0
                                 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_value) e
                                                 WHERE jsonb_typeof(e) <> 'string')
            WHEN 'between'  THEN jsonb_typeof(v_value) = 'array' AND jsonb_array_length(v_value) = 2
                                 AND (jsonb_typeof(v_value -> 0) = 'number' AND jsonb_typeof(v_value -> 1) = 'number'
                                      OR (v_value ->> 0) ~ '^\d{4}-\d{2}-\d{2}$' AND (v_value ->> 1) ~ '^\d{4}-\d{2}-\d{2}$'
                                         AND jsonb_typeof(v_value -> 0) = 'string' AND jsonb_typeof(v_value -> 1) = 'string')
            WHEN '>'        THEN jsonb_typeof(v_value) = 'number'
                                 OR jsonb_typeof(v_value) = 'string' AND (v_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
            WHEN '>='       THEN jsonb_typeof(v_value) = 'number'
                                 OR jsonb_typeof(v_value) = 'string' AND (v_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
            WHEN '<'        THEN jsonb_typeof(v_value) = 'number'
                                 OR jsonb_typeof(v_value) = 'string' AND (v_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
            WHEN '<='       THEN jsonb_typeof(v_value) = 'number'
                                 OR jsonb_typeof(v_value) = 'string' AND (v_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
            ELSE false END) THEN
            PERFORM error.invalid(format(
                'The filter on "%s" can''t compare with %s %s: = takes a number, a text or true or false; '
                '>, >=, < and <= a number or a date (YYYY-MM-DD); between [low, high]; contains a text; '
                'in a list of texts', v_name, coalesce(v_op, '(no op)'), coalesce(v_value::text, '(no value)')));
        END IF;
        v_value := CASE
            WHEN v_op IN ('=', 'contains') AND jsonb_typeof(v_value) = 'string' THEN to_jsonb(lower(v_value #>> '{}'))
            WHEN v_op = 'in' THEN (SELECT jsonb_agg(lower(e)) FROM jsonb_array_elements_text(v_value) e)
            ELSE v_value END;
        v_result := v_result || jsonb_build_array(jsonb_build_object('attribute', v_name, 'op', v_op, 'value', v_value));
    END LOOP;
    RETURN v_result;
END;
$$;

-- Whether values p_values (an item's or a stock row's) pass filter
-- p_filter, one of item.check_filters's. A row without a value for the
-- attribute, or with a value of another kind (a text where the filter has
-- a number), doesn't pass. Dates are compared as their text, which sorts
-- as they do.
CREATE FUNCTION item.matches(p_values jsonb, p_filter jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_value jsonb := p_values -> (p_filter ->> 'attribute');
    v_op    text  := p_filter ->> 'op';
    v_with  jsonb := p_filter -> 'value';
    v_kind  text;
BEGIN
    IF v_value IS NULL THEN
        RETURN false;
    END IF;
    v_kind := CASE WHEN v_op IN ('in', 'between') THEN jsonb_typeof(v_with -> 0) ELSE jsonb_typeof(v_with) END;
    IF jsonb_typeof(v_value) <> v_kind THEN
        RETURN false;
    END IF;
    IF v_kind = 'number' THEN
        RETURN CASE v_op
            WHEN '='       THEN v_value::numeric =  v_with::numeric
            WHEN '>'       THEN v_value::numeric >  v_with::numeric
            WHEN '>='      THEN v_value::numeric >= v_with::numeric
            WHEN '<'       THEN v_value::numeric <  v_with::numeric
            WHEN '<='      THEN v_value::numeric <= v_with::numeric
            WHEN 'between' THEN v_value::numeric BETWEEN (v_with ->> 0)::numeric AND (v_with ->> 1)::numeric
        END;
    ELSIF v_kind = 'boolean' THEN
        RETURN v_value = v_with;
    END IF;
    RETURN CASE v_op
        WHEN '='        THEN lower(v_value #>> '{}') = (v_with #>> '{}')
        WHEN 'contains' THEN strpos(lower(v_value #>> '{}'), v_with #>> '{}') > 0
        WHEN 'in'       THEN v_with ? lower(v_value #>> '{}')
        WHEN '>'        THEN (v_value #>> '{}') COLLATE "C" >  (v_with #>> '{}')
        WHEN '>='       THEN (v_value #>> '{}') COLLATE "C" >= (v_with #>> '{}')
        WHEN '<'        THEN (v_value #>> '{}') COLLATE "C" <  (v_with #>> '{}')
        WHEN '<='       THEN (v_value #>> '{}') COLLATE "C" <= (v_with #>> '{}')
        WHEN 'between'  THEN (v_value #>> '{}') COLLATE "C" BETWEEN (v_with ->> 0) AND (v_with ->> 1)
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- A page of the items, by name, each with its stock total. Lists
-- page by key: p_after is the last item of the page before (NULL: the first
-- page), and the answer is {rows, more, next}, next being the item to give
-- as p_after for the next page when there is more. There is no total.
-- Optional:
--   p_class   only items in this class or the classes below it
--   p_search  words; each must occur, letter case ignored, in the item's
--             search text: its name, the names of the classes in its path,
--             and its text, url and choice values (item.search)
--   p_where   attribute filters by name, all of which must pass
--             (item.check_filters); one passes when the item's values do,
--             or one of its stock rows' values
-- The items are read in name order (item_name_idx) until the page
-- is full, so a page of a list that most items pass costs little, and one
-- that few pass reads more of the items.
CREATE FUNCTION item.list(
    p_request public.request,
    p_class   uuid    DEFAULT NULL,
    p_search  text    DEFAULT NULL,
    p_where   jsonb   DEFAULT NULL,
    p_limit   integer DEFAULT 100,
    p_after   uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_words   text[] := ARRAY(SELECT DISTINCT w
                              FROM regexp_split_to_table(lower(btrim(coalesce(p_search, ''))), '\s+') w
                              WHERE w <> '');
    v_filters jsonb := item.check_filters(p_where);
    v_after   text;
BEGIN
    PERFORM util.check_limit(p_limit);
    IF p_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.class c
                                           WHERE c.id = p_class) THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    IF p_after IS NOT NULL THEN
        SELECT i.name INTO v_after FROM public.item i WHERE i.id = p_after;
        IF NOT FOUND THEN
            PERFORM error.invalid('The item to list after isn''t there any more; start from the first page');
        END IF;
    END IF;

    RETURN (
        WITH RECURSIVE subtree (id) AS (
            SELECT p_class WHERE p_class IS NOT NULL
            UNION ALL
            SELECT c.id FROM public.class c JOIN subtree s ON c.parent = s.id
        ),
        page AS (
            SELECT i.id, row_number() OVER (ORDER BY i.name COLLATE public.natural, i.id) AS n
            FROM (SELECT i.id, i.name FROM public.item i
                  WHERE (p_class IS NULL OR i.class IN (SELECT id FROM subtree))
                    AND (p_after IS NULL
                         OR i.name COLLATE public.natural >= v_after
                            AND (i.name COLLATE public.natural > v_after OR i.id > p_after))
                    AND NOT EXISTS (SELECT 1 FROM unnest(v_words) w WHERE strpos(i.search, w) = 0)
                    AND NOT EXISTS (
                            SELECT 1 FROM jsonb_array_elements(v_filters) f
                            WHERE NOT item.matches(i.values, f)
                              AND NOT EXISTS (SELECT 1 FROM public.stock s
                                              WHERE s.item = i.id AND item.matches(s.values, f)))
                  ORDER BY i.name COLLATE public.natural, i.id
                  LIMIT p_limit + 1) i
        ),
        totals AS (
            SELECT s.item, sum(s.amount) AS total, bool_or(s.amount IS NULL) AS uncounted
            FROM public.stock s
            WHERE s.item IN (SELECT id FROM page WHERE n <= p_limit)
            GROUP BY s.item
        )
        SELECT jsonb_build_object(
            'rows', coalesce((
                SELECT jsonb_agg(item.json(i) || jsonb_build_object(
                           'stock', jsonb_build_object('total',     coalesce(t.total, 0),
                                                       'uncounted', coalesce(t.uncounted, false)))
                       ORDER BY p.n)
                FROM page p
                JOIN public.item i ON i.id = p.id
                LEFT JOIN totals t ON t.item = p.id
                WHERE p.n <= p_limit), '[]'),
            'more', EXISTS (SELECT 1 FROM page WHERE n > p_limit),
            'next', CASE WHEN EXISTS (SELECT 1 FROM page WHERE n > p_limit)
                         THEN (SELECT id FROM page WHERE n = p_limit) END)
    );
END;
$$;

-- An item, as item.detail_json shows it.
CREATE FUNCTION item.get(p_request public.request, p_item uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT item.detail_json(i) INTO v_result
    FROM public.item i
    WHERE i.id = p_item;
    IF NOT FOUND THEN
        PERFORM error.not_found('item', p_item::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates an item in a class, with values for its item
-- attributes, p_values: {"Length": 100, ...} ({} for none; a JSON null
-- gives no value). Every attribute it isn't given a value for gets its
-- class's default, if it has one, and follows it; a required one without
-- a default must be given. Files are uploaded afterwards. p_unit is what its
-- stock is counted in, a label ("m"); NULL for pieces. Returns the item as
-- item.get does.
CREATE FUNCTION item.create(
    p_request public.request,
    p_class   uuid,
    p_name    text,
    p_unit    text,
    p_values  jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_name    text := util.trim_and_check(p_name);
    v_values  jsonb := util.given_values(p_values);
    v_class   public.class;
    v_checked record;
    v_item    public.item;
BEGIN
    v_class := item.class_for_write(p_class);
    PERFORM item.refuse_files(v_class, 'item', v_values);
    v_checked := class.check_values(v_values, '{}', v_class.attributes, 'item', true);
    IF v_checked.problem IS NOT NULL THEN
        PERFORM error.not_allowed(format('Item "%s" %s', v_name, v_checked.problem));
    END IF;

    INSERT INTO public.item (code, class, name, unit, values, defaulted, search)
    VALUES (util.take_codes(1), p_class, v_name, item.clean_unit(p_unit),
            v_checked.new_values, v_checked.new_defaulted,
            class.search_text(v_name, class.path_text(p_class), v_checked.new_values, v_class.attributes))
    RETURNING * INTO v_item;
    RETURN item.detail_json(v_item);
END;
$$;

-- Changes the fields of an item that p_patch has: class, name, unit (null:
-- pieces), photo (null only: a photo is uploaded), and its values: values,
-- {"<name>": <value or null>, ...}, and default, ["<name>", ...], as
-- class.patch_values says. All in one transaction, and checked together.
-- In another class, its values and its stock rows' values are checked
-- against the new class's attributes, and those that follow a default take
-- the new class's; refused if they don't fit. Its unit can't become pieces
-- while a stock row has an amount that isn't whole. Returns the item as
-- item.get does.
CREATE FUNCTION item.patch(p_request public.request, p_item uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_locked  record;
    v_item    public.item;
    v_class   public.class;
    v_unit    text;
    v_problem record;
    v_old_class uuid;
    v_changed record;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['class', 'name', 'unit', 'photo', 'values', 'default'],
                             ARRAY['class', 'name']);
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') <> 'null' THEN
        PERFORM error.invalid('A photo is uploaded; photo can only be set to null here, which removes it');
    END IF;
    v_locked := item.lock_for_write(p_item);
    v_item := v_locked.item_row;
    v_class := v_locked.class_row;
    v_old_class := v_item.class;
    IF p_patch ? 'class' AND (p_patch ->> 'class')::uuid <> v_item.class THEN
        v_class := item.class_for_write((p_patch ->> 'class')::uuid);
    END IF;
    v_unit := CASE WHEN p_patch ? 'unit' THEN item.clean_unit(p_patch ->> 'unit') ELSE v_item.unit END;
    IF v_unit IS NULL AND v_item.unit IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.stock s WHERE s.item = p_item AND s.amount <> trunc(s.amount)) THEN
        PERFORM error.not_allowed(format('Item "%s" has stock amounts that aren''t whole, so it can''t be counted in pieces',
                                         v_item.name));
    END IF;

    UPDATE public.item i
    SET class = v_class.id,
        name  = CASE WHEN p_patch ? 'name' THEN util.trim_and_check(p_patch ->> 'name') ELSE i.name END,
        unit  = v_unit,
        photo = CASE WHEN p_patch ? 'photo' THEN NULL ELSE i.photo END
    WHERE i.id = p_item
    RETURNING * INTO v_item;
    v_changed := class.patch_values(v_item.values, v_item.defaulted, v_class, 'item',
                                    p_patch -> 'values', p_patch -> 'default');
    v_item := item.store_values(v_item, v_class, v_changed.new_values, v_changed.new_defaulted);
    IF v_class.id = v_old_class THEN
        RETURN item.detail_json(v_item);
    END IF;

    -- In another class: its stock rows too, against the class it is in now.
    SELECT s.id, n.problem INTO v_problem
    FROM public.stock s
    CROSS JOIN LATERAL class.check_values(s.values, s.defaulted, v_class.attributes, 'stock', false) n
    WHERE s.item = p_item AND n.problem IS NOT NULL
    LIMIT 1;
    IF FOUND THEN
        PERFORM error.not_allowed(format('%s %s', error.row_label('stock', v_problem.id), v_problem.problem));
    END IF;
    UPDATE public.stock s
    SET values = n.new_values, defaulted = n.new_defaulted
    FROM public.stock x
    CROSS JOIN LATERAL class.check_values(x.values, x.defaulted, v_class.attributes, 'stock', false) n
    WHERE s.id = x.id AND x.item = p_item
      AND (n.new_values <> x.values OR n.new_defaulted <> x.defaulted);
    RETURN item.detail_json(v_item);
END;
$$;

-- Deletes an item. An item with stock rows can't be
-- deleted (409): its stock goes first. The foreign key refuses the same;
-- this says what is in the way. Its files stay until "wtfd gc" finds that
-- nothing has them.
CREATE FUNCTION item.delete(p_request public.request, p_item uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_item    public.item := item.find(p_item);
BEGIN
    IF EXISTS (SELECT 1 FROM public.stock s WHERE s.item = p_item) THEN
        PERFORM error.in_use(format('Item "%s" still has stock', v_item.name),
                             'Delete its stock rows first.');
    END IF;
    DELETE FROM public.item i WHERE i.id = p_item;
END;
$$;

