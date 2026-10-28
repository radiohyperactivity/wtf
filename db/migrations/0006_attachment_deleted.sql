-- Deleting an attachment marks it deleted again, as for items, locations and
-- the rest (see api/deleting.md): it can be restored, until the operator
-- purges it ("wtfd deleted purge"); then "wtfd gc" removes its file once no
-- attachment has its hash. A deleted attachment is no object's photo.

DO $$
DECLARE
    v_owner text;
BEGIN
    FOREACH v_owner IN ARRAY ARRAY['item', 'stock', 'location', 'class'] LOOP
        EXECUTE format('ALTER TABLE %I ADD COLUMN deleted boolean NOT NULL DEFAULT false',
                       v_owner || '_attachment');
        -- A deleted attachment is frozen until it is restored.
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I '
                       'FOR EACH ROW EXECUTE FUNCTION block_change_when_deleted()',
                       v_owner || '_attachment_block_change_when_deleted', v_owner || '_attachment');
    END LOOP;
END;
$$;

-- A photo is an image, and not deleted. (That it is one of the object's own
-- attachments is the photo's foreign key.)
CREATE OR REPLACE FUNCTION check_photo() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type    text;
    v_title   text;
    v_deleted boolean;
BEGIN
    IF NEW.photo IS NULL THEN
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT type, title, deleted FROM %I WHERE id = $1', TG_TABLE_NAME || '_attachment')
        INTO v_type, v_title, v_deleted USING NEW.photo;
    IF v_type NOT LIKE 'image/%' THEN
        RAISE EXCEPTION 'A photo must be an image; "%" is %', v_title, v_type
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_deleted THEN
        RAISE EXCEPTION 'Attachment "%" is deleted', v_title
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END;
$$;
