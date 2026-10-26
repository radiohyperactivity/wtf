-- Containers: a class or location that only holds other classes or
-- locations. A container class has no items, a container location no stock.
-- Explained in SCHEMA.md.

ALTER TABLE class    ADD COLUMN container boolean NOT NULL DEFAULT false;
ALTER TABLE location ADD COLUMN container boolean NOT NULL DEFAULT false;

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

-- A class can only become a container while it has no items.
CREATE FUNCTION class_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_items bigint;
BEGIN
    IF NEW.container AND NOT OLD.container THEN
        SELECT count(*) INTO v_items FROM item WHERE class = NEW.id;
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

-- A location can only become a container while it has no stock.
CREATE FUNCTION location_check_container() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_stock bigint;
BEGIN
    IF NEW.container AND NOT OLD.container THEN
        SELECT count(*) INTO v_stock FROM stock WHERE location = NEW.id;
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
