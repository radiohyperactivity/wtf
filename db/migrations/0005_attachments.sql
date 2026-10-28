-- Attachments, once more (see api/attachment.md): items, stock rows,
-- locations and classes each have attachments of their own, in
-- item_attachment, stock_attachment, location_attachment and
-- class_attachment, with an id, the owner, the MIME type, the SHA-256 hash
-- of the content, its size and a title. Nothing is shared between objects,
-- and the attachment table of migration 0004 is gone. The contents stay in
-- one files directory, named by their hash, so the same content is stored
-- once however often it is attached.

-- 0004 dropped the sizes, which can't be recovered here. Only one
-- installation ran 0004, and it had no attachments; should there be any,
-- stop rather than invent sizes.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM attachment) THEN
        RAISE EXCEPTION 'Migration 0005 can''t keep existing attachments: their sizes were dropped by 0004. Delete them first (DELETE FROM attachment).';
    END IF;
END;
$$;

DROP TRIGGER item_check_photo ON item;
DROP TRIGGER stock_check_photo ON stock;
DROP TRIGGER location_check_photo ON location;
DROP TRIGGER class_check_photo ON class;
DROP FUNCTION check_photo();
ALTER TABLE item     DROP COLUMN photo;
ALTER TABLE stock    DROP COLUMN photo;
ALTER TABLE location DROP COLUMN photo;
ALTER TABLE class    DROP COLUMN photo;

DROP TABLE item_attachment, stock_attachment, location_attachment, class_attachment;
DROP FUNCTION attachment_link_check_live();
DROP FUNCTION attachment_link_removed();
DROP TABLE attachment;

-- ---------------------------------------------------------------------------
-- The attachments of each kind of object
-- ---------------------------------------------------------------------------

-- An attachment is added to or changed on a live object only. TG_ARGV[0] is
-- the owner's table, which is also the column naming it.
CREATE FUNCTION attachment_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owner text := TG_ARGV[0];
BEGIN
    PERFORM check_live(v_owner, (to_jsonb(NEW) ->> v_owner)::uuid);
    RETURN NEW;
END;
$$;

-- A photo is an image. (That it is one of the object's own attachments is
-- the photo's foreign key.)
CREATE FUNCTION check_photo() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type  text;
    v_title text;
BEGIN
    IF NEW.photo IS NULL THEN
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT type, title FROM %I WHERE id = $1', TG_TABLE_NAME || '_attachment')
        INTO v_type, v_title USING NEW.photo;
    IF v_type NOT LIKE 'image/%' THEN
        RAISE EXCEPTION 'A photo must be an image; "%" is %', v_title, v_type
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Attachments are named by their title in error messages.
CREATE OR REPLACE FUNCTION row_label(p_table text, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN CASE p_table
        WHEN 'class'            THEN (SELECT format('Class "%s"', name) FROM class WHERE id = p_id)
        WHEN 'location'         THEN (SELECT format('Location "%s"', name) FROM location WHERE id = p_id)
        WHEN 'item'             THEN (SELECT format('Item "%s"', name) FROM item WHERE id = p_id)
        WHEN 'stock'            THEN (SELECT format('The stock row of "%s"', i.name)
                                      FROM stock s JOIN item i ON i.id = s.item WHERE s.id = p_id)
        WHEN 'attribute'        THEN (SELECT format('Attribute "%s"', name) FROM attribute WHERE id = p_id)
        WHEN 'attribute_option' THEN (SELECT format('Option "%s"', name) FROM attribute_option WHERE id = p_id)
        WHEN 'item_attachment'     THEN (SELECT format('Attachment "%s"', title) FROM item_attachment WHERE id = p_id)
        WHEN 'stock_attachment'    THEN (SELECT format('Attachment "%s"', title) FROM stock_attachment WHERE id = p_id)
        WHEN 'location_attachment' THEN (SELECT format('Attachment "%s"', title) FROM location_attachment WHERE id = p_id)
        WHEN 'class_attachment'    THEN (SELECT format('Attachment "%s"', title) FROM class_attachment WHERE id = p_id)
    END;
END;
$$;

DO $$
DECLARE
    v_owner text;
BEGIN
    FOREACH v_owner IN ARRAY ARRAY['item', 'stock', 'location', 'class'] LOOP
        EXECUTE format($sql$
            CREATE TABLE %1$I (
                id    uuid   NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
                %2$I  uuid   NOT NULL REFERENCES %2$I (id) ON DELETE CASCADE,
                -- MIME type
                type  text   NOT NULL CHECK (btrim(type) <> ''),
                -- hex SHA-256 of the content: its name in the files directory
                hash  text   NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$'),
                size  bigint NOT NULL CHECK (size >= 0),
                title text   NOT NULL CHECK (btrim(title) <> ''),
                -- for the photo's foreign key
                UNIQUE (%2$I, id)
            )$sql$, v_owner || '_attachment', v_owner);
        EXECUTE format('CREATE INDEX %I ON %I (%I)',
                       v_owner || '_attachment_' || v_owner || '_id_idx', v_owner || '_attachment', v_owner);
        -- "wtfd gc" looks files up by hash.
        EXECUTE format('CREATE INDEX %I ON %I (hash)',
                       v_owner || '_attachment_hash_idx', v_owner || '_attachment');

        -- The photo is one of the object's own attachments (the foreign key)
        -- and an image (the trigger below). Removing the attachment clears it.
        EXECUTE format('ALTER TABLE %1$I ADD COLUMN photo uuid NULL, '
                       'ADD FOREIGN KEY (id, photo) REFERENCES %2$I (%1$I, id) ON DELETE SET NULL (photo)',
                       v_owner, v_owner || '_attachment');

        -- Attachments are added to and changed on live objects only; a
        -- deleted object's attachments are frozen with it.
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I '
                       'FOR EACH ROW EXECUTE FUNCTION attachment_check_live(%L)',
                       v_owner || '_attachment_check_live', v_owner || '_attachment', v_owner);
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I '
                       'FOR EACH ROW EXECUTE FUNCTION record_history()',
                       v_owner || '_attachment_record_history', v_owner || '_attachment');
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF photo ON %I '
                       'FOR EACH ROW EXECUTE FUNCTION check_photo()',
                       v_owner || '_check_photo', v_owner);
    END LOOP;
END;
$$;
