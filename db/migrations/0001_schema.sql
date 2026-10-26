-- Types, tables, views, integrity triggers. Explained in SCHEMA.md.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

CREATE TYPE datatype AS ENUM (
    'text',
    'integer',
    'float',
    'date',
    'boolean',
    'url',
    'choice'
);

-- ---------------------------------------------------------------------------
-- Shared trigger functions
-- ---------------------------------------------------------------------------

-- True when the typed column matching p_datatype is the one that is set.
-- url is stored in the text column and must look like an http(s) URL.
-- Shared by the datatype triggers on value and class_attribute.
CREATE FUNCTION typed_column_is_set(
    p_datatype datatype,
    p_text     text,
    p_integer  bigint,
    p_float    double precision,
    p_date     date,
    p_boolean  boolean,
    p_option   uuid
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_datatype
        WHEN 'text'    THEN p_text    IS NOT NULL
        WHEN 'integer' THEN p_integer IS NOT NULL
        WHEN 'float'   THEN p_float   IS NOT NULL
        WHEN 'date'    THEN p_date    IS NOT NULL
        WHEN 'boolean' THEN p_boolean IS NOT NULL
        WHEN 'url'     THEN p_text    IS NOT NULL AND p_text ~* '^https?://\S+$'
        WHEN 'choice'  THEN p_option  IS NOT NULL
        ELSE false
    END;
$$;

-- Rejects a parent change that would make a row its own ancestor.
-- Used by every self-referencing tree table (class, location).
CREATE FUNCTION prevent_tree_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    creates_cycle boolean;
BEGIN
    IF NEW.parent IS NULL THEN
        RETURN NEW;
    END IF;

    EXECUTE format($q$
        WITH RECURSIVE ancestors(id) AS (
            SELECT $1
            UNION
            SELECT t.parent
            FROM %I.%I t
            JOIN ancestors a ON t.id = a.id
            WHERE t.parent IS NOT NULL
        )
        SELECT EXISTS (SELECT 1 FROM ancestors WHERE id = $2)
    $q$, TG_TABLE_SCHEMA, TG_TABLE_NAME)
    INTO creates_cycle
    USING NEW.parent, NEW.id;

    IF creates_cycle THEN
        RAISE EXCEPTION 'Setting parent of % to % would create a cycle in %',
            NEW.id, NEW.parent, TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- class
-- ---------------------------------------------------------------------------

CREATE TABLE class (
    id     uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    parent uuid NULL     REFERENCES class (id) ON DELETE RESTRICT,
    name   text NOT NULL CHECK (btrim(name) <> ''),
    CHECK (parent <> id)
);

CREATE UNIQUE INDEX class_sibling_name_unique
    ON class (parent, lower(name)) NULLS NOT DISTINCT;
CREATE INDEX class_parent_id_idx ON class (parent);

CREATE TRIGGER class_prevent_cycle
    BEFORE UPDATE OF parent ON class
    FOR EACH ROW EXECUTE FUNCTION prevent_tree_cycle();

-- ---------------------------------------------------------------------------
-- quantity
-- ---------------------------------------------------------------------------

CREATE TABLE quantity (
    id       uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    name     text     NOT NULL CHECK (btrim(name) <> ''),
    -- Datatype of numbers of this quantity: integer for counts, float otherwise.
    datatype datatype NOT NULL CHECK (datatype IN ('integer', 'float'))
);

CREATE UNIQUE INDEX quantity_name_unique ON quantity (lower(name));

-- ---------------------------------------------------------------------------
-- unit
-- ---------------------------------------------------------------------------

-- base = value × base_factor + base_offset converts a value in this unit to
-- the quantity's SI base unit. The offset is only non-zero for temperature
-- scales (°C, °F).
CREATE TABLE unit (
    id          uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    quantity    uuid    NOT NULL REFERENCES quantity (id) ON DELETE RESTRICT,
    name        text    NOT NULL CHECK (btrim(name) <> ''),
    symbol      text    NOT NULL CHECK (btrim(symbol) <> ''),
    base_factor numeric NOT NULL CHECK (base_factor > 0),
    base_offset numeric NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX unit_name_unique   ON unit (lower(name));
CREATE UNIQUE INDEX unit_symbol_unique ON unit (symbol);
CREATE UNIQUE INDEX unit_base_unique
    ON unit (quantity) WHERE base_factor = 1 AND base_offset = 0;
CREATE INDEX unit_quantity_id_idx ON unit (quantity);

-- ---------------------------------------------------------------------------
-- unit_group
-- ---------------------------------------------------------------------------

CREATE TABLE unit_group (
    id       uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    quantity uuid NOT NULL REFERENCES quantity (id) ON DELETE RESTRICT,
    name     text NOT NULL CHECK (btrim(name) <> '')
);

CREATE UNIQUE INDEX unit_group_name_unique ON unit_group (lower(name));
CREATE INDEX unit_group_quantity_id_idx ON unit_group (quantity);

CREATE TABLE unit_group_unit (
    unit_group uuid NOT NULL REFERENCES unit_group (id) ON DELETE CASCADE,
    unit       uuid NOT NULL REFERENCES unit (id) ON DELETE RESTRICT,
    PRIMARY KEY (unit_group, unit)
);

CREATE INDEX unit_group_unit_unit_id_idx ON unit_group_unit (unit);

CREATE FUNCTION unit_group_unit_check_quantity() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT quantity FROM unit_group WHERE id = NEW.unit_group)
       IS DISTINCT FROM (SELECT quantity FROM unit WHERE id = NEW.unit)
    THEN
        RAISE EXCEPTION 'Unit % does not measure the quantity of unit group %',
            NEW.unit, NEW.unit_group
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER unit_group_unit_check_quantity
    BEFORE INSERT OR UPDATE ON unit_group_unit
    FOR EACH ROW EXECUTE FUNCTION unit_group_unit_check_quantity();

-- ---------------------------------------------------------------------------
-- attribute
-- ---------------------------------------------------------------------------

CREATE TABLE attribute (
    id         uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text     NOT NULL CHECK (btrim(name) <> ''),
    datatype   datatype NOT NULL,
    -- Numbers of this attribute are stored in the base unit of the group's
    -- quantity, and scaled between the group's units on output.
    unit_group uuid     NULL     REFERENCES unit_group (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX attribute_name_unique ON attribute (lower(name));
CREATE INDEX attribute_unit_group_id_idx ON attribute (unit_group);

-- An attribute with a unit group must have its quantity's datatype.
CREATE FUNCTION attribute_check_unit_group() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.unit_group IS NOT NULL
       AND NEW.datatype IS DISTINCT FROM (
           SELECT q.datatype
           FROM unit_group g
           JOIN quantity q ON q.id = g.quantity
           WHERE g.id = NEW.unit_group
       )
    THEN
        RAISE EXCEPTION 'Attribute % must have the datatype of its unit group''s quantity', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_check_unit_group
    BEFORE INSERT OR UPDATE OF datatype, unit_group ON attribute
    FOR EACH ROW EXECUTE FUNCTION attribute_check_unit_group();

-- ---------------------------------------------------------------------------
-- attribute_option
-- ---------------------------------------------------------------------------

CREATE TABLE attribute_option (
    id        uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    attribute uuid NOT NULL REFERENCES attribute (id) ON DELETE CASCADE,
    name      text NOT NULL CHECK (btrim(name) <> ''),

    -- Target for the composite FKs from value and class_attribute, which keep
    -- an option within its own attribute.
    CONSTRAINT attribute_option_attribute_id_unique UNIQUE (attribute, id)
);

CREATE UNIQUE INDEX attribute_option_name_unique
    ON attribute_option (attribute, lower(name));

CREATE FUNCTION attribute_option_check_choice() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT datatype FROM attribute WHERE id = NEW.attribute FOR SHARE)
        IS DISTINCT FROM 'choice'
    THEN
        RAISE EXCEPTION 'Attribute % is not a choice attribute', NEW.attribute
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_option_check_choice
    BEFORE INSERT OR UPDATE OF attribute ON attribute_option
    FOR EACH ROW EXECUTE FUNCTION attribute_option_check_choice();

-- ---------------------------------------------------------------------------
-- class_attribute
-- ---------------------------------------------------------------------------

CREATE TABLE class_attribute (
    class           uuid             NOT NULL REFERENCES class (id) ON DELETE CASCADE,
    attribute       uuid             NOT NULL REFERENCES attribute (id) ON DELETE RESTRICT,
    -- Optional default value. At most one column is set, and the trigger
    -- below checks it matches the attribute's datatype.
    text_default    text             NULL,
    integer_default bigint           NULL,
    float_default   double precision NULL,
    date_default    date             NULL,
    boolean_default boolean          NULL,
    option_default  uuid             NULL,

    PRIMARY KEY (class, attribute),

    FOREIGN KEY (attribute, option_default)
        REFERENCES attribute_option (attribute, id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CHECK (num_nonnulls(text_default, integer_default, float_default,
                        date_default, boolean_default, option_default) <= 1)
);

CREATE INDEX class_attribute_attribute_id_idx ON class_attribute (attribute);

CREATE FUNCTION class_attribute_check_datatype() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF num_nonnulls(NEW.text_default, NEW.integer_default, NEW.float_default,
                    NEW.date_default, NEW.boolean_default, NEW.option_default) = 0
    THEN
        RETURN NEW;
    END IF;

    IF NOT typed_column_is_set(
        (SELECT datatype FROM attribute WHERE id = NEW.attribute FOR SHARE),
        NEW.text_default, NEW.integer_default, NEW.float_default,
        NEW.date_default, NEW.boolean_default, NEW.option_default
    ) THEN
        RAISE EXCEPTION 'Default for attribute % is not valid for its datatype', NEW.attribute
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER class_attribute_check_datatype
    BEFORE INSERT OR UPDATE ON class_attribute
    FOR EACH ROW EXECUTE FUNCTION class_attribute_check_datatype();

-- Every attribute that applies to a class, including inherited ones.
-- If an attribute is assigned at several levels, the nearest assignment wins,
-- including its default (or lack of one).
CREATE VIEW class_effective_attribute AS
WITH RECURSIVE lineage (class, ancestor, depth) AS (
    SELECT id, id, 0
    FROM class
    UNION ALL
    SELECT l.class, c.parent, l.depth + 1
    FROM lineage l
    JOIN class c ON c.id = l.ancestor
    WHERE c.parent IS NOT NULL
)
SELECT DISTINCT ON (l.class, ca.attribute)
    l.class,
    ca.attribute,
    ca.class    AS defined_on_class,
    l.depth     AS inherited_depth,
    ca.text_default,
    ca.integer_default,
    ca.float_default,
    ca.date_default,
    ca.boolean_default,
    ca.option_default
FROM lineage l
JOIN class_attribute ca ON ca.class = l.ancestor
ORDER BY l.class, ca.attribute, l.depth;

CREATE FUNCTION attribute_applies_to_class(p_class_id uuid, p_attribute_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE lineage (id) AS (
        SELECT p_class_id
        UNION
        SELECT c.parent
        FROM class c
        JOIN lineage l ON c.id = l.id
        WHERE c.parent IS NOT NULL
    )
    SELECT EXISTS (
        SELECT 1
        FROM class_attribute ca
        JOIN lineage l ON ca.class = l.id
        WHERE ca.attribute = p_attribute_id
    );
$$;

-- ---------------------------------------------------------------------------
-- item
-- ---------------------------------------------------------------------------

CREATE TABLE item (
    id         uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    class      uuid NOT NULL REFERENCES class (id) ON DELETE RESTRICT,
    name       text NOT NULL CHECK (btrim(name) <> ''),
    -- Stock quantities are stored in the base unit of this group's quantity.
    -- NULL = pieces.
    unit_group uuid NULL     REFERENCES unit_group (id) ON DELETE RESTRICT
);

CREATE INDEX item_class_id_idx      ON item (class);
CREATE INDEX item_unit_group_id_idx ON item (unit_group);

-- True when the item's stock must be counted in whole numbers: no unit group
-- (pieces), or a unit group of an integer quantity (Count).
CREATE FUNCTION item_counts_whole(p_item uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT i.unit_group IS NULL OR q.datatype = 'integer'
        FROM item i
        LEFT JOIN unit_group g ON g.id = i.unit_group
        LEFT JOIN quantity q   ON q.id = g.quantity
        WHERE i.id = p_item
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- value
-- ---------------------------------------------------------------------------

CREATE TABLE value (
    id            uuid             NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    item          uuid             NOT NULL REFERENCES item (id) ON DELETE CASCADE,
    attribute     uuid             NOT NULL REFERENCES attribute (id) ON DELETE RESTRICT,
    -- Exactly one column is set, and the trigger below checks it matches the
    -- attribute's datatype.
    text_value    text             NULL,
    integer_value bigint           NULL,
    float_value   double precision NULL,
    date_value    date             NULL,
    boolean_value boolean          NULL,
    option_value  uuid             NULL,

    FOREIGN KEY (attribute, option_value)
        REFERENCES attribute_option (attribute, id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT value_item_attribute_unique UNIQUE (item, attribute),

    CHECK (num_nonnulls(text_value, integer_value, float_value,
                        date_value, boolean_value, option_value) = 1)
);

CREATE INDEX value_attribute_id_idx    ON value (attribute);
CREATE INDEX value_value_option_id_idx ON value (option_value);

CREATE FUNCTION value_check_datatype() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT typed_column_is_set(
        (SELECT datatype FROM attribute WHERE id = NEW.attribute FOR SHARE),
        NEW.text_value, NEW.integer_value, NEW.float_value,
        NEW.date_value, NEW.boolean_value, NEW.option_value
    ) THEN
        RAISE EXCEPTION 'Value for attribute % is not valid for its datatype', NEW.attribute
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER value_check_datatype
    BEFORE INSERT OR UPDATE ON value
    FOR EACH ROW EXECUTE FUNCTION value_check_datatype();

CREATE FUNCTION value_check_applicable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT attribute_applies_to_class(
        (SELECT class FROM item WHERE id = NEW.item),
        NEW.attribute
    ) THEN
        RAISE EXCEPTION 'Attribute % does not apply to the class of item %',
            NEW.attribute, NEW.item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER value_check_applicable
    BEFORE INSERT OR UPDATE OF item, attribute ON value
    FOR EACH ROW EXECUTE FUNCTION value_check_applicable();

CREATE FUNCTION item_check_class_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM value v
        WHERE v.item = NEW.id
          AND NOT attribute_applies_to_class(NEW.class, v.attribute)
    ) THEN
        RAISE EXCEPTION 'Item % has values for attributes that do not apply to class %',
            NEW.id, NEW.class
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER item_check_class_change
    BEFORE UPDATE OF class ON item
    FOR EACH ROW EXECUTE FUNCTION item_check_class_change();

-- ---------------------------------------------------------------------------
-- Schema-change guards
-- ---------------------------------------------------------------------------

-- Raises if any item in the class subtree rooted at p_class_id has a value for
-- an attribute that no longer applies to its class. p_attribute_id narrows the
-- check to one attribute; NULL checks all of them.
CREATE FUNCTION check_values_applicable_in_subtree(p_class_id uuid, p_attribute_id uuid)
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
        WHERE (p_attribute_id IS NULL OR v.attribute = p_attribute_id)
          AND NOT attribute_applies_to_class(i.class, v.attribute)
    ) THEN
        RAISE EXCEPTION 'Change would leave values without a matching attribute in class % or its descendants',
            p_class_id
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

-- Changing an attribute's datatype.
CREATE FUNCTION attribute_check_datatype_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM value v WHERE v.attribute = NEW.id)
       OR EXISTS (SELECT 1 FROM attribute_option o WHERE o.attribute = NEW.id)
       OR EXISTS (
           SELECT 1
           FROM class_attribute ca
           WHERE ca.attribute = NEW.id
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

CREATE TRIGGER attribute_check_datatype_change
    BEFORE UPDATE OF datatype ON attribute
    FOR EACH ROW
    WHEN (OLD.datatype IS DISTINCT FROM NEW.datatype)
    EXECUTE FUNCTION attribute_check_datatype_change();

-- Removing an attribute from a class.
CREATE FUNCTION class_attribute_check_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_values_applicable_in_subtree(OLD.class, OLD.attribute);
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_attribute_check_removal
    AFTER DELETE OR UPDATE OF class, attribute ON class_attribute
    FOR EACH ROW EXECUTE FUNCTION class_attribute_check_removal();

-- Moving a class to a different parent.
CREATE FUNCTION class_check_reparent() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_values_applicable_in_subtree(NEW.id, NULL);
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_check_reparent
    AFTER UPDATE OF parent ON class
    FOR EACH ROW
    WHEN (OLD.parent IS DISTINCT FROM NEW.parent)
    EXECUTE FUNCTION class_check_reparent();

-- An attribute's or item's unit group can only change to another group of the
-- same quantity (e.g. Metric length -> Imperial length). Numbers are stored in
-- the base unit, so nothing needs converting. Adding a group where there was
-- none, or removing one, is not allowed.
CREATE FUNCTION check_unit_group_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.unit_group IS NULL
       OR NEW.unit_group IS NULL
       OR (SELECT quantity FROM unit_group WHERE id = OLD.unit_group)
          IS DISTINCT FROM (SELECT quantity FROM unit_group WHERE id = NEW.unit_group)
    THEN
        RAISE EXCEPTION 'The unit group of % % can only change to a group of the same quantity',
            TG_TABLE_NAME, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_check_unit_group_change
    BEFORE UPDATE OF unit_group ON attribute
    FOR EACH ROW
    WHEN (OLD.unit_group IS DISTINCT FROM NEW.unit_group)
    EXECUTE FUNCTION check_unit_group_change();

CREATE TRIGGER item_check_unit_group_change
    BEFORE UPDATE OF unit_group ON item
    FOR EACH ROW
    WHEN (OLD.unit_group IS DISTINCT FROM NEW.unit_group)
    EXECUTE FUNCTION check_unit_group_change();

-- ---------------------------------------------------------------------------
-- location
-- ---------------------------------------------------------------------------

CREATE TABLE location (
    id     uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    parent uuid NULL     REFERENCES location (id) ON DELETE RESTRICT,
    name   text NOT NULL CHECK (btrim(name) <> ''),
    CHECK (parent <> id)
);

CREATE UNIQUE INDEX location_sibling_name_unique
    ON location (parent, lower(name)) NULLS NOT DISTINCT;
CREATE INDEX location_parent_id_idx ON location (parent);

CREATE TRIGGER location_prevent_cycle
    BEFORE UPDATE OF parent ON location
    FOR EACH ROW EXECUTE FUNCTION prevent_tree_cycle();

-- ---------------------------------------------------------------------------
-- stock
-- ---------------------------------------------------------------------------

-- One row per physical thing or batch of things. The same item may have
-- several rows at the same location (e.g. two identical drills).
-- quantity is in the base unit of the item's unit group (pieces if none).
-- quantity NULL = present, but not counted ("some cable ties").
-- quantity 0    = none left, but this is where they belong.
CREATE TABLE stock (
    id       uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    item     uuid    NOT NULL REFERENCES item (id) ON DELETE RESTRICT,
    location uuid    NOT NULL REFERENCES location (id) ON DELETE RESTRICT,
    quantity numeric NULL     CHECK (quantity >= 0)
);

CREATE INDEX stock_item_id_idx     ON stock (item);
CREATE INDEX stock_location_id_idx ON stock (location);

CREATE FUNCTION stock_check_whole() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.quantity <> trunc(NEW.quantity) AND item_counts_whole(NEW.item) THEN
        RAISE EXCEPTION 'Stock of item % must be a whole number', NEW.item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_check_whole
    BEFORE INSERT OR UPDATE OF item, quantity ON stock
    FOR EACH ROW EXECUTE FUNCTION stock_check_whole();

-- ---------------------------------------------------------------------------
-- data_version
-- ---------------------------------------------------------------------------

-- One change counter per tracked table. The REST layer exposes it as an ETag.
CREATE TABLE data_version (
    name    text   NOT NULL PRIMARY KEY,
    version bigint NOT NULL DEFAULT 1
);

INSERT INTO data_version (name) VALUES ('class'), ('location');

CREATE FUNCTION bump_data_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE data_version
    SET version = version + 1
    WHERE name = TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_bump_data_version
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON class
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();

CREATE TRIGGER location_bump_data_version
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON location
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version();
