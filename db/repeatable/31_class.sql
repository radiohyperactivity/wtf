-- Classes and the attributes assigned to them (schema class): their rules,
-- and the functions the API calls for them.

CREATE SCHEMA class;

-- ---------------------------------------------------------------------------
-- The attributes of a class
-- ---------------------------------------------------------------------------

-- Where the values of attribute p_attribute live for items of class
-- p_class: 'item' (on the item), 'stock' (on each stock row), or NULL when
-- the attribute isn't assigned to the class or any class above it.
--
-- An attribute can be assigned at several levels of the class tree; the
-- assignment nearest to the class decides (Drills overrides Tools). So this
-- walks up from the class, and takes the first assignment it meets. For the
-- rules that write one value; reads use class.effective_attributes.
CREATE FUNCTION class.attribute_scope(p_class uuid, p_attribute uuid)
RETURNS public.scope
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE path (class, depth) AS (
        SELECT p_class, 0
        UNION ALL
        SELECT c.parent, p.depth + 1
        FROM public.class c
        JOIN path p ON c.id = p.class
        WHERE c.parent IS NOT NULL
    )
    SELECT ca.scope
    FROM path p
    JOIN public.class_attribute ca ON ca.class = p.class AND ca.attribute = p_attribute
    ORDER BY p.depth
    LIMIT 1;
$$;

-- Every attribute that applies to each of the classes p_classes: those
-- assigned to the class itself and those assigned to any class above it.
-- Where an attribute is assigned at several levels, the assignment nearest
-- to the class decides: where its values live, whether they're required,
-- and the default. All the classes are worked out in one query.
CREATE FUNCTION class.effective_attributes(p_classes uuid[])
RETURNS TABLE (
    class           uuid,          -- one of p_classes
    attribute       uuid,
    assigned_to     uuid,          -- the class whose assignment decides
    depth           integer,       -- 0 when assigned to the class itself, 1 for its parent, …
    scope           public.scope,
    required        boolean,
    default_text    text,
    default_number  numeric,
    default_date    date,
    default_boolean boolean,
    default_option  uuid
)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE path (class, ancestor, depth) AS (
        SELECT c, c, 0 FROM unnest(p_classes) AS c
        UNION ALL
        SELECT p.class, c.parent, p.depth + 1
        FROM path p
        JOIN public.class c ON c.id = p.ancestor
        WHERE c.parent IS NOT NULL
    )
    SELECT DISTINCT ON (p.class, ca.attribute)
           p.class, ca.attribute, ca.class, p.depth, ca.scope, ca.required,
           ca.default_text, ca.default_number, ca.default_date,
           ca.default_boolean, ca.default_option
    FROM path p
    JOIN public.class_attribute ca ON ca.class = p.ancestor
    ORDER BY p.class, ca.attribute, p.depth;
$$;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- Refuses a change of the model that would leave values behind without an
-- attribute to belong to: a value on an item (or a stock row) whose
-- attribute no longer applies to the item's class, or no longer with its
-- values on the item (or on the stock rows).
--
-- Checks the live items of class p_class and of every class below it, as
-- the change affects them all. p_attribute narrows it to one attribute;
-- NULL checks every attribute. Runs after the change, so the class tree and
-- the assignments are already as they will be. The attributes of all the
-- classes in the subtree are worked out in one query.
CREATE FUNCTION class.check_values_still_apply(p_class uuid, p_attribute uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_items   bigint;
    v_example text;
BEGIN
    WITH RECURSIVE subtree (class) AS (
        SELECT p_class
        UNION
        SELECT c.id FROM public.class c JOIN subtree s ON c.parent = s.class
    ),
    applies AS (
        SELECT e.class, e.attribute, e.scope
        FROM class.effective_attributes(ARRAY(SELECT s.class FROM subtree s)) e
        WHERE p_attribute IS NULL OR e.attribute = p_attribute
    ),
    stranded AS (
        SELECT i.id, i.name
        FROM subtree s
        JOIN public.item i       ON i.class = s.class AND i.deleted IS NULL
        JOIN public.item_value v ON v.item = i.id
        LEFT JOIN applies a      ON a.class = i.class AND a.attribute = v.attribute AND a.scope = 'item'
        WHERE a.attribute IS NULL
          AND (p_attribute IS NULL OR v.attribute = p_attribute)
        UNION
        SELECT i.id, i.name
        FROM subtree s
        JOIN public.item i         ON i.class = s.class AND i.deleted IS NULL
        JOIN public.stock st       ON st.item = i.id AND st.deleted IS NULL
        JOIN public.stock_value sv ON sv.stock = st.id
        LEFT JOIN applies a        ON a.class = i.class AND a.attribute = sv.attribute AND a.scope = 'stock'
        WHERE a.attribute IS NULL
          AND (p_attribute IS NULL OR sv.attribute = p_attribute)
    )
    SELECT count(*), min(name) INTO v_items, v_example FROM stranded;

    IF v_items > 0 THEN
        RAISE EXCEPTION '% item(s) would have values without a matching attribute, such as "%"',
            v_items, v_example
            USING ERRCODE = 'check_violation',
                  HINT = 'Clear those values first.';
    END IF;
END;
$$;

-- Assigning an attribute to a class, removing it from one, or changing
-- where its values live (scope).
--
-- A new assignment only matters when a class above already assigns the same
-- attribute with the other scope: the new one is nearer, so the values in
-- the subtree that followed the inherited scope would end up on the wrong
-- side (item values where the values now belong on each stock row, or the
-- other way round). Without an inherited assignment, no class in the
-- subtree that the new one decides for had the attribute before.
CREATE FUNCTION class.check_assignment_change()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF EXISTS (
            SELECT 1
            FROM public.class c
            JOIN class.effective_attributes(ARRAY[c.parent]) e ON e.attribute = NEW.attribute
            WHERE c.id = NEW.class
              AND c.parent IS NOT NULL
              AND e.scope <> NEW.scope
        ) THEN
            PERFORM class.check_values_still_apply(NEW.class, NEW.attribute);
        END IF;
    ELSE
        PERFORM class.check_values_still_apply(OLD.class, OLD.attribute);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER check_assignment_change
    AFTER INSERT OR DELETE ON public.class_attribute
    FOR EACH ROW EXECUTE FUNCTION class.check_assignment_change();

CREATE TRIGGER check_assignment_change_scope
    AFTER UPDATE OF scope ON public.class_attribute
    FOR EACH ROW
    WHEN (OLD.scope <> NEW.scope)
    EXECUTE FUNCTION class.check_assignment_change();

-- Moving a class to another parent: what it inherits may change.
CREATE FUNCTION class.check_move()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM class.check_values_still_apply(NEW.id, NULL);
    RETURN NULL;
END;
$$;

CREATE TRIGGER check_move
    AFTER UPDATE OF parent ON public.class
    FOR EACH ROW
    WHEN (NEW.parent IS DISTINCT FROM OLD.parent)
    EXECUTE FUNCTION class.check_move();

-- An assignment's default value must fit the attribute's datatype: a
-- 'decimal' attribute's default is in default_number, an 'integer' one's
-- is a whole number in default_number, a 'url' one's is a web address in
-- default_text, and so on (util.typed_value_fits says which). That an
-- option default is one of this attribute's own options is already ensured
-- by the foreign key (attribute, default_option). An attribute's datatype
-- never changes, so nothing needs locking.
CREATE FUNCTION class.check_default()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_attribute record;
BEGIN
    SELECT a.name, a.datatype INTO v_attribute
    FROM public.attribute a
    WHERE a.id = NEW.attribute;
    IF NOT util.typed_value_fits(v_attribute.datatype,
                                 NEW.default_text, NEW.default_number, NEW.default_date,
                                 NEW.default_boolean, NEW.default_option) THEN
        RAISE EXCEPTION 'The default value for "%" doesn''t fit its datatype (%)',
            v_attribute.name, v_attribute.datatype
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_default
    BEFORE INSERT ON public.class_attribute
    FOR EACH ROW
    WHEN (num_nonnulls(NEW.default_text, NEW.default_number, NEW.default_date,
                       NEW.default_boolean, NEW.default_option) > 0)
    EXECUTE FUNCTION class.check_default();

CREATE TRIGGER check_default_change
    BEFORE UPDATE OF attribute, default_text, default_number, default_date,
                     default_boolean, default_option ON public.class_attribute
    FOR EACH ROW
    WHEN (num_nonnulls(NEW.default_text, NEW.default_number, NEW.default_date,
                       NEW.default_boolean, NEW.default_option) > 0
          AND (OLD.attribute <> NEW.attribute
               OR OLD.default_text    IS DISTINCT FROM NEW.default_text
               OR OLD.default_number  IS DISTINCT FROM NEW.default_number
               OR OLD.default_date    IS DISTINCT FROM NEW.default_date
               OR OLD.default_boolean IS DISTINCT FROM NEW.default_boolean
               OR OLD.default_option  IS DISTINCT FROM NEW.default_option))
    EXECUTE FUNCTION class.check_default();

-- A class can only become a container while it has no live items: a
-- container class holds only other classes, never items. Deleted items
-- don't count, but item.check_container refuses to restore one into a
-- container. No lock is needed: the update's own lock on the class waits
-- for any transaction that has locked it to put an item in it.
CREATE FUNCTION class.check_container()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_items bigint;
    v_one   text;
BEGIN
    IF EXISTS (SELECT 1 FROM public.item i
               WHERE i.class = NEW.id AND i.deleted IS NULL) THEN
        SELECT count(*), min(i.name) INTO v_items, v_one
        FROM public.item i
        WHERE i.class = NEW.id AND i.deleted IS NULL;
        RAISE EXCEPTION 'Class "%" can''t become a container: it has % item(s), such as "%"',
            NEW.name, v_items, v_one
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_container_change
    BEFORE UPDATE OF container ON public.class
    FOR EACH ROW
    WHEN (NEW.container AND NOT OLD.container)
    EXECUTE FUNCTION class.check_container();

-- A live class's parent must be live: a class can't be created in, moved
-- into or restored into a deleted class. util.check_live locks the parent
-- for sharing until commit, so that creating a class in a parent and, at
-- the same time, deleting that parent can't both pass; the other half is
-- class.check_deletable.
--
-- When a class is restored, its assignments come back with it, so they
-- must refer to live attributes and options too: while the class was
-- deleted, an attribute or option it uses may have been deleted as well
-- (their deletable rules only count assignments to live classes). They are
-- locked for sharing first, so that they can't be deleted while this
-- transaction restores the class.
CREATE FUNCTION class.check_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted uuid[];
BEGIN
    PERFORM util.check_live('class', NEW.parent);

    IF TG_OP = 'UPDATE' AND OLD.deleted IS NOT NULL THEN
        PERFORM 1 FROM public.attribute a
        WHERE a.id IN (SELECT ca.attribute FROM public.class_attribute ca WHERE ca.class = NEW.id)
        FOR SHARE;
        PERFORM 1 FROM public.attribute_option o
        WHERE o.id IN (SELECT ca.default_option FROM public.class_attribute ca WHERE ca.class = NEW.id)
        FOR SHARE;

        SELECT array_agg(ca.attribute) INTO v_deleted
        FROM public.class_attribute ca
        JOIN public.attribute a             ON a.id = ca.attribute
        LEFT JOIN public.attribute_option o ON o.id = ca.default_option
        WHERE ca.class = NEW.id
          AND (a.deleted IS NOT NULL OR o.deleted IS NOT NULL);
        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'Class "%" can''t be restored: its assignments of % refer to deleted attributes or options',
                NEW.name, error.attribute_names(v_deleted)
                USING ERRCODE = 'object_not_in_prerequisite_state',
                      HINT = 'Restore those attributes or options first.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_live
    BEFORE INSERT ON public.class
    FOR EACH ROW
    WHEN (NEW.parent IS NOT NULL)
    EXECUTE FUNCTION class.check_live();

CREATE TRIGGER check_live_change
    BEFORE UPDATE OF parent, deleted ON public.class
    FOR EACH ROW
    WHEN ((NEW.parent IS NOT NULL AND OLD.parent IS DISTINCT FROM NEW.parent)
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION class.check_live();

-- An assignment's class, attribute and default option must be live. An
-- assignment has no deleted of its own: it belongs to its class, and comes
-- back with it (class.check_live checks it then).
CREATE FUNCTION class.check_assignment_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('class', NEW.class);
    PERFORM util.check_live('attribute', NEW.attribute);
    PERFORM util.check_live('attribute_option', NEW.default_option);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_assignment_live
    BEFORE INSERT ON public.class_attribute
    FOR EACH ROW EXECUTE FUNCTION class.check_assignment_live();

CREATE TRIGGER check_assignment_live_change
    BEFORE UPDATE OF class, attribute, default_option ON public.class_attribute
    FOR EACH ROW
    WHEN (OLD.class <> NEW.class
          OR OLD.attribute <> NEW.attribute
          OR OLD.default_option IS DISTINCT FROM NEW.default_option)
    EXECUTE FUNCTION class.check_assignment_live();

-- A class can only be deleted while nothing live depends on it: no live
-- subclasses and no live items. Deleting a whole tree (class.delete_tree)
-- deletes the deepest classes first, so each one is empty when its turn
-- comes. Raised as restrict_violation, as a foreign key would.
--
-- Creating a subclass or an item locks the class for sharing until commit
-- (util.check_live). This update locks the class too, so it waits for
-- them to commit, and then sees what they added.
CREATE FUNCTION class.check_deletable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.class c
               WHERE c.parent = NEW.id AND c.deleted IS NULL) THEN
        RAISE EXCEPTION 'Class "%" still has subclasses', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM public.item i
               WHERE i.class = NEW.id AND i.deleted IS NULL) THEN
        RAISE EXCEPTION 'Class "%" still has items', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_deletable
    BEFORE UPDATE OF deleted ON public.class
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION class.check_deletable();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A class as the API shows it, from its row, its photo's JSON
-- (attachment.json) and what its deleted says (util.deleted_json; NULL for
-- a live class).
CREATE FUNCTION class.json(p_class public.class, p_photo jsonb, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_class.id,
        'name',      p_class.name,
        'parent',    p_class.parent,
        'container', p_class.container,
        'photo',     p_photo,
        'deleted',   p_deleted
    );
$$;

-- [{id, name}, ...] from the top class down to and including p_class: one
-- walk up the tree.
CREATE FUNCTION class.path_json(p_class uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up (id, parent, name, depth) AS (
        SELECT c.id, c.parent, c.name, 0 FROM public.class c WHERE c.id = p_class
        UNION ALL
        SELECT c.id, c.parent, c.name, u.depth + 1
        FROM public.class c JOIN up u ON c.id = u.parent
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) ORDER BY depth DESC), '[]')
    FROM up;
$$;

-- The attributes that apply to class p_class, by name: each attribute, the
-- class its nearest assignment is on (assigned_to) and whether that is
-- inherited, whether its values are on the item or on each stock row
-- (scope), whether required, its default, and how a number default is shown
-- (in the unit that suits it, among tenant p_tenant's). One walk up the
-- tree (class.effective_attributes).
CREATE FUNCTION class.attributes_json(p_tenant uuid, p_class uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'attribute',       attribute.json(a, NULL),
               'assigned_to',     e.assigned_to,
               'inherited',       e.depth > 0,
               'scope',           e.scope,
               'required',        e.required,
               'default',         util.typed_value_json(a.datatype, e.default_text, e.default_number,
                                                        e.default_date, e.default_boolean, o),
               'default_display', CASE WHEN d.unit IS NOT NULL
                                       THEN jsonb_build_object('value', d.value, 'unit', d.unit) END)
           ORDER BY a.name COLLATE public.natural, a.id), '[]')
    FROM class.effective_attributes(ARRAY[p_class]) e
    JOIN public.attribute a ON a.id = e.attribute
    LEFT JOIN public.attribute_option o ON o.id = e.default_option
    LEFT JOIN LATERAL unit.display(p_tenant, e.default_number, a.unit, a.unit_lock) d ON true;
$$;

-- A class as class.get shows it: its path from the top, its photo, its live
-- attachments (the photo first, then by title), and the attributes that
-- apply to it. Shared by the functions that return a class after changing
-- it.
CREATE FUNCTION class.detail_json(p_tenant uuid, p_class public.class, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT class.json(p_class, attachment.json(ph, NULL), p_deleted) || jsonb_build_object(
               'path',        class.path_json(p_class.id),
               'attributes',  class.attributes_json(p_tenant, p_class.id),
               'attachments', attachment.list_json(p_class.photo, (
                                  SELECT array_agg(a ORDER BY a.title COLLATE public.natural, a.id)
                                  FROM public.attachment a
                                  WHERE a.class = p_class.id AND a.deleted IS NULL)))
    FROM (SELECT) one
    LEFT JOIN public.attachment ph ON ph.id = p_class.photo;
$$;

-- Refuses p_name for a class below p_parent (NULL: at the top) when a live
-- sibling has it already, letter case ignored; p_class is the class being
-- renamed or moved, which doesn't count (NULL when creating). The unique
-- index class_tenant_parent_name_unique refuses the same; this says it
-- clearly.
CREATE FUNCTION class.check_sibling_name(p_tenant uuid, p_parent uuid, p_name text, p_class uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.class c
               WHERE c.tenant = p_tenant
                 AND c.parent IS NOT DISTINCT FROM p_parent
                 AND lower(c.name) = lower(p_name)
                 AND c.id IS DISTINCT FROM p_class
                 AND c.deleted IS NULL) THEN
        PERFORM error.duplicate(format('There is a class "%s" there already', p_name));
    END IF;
END;
$$;

-- Restores class p_class, if it is deleted, and every deleted class above
-- it, from the top down: only that chain, not what else was deleted with
-- them. One statement per class, as each must find its parent live.
CREATE FUNCTION class.restore_parents(p_class uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_class uuid;
BEGIN
    FOR v_class IN
        WITH RECURSIVE up (id, parent, depth) AS (
            SELECT c.id, c.parent, 0 FROM public.class c
            WHERE c.id = p_class AND c.deleted IS NOT NULL
            UNION ALL
            SELECT c.id, c.parent, u.depth + 1
            FROM public.class c JOIN up u ON c.id = u.parent
            WHERE c.deleted IS NOT NULL
        )
        SELECT id FROM up ORDER BY depth DESC
    LOOP
        UPDATE public.class c SET deleted = NULL WHERE c.id = v_class;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- The tenant's class tree, flat: every live class with its parent, by name,
-- with its photo. p_known_version is the tree's version the client has, if
-- any; when nothing has changed since, only {version, unchanged: true}
-- comes back. wtfd nests the classes into a tree.
CREATE FUNCTION class.list(p_request public.request, p_known_version bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_version bigint;
BEGIN
    v_version := coalesce((SELECT v.version FROM public.data_version v
                           WHERE v.tenant = v_session.tenant AND v.name = 'class'), 1);
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;

    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'nodes', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'id',        c.id,
                       'name',      c.name,
                       'parent',    c.parent,
                       'container', c.container,
                       'photo',     attachment.json(ph, NULL))
                   ORDER BY c.name COLLATE public.natural, c.id), '[]')
            FROM public.class c
            LEFT JOIN public.attachment ph ON ph.id = c.photo
            WHERE c.tenant = v_session.tenant AND c.deleted IS NULL));
END;
$$;

-- One of the tenant's classes: its path from the top, its photo, its live
-- attachments, and every attribute that applies to it, its own and those it
-- inherits, each from its nearest assignment, with its default and how the
-- default is shown. A deleted class is returned too, saying when and by
-- whom it was deleted.
CREATE FUNCTION class.get(p_request public.request, p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT class.detail_json(v_session.tenant, c, util.deleted_json(d, db)) INTO v_result
    FROM public.class c
    LEFT JOIN public.action d   ON d.id = c.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE c.id = p_class AND c.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates a class in the tenant, below p_parent (NULL: at the top). Its
-- name can't contain "/" (it separates the names in a path), and must not
-- be one of its live siblings' already (letter case ignored). A container
-- holds only other classes, never items. For admins.
CREATE FUNCTION class.create(
    p_request   public.request,
    p_name      text,
    p_parent    uuid,
    p_container boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_name    text := util.trim_and_check_path_name(p_name, 'class');
    v_class   public.class;
BEGIN
    IF p_container IS NULL THEN
        PERFORM error.invalid('Say whether the class is a container');
    END IF;
    IF p_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.class c
                                            WHERE c.id = p_parent AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('class', p_parent);
    END IF;
    PERFORM class.check_sibling_name(v_session.tenant, p_parent, v_name, NULL);

    PERFORM util.begin_action(v_session);
    INSERT INTO public.class (tenant, name, parent, container)
    VALUES (v_session.tenant, v_name, p_parent, p_container)
    RETURNING * INTO v_class;
    RETURN class.detail_json(v_session.tenant, v_class, NULL);
END;
$$;

-- Changes the fields of one of the tenant's live classes that p_patch has:
-- name, parent (null: to the top), container, and photo (the id of one of
-- its own image attachments, or null). The rules refuse a move into one of
-- its own subclasses, a move that would leave items with values for
-- attributes that no longer apply, and becoming a container while it has
-- live items. Returns the class as class.get does. For admins.
CREATE FUNCTION class.patch(p_request public.request, p_class uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_name    text;
    v_parent  uuid;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['name', 'parent', 'container', 'photo'],
                             ARRAY['name', 'container']);
    SELECT c.* INTO v_class
    FROM public.class c
    WHERE c.id = p_class AND c.tenant = v_session.tenant AND c.deleted IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;

    v_name   := CASE WHEN p_patch ? 'name'
                     THEN util.trim_and_check_path_name(p_patch ->> 'name', 'class')
                     ELSE v_class.name END;
    v_parent := CASE WHEN p_patch ? 'parent' THEN (p_patch ->> 'parent')::uuid
                     ELSE v_class.parent END;
    IF v_parent IS DISTINCT FROM v_class.parent AND v_parent IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.class c
                       WHERE c.id = v_parent AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('class', v_parent);
    END IF;
    IF v_name IS DISTINCT FROM v_class.name OR v_parent IS DISTINCT FROM v_class.parent THEN
        PERFORM class.check_sibling_name(v_session.tenant, v_parent, v_name, p_class);
    END IF;
    IF p_patch ? 'photo' AND jsonb_typeof(p_patch -> 'photo') NOT IN ('string', 'null') THEN
        PERFORM error.invalid('photo must be the id of an attachment, or null');
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.class c
    SET name      = v_name,
        parent    = v_parent,
        container = coalesce((p_patch ->> 'container')::boolean, c.container),
        photo     = CASE WHEN p_patch ? 'photo' THEN (p_patch ->> 'photo')::uuid ELSE c.photo END
    WHERE c.id = p_class
    RETURNING * INTO v_class;
    RETURN class.detail_json(v_session.tenant, v_class, NULL);
END;
$$;

-- Deletes one of the tenant's classes on its own: it is marked deleted, by
-- this call's action. A class with live subclasses or live items can't be
-- deleted this way (409; the rule class.check_deletable says which):
-- class.delete_tree deletes a class with everything below it. For admins.
CREATE FUNCTION class.delete(p_request public.request, p_class uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.class c
    SET deleted = v_action
    WHERE c.id = p_class AND c.tenant = v_session.tenant AND c.deleted IS NULL;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
END;
$$;

-- Deletes one of the tenant's live classes with every live class below it,
-- all by this call's one action. While any of them has live items, nothing
-- is deleted (409, naming the classes and how many items each has), unless
-- p_force: then those items are deleted too, with their live stock rows.
-- With p_dry_run nothing is deleted, and only what would be is returned:
--   {classes: [{id, path}], items: [{id, code, name, class}], stock: <count>}
-- the classes deepest first, the items by name. For admins.
CREATE FUNCTION class.delete_tree(
    p_request public.request,
    p_class   uuid,
    p_force   boolean,
    p_dry_run boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_deleted uuid;
    v_items   uuid[];
    v_result  jsonb;
    v_action  uuid;
    v_depth   integer;
BEGIN
    IF p_force IS NULL OR p_dry_run IS NULL THEN
        PERFORM error.invalid('Say whether to force the delete, and whether it is a dry run');
    END IF;
    SELECT c.deleted INTO v_deleted
    FROM public.class c
    WHERE c.id = p_class AND c.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    IF v_deleted IS NOT NULL THEN
        PERFORM error.deleted('class', p_class);
    END IF;

    -- The class and its live subtree, each with its path and depth: the
    -- top's path is worked out once, and each class below adds its name.
    -- Dropped first, so that a second call in one transaction works.
    DROP TABLE IF EXISTS pg_temp.tree;
    CREATE TEMPORARY TABLE pg_temp.tree ON COMMIT DROP AS
    WITH RECURSIVE below (id, name, path, depth) AS (
        SELECT c.id, c.name, util.path_text(class.path_json(c.id)), 0
        FROM public.class c WHERE c.id = p_class
        UNION ALL
        SELECT c.id, c.name, b.path || '/' || c.name, b.depth + 1
        FROM public.class c JOIN below b ON c.parent = b.id
        WHERE c.deleted IS NULL
    )
    SELECT * FROM below;

    v_items := ARRAY(SELECT i.id FROM public.item i
                     WHERE i.class IN (SELECT t.id FROM pg_temp.tree t) AND i.deleted IS NULL);

    v_result := jsonb_build_object(
        'classes', (SELECT jsonb_agg(jsonb_build_object('id', t.id, 'path', t.path)
                                     ORDER BY t.depth DESC, t.id)
                    FROM pg_temp.tree t),
        'items',   (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                'id', i.id, 'code', util.code_text(i.code), 'name', i.name, 'class', i.class)
                            ORDER BY i.name COLLATE public.natural, i.id), '[]')
                    FROM public.item i WHERE i.id = ANY (v_items)),
        'stock',   (SELECT count(*) FROM public.stock s
                    WHERE s.item = ANY (v_items) AND s.deleted IS NULL));

    IF p_dry_run THEN
        RETURN v_result;
    END IF;
    IF cardinality(v_items) > 0 AND NOT p_force THEN
        PERFORM error.in_use(
            'These classes still have items: ' || (
                SELECT string_agg(format('%s (%s %s)', t.path, n.count,
                                         CASE WHEN n.count = 1 THEN 'item' ELSE 'items' END),
                                  ', ' ORDER BY t.path COLLATE public.natural)
                FROM (SELECT i.class, count(*) FROM public.item i
                      WHERE i.id = ANY (v_items) GROUP BY i.class) n
                JOIN pg_temp.tree t ON t.id = n.class),
            'Delete the items first, or force the delete to delete them too.');
    END IF;

    v_action := util.begin_action(v_session);
    UPDATE public.stock s SET deleted = v_action WHERE s.item = ANY (v_items) AND s.deleted IS NULL;
    UPDATE public.item i SET deleted = v_action WHERE i.id = ANY (v_items);
    -- One level at a time, deepest first, so that no class is deleted while
    -- a live class below it still refers to it.
    FOR v_depth IN SELECT DISTINCT t.depth FROM pg_temp.tree t ORDER BY t.depth DESC LOOP
        UPDATE public.class c SET deleted = v_action
        WHERE c.id IN (SELECT t.id FROM pg_temp.tree t WHERE t.depth = v_depth);
    END LOOP;
    RETURN v_result;
END;
$$;

-- Restores a deleted class of the tenant, with what was deleted together
-- with it, by the same action: the classes below it, their items, and those
-- items' stock rows (never rows merged into another by a move). p_options,
-- each optional:
--   name          a new name, for when a sibling has taken its name since
--   parent        where to restore it instead (null: at the top)
--   with_parents  true: also restore the deleted classes it is in, from the
--                 top down, whatever action deleted each
-- A class whose parent is deleted can't be restored without parent or
-- with_parents (409, naming both ways out). Returns the class as class.get
-- does. For admins.
CREATE FUNCTION class.restore(p_request public.request, p_class uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
    v_action  uuid;              -- the action that deleted the class
    v_parent  uuid;
    v_name    text;
    v_level   uuid[];
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name', 'parent', 'with_parents'],
                             ARRAY['name', 'with_parents']);
    SELECT c.* INTO v_class
    FROM public.class c
    WHERE c.id = p_class AND c.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    IF v_class.deleted IS NULL THEN
        PERFORM error.not_deleted('class', p_class);
    END IF;
    v_action := v_class.deleted;

    v_parent := CASE WHEN p_options ? 'parent' THEN (p_options ->> 'parent')::uuid
                     ELSE v_class.parent END;
    v_name   := CASE WHEN p_options ? 'name'
                     THEN util.trim_and_check_path_name(p_options ->> 'name', 'class')
                     ELSE v_class.name END;
    IF v_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.class c
                                            WHERE c.id = v_parent AND c.tenant = v_session.tenant) THEN
        PERFORM error.bad_reference('class', v_parent);
    END IF;

    PERFORM util.begin_action(v_session);

    -- The deleted classes above it, if they are to come back too.
    IF v_parent IS NOT NULL
       AND (SELECT c.deleted FROM public.class c WHERE c.id = v_parent) IS NOT NULL THEN
        IF p_options ? 'parent' THEN
            PERFORM error.deleted('class', v_parent);
        ELSIF NOT coalesce((p_options ->> 'with_parents')::boolean, false) THEN
            PERFORM error.restore_into_deleted(error.row_label('class', p_class),
                format('"%s"', util.path_text(class.path_json(v_parent))), 'parent');
        END IF;
        PERFORM class.restore_parents(v_parent);
    END IF;

    PERFORM class.check_sibling_name(v_session.tenant, v_parent, v_name, p_class);
    UPDATE public.class c SET deleted = NULL, name = v_name, parent = v_parent
    WHERE c.id = p_class;

    -- What went with it, one level of classes at a time, from the top down,
    -- so that each class's parent is live when its rule checks.
    v_level := ARRAY[p_class];
    LOOP
        v_level := ARRAY(SELECT c.id FROM public.class c
                         WHERE c.parent = ANY (v_level) AND c.deleted = v_action);
        EXIT WHEN cardinality(v_level) = 0;
        UPDATE public.class c SET deleted = NULL WHERE c.id = ANY (v_level);
    END LOOP;
    UPDATE public.item i SET deleted = NULL
    WHERE i.deleted = v_action;
    UPDATE public.stock s SET deleted = NULL
    WHERE s.deleted = v_action AND s.merged_into IS NULL;

    SELECT c.* INTO v_class FROM public.class c WHERE c.id = p_class;
    RETURN class.detail_json(v_session.tenant, v_class, NULL);
END;
$$;

-- Assigns one of the tenant's attributes to one of its live classes, or
-- changes the assignment if there is one: p_default is its default value as
-- JSON (JSON null: none), p_scope says whether its values are on the item
-- or on each stock row, and p_required makes new items, or new stock rows,
-- need a value unless there is a default. The rules refuse a change of
-- scope, or a new assignment overriding an inherited one's scope, while
-- values depend on it. Returns the class as class.get does. For admins.
CREATE FUNCTION class.assign(
    p_request   public.request,
    p_class     uuid,
    p_attribute uuid,
    p_default   jsonb,
    p_scope     public.scope,
    p_required  boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session   record := util.session(p_request, 'admin');
    v_class     public.class;
    v_attribute public.attribute;
    v_default   record;
BEGIN
    IF p_scope IS NULL OR p_required IS NULL THEN
        PERFORM error.invalid('An assignment needs its scope (item or stock), and whether it is required');
    END IF;
    SELECT c.* INTO v_class FROM public.class c
    WHERE c.id = p_class AND c.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;
    SELECT a.* INTO v_attribute FROM public.attribute a
    WHERE a.id = p_attribute AND a.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.bad_reference('attribute', p_attribute);
    END IF;
    IF p_default IS NOT NULL AND jsonb_typeof(p_default) <> 'null' THEN
        SELECT * INTO v_default FROM attribute.parse_value(v_attribute, p_default);
    ELSE
        SELECT NULL::text AS text, NULL::numeric AS number, NULL::date AS date,
               NULL::boolean AS boolean, NULL::uuid AS option
        INTO v_default;
    END IF;

    PERFORM util.begin_action(v_session);
    INSERT INTO public.class_attribute (class, attribute, scope, required,
                                        default_text, default_number, default_date,
                                        default_boolean, default_option)
    VALUES (p_class, p_attribute, p_scope, p_required,
            v_default.text, v_default.number, v_default.date,
            v_default.boolean, v_default.option)
    ON CONFLICT (class, attribute) DO UPDATE SET
        scope           = EXCLUDED.scope,
        required        = EXCLUDED.required,
        default_text    = EXCLUDED.default_text,
        default_number  = EXCLUDED.default_number,
        default_date    = EXCLUDED.default_date,
        default_boolean = EXCLUDED.default_boolean,
        default_option  = EXCLUDED.default_option;
    RETURN class.detail_json(v_session.tenant, v_class, NULL);
END;
$$;

-- Takes an attribute's assignment off one of the tenant's live classes. The
-- rules refuse it while live items in the class, or in the classes below
-- it, have values that depend on it, and say how many. An attribute that is
-- inherited from a class above stays, by that class's assignment. Returns
-- the class as class.get does. For admins.
CREATE FUNCTION class.unassign(p_request public.request, p_class uuid, p_attribute uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_class   public.class;
BEGIN
    SELECT c.* INTO v_class FROM public.class c
    WHERE c.id = p_class AND c.tenant = v_session.tenant AND c.deleted IS NULL;
    IF NOT FOUND THEN
        PERFORM error.not_found('class', p_class::text);
    END IF;

    PERFORM util.begin_action(v_session);
    DELETE FROM public.class_attribute ca
    WHERE ca.class = p_class AND ca.attribute = p_attribute;
    IF NOT FOUND THEN
        PERFORM error.not_found('assignment',
            format('of attribute %s to class "%s"', p_attribute, v_class.name));
    END IF;
    RETURN class.detail_json(v_session.tenant, v_class, NULL);
END;
$$;
