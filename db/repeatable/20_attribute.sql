-- API: quantities, units, unit groups, attributes and options. Explained in api/attribute.md.

-- ---------------------------------------------------------------------------
-- quantity (read-only)
-- ---------------------------------------------------------------------------

-- All quantities with their base units, alphabetically.
CREATE FUNCTION quantity_list() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    RETURN (
        SELECT COALESCE(
            jsonb_agg(
                util.quantity_json(q.id)
                || jsonb_build_object('base_unit', util.unit_json(util.base_unit(q.id)))
                ORDER BY lower(q.name), q.id
            ),
            '[]'::jsonb
        )
        FROM quantity q
    );
END;
$$;

-- The quantity with its base unit, all its units and all its unit groups,
-- alphabetically.
CREATE FUNCTION quantity_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb := util.quantity_json(p_id);
BEGIN
    PERFORM util.require_login();
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('quantity', p_id);
    END IF;

    RETURN v_result || jsonb_build_object(
        'base_unit', util.unit_json(util.base_unit(p_id)),
        'units', (
            SELECT COALESCE(jsonb_agg(util.unit_json(u.id) ORDER BY lower(u.name), u.id), '[]'::jsonb)
            FROM unit u
            WHERE u.quantity = p_id
        ),
        'unit_groups', (
            SELECT COALESCE(
                jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name)
                          ORDER BY lower(g.name), g.id),
                '[]'::jsonb
            )
            FROM unit_group g
            WHERE g.quantity = p_id
        )
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- unit (read-only)
-- ---------------------------------------------------------------------------

-- All units alphabetically, optionally only those of one quantity.
CREATE FUNCTION unit_list(p_quantity uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    IF p_quantity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity) THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(util.unit_json(u.id) ORDER BY lower(u.name), u.id), '[]'::jsonb)
        FROM unit u
        WHERE p_quantity IS NULL OR u.quantity = p_quantity
    );
END;
$$;

CREATE FUNCTION unit_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb := util.unit_json(p_id);
BEGIN
    PERFORM util.require_login();
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('unit', p_id);
    END IF;
    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- unit_group (read-only)
-- ---------------------------------------------------------------------------

-- All unit groups alphabetically, optionally only those of one quantity.
CREATE FUNCTION unit_group_list(p_quantity uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    IF p_quantity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity) THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(util.unit_group_json(g.id) ORDER BY lower(g.name), g.id), '[]'::jsonb)
        FROM unit_group g
        WHERE p_quantity IS NULL OR g.quantity = p_quantity
    );
END;
$$;

-- The unit group with its units, from smallest to largest.
CREATE FUNCTION unit_group_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_result jsonb := util.unit_group_json(p_id);
BEGIN
    PERFORM util.require_login();
    IF v_result IS NULL THEN
        PERFORM util.raise_not_found('unit group', p_id);
    END IF;

    RETURN v_result || jsonb_build_object(
        'units', (
            SELECT COALESCE(jsonb_agg(util.unit_json(u.id) ORDER BY u.base_factor, u.id), '[]'::jsonb)
            FROM unit_group_unit gu
            JOIN unit u ON u.id = gu.unit
            WHERE gu.unit_group = p_id
        )
    );
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
DECLARE
    v_tenant uuid := util.require_model_read();
BEGIN
    RETURN (
        SELECT COALESCE(jsonb_agg(util.attribute_json(a.id) ORDER BY lower(a.name), a.id), '[]'::jsonb)
        FROM attribute a
        WHERE a.tenant = v_tenant
          AND NOT a.deleted
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
    v_tenant uuid := util.require_model_read();
    v_result jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_id AND tenant = v_tenant) THEN
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

-- With a unit group, p_datatype must be the group's quantity's datatype
-- (integer for counts, float otherwise).
CREATE FUNCTION attribute_create(p_name text, p_datatype datatype, p_unit_group uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('model', 'write');
    v_id     uuid;
BEGIN
    INSERT INTO attribute (tenant, name, datatype, unit_group)
    VALUES (v_tenant, util.clean_name(p_name), p_datatype, p_unit_group)
    RETURNING id INTO v_id;

    RETURN attribute_get(v_id);
END;
$$;

-- Changes the fields present in p_patch: name, datatype, unit_group.
-- The unit group can only change to another group of the same quantity;
-- numbers are stored in the base unit, so nothing is converted. A group
-- can't be added or removed (see SCHEMA.md).
CREATE FUNCTION attribute_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid := util.require('model', 'write');
BEGIN
    PERFORM util.check_patch(p_patch,
                         ARRAY['name', 'datatype', 'unit_group'],
                         ARRAY['name', 'datatype']);

    UPDATE attribute
    SET name       = CASE WHEN p_patch ? 'name'
                          THEN util.clean_name(p_patch ->> 'name') ELSE name END,
        datatype   = CASE WHEN p_patch ? 'datatype'
                          THEN (p_patch ->> 'datatype')::datatype ELSE datatype END,
        unit_group = CASE WHEN p_patch ? 'unit_group'
                          THEN (p_patch ->> 'unit_group')::uuid ELSE unit_group END
    WHERE id = p_id
      AND tenant = v_tenant;

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
DECLARE
    v_tenant uuid := util.require('model', 'write');
BEGIN
    UPDATE attribute SET deleted = true WHERE id = p_id AND tenant = v_tenant;

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
    v_tenant  uuid := util.require('model', 'write');
    v_deleted boolean;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT deleted INTO v_deleted FROM attribute WHERE id = p_id AND tenant = v_tenant FOR UPDATE;
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
DECLARE
    v_tenant uuid := util.require_model_read();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute AND tenant = v_tenant) THEN
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
DECLARE
    v_tenant uuid := util.require_model_read();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM attribute_option WHERE id = p_id AND tenant = v_tenant) THEN
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
    v_tenant uuid := util.require('model', 'write');
    v_id     uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('attribute', p_attribute);
    END IF;

    INSERT INTO attribute_option (tenant, attribute, name)
    VALUES (v_tenant, p_attribute, util.clean_name(p_name))
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
DECLARE
    v_tenant uuid := util.require('model', 'write');
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['name'], ARRAY['name']);

    UPDATE attribute_option
    SET name = CASE WHEN p_patch ? 'name'
                    THEN util.clean_name(p_patch ->> 'name') ELSE name END
    WHERE id = p_id
      AND tenant = v_tenant;

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
DECLARE
    v_tenant uuid := util.require('model', 'write');
BEGIN
    UPDATE attribute_option SET deleted = true WHERE id = p_id AND tenant = v_tenant;

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
    v_tenant  uuid := util.require('model', 'write');
    v_deleted boolean;
BEGIN
    PERFORM util.check_patch(p_options, ARRAY['name'], ARRAY['name']);
    SELECT deleted INTO v_deleted FROM attribute_option WHERE id = p_id AND tenant = v_tenant FOR UPDATE;
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
