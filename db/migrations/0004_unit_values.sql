-- Per-unit attributes (values on stock rows) and required attributes.
-- Explained in SCHEMA.md.

-- ---------------------------------------------------------------------------
-- Scope and requirement of class attributes
-- ---------------------------------------------------------------------------

-- per_unit: values live on stock rows (each physical thing or batch) instead
-- of on the item. required: objects created in the class must have a value
-- (or the class must provide a default).
ALTER TABLE class_attribute
    ADD COLUMN per_unit boolean NOT NULL DEFAULT false,
    ADD COLUMN required boolean NOT NULL DEFAULT false;

-- Same view as before, with the two new columns at the end. The nearest
-- assignment wins for per_unit and required, just as for the default.
CREATE OR REPLACE VIEW class_effective_attribute AS
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
-- stock_value: values of per-unit attributes
-- ---------------------------------------------------------------------------

CREATE TABLE stock_value (
    stock         uuid             NOT NULL REFERENCES stock (id) ON DELETE CASCADE,
    attribute     uuid             NOT NULL REFERENCES attribute (id) ON DELETE RESTRICT,
    -- Exactly one column is set, matching the attribute's datatype; numbers
    -- with a unit group are in the base unit. Same rules as value.
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

-- value_check_datatype only uses columns that value and stock_value share.
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
-- Existing guards, now aware of scope and of stock_value
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION value_check_applicable() RETURNS trigger
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
        WHERE (p_attribute_id IS NULL OR v.attribute = p_attribute_id)
          AND attribute_scope(i.class, v.attribute) IS DISTINCT FROM false
        UNION ALL
        SELECT 1
        FROM subtree s
        JOIN item i         ON i.class = s.id
        JOIN stock st       ON st.item = i.id
        JOIN stock_value sv ON sv.stock = st.id
        WHERE (p_attribute_id IS NULL OR sv.attribute = p_attribute_id)
          AND attribute_scope(i.class, sv.attribute) IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'Change would leave values without a matching attribute in class % or its descendants',
            p_class_id
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

-- Changing an attribute's scope (per_unit) is checked like removing it.
DROP TRIGGER class_attribute_check_removal ON class_attribute;
CREATE TRIGGER class_attribute_check_removal
    AFTER DELETE OR UPDATE OF class, attribute, per_unit ON class_attribute
    FOR EACH ROW EXECUTE FUNCTION class_attribute_check_removal();

CREATE OR REPLACE FUNCTION attribute_check_datatype_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM value v WHERE v.attribute = NEW.id)
       OR EXISTS (SELECT 1 FROM stock_value sv WHERE sv.attribute = NEW.id)
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
-- concern new objects and removed values: making an attribute required later
-- never blocks anything (the API reports such gaps as "missing").

CREATE FUNCTION item_check_required() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_missing uuid[] := ARRAY(SELECT item_missing_attributes(NEW.id));
BEGIN
    IF EXISTS (SELECT 1 FROM item WHERE id = NEW.id) AND cardinality(v_missing) > 0 THEN
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

CREATE FUNCTION value_check_required_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.attribute IN (SELECT item_missing_attributes(OLD.item)) THEN
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
    IF EXISTS (SELECT 1 FROM stock WHERE id = NEW.id) AND cardinality(v_missing) > 0 THEN
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

CREATE FUNCTION stock_value_check_required_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.attribute IN (SELECT stock_missing_attributes(OLD.stock)) THEN
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
