-- API: attachments. Explained in api/attachment.md.
--
-- The file contents are handled by wtfd itself (stored on disk under their
-- SHA-256 hash); these functions manage the metadata. An upload runs in one
-- transaction: attachment_lock, then wtfd puts the file in place, then
-- attachment_create. "wtfd gc" takes the same lock before removing a file.
--
-- An attachment is linked to items, stock rows, locations and classes
-- through mapping tables (item_attachment, …). One that nothing links to any
-- more is deleted at once (a trigger), and its file goes at the next
-- "wtfd gc" when no attachment has its hash.
--
-- Attachments of classes belong to the model (model privilege); all others
-- belong to the data (data privilege).

-- The privilege area of an object kind.
CREATE FUNCTION util.attachment_area(p_kind text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN CASE WHEN p_kind = 'class' THEN 'model' ELSE 'data' END;
END;
$$;

-- Checks access to an existing attachment at p_level ('read' or 'write'):
-- reading needs model or data read; changing needs write on whatever it is
-- linked to.
CREATE FUNCTION util.attachment_access(p_id uuid, p_level text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM util.require_login();
    IF NOT EXISTS (SELECT 1 FROM attachment WHERE id = p_id) THEN
        PERFORM util.raise_not_found('attachment', p_id);
    END IF;
    IF p_level = 'read' THEN
        PERFORM util.require_model_read();
        RETURN;
    END IF;
    IF util.attachment_linked(p_id, 'class') THEN
        PERFORM util.require('model', 'write');
    END IF;
    IF util.attachment_linked(p_id, 'item') OR util.attachment_linked(p_id, 'stock')
       OR util.attachment_linked(p_id, 'location')
    THEN
        PERFORM util.require('data', 'write');
    END IF;
END;
$$;

-- Raises unless p_kind is one of the kinds attachments are linked to, and
-- the object p_id of it exists.
CREATE FUNCTION util.check_attachment_target(p_kind text, p_id uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('item', 'stock', 'location', 'class') THEN
        PERFORM util.raise_invalid(format('%L is not something attachments can be attached to', p_kind));
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1)', p_kind) INTO v_exists USING p_id;
    IF NOT v_exists THEN
        PERFORM util.raise_not_found(p_kind, p_id);
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

-- Attaches a file to an object. p_target_type is 'item', 'stock',
-- 'location' or 'class'. p_hash is the hex SHA-256 of the file, which wtfd
-- has already stored. p_title defaults to the uploaded file's name (wtfd
-- passes it). With p_photo, the attachment becomes the object's photo; it
-- must be an image.
CREATE FUNCTION attachment_create(
    p_target_type text,
    p_target      uuid,
    p_hash        text,
    p_type        text,
    p_title       text,
    p_photo       boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    PERFORM util.check_attachment_target(p_target_type, p_target);
    PERFORM util.require(util.attachment_area(p_target_type), 'write');

    INSERT INTO attachment (hash, type, title)
    VALUES (lower(p_hash), p_type, util.clean_name(p_title))
    RETURNING id INTO v_id;

    EXECUTE format('INSERT INTO %I (%I, attachment) VALUES ($1, $2)',
                   p_target_type || '_attachment', p_target_type)
        USING p_target, v_id;

    IF p_photo THEN
        EXECUTE format('UPDATE %I SET photo = $1 WHERE id = $2', p_target_type)
            USING v_id, p_target;
    END IF;

    RETURN util.attachment_json(v_id);
END;
$$;

CREATE FUNCTION attachment_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'read');
    RETURN util.attachment_json(p_id);
END;
$$;

-- Changes the fields present in p_patch: title. Not while it is on a
-- deleted object (deleted objects are frozen).
CREATE FUNCTION attachment_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'write');
    PERFORM util.check_patch(p_patch, ARRAY['title'], ARRAY['title']);
    PERFORM util.check_attachment_owners_live(p_id);

    UPDATE attachment
    SET title = CASE WHEN p_patch ? 'title' THEN util.clean_name(p_patch ->> 'title') ELSE title END
    WHERE id = p_id;

    RETURN util.attachment_json(p_id);
END;
$$;

-- Raises "… is deleted" (55000) when an attachment is on a deleted object,
-- whose attachments can't change.
CREATE FUNCTION util.check_attachment_owners_live(p_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_owner record;
BEGIN
    FOR v_owner IN
        SELECT 'item' AS kind, item AS id FROM item_attachment WHERE attachment = p_id
        UNION ALL SELECT 'stock', stock FROM stock_attachment WHERE attachment = p_id
        UNION ALL SELECT 'location', location FROM location_attachment WHERE attachment = p_id
        UNION ALL SELECT 'class', class FROM class_attachment WHERE attachment = p_id
    LOOP
        PERFORM check_live(v_owner.kind, v_owner.id);
    END LOOP;
END;
$$;

-- Removes an attachment from object p_target (of p_target_type). If it was
-- the object's photo, the object has no photo any more. An attachment left
-- on nothing is deleted, for good.
CREATE FUNCTION attachment_unlink(p_target_type text, p_target uuid, p_attachment uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_removed integer;
BEGIN
    PERFORM util.check_attachment_target(p_target_type, p_target);
    PERFORM util.require(util.attachment_area(p_target_type), 'write');
    PERFORM check_live(p_target_type, p_target);

    EXECUTE format('DELETE FROM %I WHERE %I = $1 AND attachment = $2',
                   p_target_type || '_attachment', p_target_type)
        USING p_target, p_attachment;
    GET DIAGNOSTICS v_removed = ROW_COUNT; -- EXECUTE doesn't set FOUND
    IF v_removed = 0 THEN
        PERFORM util.raise_not_found('attachment', p_attachment);
    END IF;
END;
$$;

-- Deletes an attachment, for good: it is removed from every object it is
-- on. Not while one of them is deleted.
CREATE FUNCTION attachment_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'write');
    PERFORM util.check_attachment_owners_live(p_id);
    DELETE FROM attachment WHERE id = p_id;
END;
$$;
