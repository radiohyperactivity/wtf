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
