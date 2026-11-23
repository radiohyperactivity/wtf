-- Files (schema attachment): the photos of items, stock rows and locations,
-- and the files of the attachment attributes of items and stock rows. Explained in api/attachment.md.
--
-- A file is stored once, in wtfd's files directory, named by the SHA-256
-- of its content. An item, stock row
-- or location holds only the hash: its photo in the photo column, an attachment in
-- its values. wtfd finds the media type from the file itself.

CREATE SCHEMA attachment;

-- The advisory lock key of file hash p_hash (hex): its first 64 bits.
-- Uploads and "wtfd gc" take it, so that gc never removes a file that an
-- upload is about to use.
CREATE FUNCTION attachment.file_lock_key(p_hash text)
RETURNS bigint
LANGUAGE sql IMMUTABLE AS $$
    SELECT ('x' || substr(p_hash, 1, 16))::bit(64)::bigint;
$$;

-- Whether media type p_media_type is one of p_allowed, a list like
-- ["application/pdf", "image/*"]; any type when there is no list.
CREATE FUNCTION attachment.media_allowed(p_allowed jsonb, p_media_type text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_allowed IS NULL
        OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_allowed) a
                   WHERE a = p_media_type
                      OR a LIKE '%/*' AND split_part(a, '/', 1) = split_part(p_media_type, '/', 1));
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------
-- An upload is one transaction of its own: attachment.lock, then wtfd puts
-- the file in place, then attachment.set. "wtfd gc" takes the same lock
-- before removing a file that nothing has any more.

-- Locks file hash p_hash (hex) until the end of the transaction.
CREATE FUNCTION attachment.lock(p_request public.request, p_hash text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
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

-- Puts a file, which wtfd has already stored under its hash p_hash, on one
-- of the items, stock rows or locations (p_kind 'item', 'stock' or
-- 'location', p_owner): as its photo when p_attribute is NULL, which must be
-- an image; otherwise as the value of attachment attribute p_attribute of
-- its class, which must take p_media_type when it lists the media types it
-- takes (a location has only a photo). A stock row has a photo only where
-- its location takes stock photos (location.stock_photos). A file that is
-- there already is replaced. Returns the item, stock row or location as its get does. For
-- users; a location's photo for admins, who set up the locations.
CREATE FUNCTION attachment.set(
    p_request    public.request,
    p_kind       text,
    p_owner      uuid,
    p_attribute  text,
    p_hash       text,
    p_media_type text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'user');
    v_hash    text := lower(p_hash);
    v_locked  record;
    v_def     jsonb;
BEGIN
    IF v_hash IS NULL OR v_hash !~ '^[0-9a-f]{64}$' THEN
        PERFORM error.invalid('A file hash is 64 hexadecimal digits');
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('item', 'stock', 'location') THEN
        PERFORM error.invalid('A file goes on an item, a stock row or a location');
    END IF;
    IF p_kind = 'location' AND p_attribute IS NOT NULL THEN
        PERFORM error.invalid('A location has a photo, and no other files');
    END IF;
    IF p_attribute IS NULL AND coalesce(p_media_type, '') NOT LIKE 'image/%' THEN
        PERFORM error.invalid(format('A photo must be an image, and this is %s', coalesce(p_media_type, 'unknown')));
    END IF;

    IF p_kind = 'location' THEN
        IF v_session.role < 'admin' THEN
            PERFORM error.forbidden(format('This needs the role admin; you are %s', v_session.role));
        END IF;
        UPDATE public.location l SET photo = v_hash WHERE l.id = p_owner;
        IF NOT FOUND THEN
            PERFORM error.not_found('location', p_owner::text);
        END IF;
        -- The tree shows the photos.
        PERFORM util.bump_version('location');
        RETURN (SELECT location.detail_json(l) FROM public.location l WHERE l.id = p_owner);
    END IF;

    IF p_kind = 'item' THEN
        v_locked := item.lock_for_write(p_owner);
    ELSE
        v_locked := stock.lock_for_write(p_owner);
    END IF;
    IF p_attribute IS NULL THEN
        IF p_kind = 'item' THEN
            UPDATE public.item i SET photo = v_hash WHERE i.id = p_owner;
            RETURN (SELECT item.detail_json(i) FROM public.item i WHERE i.id = p_owner);
        END IF;
        -- Only where its location takes stock photos.
        IF NOT (SELECT l.stock_photos FROM public.location l WHERE l.id = (v_locked.stock_row).location) THEN
            PERFORM error.not_allowed(format('Stock at "%s" has no photos of its own; an admin can change that on the location',
                                             (SELECT l.name FROM public.location l
                                              WHERE l.id = (v_locked.stock_row).location)));
        END IF;
        UPDATE public.stock s SET photo = v_hash WHERE s.id = p_owner;
        RETURN (SELECT stock.detail_json(s) FROM public.stock s WHERE s.id = p_owner);
    END IF;

    v_def := (v_locked.class_row).attributes -> p_attribute;
    IF v_def ->> 'scope' IS DISTINCT FROM p_kind OR v_def ->> 'type' <> 'attachment' THEN
        PERFORM error.not_found('attachment', format('"%s" of class "%s"', p_attribute, (v_locked.class_row).name));
    END IF;
    IF NOT attachment.media_allowed(v_def -> 'media', p_media_type) THEN
        PERFORM error.not_allowed(format('"%s" takes %s, and this is %s', p_attribute,
                                         (SELECT string_agg(m, ', ') FROM jsonb_array_elements_text(v_def -> 'media') m),
                                         coalesce(p_media_type, 'unknown')));
    END IF;
    IF p_kind = 'item' THEN
        PERFORM item.store_values(v_locked.item_row, v_locked.class_row,
                                  (v_locked.item_row).values || jsonb_build_object(p_attribute, v_hash),
                                  array_remove((v_locked.item_row).defaulted, p_attribute));
        RETURN (SELECT item.detail_json(i) FROM public.item i WHERE i.id = p_owner);
    END IF;
    PERFORM stock.store_values(v_locked.stock_row, v_locked.class_row,
                               (v_locked.stock_row).values || jsonb_build_object(p_attribute, v_hash),
                               array_remove((v_locked.stock_row).defaulted, p_attribute));
    RETURN (SELECT stock.detail_json(s) FROM public.stock s WHERE s.id = p_owner);
END;
$$;

-- The hash of a file on an item, stock row or location (p_kind,
-- p_owner): its photo when p_attribute is NULL, otherwise the value of
-- attachment attribute p_attribute. {hash, name}, name being what a
-- download is called: the attribute's name, or "Photo". Not found (404)
-- when there is no such file. wtfd serves the file.
CREATE FUNCTION attachment.get(p_request public.request, p_kind text, p_owner uuid, p_attribute text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_hash    text;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('item', 'stock', 'location') THEN
        PERFORM error.invalid('A file is on an item, a stock row or a location');
    END IF;
    IF p_kind = 'location' THEN
        SELECT l.photo INTO v_hash
        FROM public.location l
        WHERE l.id = p_owner AND p_attribute IS NULL;
    ELSIF p_kind = 'item' THEN
        SELECT CASE WHEN p_attribute IS NULL THEN i.photo ELSE i.values ->> p_attribute END
        INTO v_hash
        FROM public.item i JOIN public.class c ON c.id = i.class
        WHERE i.id = p_owner
          AND (p_attribute IS NULL OR c.attributes -> p_attribute ->> 'type' = 'attachment');
    ELSE
        SELECT CASE WHEN p_attribute IS NULL THEN s.photo ELSE s.values ->> p_attribute END
        INTO v_hash
        FROM public.stock s JOIN public.item i ON i.id = s.item JOIN public.class c ON c.id = i.class
        WHERE s.id = p_owner
          AND (p_attribute IS NULL OR c.attributes -> p_attribute ->> 'type' = 'attachment');
    END IF;
    IF v_hash IS NULL THEN
        PERFORM error.not_found(CASE WHEN p_attribute IS NULL THEN 'photo' ELSE 'file' END,
                                format('of %s %s', CASE p_kind WHEN 'stock' THEN 'stock row' ELSE p_kind END, p_owner)
                                || CASE WHEN p_attribute IS NULL THEN '' ELSE format(' for "%s"', p_attribute) END);
    END IF;
    RETURN jsonb_build_object('hash', v_hash, 'name', coalesce(p_attribute, 'Photo'));
END;
$$;

-- ---------------------------------------------------------------------------
-- Functions for gc
-- ---------------------------------------------------------------------------
-- "wtfd gc", and wtfd serve at the time its gc setting names, remove the
-- files nothing has any more. They connect as the API role, which can't read
-- the tables, so these do it for them. They take no request: gc is wtfd's
-- own work, not a user's.

-- The hashes of the files in use: the photos of the items, stock rows and
-- locations, and the values of the attachment attributes of the items and
-- stock rows. Read once per run.
CREATE FUNCTION attachment.gc_hashes_used()
RETURNS SETOF text
LANGUAGE sql STABLE
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
    SELECT i.photo FROM public.item i WHERE i.photo IS NOT NULL
    UNION
    SELECT s.photo FROM public.stock s WHERE s.photo IS NOT NULL
    UNION
    SELECT l.photo FROM public.location l WHERE l.photo IS NOT NULL
    UNION
    SELECT e.value
    FROM public.item i
    JOIN public.class c ON c.id = i.class
    CROSS JOIN LATERAL jsonb_each_text(i.values) e
    WHERE c.attributes -> e.key ->> 'type' = 'attachment'
    UNION
    SELECT e.value
    FROM public.stock s
    JOIN public.item i  ON i.id = s.item
    JOIN public.class c ON c.id = i.class
    CROSS JOIN LATERAL jsonb_each_text(s.values) e
    WHERE c.attributes -> e.key ->> 'type' = 'attachment';
$$;

-- Locks file hash p_hash (hex) until the end of the transaction, as an
-- upload does, and tells whether nothing uses it: as a photo, or as any
-- value of an item or stock row (a text value that happens to be the hash
-- keeps the file too, which errs on the safe side). wtfd removes the file
-- before the transaction ends, so no upload can start using it meanwhile.
CREATE FUNCTION attachment.gc_unused(p_hash text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
BEGIN
    IF p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$' THEN
        PERFORM error.invalid('A file hash is 64 hexadecimal digits');
    END IF;
    PERFORM pg_advisory_xact_lock(attachment.file_lock_key(p_hash));
    RETURN NOT (
        EXISTS (SELECT 1 FROM public.item i
                WHERE i.photo = p_hash OR EXISTS (SELECT 1 FROM jsonb_each_text(i.values) e WHERE e.value = p_hash))
        OR EXISTS (SELECT 1 FROM public.stock s
                   WHERE s.photo = p_hash OR EXISTS (SELECT 1 FROM jsonb_each_text(s.values) e WHERE e.value = p_hash))
        OR EXISTS (SELECT 1 FROM public.location l WHERE l.photo = p_hash));
END;
$$;
