-- Attributes and their options (schema attribute): their rules, and the
-- functions the API calls for them.

CREATE SCHEMA attribute;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- An attribute with a unit must have the datatype of its unit's quantity:
-- an attribute in millimetres is a 'decimal' because Length is, and one in
-- pieces is an 'integer' because Count is. That way its numbers are whole
-- exactly when the quantity's are. Only on insert: neither an attribute's
-- datatype nor its unit's quantity can change afterwards.
CREATE FUNCTION attribute.check_unit()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.unit u
        JOIN public.unit_family f ON f.id = u.family
        JOIN public.quantity q    ON q.id = f.quantity
        WHERE u.id = NEW.unit
          AND q.datatype = NEW.datatype
    ) THEN
        RAISE EXCEPTION 'Attribute "%" must have the datatype of its unit''s quantity', NEW.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_unit_datatype
    BEFORE INSERT ON public.attribute
    FOR EACH ROW
    WHEN (NEW.unit IS NOT NULL)
    EXECUTE FUNCTION attribute.check_unit();

-- An attribute's datatype is chosen when the attribute is created and
-- never changes. Its values, its options and the default values of its
-- assignments are all stored by datatype, including those on deleted rows
-- that can be restored, so a change would leave some of them in the wrong
-- form. To change it, make a new attribute.
CREATE FUNCTION attribute.refuse_datatype_change()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'The datatype of attribute "%" can''t be changed', NEW.name
        USING ERRCODE = 'check_violation';
END;
$$;

CREATE TRIGGER refuse_datatype_change
    BEFORE UPDATE OF datatype ON public.attribute
    FOR EACH ROW
    WHEN (OLD.datatype <> NEW.datatype)
    EXECUTE FUNCTION attribute.refuse_datatype_change();

-- Options can only belong to a 'choice' attribute.
CREATE FUNCTION attribute.check_option_choice()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_attribute record;
BEGIN
    SELECT a.name, a.datatype INTO v_attribute
    FROM public.attribute a
    WHERE a.id = NEW.attribute;
    IF v_attribute.datatype <> 'choice' THEN
        RAISE EXCEPTION 'Attribute "%" is not a choice attribute, so it can''t have options',
            v_attribute.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_option_choice
    BEFORE INSERT ON public.attribute_option
    FOR EACH ROW EXECUTE FUNCTION attribute.check_option_choice();

CREATE TRIGGER check_option_choice_change
    BEFORE UPDATE OF attribute ON public.attribute_option
    FOR EACH ROW
    WHEN (OLD.attribute <> NEW.attribute)
    EXECUTE FUNCTION attribute.check_option_choice();

-- A value must fit its attribute's datatype: a 'decimal' value is in
-- number, an 'integer' one is a whole number in number, a 'url' one is a
-- web address in text, and so on (util.typed_value_fits says which). Used
-- by both item_value and stock_value, which have the same value columns.
-- That an option value is one of this attribute's own options is already
-- ensured by the foreign key (attribute, option).
CREATE FUNCTION attribute.check_value_datatype()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_attribute record;
BEGIN
    SELECT a.name, a.datatype INTO v_attribute
    FROM public.attribute a
    WHERE a.id = NEW.attribute;
    IF NOT util.typed_value_fits(v_attribute.datatype,
                                 NEW.text, NEW.number, NEW.date,
                                 NEW.boolean, NEW.option) THEN
        RAISE EXCEPTION 'The value for "%" doesn''t fit its datatype (%)',
            v_attribute.name, v_attribute.datatype
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_value_datatype
    BEFORE INSERT ON public.item_value
    FOR EACH ROW EXECUTE FUNCTION attribute.check_value_datatype();

CREATE TRIGGER check_value_datatype_change
    BEFORE UPDATE OF attribute, text, number, date, boolean, option ON public.item_value
    FOR EACH ROW
    WHEN (OLD.attribute <> NEW.attribute
          OR OLD.text    IS DISTINCT FROM NEW.text
          OR OLD.number  IS DISTINCT FROM NEW.number
          OR OLD.date    IS DISTINCT FROM NEW.date
          OR OLD.boolean IS DISTINCT FROM NEW.boolean
          OR OLD.option  IS DISTINCT FROM NEW.option)
    EXECUTE FUNCTION attribute.check_value_datatype();

CREATE TRIGGER check_value_datatype
    BEFORE INSERT ON public.stock_value
    FOR EACH ROW EXECUTE FUNCTION attribute.check_value_datatype();

CREATE TRIGGER check_value_datatype_change
    BEFORE UPDATE OF attribute, text, number, date, boolean, option ON public.stock_value
    FOR EACH ROW
    WHEN (OLD.attribute <> NEW.attribute
          OR OLD.text    IS DISTINCT FROM NEW.text
          OR OLD.number  IS DISTINCT FROM NEW.number
          OR OLD.date    IS DISTINCT FROM NEW.date
          OR OLD.boolean IS DISTINCT FROM NEW.boolean
          OR OLD.option  IS DISTINCT FROM NEW.option)
    EXECUTE FUNCTION attribute.check_value_datatype();

-- A live option's attribute must be live: an option can't be added to, or
-- restored onto, a deleted attribute.
CREATE FUNCTION attribute.check_option_live()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM util.check_live('attribute', NEW.attribute);
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_option_live
    BEFORE INSERT ON public.attribute_option
    FOR EACH ROW EXECUTE FUNCTION attribute.check_option_live();

CREATE TRIGGER check_option_live_change
    BEFORE UPDATE OF attribute, deleted ON public.attribute_option
    FOR EACH ROW
    WHEN (OLD.attribute <> NEW.attribute
          OR (OLD.deleted IS NOT NULL AND NEW.deleted IS NULL))
    EXECUTE FUNCTION attribute.check_option_live();

-- An attribute can only be deleted while nothing live uses it: no item
-- values on live items, no stock values on live stock rows, and no
-- assignments to live classes. Its own options stay as they are, and come
-- back with it.
CREATE FUNCTION attribute.check_deletable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.item_value v JOIN public.item i ON i.id = v.item
               WHERE v.attribute = NEW.id AND i.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.stock_value sv JOIN public.stock s ON s.id = sv.stock
                  WHERE sv.attribute = NEW.id AND s.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.class_attribute ca JOIN public.class c ON c.id = ca.class
                  WHERE ca.attribute = NEW.id AND c.deleted IS NULL)
    THEN
        RAISE EXCEPTION 'Attribute "%" is still in use', NEW.name
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Remove it from its classes, and its values from items and stock rows, first.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_deletable
    BEFORE UPDATE OF deleted ON public.attribute
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION attribute.check_deletable();

-- An option can only be deleted while nothing live uses it: no item or
-- stock values on live items or stock rows, and no assignments to live
-- classes with it as their default.
CREATE FUNCTION attribute.check_option_deletable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.item_value v JOIN public.item i ON i.id = v.item
               WHERE v.option = NEW.id AND i.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.stock_value sv JOIN public.stock s ON s.id = sv.stock
                  WHERE sv.option = NEW.id AND s.deleted IS NULL)
       OR EXISTS (SELECT 1 FROM public.class_attribute ca JOIN public.class c ON c.id = ca.class
                  WHERE ca.default_option = NEW.id AND c.deleted IS NULL)
    THEN
        RAISE EXCEPTION 'Option "%" is still in use', NEW.name
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Change the values and defaults that use it first.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_option_deletable
    BEFORE UPDATE OF deleted ON public.attribute_option
    FOR EACH ROW
    WHEN (OLD.deleted IS NULL AND NEW.deleted IS NOT NULL)
    EXECUTE FUNCTION attribute.check_option_deletable();
