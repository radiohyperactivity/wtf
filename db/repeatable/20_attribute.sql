-- API: quantities, unit families, units, attributes and options. Explained in
-- api/attribute.md, and for global units and availability in TENANTS.md.

-- ---------------------------------------------------------------------------
-- What a tenant sees and has available
-- ---------------------------------------------------------------------------
-- A tenant sees the global quantities, families and units (tenant NULL) and
-- its own. Whether it has one available is its choice (tenant_quantity,
-- tenant_unit_family) or else the default: standard for global
-- ones, available for its own. A family is available only while its
-- quantity is.

-- Whether quantity p_quantity is available to tenant p_tenant.
CREATE FUNCTION util.quantity_available(p_tenant uuid, p_quantity uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT COALESCE(c.available, CASE WHEN q.tenant IS NULL THEN q.standard ELSE true END)
        FROM quantity q
        LEFT JOIN tenant_quantity c ON c.quantity = q.id AND c.tenant = p_tenant
        WHERE q.id = p_quantity
    );
END;
$$;

-- Whether unit family p_family is available to tenant p_tenant.
CREATE FUNCTION util.family_available(p_tenant uuid, p_family uuid) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT util.quantity_available(p_tenant, f.quantity)
               AND COALESCE(c.available, CASE WHEN f.tenant IS NULL THEN f.standard ELSE true END)
        FROM unit_family f
        LEFT JOIN tenant_unit_family c ON c.family = f.id AND c.tenant = p_tenant
        WHERE f.id = p_family
    );
END;
$$;

-- A quantity as tenant p_tenant sees it: util.quantity_json, plus whether
-- it is available, what the default is, and the tenant's own choice (null:
-- it follows the default).
CREATE FUNCTION util.quantity_entry_json(p_tenant uuid, p_quantity uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT util.quantity_json(q.id) || jsonb_build_object(
            'available',         util.quantity_available(p_tenant, q.id),
            'standard', CASE WHEN q.tenant IS NULL THEN q.standard ELSE true END,
            'choice',            c.available
        )
        FROM quantity q
        LEFT JOIN tenant_quantity c ON c.quantity = q.id AND c.tenant = p_tenant
        WHERE q.id = p_quantity
    );
END;
$$;

-- A unit family as tenant p_tenant sees it, with the units it sees.
CREATE FUNCTION util.family_entry_json(p_tenant uuid, p_family uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        SELECT util.unit_family_json(f.id) || jsonb_build_object(
            'available',         util.family_available(p_tenant, f.id),
            'standard', CASE WHEN f.tenant IS NULL THEN f.standard ELSE true END,
            'choice',            c.available,
            'units',             util.family_units_json(f.id)
        )
        FROM unit_family f
        LEFT JOIN tenant_unit_family c ON c.family = f.id AND c.tenant = p_tenant
        WHERE f.id = p_family
    );
END;
$$;

-- Raises 404 unless tenant p_tenant sees unit p_unit, and 409 unless its
-- family is available: a unit chosen for an attribute or an item. NULL (no
-- unit) is fine.
CREATE FUNCTION util.check_unit_choosable(p_tenant uuid, p_unit uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_unit record;
BEGIN
    IF p_unit IS NULL THEN
        RETURN;
    END IF;
    SELECT u.symbol, u.family, f.name AS family_name INTO v_unit
    FROM unit u JOIN unit_family f ON f.id = u.family
    WHERE u.id = p_unit AND (u.tenant IS NULL OR u.tenant = p_tenant);
    IF NOT FOUND THEN
        PERFORM util.raise_bad_reference('unit', p_unit);
    END IF;
    IF NOT util.family_available(p_tenant, v_unit.family) THEN
        RAISE EXCEPTION 'The unit % (%) isn''t available: its family or quantity is turned off', v_unit.symbol, v_unit.family_name
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- quantity
-- ---------------------------------------------------------------------------

-- The quantities the tenant sees, alphabetically.
CREATE FUNCTION quantity_list() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require_login();
    v_tenant := util.tenant();
    RETURN (
        SELECT COALESCE(jsonb_agg(util.quantity_entry_json(v_tenant, q.id) ORDER BY lower(q.name), q.id), '[]'::jsonb)
        FROM quantity q
        WHERE q.tenant IS NULL OR q.tenant = v_tenant
    );
END;
$$;

-- The quantity with the unit families the tenant sees, each with its units.
CREATE FUNCTION quantity_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require_login();
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_id AND (tenant IS NULL OR tenant = v_tenant)) THEN
        PERFORM util.raise_not_found('quantity', p_id);
    END IF;

    RETURN util.quantity_entry_json(v_tenant, p_id) || jsonb_build_object(
        'families', (
            SELECT COALESCE(
                jsonb_agg(util.family_entry_json(v_tenant, f.id) - 'quantity' ORDER BY lower(f.name), f.id),
                '[]'::jsonb
            )
            FROM unit_family f
            WHERE f.quantity = p_id
              AND (f.tenant IS NULL OR f.tenant = v_tenant)
        )
    );
END;
$$;

-- What uses the units of a quantity (p_quantity) or a family (p_family) in
-- tenant p_tenant: the names of live attributes and items, for the refusal
-- to turn them off. NULL when nothing does.
CREATE FUNCTION util.units_used_by(p_tenant uuid, p_quantity uuid, p_family uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
        WITH used (what) AS (
            SELECT format('attribute "%s"', a.name)
            FROM attribute a
            JOIN unit u ON u.id = a.unit
            JOIN unit_family f ON f.id = u.family
            WHERE a.tenant = p_tenant AND NOT a.deleted
              AND (f.quantity = p_quantity OR f.id = p_family)
            UNION ALL
            SELECT format('item "%s"', i.name)
            FROM item i
            JOIN unit u ON u.id = i.unit
            JOIN unit_family f ON f.id = u.family
            WHERE i.tenant = p_tenant AND NOT i.deleted
              AND (f.quantity = p_quantity OR f.id = p_family)
        )
        -- At most five, and how many more.
        SELECT CASE WHEN count(*) = 0 THEN NULL
                    WHEN count(*) <= 5 THEN string_agg(what, ', ' ORDER BY what)
                    ELSE (SELECT string_agg(f.what, ', ' ORDER BY f.what)
                          FROM (SELECT what FROM used ORDER BY what LIMIT 5) f)
                         || format(' and %s more', count(*) - 5)
               END
        FROM used
    );
END;
$$;

-- Sets the tenant's choice of whether a quantity or a unit family is
-- available, from p_patch's "available": true, false, or null to follow the
-- default again. A choice that is the default anyway isn't kept, so a
-- tenant has a choice only where it differs from the default. Something in
-- use can't be turned off (23001, 409).
CREATE FUNCTION util.set_availability(p_kind text, p_id uuid, p_patch jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_tenant uuid := util.tenant();
    v_choice boolean;
    v_name   text;
    v_used   text;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['available'], ARRAY[]::text[]);
    IF NOT p_patch ? 'available' THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_patch -> 'available') NOT IN ('boolean', 'null') THEN
        PERFORM util.raise_invalid('available must be true, false or null');
    END IF;
    v_choice := (p_patch ->> 'available')::boolean;

    -- The standard of a global one; a tenant's own are available by default.
    IF v_choice IS NOT DISTINCT FROM (
        CASE p_kind
            WHEN 'quantity' THEN (SELECT CASE WHEN tenant IS NULL THEN standard ELSE true END FROM quantity WHERE id = p_id)
            ELSE (SELECT CASE WHEN tenant IS NULL THEN standard ELSE true END FROM unit_family WHERE id = p_id)
        END)
    THEN
        v_choice := NULL;
    END IF;

    IF p_kind = 'quantity' THEN
        SELECT name INTO v_name FROM quantity WHERE id = p_id;
        IF v_choice IS NULL THEN
            DELETE FROM tenant_quantity WHERE tenant = v_tenant AND quantity = p_id;
        ELSE
            INSERT INTO tenant_quantity (tenant, quantity, available) VALUES (v_tenant, p_id, v_choice)
            ON CONFLICT (tenant, quantity) DO UPDATE SET available = EXCLUDED.available;
        END IF;
        IF NOT util.quantity_available(v_tenant, p_id) THEN
            v_used := util.units_used_by(v_tenant, p_id, NULL);
        END IF;
    ELSE
        SELECT name INTO v_name FROM unit_family WHERE id = p_id;
        IF v_choice IS NULL THEN
            DELETE FROM tenant_unit_family WHERE tenant = v_tenant AND family = p_id;
        ELSE
            INSERT INTO tenant_unit_family (tenant, family, available) VALUES (v_tenant, p_id, v_choice)
            ON CONFLICT (tenant, family) DO UPDATE SET available = EXCLUDED.available;
        END IF;
        IF NOT util.family_available(v_tenant, p_id) THEN
            v_used := util.units_used_by(v_tenant, NULL, p_id);
        END IF;
    END IF;

    IF v_used IS NOT NULL THEN
        RAISE EXCEPTION '% can''t be turned off: % use% it', v_name, v_used,
            CASE WHEN strpos(v_used, ', ') > 0 THEN '' ELSE 's' END
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Change the unit of what uses it first.';
    END IF;
END;
$$;

-- Turns a quantity on or off for the tenant: {"available": true | false |
-- null}. Turning a quantity off turns its families off too.
CREATE FUNCTION quantity_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_id AND (tenant IS NULL OR tenant = v_tenant)) THEN
        PERFORM util.raise_not_found('quantity', p_id);
    END IF;
    PERFORM util.set_availability('quantity', p_id, p_patch);
    RETURN quantity_get(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- unit_family
-- ---------------------------------------------------------------------------

-- The unit families the tenant sees, by quantity, optionally only those of
-- one quantity. Each comes with its units, from smallest to largest.
CREATE FUNCTION unit_family_list(p_quantity uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require_login();
    v_tenant := util.tenant();
    IF p_quantity IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity AND (tenant IS NULL OR tenant = v_tenant))
    THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;

    RETURN (
        SELECT COALESCE(
            jsonb_agg(util.family_entry_json(v_tenant, f.id) ORDER BY lower(q.name), lower(f.name), f.id),
            '[]'::jsonb
        )
        FROM unit_family f
        JOIN quantity q ON q.id = f.quantity
        WHERE (f.tenant IS NULL OR f.tenant = v_tenant)
          AND (p_quantity IS NULL OR f.quantity = p_quantity)
    );
END;
$$;

CREATE FUNCTION unit_family_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require_login();
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM unit_family WHERE id = p_id AND (tenant IS NULL OR tenant = v_tenant)) THEN
        PERFORM util.raise_not_found('unit family', p_id);
    END IF;
    RETURN util.family_entry_json(v_tenant, p_id);
END;
$$;

-- Turns a unit family on or off for the tenant: {"available": true | false
-- | null}. A family of a quantity that is off stays off.
CREATE FUNCTION unit_family_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
    IF NOT EXISTS (SELECT 1 FROM unit_family WHERE id = p_id AND (tenant IS NULL OR tenant = v_tenant)) THEN
        PERFORM util.raise_not_found('unit family', p_id);
    END IF;
    PERFORM util.set_availability('family', p_id, p_patch);
    RETURN unit_family_get(p_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- unit (read-only)
-- ---------------------------------------------------------------------------

-- The units the tenant sees, by family and size, optionally only those of
-- one quantity or one family.
CREATE FUNCTION unit_list(p_quantity uuid DEFAULT NULL, p_family uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require_login();
    v_tenant := util.tenant();
    IF p_quantity IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM quantity WHERE id = p_quantity AND (tenant IS NULL OR tenant = v_tenant))
    THEN
        PERFORM util.raise_not_found('quantity', p_quantity);
    END IF;
    IF p_family IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM unit_family WHERE id = p_family AND (tenant IS NULL OR tenant = v_tenant))
    THEN
        PERFORM util.raise_not_found('unit family', p_family);
    END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(util.unit_json(u.id) ORDER BY lower(f.name), f.id, u.base_factor, u.id), '[]'::jsonb)
        FROM unit u
        JOIN unit_family f ON f.id = u.family
        WHERE (u.tenant IS NULL OR u.tenant = v_tenant)
          AND (p_quantity IS NULL OR f.quantity = p_quantity)
          AND (p_family IS NULL OR u.family = p_family)
    );
END;
$$;

CREATE FUNCTION unit_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    IF NOT EXISTS (SELECT 1 FROM unit WHERE id = p_id AND (tenant IS NULL OR tenant = util.tenant())) THEN
        PERFORM util.raise_not_found('unit', p_id);
    END IF;
    RETURN util.unit_json(p_id);
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
        WHERE a.tenant = util.tenant()
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
    v_result jsonb;
BEGIN
    PERFORM util.require_model_read();
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_id AND tenant = util.tenant()) THEN
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
-- for counts, float otherwise), and the unit must be available. With
-- p_unit_lock, values are always shown in that unit instead of being scaled
-- within its family.
CREATE FUNCTION attribute_create(
    p_name      text,
    p_datatype  datatype,
    p_unit      uuid    DEFAULT NULL,
    p_unit_lock boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_id     uuid;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
    PERFORM util.check_unit_choosable(v_tenant, p_unit);
    INSERT INTO attribute (tenant, name, datatype, unit, unit_lock)
    VALUES (v_tenant, util.clean_name(p_name), p_datatype, p_unit, COALESCE(p_unit_lock, false))
    RETURNING id INTO v_id;

    RETURN attribute_get(v_id);
END;
$$;

-- Changes the fields present in p_patch: name, datatype, unit, unit_lock.
-- The unit can only change to another unit of the same quantity, in any of
-- its families; numbers are stored in the base unit, so nothing is
-- converted. A unit can't be added or removed (see SCHEMA.md). A new unit
-- must be available.
CREATE FUNCTION attribute_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
    PERFORM util.check_patch(p_patch,
                         ARRAY['name', 'datatype', 'unit', 'unit_lock'],
                         ARRAY['name', 'datatype', 'unit_lock']);
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_id AND tenant = v_tenant) THEN
        PERFORM util.raise_not_found('attribute', p_id);
    END IF;
    IF p_patch ? 'unit'
       AND (p_patch ->> 'unit')::uuid IS DISTINCT FROM (SELECT unit FROM attribute WHERE id = p_id)
    THEN
        PERFORM util.check_unit_choosable(v_tenant, (p_patch ->> 'unit')::uuid);
    END IF;

    UPDATE attribute
    SET name      = CASE WHEN p_patch ? 'name'
                         THEN util.clean_name(p_patch ->> 'name') ELSE name END,
        datatype  = CASE WHEN p_patch ? 'datatype'
                         THEN (p_patch ->> 'datatype')::datatype ELSE datatype END,
        unit      = CASE WHEN p_patch ? 'unit'
                         THEN (p_patch ->> 'unit')::uuid ELSE unit END,
        unit_lock = CASE WHEN p_patch ? 'unit_lock'
                         THEN (p_patch ->> 'unit_lock')::boolean ELSE unit_lock END
    WHERE id = p_id AND tenant = v_tenant;
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
    UPDATE attribute SET deleted = true WHERE id = p_id AND tenant = util.tenant();

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
    SELECT deleted INTO v_deleted FROM attribute WHERE id = p_id AND tenant = util.tenant() FOR UPDATE;
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
    IF NOT EXISTS (SELECT 1 FROM attribute WHERE id = p_attribute AND tenant = util.tenant()) THEN
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
    IF NOT EXISTS (SELECT 1 FROM attribute_option WHERE id = p_id AND tenant = util.tenant()) THEN
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
    v_tenant uuid;
    v_id     uuid;
BEGIN
    PERFORM util.require('model', 'write');
    v_tenant := util.tenant();
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
BEGIN
    PERFORM util.require('model', 'write');
    PERFORM util.check_patch(p_patch, ARRAY['name'], ARRAY['name']);

    UPDATE attribute_option
    SET name = CASE WHEN p_patch ? 'name'
                    THEN util.clean_name(p_patch ->> 'name') ELSE name END
    WHERE id = p_id AND tenant = util.tenant();

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
    UPDATE attribute_option SET deleted = true WHERE id = p_id AND tenant = util.tenant();

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
    SELECT deleted INTO v_deleted FROM attribute_option WHERE id = p_id AND tenant = util.tenant() FOR UPDATE;
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
