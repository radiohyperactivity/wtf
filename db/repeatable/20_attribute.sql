-- API: quantities, unit families, units, attributes and options. Explained in
-- api/attribute.md.

-- ---------------------------------------------------------------------------
-- quantity (read-only)
-- ---------------------------------------------------------------------------

-- All quantities, alphabetically.
CREATE FUNCTION quantity_list() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    RETURN (
        SELECT COALESCE(jsonb_agg(util.quantity_json(q.id) ORDER BY lower(q.name), q.id), '[]'::jsonb)
        FROM quantity q
    );
END;
$$;

-- The quantity with its unit families, each with its units.
CREATE FUNCTION quantity_get(p_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    PERFORM util.require_login();
    v_result := util.quantity_json(p_id);
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('quantity', p_id);
    END IF;

    RETURN v_result || jsonb_build_object(
        'families', (
            SELECT COALESCE(
                jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'units', util.family_units_json(f.id))
                          ORDER BY f.id),
                '[]'::jsonb
            )
            FROM unit_family f
            WHERE f.quantity = p_id
        )
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- unit_family (read-only)
-- ---------------------------------------------------------------------------

-- All unit families, by quantity, optionally only those of one quantity.
-- Each comes with its units, from smallest to largest.
CREATE FUNCTION unit_family_list(p_quantity integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    IF p_quantity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity) THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;

    RETURN (
        SELECT COALESCE(
            jsonb_agg(util.unit_family_json(f.id) || jsonb_build_object('units', util.family_units_json(f.id))
                      ORDER BY lower(q.name), f.id),
            '[]'::jsonb
        )
        FROM unit_family f
        JOIN quantity q ON q.id = f.quantity
        WHERE p_quantity IS NULL OR f.quantity = p_quantity
    );
END;
$$;

CREATE FUNCTION unit_family_get(p_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    PERFORM util.require_login();
    v_result := util.unit_family_json(p_id);
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('unit family', p_id);
    END IF;
    RETURN v_result || jsonb_build_object('units', util.family_units_json(p_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- unit (read-only)
-- ---------------------------------------------------------------------------

-- All units, by family and size, optionally only those of one quantity or
-- one family.
CREATE FUNCTION unit_list(p_quantity integer DEFAULT NULL, p_family integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    IF p_quantity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity) THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;
    IF p_family IS NOT NULL AND NOT EXISTS (SELECT 1 FROM unit_family WHERE id = p_family) THEN
        PERFORM util.raise_not_found('unit family', p_family);
    END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(util.unit_json(u.id) ORDER BY f.id, u.base_factor, u.id), '[]'::jsonb)
        FROM unit u
        JOIN unit_family f ON f.id = u.family
        WHERE (p_quantity IS NULL OR f.quantity = p_quantity)
          AND (p_family IS NULL OR u.family = p_family)
    );
END;
$$;

CREATE FUNCTION unit_get(p_id integer) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    PERFORM util.require_login();
    v_result := util.unit_json(p_id);
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('unit', p_id);
    END IF;
    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- attribute
-- ---------------------------------------------------------------------------

-- All attributes, alphabetically.
CREATE FUNCTION attribute_list() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_model_read();
    RETURN (
        SELECT COALESCE(jsonb_agg(util.attribute_json(a.id) ORDER BY lower(a.name), a.id), '[]'::jsonb)
        FROM attribute a
        WHERE NOT a.deleted
    );
END;
$$;

-- For choice attributes the result also lists all options, alphabetically.
-- A deleted attribute is returned too, with deleted: true.
CREATE FUNCTION attribute_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    PERFORM util.require_model_read();
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_id) THEN
        PERFORM util.raise_not_found('attribute', p_id);
    END IF;
    v_result := util.attribute_json(p_id);

    IF v_result ->> 'datatype' = 'choice' THEN
        v_result := v_result || jsonb_build_object(
            'options',
            (
                SELECT COALESCE(
                    jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name)
                              ORDER BY lower(o.name), o.id),
                    '[]'::jsonb
                )
                FROM attribute_option o
                WHERE o.attribute = p_id
                  AND NOT o.deleted
            )
        );
    END IF;
    RETURN v_result;
END;
$$;

-- With a unit, p_datatype must be the unit's quantity's datatype (integer
-- for counts, float otherwise). With p_unit_lock, values are always shown in
-- that unit instead of being scaled within its family.
CREATE FUNCTION attribute_create(
    p_name      text,
    p_datatype  datatype,
    p_unit      integer DEFAULT NULL,
    p_unit_lock boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     uuid;
BEGIN
    PERFORM util.require('model', 'write');
    INSERT INTO attribute (name, datatype, unit, unit_lock)
    VALUES (util.clean_name(p_name), p_datatype, p_unit, COALESCE(p_unit_lock, false))
    RETURNING id INTO v_id;

    RETURN attribute_get(v_id);
END;
$$;

-- Changes the fields present in p_patch: name, datatype, unit, unit_lock.
-- The unit can only change to another unit of the same quantity, in any of
-- its families; numbers are stored in the base unit, so nothing is
-- converted. A unit can't be added or removed (see SCHEMA.md).
CREATE FUNCTION attribute_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_patch,
                         ARRAY['name', 'datatype', 'unit', 'unit_lock'],
                         ARRAY['name', 'datatype', 'unit_lock']);

    UPDATE attribute
    SET name      = CASE WHEN p_patch ? 'name'
                         THEN util.clean_name(p_patch ->> 'name') ELSE name END,
        datatype  = CASE WHEN p_patch ? 'datatype'
                         THEN (p_patch ->> 'datatype')::datatype ELSE datatype END,
        unit      = CASE WHEN p_patch ? 'unit'
                         THEN (p_patch ->> 'unit')::integer ELSE unit END,
        unit_lock = CASE WHEN p_patch ? 'unit_lock'
                         THEN (p_patch ->> 'unit_lock')::boolean ELSE unit_lock END
    WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute', p_id);
    END IF;
    RETURN attribute_get(p_id);
END;
$$;

-- Marks an attribute deleted. Fails (23001) while live items, stock rows or
-- classes use it. Its options stay as they are, and come back with it.
CREATE FUNCTION attribute_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    UPDATE attribute SET deleted = true WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute', p_id);
    END IF;
END;
$$;

-- Restores a deleted attribute. p_options: {"name": …} gives it a new name,
-- for when the old one has been taken since.
CREATE FUNCTION attribute_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted boolean;
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT deleted INTO v_deleted FROM attribute WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute', p_id);
    END IF;
    IF NOT v_deleted THEN
        PERFORM util.raise_not_deleted('attribute', p_id);
    END IF;

    UPDATE attribute
    SET deleted = false,
        name    = CASE WHEN p_options ? 'name' THEN util.clean_name(p_options ->> 'name') ELSE name END
    WHERE id = p_id;
    RETURN attribute_get(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- attribute_option
-- ---------------------------------------------------------------------------

-- All options of an attribute, alphabetically.
CREATE FUNCTION attribute_option_list(p_attribute uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_model_read();
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(util.option_json(o.id) ORDER BY lower(o.name), o.id), '[]'::jsonb)
        FROM attribute_option o
        WHERE o.attribute = p_attribute
          AND NOT o.deleted
    );
END;
$$;

CREATE FUNCTION attribute_option_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_model_read();
    IF NOT EXISTS (SELECT 1 FROM attribute_option WHERE id = p_id) THEN
        PERFORM util.raise_not_found('attribute option', p_id);
    END IF;
    RETURN util.option_json(p_id);
END;
$$;

CREATE FUNCTION attribute_option_create(p_attribute uuid, p_name text) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     uuid;
BEGIN
    PERFORM util.require('model', 'write');
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;

    INSERT INTO attribute_option (attribute, name)
    VALUES (p_attribute, util.clean_name(p_name))
    RETURNING id INTO v_id;

    RETURN util.option_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: name. An option cannot move to
-- another attribute.
CREATE FUNCTION attribute_option_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_patch, ARRAY['name'], ARRAY['name']);

    UPDATE attribute_option
    SET name = CASE WHEN p_patch ? 'name'
                    THEN util.clean_name(p_patch ->> 'name') ELSE name END
    WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute option', p_id);
    END IF;
    RETURN util.option_json(p_id);
END;
$$;

-- Marks an option deleted. Fails (23001) while live values or defaults use it.
CREATE FUNCTION attribute_option_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    UPDATE attribute_option SET deleted = true WHERE id = p_id;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute option', p_id);
    END IF;
END;
$$;

-- Restores a deleted option; its attribute must be live. p_options:
-- {"name": …} as for attribute_restore.
CREATE FUNCTION attribute_option_restore(p_id uuid, p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted boolean;
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT deleted INTO v_deleted FROM attribute_option WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM util.raise_not_found('attribute option', p_id);
    END IF;
    IF NOT v_deleted THEN
        PERFORM util.raise_not_deleted('attribute_option', p_id);
    END IF;

    UPDATE attribute_option
    SET deleted = false,
        name    = CASE WHEN p_options ? 'name' THEN util.clean_name(p_options ->> 'name') ELSE name END
    WHERE id = p_id;
    RETURN util.option_json(p_id);
END;
$$;
