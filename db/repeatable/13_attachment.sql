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

-- An object's photo must be an image (its media type starts with 'image/').
-- That it is one of the object's own attachments is
-- already ensured by the photo's foreign key, (id, photo) to attachment
-- (item, id) and so on. Used by item, stock, location and class.
CREATE FUNCTION attachment.check_photo()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_photo record;
BEGIN
    SELECT a.media_type, a.title INTO v_photo
    FROM public.attachment a
    WHERE a.id = NEW.photo;
    IF v_photo.media_type NOT LIKE 'image/%' THEN
        RAISE EXCEPTION 'A photo must be an image; "%" is %', v_photo.title, v_photo.media_type
            USING ERRCODE = 'check_violation';
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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- An attachment is only ever reached through its owner: every function the
-- API calls takes the owner's kind and id, and an attachment of another
-- owner isn't found.

-- An attachment as the API shows it, from its row; NULL for no row, so that
-- a LEFT JOIN of an object's photo can be passed straight in.
CREATE FUNCTION attachment.json(p_attachment public.attachment)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_attachment.id IS NOT NULL THEN jsonb_build_object(
        'id',         p_attachment.id,
        'title',      p_attachment.title,
        'media_type', p_attachment.media_type,
        'size',       p_attachment.size,
        'hash',       p_attachment.hash) END;
$$;

-- An object's attachments, as the API lists them: its photo first,
-- then the others in the order given.
CREATE FUNCTION attachment.list_json(p_photo uuid, p_attachments public.attachment[])
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(jsonb_agg(attachment.json(p_attachments[i])
                              ORDER BY (p_attachments[i]).id IS DISTINCT FROM p_photo, i), '[]')
    FROM generate_subscripts(p_attachments, 1) AS i;
$$;

-- The owner of attachment p_attachment, whichever of the four kinds it is
-- (exactly one of the four columns is set, by the table's CHECK).
CREATE FUNCTION attachment.owner_of(p_attachment public.attachment)
RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(p_attachment.item, p_attachment.stock, p_attachment.location, p_attachment.class);
$$;

-- Refuses unless the session may use the attachments of object p_owner of
-- kind p_kind: it must be one of the session's tenant's (404 otherwise);
-- with p_write, the role must be user for an item or stock row, or admin
-- for a location or class (403). Looking needs no more than viewer.
-- Returns the owner's photo, read in the same query.
CREATE FUNCTION attachment.check_owner(p_session record, p_kind public.owner_kind, p_owner uuid, p_write boolean)
RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_photo   uuid;
    v_role    public.role := CASE WHEN p_kind IN ('item', 'stock') THEN 'user' ELSE 'admin' END;
BEGIN
    IF p_kind = 'item' THEN
        SELECT i.photo INTO v_photo
        FROM public.item i JOIN public.class c ON c.id = i.class
        WHERE i.id = p_owner AND c.tenant = p_session.tenant;
    ELSIF p_kind = 'stock' THEN
        SELECT s.photo INTO v_photo
        FROM public.stock s JOIN public.location l ON l.id = s.location
        WHERE s.id = p_owner AND l.tenant = p_session.tenant;
    ELSIF p_kind = 'location' THEN
        SELECT l.photo INTO v_photo
        FROM public.location l
        WHERE l.id = p_owner AND l.tenant = p_session.tenant;
    ELSE
        SELECT c.photo INTO v_photo
        FROM public.class c
        WHERE c.id = p_owner AND c.tenant = p_session.tenant;
    END IF;
    IF NOT FOUND THEN
        PERFORM error.not_found(p_kind::text, p_owner::text);
    END IF;
    IF p_write AND p_session.role < v_role THEN
        PERFORM error.forbidden(format('Changing the attachments of a %s needs the role %s', p_kind, v_role));
    END IF;
    RETURN v_photo;
END;
$$;

-- Makes attachment p_attachment (or none, NULL) the photo of object p_owner
-- of kind p_kind. The photo's foreign key and attachment.check_photo check
-- that it is the owner's own and an image.
CREATE FUNCTION attachment.set_photo(p_kind public.owner_kind, p_owner uuid, p_attachment uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_kind = 'item' THEN
        UPDATE public.item SET photo = p_attachment WHERE id = p_owner;
    ELSIF p_kind = 'stock' THEN
        UPDATE public.stock SET photo = p_attachment WHERE id = p_owner;
    ELSIF p_kind = 'location' THEN
        UPDATE public.location SET photo = p_attachment WHERE id = p_owner;
    ELSE
        UPDATE public.class SET photo = p_attachment WHERE id = p_owner;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------
-- An upload is one transaction of its own: attachment.lock, then wtfd puts
-- the file in place, then attachment.create. "wtfd gc" takes the same lock
-- before removing a file that no attachment has any more.

-- Locks file hash p_hash (hex) until the end of the transaction.
CREATE FUNCTION attachment.lock(p_request public.request, p_hash text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    IF p_hash IS NULL OR lower(p_hash) !~ '^[0-9a-f]{64}$' THEN
        PERFORM error.invalid('A file hash is 64 hexadecimal digits');
    END IF;
    PERFORM pg_advisory_xact_lock(attachment.file_lock_key(lower(p_hash)));
END;
$$;

-- Attaches a file to one of the tenant's items, stock rows, locations
-- or classes (p_kind, p_owner). wtfd has already stored the file, under its
-- SHA-256 hash, p_hash (hex), and passes its media type, size and the
-- uploaded file's name as p_title. With p_photo the attachment becomes the
-- owner's photo, and must be an image. Attachments of items and stock rows
-- are for users; those of locations and classes, which admins set up, for
-- admins. Returns the attachment.
CREATE FUNCTION attachment.create(
    p_request    public.request,
    p_kind       public.owner_kind,
    p_owner      uuid,
    p_hash       text,
    p_media_type text,
    p_size       bigint,
    p_title      text,
    p_photo      boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session    record := util.session(p_request, 'viewer');
    v_attachment public.attachment;
BEGIN
    IF p_kind IS NULL OR p_photo IS NULL THEN
        PERFORM error.invalid('Say what the attachment belongs to, and whether it is the photo');
    END IF;
    PERFORM attachment.check_owner(v_session, p_kind, p_owner, true);

    INSERT INTO public.attachment (item, stock, location, class, media_type, hash, size, title)
    VALUES (CASE WHEN p_kind = 'item'     THEN p_owner END,
            CASE WHEN p_kind = 'stock'    THEN p_owner END,
            CASE WHEN p_kind = 'location' THEN p_owner END,
            CASE WHEN p_kind = 'class'    THEN p_owner END,
            p_media_type, lower(p_hash), p_size, util.trim_and_check(p_title))
    RETURNING * INTO v_attachment;
    IF p_photo THEN
        PERFORM attachment.set_photo(p_kind, p_owner, v_attachment.id);
    END IF;
    RETURN attachment.json(v_attachment);
END;
$$;

-- One attachment of one of the tenant's objects.
CREATE FUNCTION attachment.get(
    p_request    public.request,
    p_kind       public.owner_kind,
    p_owner      uuid,
    p_attachment uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    PERFORM attachment.check_owner(v_session, p_kind, p_owner, false);
    SELECT attachment.json(a) INTO v_result
    FROM public.attachment a
    WHERE a.id = p_attachment AND attachment.owner_of(a) = p_owner;
    IF NOT FOUND THEN
        PERFORM error.not_found('attachment', p_attachment::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Changes the fields of an attachment that p_patch has: title.
CREATE FUNCTION attachment.patch(
    p_request    public.request,
    p_kind       public.owner_kind,
    p_owner      uuid,
    p_attachment uuid,
    p_patch      jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session    record := util.session(p_request, 'viewer');
    v_attachment public.attachment;
BEGIN
    PERFORM attachment.check_owner(v_session, p_kind, p_owner, true);
    PERFORM util.check_patch(p_patch, ARRAY['title'], ARRAY['title']);
    SELECT a.* INTO v_attachment
    FROM public.attachment a
    WHERE a.id = p_attachment AND attachment.owner_of(a) = p_owner
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('attachment', p_attachment::text);
    END IF;

    UPDATE public.attachment a
    SET title = CASE WHEN p_patch ? 'title' THEN util.trim_and_check(p_patch ->> 'title') ELSE a.title END
    WHERE a.id = p_attachment
    RETURNING * INTO v_attachment;
    RETURN attachment.json(v_attachment);
END;
$$;

-- Deletes an attachment of one of the tenant's objects. If it is the
-- owner's photo, the owner has no photo any more (the photo's foreign key
-- clears it). The file stays on disk until "wtfd gc" finds that no
-- attachment of the tenant has its hash.
CREATE FUNCTION attachment.delete(
    p_request    public.request,
    p_kind       public.owner_kind,
    p_owner      uuid,
    p_attachment uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    PERFORM attachment.check_owner(v_session, p_kind, p_owner, true);
    DELETE FROM public.attachment a
    WHERE a.id = p_attachment AND attachment.owner_of(a) = p_owner;
    IF NOT FOUND THEN
        PERFORM error.not_found('attachment', p_attachment::text);
    END IF;
END;
$$;
