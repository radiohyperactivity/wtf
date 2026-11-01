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
