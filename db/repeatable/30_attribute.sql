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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- An attribute as the API shows it, from its row and what its deleted says
-- (util.deleted_json; NULL for a live one). Its unit is the unit's id,
-- which clients look up in the unit families they keep.
CREATE FUNCTION attribute.json(p_attribute public.attribute, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_attribute.id,
        'name',      p_attribute.name,
        'datatype',  p_attribute.datatype,
        'unit',      p_attribute.unit,
        'unit_lock', p_attribute.unit_lock,
        'deleted',   p_deleted
    );
$$;

-- An option as the API shows it, from its row and what its deleted says.
CREATE FUNCTION attribute.option_json(p_option public.attribute_option, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_option.id,
        'attribute', p_option.attribute,
        'name',      p_option.name,
        'deleted',   p_deleted
    );
$$;

-- An attribute as attribute.get shows it: attribute.json, and for a choice
-- attribute its live options, by name. Shared with the functions that
-- return the attribute after changing it.
CREATE FUNCTION attribute.detail_json(p_attribute public.attribute, p_deleted jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT attribute.json(p_attribute, p_deleted)
           || CASE WHEN p_attribute.datatype = 'choice' THEN jsonb_build_object(
                  'options', (SELECT coalesce(jsonb_agg(attribute.option_json(o, NULL)
                                                        ORDER BY o.name COLLATE public.natural, o.id), '[]')
                              FROM public.attribute_option o
                              WHERE o.attribute = p_attribute.id AND o.deleted IS NULL))
              ELSE '{}' END;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- The tenant's live attributes, by name.
CREATE FUNCTION attribute.list(p_request public.request)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(attribute.json(a, NULL) ORDER BY a.name COLLATE public.natural, a.id), '[]')
        FROM public.attribute a
        WHERE a.tenant = v_session.tenant
          AND a.deleted IS NULL
    );
END;
$$;

-- One of the tenant's attributes; a choice attribute with its live options,
-- by name. A deleted attribute is returned too, saying when and by whom it
-- was deleted.
CREATE FUNCTION attribute.get(p_request public.request, p_attribute uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT attribute.detail_json(a, util.deleted_json(d, db)) INTO v_result
    FROM public.attribute a
    LEFT JOIN public.action d   ON d.id = a.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE a.id = p_attribute AND a.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute', p_attribute::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates an attribute in the tenant. With a unit, its datatype must be the
-- unit's quantity's (integer for counts, decimal otherwise), and the unit
-- must be one the tenant has available; with p_unit_lock, its values are
-- always shown in that unit instead of the one of its family that suits
-- each value best. The datatype and whether there is a unit can't be
-- changed later. For admins.
CREATE FUNCTION attribute.create(
    p_request   public.request,
    p_name      text,
    p_datatype  public.datatype,
    p_unit      uuid,
    p_unit_lock boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session   record := util.session(p_request, 'admin');
    v_name      text := util.trim_and_check(p_name);
    v_attribute public.attribute;
BEGIN
    IF p_datatype IS NULL OR p_unit_lock IS NULL THEN
        PERFORM error.invalid('An attribute needs a datatype, and whether its unit is locked');
    END IF;
    PERFORM unit.check_choosable(v_session.tenant, p_unit);
    IF EXISTS (SELECT 1 FROM public.attribute a
               WHERE a.tenant = v_session.tenant
                 AND lower(a.name) = lower(v_name)
                 AND a.deleted IS NULL) THEN
        PERFORM error.duplicate(format('There is an attribute "%s" already', v_name));
    END IF;

    PERFORM util.begin_action(v_session);
    INSERT INTO public.attribute (tenant, name, datatype, unit, unit_lock)
    VALUES (v_session.tenant, v_name, p_datatype, p_unit, p_unit_lock)
    RETURNING * INTO v_attribute;
    RETURN attribute.detail_json(v_attribute, NULL);
END;
$$;

-- Changes the fields of an attribute that p_patch has: name, unit and
-- unit_lock. The unit can only change to another unit of the same quantity,
-- in any of its families (numbers are stored in the base unit, so nothing
-- is converted), and must be available; a unit can't be added or removed
-- (the rule unit.check_same_quantity says so). The datatype can't be
-- changed: make a new attribute. Deleted attributes can't be changed.
-- Returns the attribute as attribute.get does. For admins.
CREATE FUNCTION attribute.patch(p_request public.request, p_attribute uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session   record := util.session(p_request, 'admin');
    v_attribute public.attribute;
    v_name      text;
    v_unit      uuid;
BEGIN
    IF p_patch ? 'datatype' THEN
        PERFORM error.invalid('An attribute''s datatype can''t be changed; make a new attribute');
    END IF;
    PERFORM util.check_patch(p_patch, ARRAY['name', 'unit', 'unit_lock'], ARRAY['name', 'unit_lock']);

    SELECT a.* INTO v_attribute
    FROM public.attribute a
    WHERE a.id = p_attribute AND a.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute', p_attribute::text);
    END IF;
    IF v_attribute.deleted IS NOT NULL THEN
        PERFORM error.deleted('attribute', p_attribute);
    END IF;

    IF p_patch ? 'name' THEN
        v_name := util.trim_and_check(p_patch ->> 'name');
        IF EXISTS (SELECT 1 FROM public.attribute a
                   WHERE a.tenant = v_session.tenant
                     AND lower(a.name) = lower(v_name)
                     AND a.id <> p_attribute
                     AND a.deleted IS NULL) THEN
            PERFORM error.duplicate(format('There is an attribute "%s" already', v_name));
        END IF;
    END IF;
    IF p_patch ? 'unit' THEN
        v_unit := (p_patch ->> 'unit')::uuid;
        IF v_unit IS DISTINCT FROM v_attribute.unit THEN
            PERFORM unit.check_choosable(v_session.tenant, v_unit);
        END IF;
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.attribute a
    SET name      = coalesce(v_name, a.name),
        unit      = CASE WHEN p_patch ? 'unit' THEN v_unit ELSE a.unit END,
        unit_lock = coalesce((p_patch ->> 'unit_lock')::boolean, a.unit_lock)
    WHERE a.id = p_attribute
    RETURNING * INTO v_attribute;
    RETURN attribute.detail_json(v_attribute, NULL);
END;
$$;

-- Deletes an attribute of the tenant: it is marked deleted, by this call's
-- action, with its options as they are, so that restoring it brings them
-- back. An attribute still in use can't be deleted (409): live items or
-- stock rows with values for it, or live classes it is assigned to (the
-- rule attribute.check_deletable says so). For admins.
CREATE FUNCTION attribute.delete(p_request public.request, p_attribute uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.attribute a
    SET deleted = v_action
    WHERE a.id = p_attribute AND a.tenant = v_session.tenant AND a.deleted IS NULL;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM public.attribute a WHERE a.id = p_attribute AND a.tenant = v_session.tenant) THEN
            PERFORM error.deleted('attribute', p_attribute);
        END IF;
        PERFORM error.not_found('attribute', p_attribute::text);
    END IF;
END;
$$;

-- Restores a deleted attribute of the tenant, with its options as they
-- were. p_options may give it a new name, {"name": ...}, for when another
-- attribute has taken its name since. For admins.
CREATE FUNCTION attribute.restore(p_request public.request, p_attribute uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session   record := util.session(p_request, 'admin');
    v_attribute public.attribute;
    v_name      text;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT a.* INTO v_attribute
    FROM public.attribute a
    WHERE a.id = p_attribute AND a.tenant = v_session.tenant
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute', p_attribute::text);
    END IF;
    IF v_attribute.deleted IS NULL THEN
        PERFORM error.not_deleted('attribute', p_attribute);
    END IF;

    v_name := CASE WHEN p_options ? 'name' THEN util.trim_and_check(p_options ->> 'name')
                   ELSE v_attribute.name END;
    IF EXISTS (SELECT 1 FROM public.attribute a
               WHERE a.tenant = v_session.tenant
                 AND lower(a.name) = lower(v_name)
                 AND a.deleted IS NULL) THEN
        PERFORM error.duplicate(format(
            'There is an attribute "%s" already; restore this one with another name ("name": ...)', v_name));
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.attribute a
    SET deleted = NULL, name = v_name
    WHERE a.id = p_attribute
    RETURNING * INTO v_attribute;
    RETURN attribute.detail_json(v_attribute, NULL);
END;
$$;

-- One option of one of the tenant's attributes. A deleted option is
-- returned too, saying when and by whom it was deleted, as values may
-- still refer to it.
CREATE FUNCTION attribute.option_get(p_request public.request, p_option uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT attribute.option_json(o, util.deleted_json(d, db)) INTO v_result
    FROM public.attribute_option o
    JOIN public.attribute a     ON a.id = o.attribute
    LEFT JOIN public.action d   ON d.id = o.deleted
    LEFT JOIN public.account db ON db.id = d.account
    WHERE o.id = p_option AND a.tenant = v_session.tenant;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute option', p_option::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Adds an option to one of the tenant's live choice attributes. Its name
-- must not be one of the attribute's live options' already (letter case
-- ignored). That the attribute is a live choice attribute is the rules'
-- to say. For admins.
CREATE FUNCTION attribute.option_create(p_request public.request, p_attribute uuid, p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_name    text := util.trim_and_check(p_name);
    v_option  public.attribute_option;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.attribute a
                   WHERE a.id = p_attribute AND a.tenant = v_session.tenant) THEN
        PERFORM error.not_found('attribute', p_attribute::text);
    END IF;
    IF EXISTS (SELECT 1 FROM public.attribute_option o
               WHERE o.attribute = p_attribute
                 AND lower(o.name) = lower(v_name)
                 AND o.deleted IS NULL) THEN
        PERFORM error.duplicate(format('The attribute has an option "%s" already', v_name));
    END IF;

    PERFORM util.begin_action(v_session);
    INSERT INTO public.attribute_option (attribute, name)
    VALUES (p_attribute, v_name)
    RETURNING * INTO v_option;
    RETURN attribute.option_json(v_option, NULL);
END;
$$;

-- Changes the fields of an option that p_patch has: its name, which must
-- not be another of the attribute's live options' (letter case ignored).
-- An option can't move to another attribute. Deleted options, and options
-- of a deleted attribute, can't be changed. For admins.
CREATE FUNCTION attribute.option_patch(p_request public.request, p_option uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_option  public.attribute_option;
    v_name    text;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['name'], ARRAY['name']);
    SELECT o.* INTO v_option
    FROM public.attribute_option o
    JOIN public.attribute a ON a.id = o.attribute
    WHERE o.id = p_option AND a.tenant = v_session.tenant
    FOR UPDATE OF o;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute option', p_option::text);
    END IF;
    IF v_option.deleted IS NOT NULL THEN
        PERFORM error.deleted('attribute_option', p_option);
    END IF;
    PERFORM util.check_live('attribute', v_option.attribute);

    IF p_patch ? 'name' THEN
        v_name := util.trim_and_check(p_patch ->> 'name');
        IF EXISTS (SELECT 1 FROM public.attribute_option o
                   WHERE o.attribute = v_option.attribute
                     AND lower(o.name) = lower(v_name)
                     AND o.id <> p_option
                     AND o.deleted IS NULL) THEN
            PERFORM error.duplicate(format('The attribute has an option "%s" already', v_name));
        END IF;
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.attribute_option o
    SET name = coalesce(v_name, o.name)
    WHERE o.id = p_option
    RETURNING * INTO v_option;
    RETURN attribute.option_json(v_option, NULL);
END;
$$;

-- Deletes an option of one of the tenant's live attributes: it is marked
-- deleted, by this call's action. An option still in use can't be deleted
-- (409): by values on live items or stock rows, or as the default of an
-- assignment to a live class (the rule attribute.check_option_deletable
-- says so). For admins.
CREATE FUNCTION attribute.option_delete(p_request public.request, p_option uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_action  uuid := util.begin_action(v_session);
BEGIN
    UPDATE public.attribute_option o
    SET deleted = v_action
    FROM public.attribute a
    WHERE o.id = p_option
      AND a.id = o.attribute AND a.tenant = v_session.tenant AND a.deleted IS NULL
      AND o.deleted IS NULL;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM public.attribute_option o JOIN public.attribute a ON a.id = o.attribute
                   WHERE o.id = p_option AND a.tenant = v_session.tenant) THEN
            PERFORM error.deleted('attribute_option', p_option);
        END IF;
        PERFORM error.not_found('attribute option', p_option::text);
    END IF;
END;
$$;

-- Restores a deleted option of one of the tenant's live attributes.
-- p_options may give it a new name, {"name": ...}, for when another option
-- of the attribute has taken its name since. An option of a deleted
-- attribute is refused, naming the attribute to restore first. For admins.
CREATE FUNCTION attribute.option_restore(p_request public.request, p_option uuid, p_options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_option  public.attribute_option;
    v_live    boolean;
    v_name    text;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT o.* INTO v_option
    FROM public.attribute_option o
    JOIN public.attribute a ON a.id = o.attribute
    WHERE o.id = p_option AND a.tenant = v_session.tenant
    FOR UPDATE OF o;
    IF NOT FOUND THEN
        PERFORM error.not_found('attribute option', p_option::text);
    END IF;
    v_live := (SELECT a.deleted IS NULL FROM public.attribute a WHERE a.id = v_option.attribute);
    IF v_option.deleted IS NULL THEN
        PERFORM error.not_deleted('attribute_option', p_option);
    END IF;
    IF NOT v_live THEN
        PERFORM error.deleted('attribute', v_option.attribute);
    END IF;

    v_name := CASE WHEN p_options ? 'name' THEN util.trim_and_check(p_options ->> 'name')
                   ELSE v_option.name END;
    IF EXISTS (SELECT 1 FROM public.attribute_option o
               WHERE o.attribute = v_option.attribute
                 AND lower(o.name) = lower(v_name)
                 AND o.deleted IS NULL) THEN
        PERFORM error.duplicate(format(
            'The attribute has an option "%s" already; restore this one with another name ("name": ...)', v_name));
    END IF;

    PERFORM util.begin_action(v_session);
    UPDATE public.attribute_option o
    SET deleted = NULL, name = v_name
    WHERE o.id = p_option
    RETURNING * INTO v_option;
    RETURN attribute.option_json(v_option, NULL);
END;
$$;

-- ---------------------------------------------------------------------------
-- Typed values
-- ---------------------------------------------------------------------------

-- A value given as JSON for attribute p_attribute, as the typed column its
-- datatype uses; exactly one is set, or, when the value doesn't fit,
-- problem says why (naming the attribute) and none is. Numbers of an
-- attribute with a unit are in the base unit. Accepted: text and url a
-- string; integer a whole number; decimal a number; date a string
-- YYYY-MM-DD; boolean true or false; choice a string, the id or the name
-- (letter case ignored) of one of its live options, an id winning over a
-- name. (That a url looks like one, and that a value fits, the rules check
-- as well.) Reports rather than raises, so that a model import can list a
-- default that doesn't fit as a conflict.
CREATE FUNCTION attribute.try_parse_value(
    p_attribute public.attribute,
    p_value     jsonb,
    OUT text    text,
    OUT number  numeric,
    OUT date    date,
    OUT "boolean" boolean,
    OUT option  uuid,
    OUT problem text
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_kind   text := jsonb_typeof(p_value);
    v_string text := CASE WHEN jsonb_typeof(p_value) = 'string' THEN p_value #>> '{}' END;
BEGIN
    IF v_kind IS NULL OR v_kind = 'null' THEN
        problem := format('"%s" needs a value', p_attribute.name);
        RETURN;
    END IF;
    CASE p_attribute.datatype
    WHEN 'text', 'url' THEN
        IF v_kind <> 'string' THEN
            problem := format('"%s" takes text', p_attribute.name);
            RETURN;
        END IF;
        text := v_string;
    WHEN 'integer', 'decimal' THEN
        IF v_kind <> 'number' THEN
            problem := format('"%s" takes a number', p_attribute.name);
            RETURN;
        END IF;
        IF p_attribute.datatype = 'integer' AND p_value::numeric <> trunc(p_value::numeric) THEN
            problem := format('"%s" takes a whole number', p_attribute.name);
            RETURN;
        END IF;
        number := p_value::numeric;
    WHEN 'date' THEN
        IF v_kind <> 'string' OR v_string !~ '^\d{4}-\d{2}-\d{2}$' THEN
            problem := format('"%s" takes a date, YYYY-MM-DD', p_attribute.name);
            RETURN;
        END IF;
        -- Checked without raising (2026-02-30 isn't a date).
        IF NOT pg_input_is_valid(v_string, 'date') THEN
            problem := format('"%s": %s is not a date', p_attribute.name, v_string);
            RETURN;
        END IF;
        date := v_string::date;
    WHEN 'boolean' THEN
        IF v_kind <> 'boolean' THEN
            problem := format('"%s" takes true or false', p_attribute.name);
            RETURN;
        END IF;
        "boolean" := p_value::boolean;
    WHEN 'choice' THEN
        IF v_kind <> 'string' THEN
            problem := format('"%s" takes the id or the name of an option', p_attribute.name);
            RETURN;
        END IF;
        SELECT o.id INTO option
        FROM public.attribute_option o
        WHERE o.attribute = p_attribute.id AND o.deleted IS NULL
          AND (o.id::text = lower(v_string) OR lower(o.name) = lower(v_string))
        ORDER BY o.id::text = lower(v_string) DESC
        LIMIT 1;
        IF option IS NULL THEN
            problem := format('"%s" has no option %L', p_attribute.name, v_string);
        END IF;
    END CASE;
END;
$$;

-- attribute.try_parse_value, raising its problem as "invalid" (400).
CREATE FUNCTION attribute.parse_value(
    p_attribute public.attribute,
    p_value     jsonb,
    OUT text    text,
    OUT number  numeric,
    OUT date    date,
    OUT "boolean" boolean,
    OUT option  uuid
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_parsed record;
BEGIN
    SELECT * INTO v_parsed FROM attribute.try_parse_value(p_attribute, p_value);
    IF v_parsed.problem IS NOT NULL THEN
        PERFORM error.invalid(v_parsed.problem);
    END IF;
    text    := v_parsed.text;
    number  := v_parsed.number;
    date    := v_parsed.date;
    "boolean" := v_parsed.boolean;
    option  := v_parsed.option;
END;
$$;
