-- Deleting by marking as deleted: items, stock rows, locations, classes,
-- attributes, options and attachments keep their rows, with deleted set.
-- Rules apply between live rows only; deleted rows are frozen until they are
-- restored or purged. Explained in SCHEMA.md and api/deleting.md.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

ALTER TABLE class            ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE location         ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE item             ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE stock            ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE attribute        ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE attribute_option ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE attachment       ADD COLUMN deleted boolean NOT NULL DEFAULT false;

-- A stock row merged into another by a move: deleted, and pointing to the
-- row its quantity went into, so its label still leads somewhere.
ALTER TABLE stock
    ADD COLUMN merged_into uuid NULL,
    ADD FOREIGN KEY (tenant, merged_into) REFERENCES stock (tenant, id) ON DELETE SET NULL (merged_into),
    ADD CONSTRAINT stock_merged_into_check CHECK (merged_into IS NULL OR deleted);

CREATE INDEX stock_merged_into_id_idx ON stock (merged_into) WHERE merged_into IS NOT NULL;

-- Restoring finds what was deleted together through history.
CREATE INDEX history_data_id_idx ON history ((data ->> 'id'));

-- ---------------------------------------------------------------------------
-- Names are unique among live rows
-- ---------------------------------------------------------------------------

DROP INDEX class_sibling_name_unique;
CREATE UNIQUE INDEX class_sibling_name_unique
    ON class (tenant, parent, lower(name)) NULLS NOT DISTINCT WHERE NOT deleted;

DROP INDEX location_sibling_name_unique;
CREATE UNIQUE INDEX location_sibling_name_unique
    ON location (tenant, parent, lower(name)) NULLS NOT DISTINCT WHERE NOT deleted;

DROP INDEX attribute_name_unique;
CREATE UNIQUE INDEX attribute_name_unique ON attribute (tenant, lower(name)) WHERE NOT deleted;

DROP INDEX attribute_option_name_unique;
CREATE UNIQUE INDEX attribute_option_name_unique
    ON attribute_option (attribute, lower(name)) WHERE NOT deleted;

DROP INDEX attachment_item_primary_photo_unique;
DROP INDEX attachment_stock_primary_photo_unique;
DROP INDEX attachment_location_primary_photo_unique;
DROP INDEX attachment_class_primary_photo_unique;
CREATE UNIQUE INDEX attachment_item_primary_photo_unique     ON attachment (item)     WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_stock_primary_photo_unique    ON attachment (stock)    WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_location_primary_photo_unique ON attachment (location) WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_class_primary_photo_unique    ON attachment (class)    WHERE primary_photo AND NOT deleted;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- How an error message names a row: Item "Drill", Location "Shelf 2", …
CREATE FUNCTION row_label(p_table text, p_id uuid) RETURNS text
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
        WHEN 'attachment'       THEN (SELECT format('Attachment "%s"', file_name) FROM attachment WHERE id = p_id)
    END;
END;
$$;

-- Raises "… is deleted" (SQLSTATE 55000, object_not_in_prerequisite_state),
-- which the REST layer maps to 409.
CREATE FUNCTION raise_deleted(p_table text, p_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is deleted', row_label(p_table, p_id)
        USING ERRCODE = 'object_not_in_prerequisite_state';
END;
$$;

-- Raises raise_deleted when the row p_id of p_table is deleted, and locks it
-- (FOR SHARE), so it can't be deleted until this transaction ends. NULL is
-- fine (no reference).
CREATE FUNCTION check_live(p_table text, p_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted boolean;
BEGIN
    IF p_id IS NULL THEN
        RETURN;
    END IF;
    EXECUTE format('SELECT deleted FROM %I WHERE id = $1 FOR SHARE', p_table) INTO v_deleted USING p_id;
    IF v_deleted THEN
        PERFORM raise_deleted(p_table, p_id);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Deleted rows are frozen
-- ---------------------------------------------------------------------------

-- A deleted row can only be restored (deleted set to false, possibly with a
-- new name or place) or purged. The one exception: merged_into is cleared
-- when the row it points to is purged.
CREATE FUNCTION block_change_when_deleted() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.deleted AND NEW.deleted
       AND (to_jsonb(NEW) - 'merged_into') IS DISTINCT FROM (to_jsonb(OLD) - 'merged_into')
    THEN
        PERFORM raise_deleted(TG_TABLE_NAME, OLD.id);
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'class', 'location', 'item', 'stock', 'attribute', 'attribute_option', 'attachment'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION block_change_when_deleted()',
            v_table || '_block_change_when_deleted', v_table);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Live rows only refer to live rows
-- ---------------------------------------------------------------------------

CREATE FUNCTION class_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.deleted THEN
        PERFORM check_live('class', NEW.parent);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER class_check_live
    BEFORE INSERT OR UPDATE ON class
    FOR EACH ROW EXECUTE FUNCTION class_check_live();

CREATE FUNCTION location_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.deleted THEN
        PERFORM check_live('location', NEW.parent);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER location_check_live
    BEFORE INSERT OR UPDATE ON location
    FOR EACH ROW EXECUTE FUNCTION location_check_live();

CREATE FUNCTION item_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.deleted THEN
        PERFORM check_live('class', NEW.class);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER item_check_live
    BEFORE INSERT OR UPDATE ON item
    FOR EACH ROW EXECUTE FUNCTION item_check_live();

CREATE FUNCTION stock_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.deleted THEN
        PERFORM check_live('item', NEW.item);
        PERFORM check_live('location', NEW.location);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_check_live
    BEFORE INSERT OR UPDATE ON stock
    FOR EACH ROW EXECUTE FUNCTION stock_check_live();

CREATE FUNCTION attribute_option_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.deleted THEN
        PERFORM check_live('attribute', NEW.attribute);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_option_check_live
    BEFORE INSERT OR UPDATE ON attribute_option
    FOR EACH ROW EXECUTE FUNCTION attribute_option_check_live();

-- Attachments, values and assignments are never marked deleted themselves:
-- they stay as they are while their owner is deleted, and can't be changed
-- then.
CREATE FUNCTION attachment_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_live('item', NEW.item);
    PERFORM check_live('stock', NEW.stock);
    PERFORM check_live('location', NEW.location);
    PERFORM check_live('class', NEW.class);
    RETURN NEW;
END;
$$;

CREATE TRIGGER attachment_check_live
    BEFORE INSERT OR UPDATE ON attachment
    FOR EACH ROW EXECUTE FUNCTION attachment_check_live();

CREATE FUNCTION value_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_live('item', NEW.item);
    PERFORM check_live('attribute', NEW.attribute);
    PERFORM check_live('attribute_option', NEW.option_value);
    RETURN NEW;
END;
$$;

CREATE TRIGGER value_check_live
    BEFORE INSERT OR UPDATE ON value
    FOR EACH ROW EXECUTE FUNCTION value_check_live();

CREATE FUNCTION stock_value_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_live('stock', NEW.stock);
    PERFORM check_live('attribute', NEW.attribute);
    PERFORM check_live('attribute_option', NEW.option_value);
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_value_check_live
    BEFORE INSERT OR UPDATE ON stock_value
    FOR EACH ROW EXECUTE FUNCTION stock_value_check_live();

CREATE FUNCTION class_attribute_check_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_live('class', NEW.class);
    PERFORM check_live('attribute', NEW.attribute);
    PERFORM check_live('attribute_option', NEW.option_default);
    RETURN NEW;
END;
$$;

CREATE TRIGGER class_attribute_check_live
    BEFORE INSERT OR UPDATE ON class_attribute
    FOR EACH ROW EXECUTE FUNCTION class_attribute_check_live();

-- ---------------------------------------------------------------------------
-- Only what nothing live depends on can be deleted
-- ---------------------------------------------------------------------------
-- Raised as 23001 (restrict_violation), as the foreign keys did when rows
-- were removed.

CREATE FUNCTION class_check_deletable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM class WHERE parent = NEW.id AND NOT deleted) THEN
        RAISE EXCEPTION 'Class "%" still has subclasses', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM item WHERE class = NEW.id AND NOT deleted) THEN
        RAISE EXCEPTION 'Class "%" still has items', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER class_check_deletable
    BEFORE UPDATE OF deleted ON class
    FOR EACH ROW
    WHEN (NEW.deleted AND NOT OLD.deleted)
    EXECUTE FUNCTION class_check_deletable();

CREATE FUNCTION location_check_deletable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM location WHERE parent = NEW.id AND NOT deleted) THEN
        RAISE EXCEPTION 'Location "%" still has locations inside it', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM stock WHERE location = NEW.id AND NOT deleted) THEN
        RAISE EXCEPTION 'Location "%" still has stock', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER location_check_deletable
    BEFORE UPDATE OF deleted ON location
    FOR EACH ROW
    WHEN (NEW.deleted AND NOT OLD.deleted)
    EXECUTE FUNCTION location_check_deletable();

CREATE FUNCTION item_check_deletable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM stock WHERE item = NEW.id AND NOT deleted) THEN
        RAISE EXCEPTION 'Item "%" still has stock', NEW.name
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER item_check_deletable
    BEFORE UPDATE OF deleted ON item
    FOR EACH ROW
    WHEN (NEW.deleted AND NOT OLD.deleted)
    EXECUTE FUNCTION item_check_deletable();

-- An attribute is in use while live items or stock rows have values for it,
-- or live classes assign it.
CREATE FUNCTION attribute_check_deletable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM value v JOIN item i ON i.id = v.item
               WHERE v.attribute = NEW.id AND NOT i.deleted)
       OR EXISTS (SELECT 1 FROM stock_value sv JOIN stock s ON s.id = sv.stock
                  WHERE sv.attribute = NEW.id AND NOT s.deleted)
       OR EXISTS (SELECT 1 FROM class_attribute ca JOIN class c ON c.id = ca.class
                  WHERE ca.attribute = NEW.id AND NOT c.deleted)
    THEN
        RAISE EXCEPTION 'Attribute "%" is still in use', NEW.name
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Remove it from its classes, and its values from items and stock rows, first.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_check_deletable
    BEFORE UPDATE OF deleted ON attribute
    FOR EACH ROW
    WHEN (NEW.deleted AND NOT OLD.deleted)
    EXECUTE FUNCTION attribute_check_deletable();

CREATE FUNCTION attribute_option_check_deletable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM value v JOIN item i ON i.id = v.item
               WHERE v.option_value = NEW.id AND NOT i.deleted)
       OR EXISTS (SELECT 1 FROM stock_value sv JOIN stock s ON s.id = sv.stock
                  WHERE sv.option_value = NEW.id AND NOT s.deleted)
       OR EXISTS (SELECT 1 FROM class_attribute ca JOIN class c ON c.id = ca.class
                  WHERE ca.option_default = NEW.id AND NOT c.deleted)
    THEN
        RAISE EXCEPTION 'Option "%" is still in use', NEW.name
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Change the values and defaults that use it first.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_option_check_deletable
    BEFORE UPDATE OF deleted ON attribute_option
    FOR EACH ROW
    WHEN (NEW.deleted AND NOT OLD.deleted)
    EXECUTE FUNCTION attribute_option_check_deletable();

-- ---------------------------------------------------------------------------
-- The existing rules, for live rows only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION item_check_class_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
           SELECT 1
           FROM value v
           WHERE v.item = NEW.id
             AND attribute_scope(NEW.class, v.attribute) IS DISTINCT FROM false
       )
       OR EXISTS (
           SELECT 1
           FROM stock s
           JOIN stock_value sv ON sv.stock = s.id
           WHERE s.item = NEW.id
             AND NOT s.deleted
             AND attribute_scope(NEW.class, sv.attribute) IS NOT TRUE
       )
    THEN
        RAISE EXCEPTION 'Item % has values for attributes that do not apply (in the same way) to class %',
            NEW.id, NEW.class
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION check_values_applicable_in_subtree(p_class_id uuid, p_attribute_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        WITH RECURSIVE subtree (id) AS (
            SELECT p_class_id
            UNION
            SELECT c.id
            FROM class c
            JOIN subtree s ON c.parent = s.id
        )
        SELECT 1
        FROM subtree s
        JOIN item i  ON i.class = s.id
        JOIN value v ON v.item = i.id
        WHERE NOT i.deleted
          AND (p_attribute_id IS NULL OR v.attribute = p_attribute_id)
          AND attribute_scope(i.class, v.attribute) IS DISTINCT FROM false
        UNION ALL
        SELECT 1
        FROM subtree s
        JOIN item i         ON i.class = s.id
        JOIN stock st       ON st.item = i.id
        JOIN stock_value sv ON sv.stock = st.id
        WHERE NOT i.deleted
          AND NOT st.deleted
          AND (p_attribute_id IS NULL OR sv.attribute = p_attribute_id)
          AND attribute_scope(i.class, sv.attribute) IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'Change would leave values without a matching attribute in class % or its descendants',
            p_class_id
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION attribute_check_datatype_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM value v JOIN item i ON i.id = v.item
               WHERE v.attribute = NEW.id AND NOT i.deleted)
       OR EXISTS (SELECT 1 FROM stock_value sv JOIN stock s ON s.id = sv.stock
                  WHERE sv.attribute = NEW.id AND NOT s.deleted)
       OR EXISTS (SELECT 1 FROM attribute_option o WHERE o.attribute = NEW.id AND NOT o.deleted)
       OR EXISTS (
           SELECT 1
           FROM class_attribute ca
           JOIN class c ON c.id = ca.class
           WHERE ca.attribute = NEW.id
             AND NOT c.deleted
             AND num_nonnulls(ca.text_default, ca.integer_default, ca.float_default,
                              ca.date_default, ca.boolean_default, ca.option_default) > 0
       )
    THEN
        RAISE EXCEPTION 'Cannot change datatype of attribute %: values, defaults or options exist',
            NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- Required values: checked for new and restored items and stock rows, at
-- commit.
CREATE OR REPLACE FUNCTION item_check_required() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_missing uuid[] := ARRAY(SELECT item_missing_attributes(NEW.id));
BEGIN
    IF EXISTS (SELECT 1 FROM item WHERE id = NEW.id AND NOT deleted) AND cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION 'Item % is missing required attributes: %', NEW.name, attribute_names(v_missing)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER item_check_required_restore
    AFTER UPDATE OF deleted ON item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.deleted AND NOT NEW.deleted)
    EXECUTE FUNCTION item_check_required();

CREATE OR REPLACE FUNCTION stock_check_required() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_missing uuid[] := ARRAY(SELECT stock_missing_attributes(NEW.id));
BEGIN
    IF EXISTS (SELECT 1 FROM stock WHERE id = NEW.id AND NOT deleted) AND cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION 'Stock row is missing required attributes: %', attribute_names(v_missing)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER stock_check_required_restore
    AFTER UPDATE OF deleted ON stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.deleted AND NOT NEW.deleted)
    EXECUTE FUNCTION stock_check_required();

-- Removing a value of a deleted (or purged) owner isn't checked.
CREATE OR REPLACE FUNCTION value_check_required_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM item WHERE id = OLD.item AND NOT deleted)
       AND OLD.attribute IN (SELECT item_missing_attributes(OLD.item))
    THEN
        RAISE EXCEPTION 'Attribute % is required and cannot be removed', attribute_names(ARRAY[OLD.attribute])
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION stock_value_check_required_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM stock WHERE id = OLD.stock AND NOT deleted)
       AND OLD.attribute IN (SELECT stock_missing_attributes(OLD.stock))
    THEN
        RAISE EXCEPTION 'Attribute % is required and cannot be removed', attribute_names(ARRAY[OLD.attribute])
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION class_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_items bigint;
BEGIN
    IF NEW.container AND NOT OLD.container THEN
        SELECT count(*) INTO v_items FROM item WHERE class = NEW.id AND NOT deleted;
        IF v_items > 0 THEN
            RAISE EXCEPTION 'Class "%" can''t become a container: it has % item(s)', NEW.name, v_items
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION location_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_stock bigint;
BEGIN
    IF NEW.container AND NOT OLD.container THEN
        SELECT count(*) INTO v_stock FROM stock WHERE location = NEW.id AND NOT deleted;
        IF v_stock > 0 THEN
            RAISE EXCEPTION 'Location "%" can''t become a container: it has % stock row(s)', NEW.name, v_stock
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
