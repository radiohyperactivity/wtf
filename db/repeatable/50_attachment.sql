-- Attachments (schema attachment): their rules, and the functions the API
-- calls for them. See api/attachment.md.

CREATE SCHEMA attachment;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- The key of the lock that keeps an upload and the file clean-up ("wtfd
-- gc") from working on the same file at once: an upload could otherwise
-- attach a file at the moment the clean-up removes it as unused.
--
-- PostgreSQL's advisory locks are keyed by a number, so the file's hash (64
-- hex digits) is turned into one: its first 16 hex digits, 8 bytes, read as
-- a bigint. Two different files share a key only if their hashes start
-- alike, which at worst makes one of them wait for the other. One
-- definition, as wtfd computes the same key through it.
CREATE FUNCTION attachment.file_lock_key(p_hash text)
RETURNS bigint
LANGUAGE sql IMMUTABLE AS $$
    SELECT ('x' || substr(p_hash, 1, 16))::bit(64)::bigint;
$$;

-- A live attachment's owner must be live: an attachment can't be added
-- to, moved to or restored onto a deleted item, stock row, location or
-- class. Exactly one of the four owner columns is set (the table's CHECK),
-- and util.check_live passes at once for the three that are NULL. It locks
-- the owner for sharing until commit, so that adding an attachment and, at
-- the same time, deleting its owner can't both pass.
CREATE FUNCTION attachment.check_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('item',     NEW.item);
    PERFORM util.check_live('stock',    NEW.stock);
    PERFORM util.check_live('location', NEW.location);
    PERFORM util.check_live('class',    NEW.class);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_live
    BEFORE INSERT ON public.attachment
    FOR EACH ROW EXECUTE FUNCTION attachment.check_live();

CREATE TRIGGER check_live_change
    BEFORE UPDATE OF item, stock, location, class, deleted ON public.attachment
    FOR EACH ROW
    WHEN (OLD.item     IS DISTINCT FROM NEW.item
          OR OLD.stock    IS DISTINCT FROM NEW.stock
          OR OLD.location IS DISTINCT FROM NEW.location
          OR OLD.class    IS DISTINCT FROM NEW.class
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION attachment.check_live();

-- An object's photo must be an image (its media type starts with 'image/')
-- and not deleted. That it is one of the object's own attachments is
-- already ensured by the photo's foreign key, (id, photo) to attachment
-- (item, id) and so on. Used by item, stock, location and class.
CREATE FUNCTION attachment.check_photo()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_photo record;
BEGIN
    SELECT a.media_type, a.title, a.deleted INTO v_photo
    FROM public.attachment a
    WHERE a.id = NEW.photo;
    IF v_photo.media_type NOT LIKE 'image/%' THEN
        RAISE EXCEPTION 'A photo must be an image; "%" is %', v_photo.title, v_photo.media_type
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_photo.deleted IS NOT NULL THEN
        RAISE EXCEPTION 'Attachment "%" is deleted, so it can''t be the photo', v_photo.title
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_photo
    BEFORE INSERT ON public.item
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL)
    EXECUTE FUNCTION attachment.check_photo();
CREATE TRIGGER check_photo_change
    BEFORE UPDATE OF photo ON public.item
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL AND OLD.photo IS DISTINCT FROM NEW.photo)
    EXECUTE FUNCTION attachment.check_photo();

CREATE TRIGGER check_photo
    BEFORE INSERT ON public.stock
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL)
    EXECUTE FUNCTION attachment.check_photo();
CREATE TRIGGER check_photo_change
    BEFORE UPDATE OF photo ON public.stock
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL AND OLD.photo IS DISTINCT FROM NEW.photo)
    EXECUTE FUNCTION attachment.check_photo();

CREATE TRIGGER check_photo
    BEFORE INSERT ON public.location
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL)
    EXECUTE FUNCTION attachment.check_photo();
CREATE TRIGGER check_photo_change
    BEFORE UPDATE OF photo ON public.location
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL AND OLD.photo IS DISTINCT FROM NEW.photo)
    EXECUTE FUNCTION attachment.check_photo();

CREATE TRIGGER check_photo
    BEFORE INSERT ON public.class
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL)
    EXECUTE FUNCTION attachment.check_photo();
CREATE TRIGGER check_photo_change
    BEFORE UPDATE OF photo ON public.class
    FOR EACH ROW WHEN (NEW.photo IS NOT NULL AND OLD.photo IS DISTINCT FROM NEW.photo)
    EXECUTE FUNCTION attachment.check_photo();

-- An attachment that is a live object's photo can't be deleted: the
-- object's photo must be cleared first (attachment.delete does so). If the
-- owner is deleted itself, its attachments aren't deleted with it, so this
-- never stands in the way of that.
CREATE FUNCTION attachment.check_not_photo()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.item     o WHERE o.id = NEW.item     AND o.photo = NEW.id AND o.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.stock    o WHERE o.id = NEW.stock    AND o.photo = NEW.id AND o.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.location o WHERE o.id = NEW.location AND o.photo = NEW.id AND o.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.class    o WHERE o.id = NEW.class    AND o.photo = NEW.id AND o.deleted IS NULL)
    THEN
        RAISE EXCEPTION 'Attachment "%" is a photo; clear the photo before deleting it', NEW.title
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_not_photo
    BEFORE UPDATE OF deleted ON public.attachment
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION attachment.check_not_photo();

-- The tree nodes show their photo, whose title can change without the
-- class or location changing, so a change to a class's or a location's
-- attachments moves its tree on too (see util.bump_tree_version). An
-- attachment has no tenant of its own, so it is found through its class or
-- location; attachments of items and stock rows find neither, and bump
-- nothing.
CREATE FUNCTION attachment.bump_tree_version()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.data_version (tenant, name)
        SELECT DISTINCT o.tenant, o.name
        FROM old_rows r
        JOIN (SELECT id, tenant, 'class' AS name FROM public.class
              UNION ALL
              SELECT id, tenant, 'location' FROM public.location) o
          ON o.id = coalesce(r.class, r.location)
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    ELSE
        INSERT INTO public.data_version (tenant, name)
        SELECT DISTINCT o.tenant, o.name
        FROM new_rows r
        JOIN (SELECT id, tenant, 'class' AS name FROM public.class
              UNION ALL
              SELECT id, tenant, 'location' FROM public.location) o
          ON o.id = coalesce(r.class, r.location)
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER bump_tree_version_insert AFTER INSERT ON public.attachment
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION attachment.bump_tree_version();
CREATE TRIGGER bump_tree_version_update AFTER UPDATE ON public.attachment
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION attachment.bump_tree_version();
CREATE TRIGGER bump_tree_version_delete AFTER DELETE ON public.attachment
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION attachment.bump_tree_version();
