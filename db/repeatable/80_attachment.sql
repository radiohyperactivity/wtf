-- API: attachments. Explained in api/attachment.md.
--
-- The file contents are handled by wtfd itself (stored on disk under their
-- SHA-256 hash); these functions manage the metadata. An upload runs in one
-- transaction: attachment_lock, then wtfd puts the file in place, then
-- attachment_create. "wtfd gc" takes the same lock before removing a file.
--
-- Attachments of classes belong to the model (model privilege); all others
-- belong to the data (data privilege).

-- Checks access to an existing attachment of the session's tenant, at
-- p_level ('read' or 'write'). Unknown attachments and those of other
-- tenants are "not found".
CREATE FUNCTION util.attachment_access(p_id uuid, p_level text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tenant   uuid;
    v_is_class boolean;
BEGIN
    SELECT tenant, class IS NOT NULL INTO v_tenant, v_is_class FROM attachment WHERE id = p_id;
    IF NOT FOUND OR v_tenant IS DISTINCT FROM util.require_login() THEN
        PERFORM util.raise_not_found('attachment', p_id);
    END IF;
    IF NOT v_is_class THEN
        PERFORM util.require('data', p_level);
    ELSIF p_level = 'read' THEN
        PERFORM util.require_model_read();
    ELSE
        PERFORM util.require('model', 'write');
    END IF;
END;
$$;

-- Locks a file hash (hex) until the end of the transaction.
CREATE FUNCTION attachment_lock(p_sha256 text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    PERFORM pg_advisory_xact_lock(file_lock_key(decode(p_sha256, 'hex')));
END;
$$;

-- Attaches a file to an object. p_target_type is 'item', 'stock',
-- 'location' or 'class'. p_sha256 is the hex hash of the file, which wtfd has
-- already stored. Marking it as the primary photo replaces any previous one.
CREATE FUNCTION attachment_create(
    p_target_type   text,
    p_target        uuid,
    p_sha256        text,
    p_size          bigint,
    p_file_name     text,
    p_content_type  text,
    p_caption       text    DEFAULT NULL,
    p_primary_photo boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_hash   bytea := decode(p_sha256, 'hex');
    v_id     uuid;
BEGIN
    IF p_target_type NOT IN ('item', 'stock', 'location', 'class') THEN
        PERFORM util.raise_invalid(format('%L is not something attachments can be attached to', p_target_type));
    END IF;
    v_tenant := util.require(CASE WHEN p_target_type = 'class' THEN 'model' ELSE 'data' END, 'write');

    IF (p_target_type = 'item'     AND NOT EXISTS (SELECT 1 FROM item     WHERE id = p_target AND tenant = v_tenant))
       OR (p_target_type = 'stock'    AND NOT EXISTS (SELECT 1 FROM stock    WHERE id = p_target AND tenant = v_tenant))
       OR (p_target_type = 'location' AND NOT EXISTS (SELECT 1 FROM location WHERE id = p_target AND tenant = v_tenant))
       OR (p_target_type = 'class'    AND NOT EXISTS (SELECT 1 FROM class    WHERE id = p_target AND tenant = v_tenant))
    THEN
        PERFORM util.raise_not_found(p_target_type, p_target);
    END IF;

    INSERT INTO file (sha256, size)
    VALUES (v_hash, p_size)
    ON CONFLICT (sha256) DO NOTHING;

    INSERT INTO attachment (tenant, file, file_name, content_type, caption, primary_photo,
                            item, stock, location, class)
    VALUES (v_tenant, v_hash, util.clean_name(p_file_name), p_content_type, NULLIF(btrim(p_caption), ''), false,
            CASE WHEN p_target_type = 'item'     THEN p_target END,
            CASE WHEN p_target_type = 'stock'    THEN p_target END,
            CASE WHEN p_target_type = 'location' THEN p_target END,
            CASE WHEN p_target_type = 'class'    THEN p_target END)
    RETURNING id INTO v_id;

    IF p_primary_photo THEN
        PERFORM util.attachment_clear_primary(v_id);
        UPDATE attachment SET primary_photo = true WHERE id = v_id;
    END IF;

    RETURN util.attachment_json(v_id);
END;
$$;

-- A deleted attachment is returned too, with deleted: true.
CREATE FUNCTION attachment_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'read');
    RETURN util.attachment_json(p_id);
END;
$$;

-- Changes the fields present in p_patch: file_name, caption (null clears it),
-- primary_photo (true replaces any previous primary photo of the object).
CREATE FUNCTION attachment_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'write');
    PERFORM util.check_patch(p_patch,
                             ARRAY['file_name', 'caption', 'primary_photo'],
                             ARRAY['file_name', 'primary_photo']);

    IF (p_patch ->> 'primary_photo')::boolean THEN
        PERFORM util.attachment_clear_primary(p_id);
    END IF;

    UPDATE attachment
    SET file_name     = CASE WHEN p_patch ? 'file_name'
                             THEN util.clean_name(p_patch ->> 'file_name') ELSE file_name END,
        caption       = CASE WHEN p_patch ? 'caption'
                             THEN NULLIF(btrim(p_patch ->> 'caption'), '') ELSE caption END,
        primary_photo = CASE WHEN p_patch ? 'primary_photo'
                             THEN (p_patch ->> 'primary_photo')::boolean ELSE primary_photo END
    WHERE id = p_id;

    RETURN util.attachment_json(p_id);
END;
$$;

-- Marks an attachment deleted. Its file stays on disk while it is referenced,
-- until the attachment is purged and "wtfd gc" finds the file unreferenced.
CREATE FUNCTION attachment_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.attachment_access(p_id, 'write');
    UPDATE attachment SET deleted = true WHERE id = p_id;
END;
$$;

-- Restores a deleted attachment; its object must be live. If it was the
-- primary photo and the object has another one by now, it comes back as an
-- ordinary attachment.
CREATE FUNCTION attachment_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_attachment attachment;
BEGIN
    PERFORM util.attachment_access(p_id, 'write');
    PERFORM util.check_patch(p_options, ARRAY[]::text[], ARRAY[]::text[]);
    SELECT * INTO v_attachment FROM attachment WHERE id = p_id FOR UPDATE;
    IF NOT v_attachment.deleted THEN
        PERFORM util.raise_not_deleted('attachment', p_id);
    END IF;

    UPDATE attachment a
    SET deleted       = false,
        primary_photo = a.primary_photo AND NOT EXISTS (
            SELECT 1 FROM attachment o
            WHERE o.id <> a.id AND o.primary_photo AND NOT o.deleted
              AND (o.item = a.item OR o.stock = a.stock OR o.location = a.location OR o.class = a.class))
    WHERE a.id = p_id;
    RETURN util.attachment_json(p_id);
END;
$$;
