-- Attachments, redone (see api/attachment.md):
--
--   - an attachment is a file's hash, its MIME type and a title;
--   - items, stock rows, locations and classes are linked to attachments
--     through a mapping table each, so an attachment can be on several of
--     them (a split stock row shares its attachments with the new row);
--   - each of them can name one of its own image attachments as its photo;
--   - an attachment that nothing links to any more is deleted at once, and
--     its file goes at the next "wtfd gc" when no attachment has its hash.
--
-- The file table, captions, file names, sizes, deleted attachments and the
-- primary photo flag are gone.

-- Deleted attachments could only be restored, and nothing restores any more.
DELETE FROM attachment WHERE deleted;

-- ---------------------------------------------------------------------------
-- Mapping tables
-- ---------------------------------------------------------------------------

CREATE TABLE item_attachment (
    item       uuid NOT NULL REFERENCES item (id) ON DELETE CASCADE,
    attachment uuid NOT NULL REFERENCES attachment (id) ON DELETE CASCADE,
    PRIMARY KEY (item, attachment)
);

CREATE TABLE stock_attachment (
    stock      uuid NOT NULL REFERENCES stock (id) ON DELETE CASCADE,
    attachment uuid NOT NULL REFERENCES attachment (id) ON DELETE CASCADE,
    PRIMARY KEY (stock, attachment)
);

CREATE TABLE location_attachment (
    location   uuid NOT NULL REFERENCES location (id) ON DELETE CASCADE,
    attachment uuid NOT NULL REFERENCES attachment (id) ON DELETE CASCADE,
    PRIMARY KEY (location, attachment)
);

CREATE TABLE class_attachment (
    class      uuid NOT NULL REFERENCES class (id) ON DELETE CASCADE,
    attachment uuid NOT NULL REFERENCES attachment (id) ON DELETE CASCADE,
    PRIMARY KEY (class, attachment)
);

CREATE INDEX item_attachment_attachment_id_idx     ON item_attachment (attachment);
CREATE INDEX stock_attachment_attachment_id_idx    ON stock_attachment (attachment);
CREATE INDEX location_attachment_attachment_id_idx ON location_attachment (attachment);
CREATE INDEX class_attachment_attachment_id_idx    ON class_attachment (attachment);

INSERT INTO item_attachment     SELECT item, id     FROM attachment WHERE item IS NOT NULL;
INSERT INTO stock_attachment    SELECT stock, id    FROM attachment WHERE stock IS NOT NULL;
INSERT INTO location_attachment SELECT location, id FROM attachment WHERE location IS NOT NULL;
INSERT INTO class_attachment    SELECT class, id    FROM attachment WHERE class IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Photos
-- ---------------------------------------------------------------------------

ALTER TABLE item     ADD COLUMN photo uuid NULL REFERENCES attachment (id) ON DELETE SET NULL;
ALTER TABLE stock    ADD COLUMN photo uuid NULL REFERENCES attachment (id) ON DELETE SET NULL;
ALTER TABLE location ADD COLUMN photo uuid NULL REFERENCES attachment (id) ON DELETE SET NULL;
ALTER TABLE class    ADD COLUMN photo uuid NULL REFERENCES attachment (id) ON DELETE SET NULL;

CREATE INDEX item_photo_id_idx     ON item (photo);
CREATE INDEX stock_photo_id_idx    ON stock (photo);
CREATE INDEX location_photo_id_idx ON location (photo);
CREATE INDEX class_photo_id_idx    ON class (photo);

-- The primary photos become photos. Deleted rows are frozen and every change
-- is logged, so the triggers are off for this one copy.
ALTER TABLE item     DISABLE TRIGGER USER;
ALTER TABLE stock    DISABLE TRIGGER USER;
ALTER TABLE location DISABLE TRIGGER USER;
ALTER TABLE class    DISABLE TRIGGER USER;
UPDATE item o     SET photo = a.id FROM attachment a WHERE a.item = o.id     AND a.primary_photo;
UPDATE stock o    SET photo = a.id FROM attachment a WHERE a.stock = o.id    AND a.primary_photo;
UPDATE location o SET photo = a.id FROM attachment a WHERE a.location = o.id AND a.primary_photo;
UPDATE class o    SET photo = a.id FROM attachment a WHERE a.class = o.id    AND a.primary_photo;
ALTER TABLE item     ENABLE TRIGGER USER;
ALTER TABLE stock    ENABLE TRIGGER USER;
ALTER TABLE location ENABLE TRIGGER USER;
ALTER TABLE class    ENABLE TRIGGER USER;

-- A photo is an image, and one of its object's own attachments.
CREATE FUNCTION check_photo() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type   text;
    v_linked boolean;
BEGIN
    IF NEW.photo IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT type INTO v_type FROM attachment WHERE id = NEW.photo;
    IF v_type NOT LIKE 'image/%' THEN
        RAISE EXCEPTION 'A photo must be an image; % is %', row_label('attachment', NEW.photo), v_type
            USING ERRCODE = 'check_violation';
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE %I = $1 AND attachment = $2)',
                   TG_TABLE_NAME || '_attachment', TG_TABLE_NAME)
        INTO v_linked USING NEW.id, NEW.photo;
    IF NOT v_linked THEN
        RAISE EXCEPTION 'The photo of % must be one of its own attachments', row_label(TG_TABLE_NAME, NEW.id)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER item_check_photo     BEFORE INSERT OR UPDATE OF photo ON item     FOR EACH ROW EXECUTE FUNCTION check_photo();
CREATE TRIGGER stock_check_photo    BEFORE INSERT OR UPDATE OF photo ON stock    FOR EACH ROW EXECUTE FUNCTION check_photo();
CREATE TRIGGER location_check_photo BEFORE INSERT OR UPDATE OF photo ON location FOR EACH ROW EXECUTE FUNCTION check_photo();
CREATE TRIGGER class_check_photo    BEFORE INSERT OR UPDATE OF photo ON class    FOR EACH ROW EXECUTE FUNCTION check_photo();

-- ---------------------------------------------------------------------------
-- The attachment table
-- ---------------------------------------------------------------------------

DROP TRIGGER attachment_block_change_when_deleted ON attachment;
DROP TRIGGER attachment_check_live ON attachment;
DROP FUNCTION attachment_check_live();

ALTER TABLE attachment DISABLE TRIGGER USER;
ALTER TABLE attachment
    ADD COLUMN hash  text NULL,
    ADD COLUMN title text NULL;
UPDATE attachment SET hash = encode(file, 'hex'), title = file_name;
ALTER TABLE attachment ENABLE TRIGGER USER;

ALTER TABLE attachment RENAME COLUMN content_type TO type;
ALTER TABLE attachment
    DROP COLUMN file,
    DROP COLUMN file_name,
    DROP COLUMN caption,
    DROP COLUMN primary_photo,
    DROP COLUMN item,
    DROP COLUMN stock,
    DROP COLUMN location,
    DROP COLUMN class,
    DROP COLUMN deleted;
ALTER TABLE attachment
    ALTER COLUMN hash  SET NOT NULL,
    ALTER COLUMN title SET NOT NULL,
    ADD CHECK (hash ~ '^[0-9a-f]{64}$'),
    ADD CHECK (btrim(title) <> '');

-- "wtfd gc" looks files up by hash.
CREATE INDEX attachment_hash_idx ON attachment (hash);

DROP TABLE file;

-- The advisory lock that serialises uploads and "wtfd gc" per file, now
-- keyed by the hex hash: its first 16 hex digits (8 bytes).
DROP FUNCTION file_lock_key(bytea);
CREATE FUNCTION file_lock_key(p_hash text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN ('x' || substr(p_hash, 1, 16))::bit(64)::bigint;
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
        WHEN 'attachment'       THEN (SELECT format('Attachment "%s"', title) FROM attachment WHERE id = p_id)
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rules for the mapping tables
-- ---------------------------------------------------------------------------

-- An attachment is only linked to a live object; the object of a mapping is
-- named by the column of the table's name without "_attachment".
CREATE FUNCTION attachment_link_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owner text := TG_ARGV[0];
BEGIN
    PERFORM check_live(v_owner, (to_jsonb(NEW) ->> v_owner)::uuid);
    RETURN NEW;
END;
$$;

-- When a link goes: the object's photo, if it was this attachment, goes
-- too; and an attachment that nothing links to any more is deleted.
CREATE FUNCTION attachment_link_removed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owner text := TG_ARGV[0];
BEGIN
    EXECUTE format('UPDATE %I SET photo = NULL WHERE id = $1 AND photo = $2', v_owner)
        USING (to_jsonb(OLD) ->> v_owner)::uuid, OLD.attachment;
    DELETE FROM attachment a
    WHERE a.id = OLD.attachment
      AND NOT EXISTS (SELECT 1 FROM item_attachment     WHERE attachment = a.id)
      AND NOT EXISTS (SELECT 1 FROM stock_attachment    WHERE attachment = a.id)
      AND NOT EXISTS (SELECT 1 FROM location_attachment WHERE attachment = a.id)
      AND NOT EXISTS (SELECT 1 FROM class_attachment    WHERE attachment = a.id);
    RETURN NULL;
END;
$$;

DO $$
DECLARE
    v_owner text;
BEGIN
    FOREACH v_owner IN ARRAY ARRAY['item', 'stock', 'location', 'class'] LOOP
        EXECUTE format(
            'CREATE TRIGGER %1$I BEFORE INSERT OR UPDATE ON %2$I '
            'FOR EACH ROW EXECUTE FUNCTION attachment_link_check_live(%3$L)',
            v_owner || '_attachment_check_live', v_owner || '_attachment', v_owner);
        EXECUTE format(
            'CREATE TRIGGER %1$I AFTER DELETE ON %2$I '
            'FOR EACH ROW EXECUTE FUNCTION attachment_link_removed(%3$L)',
            v_owner || '_attachment_removed', v_owner || '_attachment', v_owner);
        EXECUTE format(
            'CREATE TRIGGER %1$I AFTER INSERT OR UPDATE OR DELETE ON %2$I '
            'FOR EACH ROW EXECUTE FUNCTION record_history()',
            v_owner || '_attachment_record_history', v_owner || '_attachment');
    END LOOP;
END;
$$;
