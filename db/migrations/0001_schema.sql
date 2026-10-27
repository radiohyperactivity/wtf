-- Types, tables, views and integrity triggers. Explained in SCHEMA.md.

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

CREATE TYPE privilege AS ENUM ('none', 'read_only', 'read_write');

CREATE TYPE history_operation AS ENUM ('insert', 'update', 'delete');

-- ---------------------------------------------------------------------------
-- pgcrypto, in a schema of its own that wtf_api has no access to
-- ---------------------------------------------------------------------------

CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Shared trigger functions
-- ---------------------------------------------------------------------------

-- True when the typed column matching p_datatype is the one that is set.
-- url is stored in the text column and must look like an http(s) URL.
-- Shared by the datatype triggers on value, stock_value and class_attribute.
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

-- A deleted row can only be restored (deleted set to false, possibly with a
-- new name or place) or purged. The one exception: merged_into is cleared
-- when the row it points to is purged. Attached as <table>_block_change_when_deleted,
-- so it runs before the other BEFORE UPDATE triggers of its table.
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

-- ---------------------------------------------------------------------------
-- Quantities, unit families and units (system data, see seed/units.md)
-- ---------------------------------------------------------------------------
-- Numbers of a quantity are stored in its base unit: the unit with factor 1
-- and offset 0, usually the SI unit. A family is a set of units of one
-- quantity that are used together (Metric length: nm … km), and numbers are
-- scaled between them on output. Every unit is in exactly one family; the
-- base unit need not be in any.

CREATE TABLE quantity (
    id       integer  NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY (START WITH 1000),
    name     text     NOT NULL CHECK (btrim(name) <> ''),
    -- Datatype of numbers of this quantity: integer for counts, float otherwise.
    datatype datatype NOT NULL CHECK (datatype IN ('integer', 'float'))
);

CREATE UNIQUE INDEX quantity_name_unique ON quantity (lower(name));

CREATE TABLE unit_family (
    id       integer NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY (START WITH 1000),
    quantity integer NOT NULL REFERENCES quantity (id) ON DELETE RESTRICT,
    name     text    NOT NULL CHECK (btrim(name) <> '')
);

CREATE UNIQUE INDEX unit_family_name_unique ON unit_family (lower(name));
CREATE INDEX unit_family_quantity_id_idx ON unit_family (quantity);

-- base = value × base_factor + base_offset converts a value in this unit to
-- the quantity's base unit. The offset is only non-zero for temperature
-- scales (°C, °F).
CREATE TABLE unit (
    id          integer NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY (START WITH 1000),
    family      integer NOT NULL REFERENCES unit_family (id) ON DELETE RESTRICT,
    name        text    NOT NULL CHECK (btrim(name) <> ''),
    symbol      text    NOT NULL CHECK (btrim(symbol) <> ''),
    base_factor numeric NOT NULL CHECK (base_factor > 0),
    base_offset numeric NOT NULL DEFAULT 0
);

-- Case-sensitive: mS (millisiemens) and ms (millisecond) are different.
CREATE UNIQUE INDEX unit_symbol_unique ON unit (family, symbol);
CREATE UNIQUE INDEX unit_name_unique   ON unit (family, lower(name));
CREATE INDEX unit_family_id_idx ON unit (family);

-- The same symbol may appear in several families of a quantity (B in decimal
-- and binary bytes), but then it must mean the same unit, so a number typed
-- with that symbol converts the same whichever unit is picked.
CREATE FUNCTION unit_check_symbol() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_other record;
BEGIN
    SELECT u.base_factor, u.base_offset, f.name AS family INTO v_other
    FROM unit u
    JOIN unit_family f ON f.id = u.family
    WHERE u.symbol = NEW.symbol
      AND u.id <> NEW.id
      AND f.quantity = (SELECT quantity FROM unit_family WHERE id = NEW.family)
      AND (u.base_factor <> NEW.base_factor OR u.base_offset <> NEW.base_offset)
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Unit symbol "%" already means a different unit in family "%"', NEW.symbol, v_other.family
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER unit_check_symbol
    BEFORE INSERT OR UPDATE OF family, symbol, base_factor, base_offset ON unit
    FOR EACH ROW EXECUTE FUNCTION unit_check_symbol();

-- The quantity of a unit, through its family.
CREATE FUNCTION unit_quantity(p_unit integer) RETURNS integer
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT f.quantity FROM unit u JOIN unit_family f ON f.id = u.family WHERE u.id = p_unit);
END;
$$;

-- An attribute's or item's unit can only change to another unit of the same
-- quantity (e.g. mm -> in). Numbers are stored in the base unit, so nothing
-- needs converting. Adding a unit where there was none, or removing one, is
-- not allowed.
CREATE FUNCTION check_unit_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.unit IS NULL
       OR NEW.unit IS NULL
       OR unit_quantity(OLD.unit) IS DISTINCT FROM unit_quantity(NEW.unit)
    THEN
        RAISE EXCEPTION 'The unit of % % can only change to another unit of the same quantity',
            TG_TABLE_NAME, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Accounts and sessions (see ACCOUNTS.md)
-- ---------------------------------------------------------------------------

-- A user. The email address is the user name.
CREATE TABLE account (
    id                uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    email             text        NOT NULL CHECK (btrim(email) <> ''),
    -- bcrypt hash (pgcrypto); NULL = the account can't log in.
    password_hash     text        NULL,
    data_privilege    privilege   NOT NULL DEFAULT 'none',
    model_privilege   privilege   NOT NULL DEFAULT 'none',
    account_privilege privilege   NOT NULL DEFAULT 'none',
    history_privilege privilege   NOT NULL DEFAULT 'none',
    -- Lockout after repeated failed logins (see ACCOUNTS.md).
    failed_logins     integer     NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    last_failed_login timestamptz NULL,
    -- A deleted account keeps its row, so history can still say who did
    -- what. It can't log in, and its email can be used again.
    deleted           boolean     NOT NULL DEFAULT false
);

CREATE UNIQUE INDEX account_email_unique ON account (lower(email)) WHERE NOT deleted;

-- A login. Only the SHA-256 hash of the token is stored.
CREATE TABLE session (
    token_hash bytea       NOT NULL PRIMARY KEY CHECK (length(token_hash) = 32),
    account    uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    last_used  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX session_account_id_idx ON session (account);

-- ---------------------------------------------------------------------------
-- Codes
-- ---------------------------------------------------------------------------

-- Short codes for labels on locations, items and stock rows. One sequence for
-- all three tables, so every code is unique across all of them by
-- construction. It starts at 32768 = 32^3, the smallest number whose
-- Crockford Base32 rendering has four characters ("1000"); codes grow to five
-- characters after "ZZZZ" (1048575).
CREATE SEQUENCE code_sequence START WITH 32768;

-- ---------------------------------------------------------------------------
-- class
-- ---------------------------------------------------------------------------

CREATE TABLE class (
    id        uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    parent    uuid    NULL     REFERENCES class (id) ON DELETE RESTRICT,
    -- "/" separates the names in a path ("Tools/Drills"), so a path always
    -- means one thing.
    name      text    NOT NULL CHECK (btrim(name) <> '' AND strpos(name, '/') = 0),
    -- A container holds only other classes, no items.
    container boolean NOT NULL DEFAULT false,
    deleted   boolean NOT NULL DEFAULT false,
    CHECK (parent <> id)
);

-- Names are unique among live siblings.
CREATE UNIQUE INDEX class_sibling_name_unique
    ON class (parent, lower(name)) NULLS NOT DISTINCT WHERE NOT deleted;
CREATE INDEX class_parent_id_idx ON class (parent);

CREATE TRIGGER class_prevent_cycle
    BEFORE UPDATE OF parent ON class
    FOR EACH ROW EXECUTE FUNCTION prevent_tree_cycle();

-- ---------------------------------------------------------------------------
-- attribute
-- ---------------------------------------------------------------------------

CREATE TABLE attribute (
    id        uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    name      text     NOT NULL CHECK (btrim(name) <> ''),
    datatype  datatype NOT NULL,
    -- Numbers of this attribute are stored in the base unit of the unit's
    -- quantity. They are entered in this unit by default, and shown in it
    -- with unit_lock; otherwise scaled between the units of its family.
    unit      integer  NULL     REFERENCES unit (id) ON DELETE RESTRICT,
    unit_lock boolean  NOT NULL DEFAULT false,
    deleted   boolean  NOT NULL DEFAULT false,
    CHECK (unit IS NOT NULL OR NOT unit_lock)
);

CREATE UNIQUE INDEX attribute_name_unique ON attribute (lower(name)) WHERE NOT deleted;
CREATE INDEX attribute_unit_id_idx ON attribute (unit);

-- An attribute with a unit must have its quantity's datatype.
CREATE FUNCTION attribute_check_unit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.unit IS NOT NULL
       AND NEW.datatype IS DISTINCT FROM (SELECT datatype FROM quantity WHERE id = unit_quantity(NEW.unit))
    THEN
        RAISE EXCEPTION 'Attribute "%" must have the datatype of its unit''s quantity', NEW.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER attribute_check_unit
    BEFORE INSERT OR UPDATE OF datatype, unit ON attribute
    FOR EACH ROW EXECUTE FUNCTION attribute_check_unit();

CREATE TRIGGER attribute_check_unit_change
    BEFORE UPDATE OF unit ON attribute
    FOR EACH ROW
    WHEN (OLD.unit IS DISTINCT FROM NEW.unit)
    EXECUTE FUNCTION check_unit_change();

-- ---------------------------------------------------------------------------
-- attribute_option
-- ---------------------------------------------------------------------------

CREATE TABLE attribute_option (
    id        uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    attribute uuid    NOT NULL REFERENCES attribute (id) ON DELETE CASCADE,
    name      text    NOT NULL CHECK (btrim(name) <> ''),
    deleted   boolean NOT NULL DEFAULT false,

    -- Target for the composite FKs from value, stock_value and
    -- class_attribute, which keep an option within its own attribute.
    CONSTRAINT attribute_option_attribute_id_unique UNIQUE (attribute, id)
);

CREATE UNIQUE INDEX attribute_option_name_unique
    ON attribute_option (attribute, lower(name)) WHERE NOT deleted;

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
    -- per_unit: values live on stock rows (each physical thing or batch)
    -- instead of on the item. required: objects created in the class must
    -- have a value (or the class must provide a default).
    per_unit        boolean          NOT NULL DEFAULT false,
    required        boolean          NOT NULL DEFAULT false,

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
-- including its default (or lack of one), per_unit and required.
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
    ca.option_default,
    ca.per_unit,
    ca.required
FROM lineage l
JOIN class_attribute ca ON ca.class = l.ancestor
ORDER BY l.class, ca.attribute, l.depth;

-- How an attribute applies to a class, by the nearest assignment: NULL = not
-- at all, false = per kind (values on items), true = per unit (values on
-- stock rows).
CREATE FUNCTION attribute_scope(p_class uuid, p_attribute uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH RECURSIVE lineage (id, depth) AS (
            SELECT p_class, 0
            UNION ALL
            SELECT c.parent, l.depth + 1
            FROM class c
            JOIN lineage l ON c.id = l.id
            WHERE c.parent IS NOT NULL
        )
        SELECT ca.per_unit
        FROM lineage l
        JOIN class_attribute ca ON ca.class = l.id
        WHERE ca.attribute = p_attribute
        ORDER BY l.depth
        LIMIT 1
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- item
-- ---------------------------------------------------------------------------

CREATE TABLE item (
    id        uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    code      bigint  NOT NULL DEFAULT nextval('code_sequence'),
    class     uuid    NOT NULL REFERENCES class (id) ON DELETE RESTRICT,
    name      text    NOT NULL CHECK (btrim(name) <> ''),
    -- Stock quantities are stored in the base unit of this unit's quantity,
    -- and entered and shown as for an attribute's unit. NULL = pieces.
    unit      integer NULL     REFERENCES unit (id) ON DELETE RESTRICT,
    unit_lock boolean NOT NULL DEFAULT false,
    deleted   boolean NOT NULL DEFAULT false,
    CHECK (unit IS NOT NULL OR NOT unit_lock)
);

CREATE UNIQUE INDEX item_code_unique ON item (code);
CREATE INDEX item_class_id_idx ON item (class);
CREATE INDEX item_unit_id_idx  ON item (unit);

CREATE TRIGGER item_check_unit_change
    BEFORE UPDATE OF unit ON item
    FOR EACH ROW
    WHEN (OLD.unit IS DISTINCT FROM NEW.unit)
    EXECUTE FUNCTION check_unit_change();

-- True when the item's stock must be counted in whole numbers: no unit
-- (pieces), or a unit of an integer quantity (Count).
CREATE FUNCTION item_counts_whole(p_item uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT i.unit IS NULL OR q.datatype = 'integer'
        FROM item i
        LEFT JOIN quantity q ON q.id = unit_quantity(i.unit)
        WHERE i.id = p_item
    );
END;
$$;

-- An item's class must not be a container. The class row is locked, so a
-- concurrent change of its container flag waits for this transaction.
CREATE FUNCTION item_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_class record;
BEGIN
    SELECT name, container INTO v_class FROM class WHERE id = NEW.class FOR SHARE;
    IF v_class.container THEN
        RAISE EXCEPTION 'Class "%" is a container: it holds only other classes, not items', v_class.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER item_check_container
    BEFORE INSERT OR UPDATE OF class ON item
    FOR EACH ROW EXECUTE FUNCTION item_check_container();

-- A class can only become a container while it has no live items.
CREATE FUNCTION class_check_container() RETURNS trigger
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

CREATE TRIGGER class_check_container
    BEFORE UPDATE OF container ON class
    FOR EACH ROW EXECUTE FUNCTION class_check_container();

-- ---------------------------------------------------------------------------
-- value: values of per-kind attributes
-- ---------------------------------------------------------------------------

CREATE TABLE value (
    id            uuid             NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    item          uuid             NOT NULL REFERENCES item (id) ON DELETE CASCADE,
    attribute     uuid             NOT NULL REFERENCES attribute (id) ON DELETE RESTRICT,
    -- Exactly one column is set, and the trigger below checks it matches the
    -- attribute's datatype. Numbers with a unit are in the base unit.
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

-- Only uses columns that value and stock_value share.
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
    IF attribute_scope((SELECT class FROM item WHERE id = NEW.item), NEW.attribute) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Attribute % is not a per-kind attribute of the class of item %',
            NEW.attribute, NEW.item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER value_check_applicable
    BEFORE INSERT OR UPDATE OF item, attribute ON value
    FOR EACH ROW EXECUTE FUNCTION value_check_applicable();

-- ---------------------------------------------------------------------------
-- location
-- ---------------------------------------------------------------------------

CREATE TABLE location (
    id        uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    code      bigint  NOT NULL DEFAULT nextval('code_sequence'),
    parent    uuid    NULL     REFERENCES location (id) ON DELETE RESTRICT,
    -- "/" separates the names in a path ("Garage/Shelf 2").
    name      text    NOT NULL CHECK (btrim(name) <> '' AND strpos(name, '/') = 0),
    -- A container holds only other locations, no stock.
    container boolean NOT NULL DEFAULT false,
    deleted   boolean NOT NULL DEFAULT false,
    CHECK (parent <> id)
);

CREATE UNIQUE INDEX location_code_unique ON location (code);
CREATE UNIQUE INDEX location_sibling_name_unique
    ON location (parent, lower(name)) NULLS NOT DISTINCT WHERE NOT deleted;
CREATE INDEX location_parent_id_idx ON location (parent);

CREATE TRIGGER location_prevent_cycle
    BEFORE UPDATE OF parent ON location
    FOR EACH ROW EXECUTE FUNCTION prevent_tree_cycle();

-- ---------------------------------------------------------------------------
-- stock
-- ---------------------------------------------------------------------------

-- One row per physical thing or batch of things. The same item may have
-- several rows at the same location (e.g. two identical drills).
-- quantity is in the base unit of the item's unit (pieces if none).
-- quantity NULL = present, but not counted ("some cable ties").
-- quantity 0    = none left, but this is where they belong.
CREATE TABLE stock (
    id          uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    code        bigint  NOT NULL DEFAULT nextval('code_sequence'),
    item        uuid    NOT NULL REFERENCES item (id) ON DELETE RESTRICT,
    location    uuid    NOT NULL REFERENCES location (id) ON DELETE RESTRICT,
    quantity    numeric NULL     CHECK (quantity >= 0),
    deleted     boolean NOT NULL DEFAULT false,
    -- A row merged into another by a move: deleted, and pointing to the row
    -- its quantity went into, so its label still leads somewhere.
    merged_into uuid    NULL     REFERENCES stock (id) ON DELETE SET NULL,
    CHECK (merged_into IS NULL OR deleted)
);

CREATE UNIQUE INDEX stock_code_unique ON stock (code);
CREATE INDEX stock_item_id_idx        ON stock (item);
CREATE INDEX stock_location_id_idx    ON stock (location);
CREATE INDEX stock_merged_into_id_idx ON stock (merged_into) WHERE merged_into IS NOT NULL;

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

-- A stock row's location must not be a container (this covers moves too).
CREATE FUNCTION stock_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_location record;
BEGIN
    SELECT name, container INTO v_location FROM location WHERE id = NEW.location FOR SHARE;
    IF v_location.container THEN
        RAISE EXCEPTION 'Location "%" is a container: it holds only other locations, not stock', v_location.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_check_container
    BEFORE INSERT OR UPDATE OF location ON stock
    FOR EACH ROW EXECUTE FUNCTION stock_check_container();

-- A location can only become a container while it has no live stock.
CREATE FUNCTION location_check_container() RETURNS trigger
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

CREATE TRIGGER location_check_container
    BEFORE UPDATE OF container ON location
    FOR EACH ROW EXECUTE FUNCTION location_check_container();

-- ---------------------------------------------------------------------------
-- stock_value: values of per-unit attributes
-- ---------------------------------------------------------------------------

CREATE TABLE stock_value (
    stock         uuid             NOT NULL REFERENCES stock (id) ON DELETE CASCADE,
    attribute     uuid             NOT NULL REFERENCES attribute (id) ON DELETE RESTRICT,
    -- Exactly one column is set, matching the attribute's datatype; numbers
    -- with a unit are in the base unit. Same rules as value.
    text_value    text             NULL,
    integer_value bigint           NULL,
    float_value   double precision NULL,
    date_value    date             NULL,
    boolean_value boolean          NULL,
    option_value  uuid             NULL,

    PRIMARY KEY (stock, attribute),

    FOREIGN KEY (attribute, option_value)
        REFERENCES attribute_option (attribute, id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CHECK (num_nonnulls(text_value, integer_value, float_value,
                        date_value, boolean_value, option_value) = 1)
);

CREATE INDEX stock_value_attribute_id_idx    ON stock_value (attribute);
CREATE INDEX stock_value_option_value_id_idx ON stock_value (option_value);

CREATE TRIGGER stock_value_check_datatype
    BEFORE INSERT OR UPDATE ON stock_value
    FOR EACH ROW EXECUTE FUNCTION value_check_datatype();

CREATE FUNCTION stock_value_check_applicable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF attribute_scope(
           (SELECT i.class FROM stock s JOIN item i ON i.id = s.item WHERE s.id = NEW.stock),
           NEW.attribute
       ) IS NOT TRUE
    THEN
        RAISE EXCEPTION 'Attribute % is not a per-unit attribute of the class of stock row %',
            NEW.attribute, NEW.stock
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_value_check_applicable
    BEFORE INSERT OR UPDATE OF stock, attribute ON stock_value
    FOR EACH ROW EXECUTE FUNCTION stock_value_check_applicable();

-- ---------------------------------------------------------------------------
-- Attachments
-- ---------------------------------------------------------------------------

-- A stored file, identified by its content. The bytes live on disk, in
-- wtfd's files directory, named by the SHA-256 hash; the same content is
-- stored once however often it is attached.
CREATE TABLE file (
    sha256 bytea  NOT NULL PRIMARY KEY CHECK (length(sha256) = 32),
    size   bigint NOT NULL CHECK (size >= 0)
);

-- A file attached to exactly one item, stock row, location or class.
CREATE TABLE attachment (
    id            uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    file          bytea   NOT NULL REFERENCES file (sha256) ON DELETE RESTRICT,
    file_name     text    NOT NULL CHECK (btrim(file_name) <> ''),
    content_type  text    NOT NULL CHECK (btrim(content_type) <> ''),
    caption       text    NULL,
    -- The main picture of its object; at most one live one per object, and
    -- an image.
    primary_photo boolean NOT NULL DEFAULT false,
    item          uuid    NULL     REFERENCES item (id) ON DELETE CASCADE,
    stock         uuid    NULL     REFERENCES stock (id) ON DELETE CASCADE,
    location      uuid    NULL     REFERENCES location (id) ON DELETE CASCADE,
    class         uuid    NULL     REFERENCES class (id) ON DELETE CASCADE,
    deleted       boolean NOT NULL DEFAULT false,

    CHECK (num_nonnulls(item, stock, location, class) = 1),
    CHECK (NOT primary_photo OR content_type LIKE 'image/%')
);

CREATE INDEX attachment_file_id_idx     ON attachment (file);
CREATE INDEX attachment_item_id_idx     ON attachment (item);
CREATE INDEX attachment_stock_id_idx    ON attachment (stock);
CREATE INDEX attachment_location_id_idx ON attachment (location);
CREATE INDEX attachment_class_id_idx    ON attachment (class);

CREATE UNIQUE INDEX attachment_item_primary_photo_unique     ON attachment (item)     WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_stock_primary_photo_unique    ON attachment (stock)    WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_location_primary_photo_unique ON attachment (location) WHERE primary_photo AND NOT deleted;
CREATE UNIQUE INDEX attachment_class_primary_photo_unique    ON attachment (class)    WHERE primary_photo AND NOT deleted;

-- Key of the advisory lock that serialises uploads and "wtfd gc" per file:
-- the first 8 bytes of the hash.
CREATE FUNCTION file_lock_key(p_sha256 bytea) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN ('x' || encode(substr(p_sha256, 1, 8), 'hex'))::bit(64)::bigint;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rules that keep values matching their attributes
-- ---------------------------------------------------------------------------

CREATE FUNCTION item_check_class_change() RETURNS trigger
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

CREATE TRIGGER item_check_class_change
    BEFORE UPDATE OF class ON item
    FOR EACH ROW EXECUTE FUNCTION item_check_class_change();

-- Moving a stock row to another item: its values must apply to that item's class.
CREATE FUNCTION stock_check_item_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM stock_value sv
        WHERE sv.stock = NEW.id
          AND attribute_scope((SELECT class FROM item WHERE id = NEW.item), sv.attribute) IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'Stock row % has values for attributes that are not per-unit attributes of item %',
            NEW.id, NEW.item
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER stock_check_item_change
    BEFORE UPDATE OF item ON stock
    FOR EACH ROW
    WHEN (OLD.item IS DISTINCT FROM NEW.item)
    EXECUTE FUNCTION stock_check_item_change();

-- Raises if any live item in the class subtree rooted at p_class_id has a
-- value for an attribute that no longer applies to its class (in the same
-- scope). p_attribute_id narrows the check to one attribute; NULL checks all
-- of them.
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

-- Removing an attribute from a class, or changing its scope (per_unit).
CREATE FUNCTION class_attribute_check_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_values_applicable_in_subtree(OLD.class, OLD.attribute);
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_attribute_check_removal
    AFTER DELETE OR UPDATE OF class, attribute, per_unit ON class_attribute
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

-- Changing an attribute's datatype, while live values, defaults or options
-- depend on it.
CREATE FUNCTION attribute_check_datatype_change() RETURNS trigger
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

CREATE TRIGGER attribute_check_datatype_change
    BEFORE UPDATE OF datatype ON attribute
    FOR EACH ROW
    WHEN (OLD.datatype IS DISTINCT FROM NEW.datatype)
    EXECUTE FUNCTION attribute_check_datatype_change();

-- ---------------------------------------------------------------------------
-- Required attributes
-- ---------------------------------------------------------------------------

-- The required attributes of a class, of one scope, that have no default: an
-- object of the class must have its own value for each of them.
CREATE FUNCTION required_without_default(p_class uuid, p_per_unit boolean) RETURNS SETOF uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        WITH RECURSIVE lineage (id, depth) AS (
            SELECT p_class, 0
            UNION ALL
            SELECT c.parent, l.depth + 1
            FROM class c
            JOIN lineage l ON c.id = l.id
            WHERE c.parent IS NOT NULL
        ),
        nearest AS (
            SELECT DISTINCT ON (ca.attribute) ca.*
            FROM lineage l
            JOIN class_attribute ca ON ca.class = l.id
            ORDER BY ca.attribute, l.depth
        )
        SELECT n.attribute
        FROM nearest n
        WHERE n.per_unit = p_per_unit
          AND n.required
          AND num_nonnulls(n.text_default, n.integer_default, n.float_default,
                           n.date_default, n.boolean_default, n.option_default) = 0;
END;
$$;

-- Required attributes an item has no value for (per-kind attributes only).
CREATE FUNCTION item_missing_attributes(p_item uuid) RETURNS SETOF uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        SELECT r.a
        FROM required_without_default((SELECT class FROM item WHERE id = p_item), false) AS r (a)
        WHERE NOT EXISTS (SELECT 1 FROM value v WHERE v.item = p_item AND v.attribute = r.a);
END;
$$;

-- Required per-unit attributes a stock row has no value for.
CREATE FUNCTION stock_missing_attributes(p_stock uuid) RETURNS SETOF uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
        SELECT r.a
        FROM required_without_default(
                 (SELECT i.class FROM stock s JOIN item i ON i.id = s.item WHERE s.id = p_stock),
                 true) AS r (a)
        WHERE NOT EXISTS (SELECT 1 FROM stock_value sv WHERE sv.stock = p_stock AND sv.attribute = r.a);
END;
$$;

CREATE FUNCTION attribute_names(p_attributes uuid[]) RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT string_agg(a.name, ', ' ORDER BY lower(a.name)) FROM attribute a WHERE a.id = ANY (p_attributes));
END;
$$;

-- The checks below are deferred to the end of the transaction, so an item or
-- stock row can be created first and its values added afterwards. They only
-- concern new and restored objects and removed values: making an attribute
-- required later never blocks anything (the API reports such gaps as
-- "missing").

CREATE FUNCTION item_check_required() RETURNS trigger
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

CREATE CONSTRAINT TRIGGER item_check_required
    AFTER INSERT ON item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION item_check_required();

CREATE CONSTRAINT TRIGGER item_check_required_restore
    AFTER UPDATE OF deleted ON item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.deleted AND NOT NEW.deleted)
    EXECUTE FUNCTION item_check_required();

-- Removing a value of a deleted (or purged) owner isn't checked.
CREATE FUNCTION value_check_required_removal() RETURNS trigger
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

CREATE CONSTRAINT TRIGGER value_check_required_removal
    AFTER DELETE ON value
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION value_check_required_removal();

CREATE FUNCTION stock_check_required() RETURNS trigger
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

CREATE CONSTRAINT TRIGGER stock_check_required
    AFTER INSERT ON stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION stock_check_required();

CREATE CONSTRAINT TRIGGER stock_check_required_restore
    AFTER UPDATE OF deleted ON stock
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.deleted AND NOT NEW.deleted)
    EXECUTE FUNCTION stock_check_required();

CREATE FUNCTION stock_value_check_required_removal() RETURNS trigger
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

CREATE CONSTRAINT TRIGGER stock_value_check_required_removal
    AFTER DELETE ON stock_value
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION stock_value_check_required_removal();

-- ---------------------------------------------------------------------------
-- Deleted rows (see api/deleting.md)
-- ---------------------------------------------------------------------------
-- Items, stock rows, locations, classes, attributes, options and attachments
-- are deleted by marking them. Rules apply between live rows only; deleted
-- rows are frozen until they are restored or purged.

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

-- Live rows only refer to live rows.

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

-- Only what nothing live depends on can be deleted. Raised as 23001
-- (restrict_violation), as a foreign key would.

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
-- data_version
-- ---------------------------------------------------------------------------

-- One change counter per tracked table. The REST layer exposes it as the
-- version of the class and location trees.
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

-- ---------------------------------------------------------------------------
-- history (see api/history.md)
-- ---------------------------------------------------------------------------

-- One entry per changed row.
CREATE TABLE history (
    id          bigint            NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Start of the transaction, so all changes of one API call share it.
    happened_at timestamptz       NOT NULL DEFAULT now(),
    -- Groups the entries of one transaction (e.g. a stock_move).
    transaction xid8              NOT NULL DEFAULT pg_current_xact_id(),
    -- The logged-in account; NULL for changes outside the API ("system").
    account     uuid              NULL     REFERENCES account (id) ON DELETE RESTRICT,
    table_name  text              NOT NULL,
    operation   history_operation NOT NULL,
    -- The row after the change (before it, for a delete).
    data        jsonb             NOT NULL,
    -- Updates only: {column: {old, new}} for every changed column.
    changes     jsonb             NULL
);

CREATE INDEX history_happened_at_idx ON history (happened_at);
CREATE INDEX history_account_id_idx  ON history (account);
-- Restoring finds what was deleted together through history.
CREATE INDEX history_data_id_idx     ON history ((data ->> 'id'));

-- Row-level trigger on every data table and on account. Password hashes are
-- never logged (only whether there is one, and that it changed); updates
-- that only touch the lockout counters are not logged at all.
CREATE FUNCTION record_history() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old              jsonb;
    v_new              jsonb;
    v_changes          jsonb;
    v_password_changed boolean := false;
    v_token            text := current_setting('wtf.token', true);
    v_account          uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'account' THEN
        v_password_changed := TG_OP = 'UPDATE'
            AND (v_old ->> 'password_hash') IS DISTINCT FROM (v_new ->> 'password_hash');
        v_old := v_old - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_old ->> 'password_hash') IS NOT NULL);
        v_new := v_new - 'password_hash' - 'failed_logins' - 'last_failed_login'
                 || jsonb_build_object('has_password', (v_new ->> 'password_hash') IS NOT NULL);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value))
        INTO v_changes
        FROM jsonb_each(v_new) AS n
        WHERE (v_old -> n.key) IS DISTINCT FROM n.value;
        IF v_password_changed THEN
            v_changes := COALESCE(v_changes, '{}'::jsonb) || jsonb_build_object('password', 'changed');
        END IF;
        IF v_changes IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;

    IF v_token IS NOT NULL AND v_token <> '' THEN
        SELECT s.account INTO v_account
        FROM session s
        WHERE s.token_hash = sha256(convert_to(v_token, 'UTF8'));
    END IF;

    INSERT INTO history (account, table_name, operation, data, changes)
    VALUES (v_account,
            TG_TABLE_NAME,
            lower(TG_OP)::history_operation,
            COALESCE(v_new, v_old),
            v_changes);
    RETURN NULL;
END;
$$;

DO $$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'class', 'attribute', 'attribute_option', 'class_attribute', 'item', 'value',
        'location', 'stock', 'stock_value', 'attachment', 'account'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION record_history()',
            v_table || '_record_history', v_table);
    END LOOP;
END;
$$;
