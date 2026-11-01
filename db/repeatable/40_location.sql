-- Locations (schema location): their rules, and the functions the API
-- calls for them.

CREATE SCHEMA location;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- A location can only become a container while it has no live stock: a
-- container location holds only other locations, never stock. Deleted
-- stock rows don't count, but stock.check_container refuses to restore one
-- into a container. No lock is needed: the update's own lock on the
-- location waits for any transaction that has locked it to put stock in it.
CREATE FUNCTION location.check_container()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_rows bigint;
    v_one  uuid;
BEGIN
    IF EXISTS (SELECT 1 FROM public.stock s
               WHERE s.location = NEW.id AND s.deleted IS NULL) THEN
        -- min() of the ids as text just picks one row; uuid has no min().
        SELECT count(*), min(s.id::text)::uuid INTO v_rows, v_one
        FROM public.stock s
        WHERE s.location = NEW.id AND s.deleted IS NULL;
        RAISE EXCEPTION 'Location "%" can''t become a container: it has % stock row(s), such as %',
            NEW.name, v_rows, error.row_label('stock', v_one)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_container_change
    BEFORE UPDATE OF container ON public.location
    FOR EACH ROW
    WHEN (NEW.container AND NOT OLD.container)
    EXECUTE FUNCTION location.check_container();

-- A live location's parent must be live: a location can't be created in,
-- moved into or restored into a deleted location. util.check_live locks the
-- parent for sharing until commit; the other half is
-- location.check_deletable.
CREATE FUNCTION location.check_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('location', NEW.parent);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_live
    BEFORE INSERT ON public.location
    FOR EACH ROW
    WHEN (NEW.parent IS NOT NULL)
    EXECUTE FUNCTION location.check_live();

CREATE TRIGGER check_live_change
    BEFORE UPDATE OF parent, deleted ON public.location
    FOR EACH ROW
    WHEN (NEW.parent IS NOT NULL
          AND (OLD.parent IS DISTINCT FROM NEW.parent
               OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL)))
    EXECUTE FUNCTION location.check_live();

-- A location can only be deleted while nothing live is in it: no live
-- locations inside it and no live stock rows. Deleting a whole tree
-- (location.delete_tree) deletes the deepest locations first.
CREATE FUNCTION location.check_deletable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.location l
               WHERE l.parent = NEW.id AND l.deleted IS NULL) THEN
        RAISE EXCEPTION 'Location "%" still has locations inside it', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock s
               WHERE s.location = NEW.id AND s.deleted IS NULL) THEN
        RAISE EXCEPTION 'Location "%" still has stock', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_deletable
    BEFORE UPDATE OF deleted ON public.location
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION location.check_deletable();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A location as the API shows it, from its row, its photo's JSON and what
-- its deleted says (NULL for a live location). Its code is for its label.
CREATE FUNCTION location.json(p_location public.location, p_photo jsonb, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_location.id,
        'code',      util.code_text(p_location.code),
        'name',      p_location.name,
        'parent',    p_location.parent,
        'container', p_location.container,
        'photo',     p_photo,
        'deleted',   p_deleted
    );
$$;

-- [{id, name}, ...] from the top location down to and including
-- p_location: one walk up the tree.
CREATE FUNCTION location.path_json(p_location uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up (id, parent, name, depth) AS (
        SELECT l.id, l.parent, l.name, 0 FROM public.location l WHERE l.id = p_location
        UNION ALL
        SELECT l.id, l.parent, l.name, u.depth + 1
        FROM public.location l JOIN up u ON l.id = u.parent
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) ORDER BY depth DESC), '[]')
    FROM up;
$$;

-- A location as location.get shows it: its path, photo and live
-- attachments (the photo first, then by title). Shared by the functions
-- that return a location after changing it.
CREATE FUNCTION location.detail_json(p_location public.location, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT location.json(p_location, attachment.json(ph, NULL), p_deleted) || jsonb_build_object(
        'path',        location.path_json(p_location.id),
        'attachments', attachment.list_json(p_location.photo, (
                           SELECT array_agg(a ORDER BY a.title COLLATE public.natural, a.id)
                           FROM public.attachment a
                           WHERE a.location = p_location.id AND a.deleted IS NULL)))
    FROM (SELECT) one
    LEFT JOIN public.attachment ph ON ph.id = p_location.photo;
$$;

-- Refuses p_name for a location below p_parent (NULL: at the top) when a
-- live sibling has it already, letter case ignored; p_location is the
-- location being renamed or moved, which doesn't count (NULL when
-- creating).
CREATE FUNCTION location.check_sibling_name(p_tenant uuid, p_parent uuid, p_name text, p_location uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.location l
               WHERE l.tenant = p_tenant
                 AND l.parent IS NOT DISTINCT FROM p_parent
                 AND lower(l.name) = lower(p_name)
                 AND l.id IS DISTINCT FROM p_location
                 AND l.deleted IS NULL) THEN
        PERFORM error.duplicate(format('There is a location "%s" there already', p_name));
    END IF;
END;
$$;

-- Restores location p_location, if it is deleted, and every deleted
-- location above it, from the top down: only that chain. One statement per
-- location, as each must find its parent live.
CREATE FUNCTION location.restore_parents(p_location uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_location uuid;
BEGIN
    FOR v_location IN
        WITH RECURSIVE up (id, parent, depth) AS (
            SELECT l.id, l.parent, 0 FROM public.location l
            WHERE l.id = p_location AND l.deleted IS NOT NULL
            UNION ALL
            SELECT l.id, l.parent, u.depth + 1
            FROM public.location l JOIN up u ON l.id = u.parent
            WHERE l.deleted IS NOT NULL
        )
        SELECT id FROM up ORDER BY depth DESC
    LOOP
        UPDATE public.location l SET deleted = NULL WHERE l.id = v_location;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- The tenant's location tree, flat: every live location with its parent,
-- code, name and photo, by name. p_known_version is the tree's version the
-- client has, if any; when nothing has changed since, only {version,
-- unchanged: true} comes back. wtfd nests the locations into a tree.
CREATE FUNCTION location.list(p_request public.request, p_known_version bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_version bigint;
BEGIN
    v_version := coalesce((SELECT v.version FROM public.data_version v
                           WHERE v.tenant = v_session.tenant AND v.name = 'location'), 1);
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;

    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'nodes', (
            SELECT coalesce(jsonb_agg(location.json(l, attachment.json(ph, NULL), NULL)
                                      ORDER BY l.name COLLATE public.natural, l.id), '[]')
            FROM public.location l
            LEFT JOIN public.attachment ph ON ph.id = l.photo
            WHERE l.tenant = v_session.tenant AND l.deleted IS NULL));
END;
$$;

-- One of the tenant's locations: its code, its path from the top, its photo
-- and its live attachments. A deleted location is returned too, saying when
-- and by whom it was deleted. What is stored there is listed by stock.list.
CREATE FUNCTION location.get(p_request public.request, p_location uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT location.detail_json(l, util.deleted_json(d, db)) INTO v_result
    FROM public.location l
    LEFT JOIN public.action d   ON d.id = l.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE l.id = p_location AND l.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates a location in the tenant, below p_parent (NULL: at the top), with
-- a code for its label. Its name can't contain "/", and must not be a live
-- sibling's already (letter case ignored). A container holds only other
-- locations, never stock.
--
-- p_columns and p_rows (both NULL for none) also create a compartment below
-- it for every cell of a grid of that many columns and rows, named like the
-- cells of a spreadsheet: columns A, B, …, Z, AA, … and rows 1 … R, so 8 × 5
-- gives A1 … H5, with codes in that order. A location with a grid is a
-- container. Nothing about the grid is stored; the compartments are
-- ordinary locations. A grid that creates more than 1000 locations must be
-- confirmed with p_confirm, so that a typo can't flood the tree. Returns the
-- location as location.get does. For admins.
CREATE FUNCTION location.create(
    p_request   public.request,
    p_name      text,
    p_parent    uuid,
    p_container boolean,
    p_columns   integer,
    p_rows      integer,
    p_confirm   boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'admin');
    v_name     text := util.trim_and_check_path_name(p_name, 'location');
    v_code     bigint;
    v_location public.location;
BEGIN
    IF p_container IS NULL THEN
        PERFORM error.invalid('Say whether the location is a container');
    END IF;
    IF p_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.location l
                                            WHERE l.id = p_parent AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', p_parent);
    END IF;
    PERFORM location.check_sibling_name(v_session.tenant, p_parent, v_name, NULL);
    IF (p_columns IS NULL) <> (p_rows IS NULL) THEN
        PERFORM error.invalid('A grid needs both its columns and its rows');
    END IF;
    IF p_columns < 1 OR p_rows < 1 THEN
        PERFORM error.invalid('A grid needs at least 1 column and 1 row');
    END IF;
    IF p_columns::bigint * p_rows + 1 > 1000 AND NOT coalesce(p_confirm, false) THEN
        PERFORM error.invalid(format('This grid creates %s locations; confirm it', p_columns::bigint * p_rows + 1));
    END IF;

    PERFORM util.begin_action(v_session);
    v_code := tenant.take_codes(v_session.tenant, 1 + coalesce(p_columns * p_rows, 0));
    INSERT INTO public.location (tenant, code, name, parent, container)
    VALUES (v_session.tenant, v_code, v_name, p_parent, p_container OR p_columns IS NOT NULL)
    RETURNING * INTO v_location;

    -- The compartments, coded in the order of the cells: A1, A2, …, B1, …
    -- With no grid, generate_series(1, NULL) gives no rows.
    INSERT INTO public.location (tenant, code, name, parent, container)
    SELECT v_session.tenant, v_code + g.n, g.name, v_location.id, false
    FROM (SELECT util.column_label(c) || r AS name, row_number() OVER (ORDER BY c, r) AS n
          FROM generate_series(1, p_columns) c CROSS JOIN generate_series(1, p_rows) r) g;

    RETURN location.detail_json(v_location, NULL);
END;
$$;

-- Changes the fields of one of the tenant's live locations that p_patch
-- has: name, parent (null: to the top), container, and photo (the id of one
-- of its own image attachments, or null). Moving a location takes
-- everything in and below it along. The rules refuse a move into one of its
-- own locations, and becoming a container while it has live stock. Returns
-- the location as location.get does. For admins.
CREATE FUNCTION location.patch(p_request public.request, p_location uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'admin');
    v_location public.location;
    v_name     text;
    v_parent   uuid;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['name', 'parent', 'container', 'photo'],
                             ARRAY['name', 'container']);
    SELECT l.* INTO v_location
    FROM public.location l
    WHERE l.id = p_location AND l.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;
    IF v_location.deleted IS NOT NULL THEN
        PERFORM error.deleted('location', p_location);
    END IF;

    v_name   := CASE WHEN p_patch ? 'name'
                     THEN util.trim_and_check_path_name(p_patch ->> 'name', 'location')
                     ELSE v_location.name END;
    v_parent := CASE WHEN p_patch ? 'parent' THEN (p_patch ->> 'parent')::uuid
                     ELSE v_location.parent END;
    IF v_parent IS DISTINCT FROM v_location.parent AND v_parent IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.location l
                       WHERE l.id = v_parent AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', v_parent);
    END IF;
    IF v_name IS DISTINCT FROM v_location.name OR v_parent IS DISTINCT FROM v_location.parent THEN
        PERFORM location.check_sibling_name(v_session.tenant, v_parent, v_name, p_location);
    END IF;
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') NOT IN ('string', 'null') THEN
        PERFORM error.invalid('photo must be the id of an attachment, or null');
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.location l
    SET name      = v_name,
        parent    = v_parent,
        container = coalesce((p_patch ->> 'container')::boolean, l.container),
        photo     = CASE WHEN p_patch ? 'photo' THEN (p_patch ->> 'photo')::uuid ELSE l.photo END
    WHERE l.id = p_location
    RETURNING * INTO v_location;
    RETURN location.detail_json(v_location, NULL);
END;
$$;

-- Deletes one of the tenant's locations on its own: it is marked deleted,
-- by this call's action. A location with live locations inside it, or live
-- stock, can't be deleted this way (409; the rule location.check_deletable
-- says which): location.delete_tree deletes a location with everything in
-- and below it. For admins.
CREATE FUNCTION location.delete(p_request public.request, p_location uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.location l
    SET deleted = v_action
    WHERE l.id = p_location AND l.tenant = v_session.tenant AND l.deleted IS NULL;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM public.location l WHERE l.id = p_location AND l.tenant = v_session.tenant) THEN
            PERFORM error.deleted('location', p_location);
        END IF;
        PERFORM error.not_found('location', p_location::text);
    END IF;
END;
$$;

-- Deletes one of the tenant's live locations with every live location below
-- it, all by this call's one action. While there is live stock in any of
-- them, nothing is deleted (409, naming the locations and how many stock
-- rows each has), unless p_force: then those stock rows are deleted too.
-- With p_dry_run nothing is deleted, and only what would be is returned:
--   {locations: [{id, code, path}],
--    stock: [{id, code, item: {id, code, name}, location, amount}]}
-- the locations deepest first, the stock rows by item name. For admins.
CREATE FUNCTION location.delete_tree(
    p_request  public.request,
    p_location uuid,
    p_force    boolean,
    p_dry_run  boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_deleted uuid;
    v_stock   uuid[];
    v_result  jsonb;
    v_action  uuid;
    v_depth   integer;
BEGIN
    IF p_force IS NULL OR p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether to force the delete, and whether it is a dry run');
    END IF;
    SELECT l.deleted INTO v_deleted
    FROM public.location l
    WHERE l.id = p_location AND l.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;
    IF v_deleted IS NOT NULL THEN
        PERFORM error.deleted('location', p_location);
    END IF;

    -- The subtree, each location with its code, path and depth. Dropped
    -- first, so that a second call in one transaction works.
    DROP TABLE IF EXISTS pg_temp.tree;
    CREATE TEMPORARY TABLE pg_temp.tree ON COMMIT DROP AS
    WITH RECURSIVE below (id, code, path, depth) AS (
        SELECT l.id, l.code, util.path_text(location.path_json(l.id)), 0
        FROM public.location l WHERE l.id = p_location
        UNION ALL
        SELECT l.id, l.code, b.path || '/' || l.name, b.depth + 1
        FROM public.location l JOIN below b ON l.parent = b.id
        WHERE l.deleted IS NULL
    )
    SELECT * FROM below;

    v_stock := ARRAY(SELECT s.id FROM public.stock s
                     WHERE s.location IN (SELECT t.id FROM pg_temp.tree t) AND s.deleted IS NULL);

    v_result := jsonb_build_object(
        'locations', (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'code', util.code_text(t.code),
                                                          'path', t.path)
                                       ORDER BY t.depth DESC, t.id)
                      FROM pg_temp.tree t),
        'stock',     (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                 'id', s.id, 'code', util.code_text(s.code),
                                 'item', jsonb_build_object('id', i.id, 'code', util.code_text(i.code),
                                                            'name', i.name),
                                 'location', s.location, 'amount', s.amount)
                             ORDER BY i.name COLLATE public.natural, s.id), '[]')
                      FROM public.stock s JOIN public.item i ON i.id = s.item
                      WHERE s.id = ANY (v_stock)));

    IF p_dry_run THEN
        RETURN v_result;
    END IF;
    IF cardinality(v_stock) > 0 AND NOT p_force THEN
        PERFORM error.in_use(
            'These locations still have stock: ' || (
                SELECT string_agg(format('%s (%s %s)', t.path, n.count,
                                         CASE WHEN n.count = 1 THEN 'stock row' ELSE 'stock rows' END),
                                  ', ' ORDER BY t.path COLLATE public.natural)
                FROM (SELECT s.location, count(*) FROM public.stock s
                      WHERE s.id = ANY (v_stock) GROUP BY s.location) n
                JOIN pg_temp.tree t ON t.id = n.location),
            'Move or delete the stock first, or force the delete to delete it too.');
    END IF;

    v_action := util.begin_action(v_session);
    UPDATE public.stock s SET deleted = v_action WHERE s.id = ANY (v_stock);
    -- One level at a time, deepest first.
    FOR v_depth IN SELECT DISTINCT t.depth FROM pg_temp.tree t ORDER BY t.depth DESC LOOP
        UPDATE public.location l SET deleted = v_action
        WHERE l.id IN (SELECT t.id FROM pg_temp.tree t WHERE t.depth = v_depth);
    END LOOP;
    RETURN v_result;
END;
$$;

-- Restores a deleted location of the tenant, with what was deleted together
-- with it, by the same action: the locations below it, and the stock rows
-- in them (never rows merged into another by a move). p_options, each
-- optional: name, parent (null: at the top), with_parents, as for
-- class.restore. Returns the location as location.get does. For admins.
CREATE FUNCTION location.restore(p_request public.request, p_location uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'admin');
    v_location public.location;
    v_action   uuid;             -- the action that deleted the location
    v_parent   uuid;
    v_name     text;
    v_level    uuid[];
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name', 'parent', 'with_parents'],
                             ARRAY['name', 'with_parents']);
    SELECT l.* INTO v_location
    FROM public.location l
    WHERE l.id = p_location AND l.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('location', p_location::text);
    END IF;
    IF v_location.deleted IS NULL THEN
        PERFORM error.not_deleted('location', p_location);
    END IF;
    v_action := v_location.deleted;

    v_parent := CASE WHEN p_options ? 'parent' THEN (p_options ->> 'parent')::uuid
                     ELSE v_location.parent END;
    v_name   := CASE WHEN p_options ? 'name'
                     THEN util.trim_and_check_path_name(p_options ->> 'name', 'location')
                     ELSE v_location.name END;
    IF v_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.location l
                                            WHERE l.id = v_parent AND l.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('location', v_parent);
    END IF;

    PERFORM util.begin_action(v_session);

    IF v_parent IS NOT NULL
       AND (SELECT l.deleted FROM public.location l WHERE l.id = v_parent) IS NOT NULL THEN
        IF p_options ? 'parent' THEN
            PERFORM error.deleted('location', v_parent);
        ELSIF NOT coalesce((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM error.restore_into_deleted(error.row_label('location', p_location),
                format('"%s"', util.path_text(location.path_json(v_parent))), 'parent');
        END IF;
        PERFORM location.restore_parents(v_parent);
    END IF;

    PERFORM location.check_sibling_name(v_session.tenant, v_parent, v_name, p_location);
    UPDATE public.location l SET deleted = NULL, name = v_name, parent = v_parent
    WHERE l.id = p_location;

    v_level := ARRAY[p_location];
    LOOP
        v_level := ARRAY(SELECT l.id FROM public.location l
                         WHERE l.parent = ANY (v_level) AND l.deleted = v_action);
        EXIT WHEN cardinality(v_level) = 0;
        UPDATE public.location l SET deleted = NULL WHERE l.id = ANY (v_level);
    END LOOP;
    UPDATE public.stock s SET deleted = NULL
    WHERE s.deleted = v_action AND s.merged_into IS NULL;

    SELECT l.* INTO v_location FROM public.location l WHERE l.id = p_location;
    RETURN location.detail_json(v_location, NULL);
END;
$$;
