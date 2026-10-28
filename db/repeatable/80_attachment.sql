-- API: attachments. Explained in api/attachment.md.
--
-- Items, stock rows, locations and classes each have attachments of their
-- own (item_attachment, stock_attachment, location_attachment,
-- class_attachment). Every function takes the kind of object (p_kind:
-- 'item', 'stock', 'location' or 'class') and the object's id; an
-- attachment is only ever reached through its object.
--
-- The file contents are handled by wtfd itself, stored on disk under their
-- SHA-256 hash, once however often they are attached. An upload runs in one
-- transaction: attachment_lock, then wtfd puts the file in place, then
-- attachment_create. "wtfd gc" takes the same lock before removing a file
-- that no attachment has any more.
--
-- Attachments of classes belong to the model (model privilege); all others
-- belong to the data (data privilege).

-- Checks p_kind and the privilege for p_level ('read' or 'write'), and that
-- the object p_owner exists; for 'write', also that it is live (a deleted
-- object's attachments are frozen with it).
CREATE FUNCTION util.attachment_owner(p_kind text, p_owner uuid, p_level text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('item', 'stock', 'location', 'class') THEN
        PERFORM util.raise_invalid(format('%L is not something attachments can be attached to', p_kind));
    END IF;
    IF p_level = 'read' THEN
        IF p_kind = 'class' THEN
            PERFORM util.require_model_read();
        ELSE
            PERFORM util.require('data', 'read');
        END IF;
    ELSE
        PERFORM util.require(CASE WHEN p_kind = 'class' THEN 'model' ELSE 'data' END, 'write');
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1)', p_kind) INTO v_exists USING p_owner;
    IF NOT v_exists THEN
        PERFORM util.raise_not_found(p_kind, p_owner);
    END IF;
    IF p_level = 'write' THEN
        PERFORM check_live(p_kind, p_owner);
    END IF;
END;
$$;

-- Raises "not found" unless attachment p_id belongs to object p_owner.
CREATE FUNCTION util.check_attachment_of(p_kind text, p_owner uuid, p_id uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists boolean;
BEGIN
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1 AND %I = $2)', p_kind || '_attachment', p_kind)
        INTO v_exists USING p_id, p_owner;
    IF NOT v_exists THEN
        PERFORM util.raise_not_found('attachment', p_id);
    END IF;
END;
$$;

-- Locks a file hash (hex) until the end of the transaction.
CREATE FUNCTION attachment_lock(p_hash text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    PERFORM pg_advisory_xact_lock(file_lock_key(lower(p_hash)));
END;
$$;

-- Attaches a file to object p_owner of p_kind. p_hash is the hex SHA-256 of
-- the file, which wtfd has already stored, and p_size its size. p_title
-- defaults to the uploaded file's name (wtfd passes it). With p_photo, the
-- attachment becomes the object's photo; it must be an image.
CREATE FUNCTION attachment_create(
    p_kind  text,
    p_owner uuid,
    p_hash  text,
    p_type  text,
    p_size  bigint,
    p_title text,
    p_photo boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    PERFORM util.attachment_owner(p_kind, p_owner, 'write');
    EXECUTE format('INSERT INTO %I (%I, type, hash, size, title) VALUES ($1, $2, $3, $4, $5) RETURNING id',
                   p_kind || '_attachment', p_kind)
        INTO v_id USING p_owner, p_type, lower(p_hash), p_size, util.clean_name(p_title);
    IF p_photo THEN
        EXECUTE format('UPDATE %I SET photo = $1 WHERE id = $2', p_kind) USING v_id, p_owner;
    END IF;
    RETURN util.attachment_json(p_kind, v_id);
END;
$$;

-- {id, title, type, size, hash, deleted}. A deleted attachment is returned
-- too, with deleted: true.
CREATE FUNCTION attachment_get(p_kind text, p_owner uuid, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_owner(p_kind, p_owner, 'read');
    PERFORM util.check_attachment_of(p_kind, p_owner, p_id);
    RETURN util.attachment_json(p_kind, p_id);
END;
$$;

-- Changes the fields present in p_patch: title.
CREATE FUNCTION attachment_patch(p_kind text, p_owner uuid, p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_owner(p_kind, p_owner, 'write');
    PERFORM util.check_attachment_of(p_kind, p_owner, p_id);
    PERFORM util.check_patch(p_patch, ARRAY['title'], ARRAY['title']);
    IF p_patch ? 'title' THEN
        EXECUTE format('UPDATE %I SET title = $1 WHERE id = $2', p_kind || '_attachment')
            USING util.clean_name(p_patch ->> 'title'), p_id;
    END IF;
    RETURN util.attachment_json(p_kind, p_id);
END;
$$;

-- Marks an attachment deleted (see api/deleting.md). If it was the object's
-- photo, the object has no photo any more, also when it is restored.
CREATE FUNCTION attachment_delete(p_kind text, p_owner uuid, p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_owner(p_kind, p_owner, 'write');
    PERFORM util.check_attachment_of(p_kind, p_owner, p_id);
    EXECUTE format('UPDATE %I SET photo = NULL WHERE id = $1 AND photo = $2', p_kind) USING p_owner, p_id;
    EXECUTE format('UPDATE %I SET deleted = true WHERE id = $1', p_kind || '_attachment') USING p_id;
END;
$$;

-- Restores a deleted attachment; its object must be live. It comes back as
-- an ordinary attachment, not as the photo it may have been. No options
-- (p_options must be empty).
CREATE FUNCTION attachment_restore(p_kind text, p_owner uuid, p_id uuid, p_options jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted boolean;
BEGIN
    PERFORM util.attachment_owner(p_kind, p_owner, 'write');
    PERFORM util.check_attachment_of(p_kind, p_owner, p_id);
    PERFORM util.check_patch(COALESCE(p_options, '{}'), ARRAY[]::text[], ARRAY[]::text[]);
    EXECUTE format('SELECT deleted FROM %I WHERE id = $1 FOR UPDATE', p_kind || '_attachment')
        INTO v_deleted USING p_id;
    IF NOT v_deleted THEN
        PERFORM util.raise_not_deleted(p_kind || '_attachment', p_id);
    END IF;
    EXECUTE format('UPDATE %I SET deleted = false WHERE id = $1', p_kind || '_attachment') USING p_id;
    RETURN util.attachment_json(p_kind, p_id);
END;
$$;
