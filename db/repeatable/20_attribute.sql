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
-- unit import (the file format is in seed/units-format.md)
-- ---------------------------------------------------------------------------

-- Raises 22023 unless p_value (at p_where in a unit file) is an object
-- whose keys are among p_keys, has every key of p_required, and has
-- nothing else but keys of its own, which start with "x-".
CREATE FUNCTION util.check_unit_file_object(
    p_value    jsonb,
    p_where    text,
    p_keys     text[],
    p_required text[]
) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_key text;
BEGIN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
        PERFORM util.raise_invalid(format('%s must be an object', p_where));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_value) LOOP
        IF NOT v_key = ANY (p_keys) AND v_key NOT LIKE 'x-%' THEN
            PERFORM util.raise_invalid(format(
                '%s: unknown key "%s" (keys of your own must start with "x-")', p_where, v_key));
        END IF;
    END LOOP;
    FOREACH v_key IN ARRAY p_required LOOP
        IF jsonb_typeof(p_value -> v_key) IS NULL OR jsonb_typeof(p_value -> v_key) = 'null' THEN
            PERFORM util.raise_invalid(format('%s needs "%s"', p_where, v_key));
        END IF;
    END LOOP;
END;
$$;

-- The text at p_key of a unit file object: a string that isn't blank.
CREATE FUNCTION util.unit_file_text(p_value jsonb, p_key text, p_where text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value -> p_key) IS DISTINCT FROM 'string' OR btrim(p_value ->> p_key) = '' THEN
        PERFORM util.raise_invalid(format('%s: "%s" must be text', p_where, p_key));
    END IF;
    RETURN btrim(p_value ->> p_key);
END;
$$;

-- The list at p_key of a unit file object; an empty one when it is absent.
CREATE FUNCTION util.unit_file_list(p_value jsonb, p_key text, p_where text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value -> p_key IS NULL OR jsonb_typeof(p_value -> p_key) = 'null' THEN
        RETURN '[]'::jsonb;
    END IF;
    IF jsonb_typeof(p_value -> p_key) <> 'array' THEN
        PERFORM util.raise_invalid(format('%s: "%s" must be a list', p_where, p_key));
    END IF;
    RETURN p_value -> p_key;
END;
$$;

-- A factor or offset of a unit file: a decimal, preferably as text so that
-- no digit is lost ("0.55555555555555555556"), or a JSON number.
CREATE FUNCTION util.unit_file_decimal(p_value jsonb, p_where text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF jsonb_typeof(p_value) = 'number'
       OR (jsonb_typeof(p_value) = 'string'
           AND btrim(p_value #>> '{}') ~ '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
    THEN
        RETURN (btrim(p_value #>> '{}'))::numeric;
    END IF;
    PERFORM util.raise_invalid(format('%s must be a decimal number, such as "0.0254"', p_where));
END;
$$;

-- Imports a unit file (seed/units-format.md) for tenant p_tenant, or as
-- global units with p_tenant NULL (the operator's "wtfd unit import
-- --global"): adds the quantities, unit families and units in it that
-- aren't there yet. Things are matched by name among what the tenant sees
-- (only global ones for a global import): quantities and families ignoring
-- case, units by symbol within their family. What is there already must be
-- the same (datatype and base unit; quantity; name, factor and offset), or
-- it is a conflict. Nothing that exists is ever changed or removed.
--
-- All or nothing: with any conflict, or with p_dry_run, nothing is kept.
-- Returns what was (or would be) added, what was there already, and the
-- conflicts:
--   {applied, dry_run,
--    quantities: {added: [{name}], existing: [...]},
--    families:   {added: [{quantity, name}], existing: [...]},
--    units:      {added: [{quantity, family, symbol, name}], existing: [...]},
--    conflicts:  [{where, message}]}
-- A file that isn't a valid unit file raises 22023, naming where.
CREATE FUNCTION util.unit_import(p_tenant uuid, p_data jsonb, p_dry_run boolean) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_dry_run     boolean := COALESCE(p_dry_run, false);
    v_version     numeric;
    v_quantities  jsonb;
    v_families    jsonb;
    v_units       jsonb;
    v_q           jsonb;
    v_f           jsonb;
    v_u           jsonb;
    v_qi          integer := 0;
    v_fi          integer;
    v_ui          integer;
    v_where       text;
    v_qname       text;
    v_datatype    text;
    v_base_symbol text;
    v_base_name   text;
    v_fname       text;
    v_symbol      text;
    v_uname       text;
    v_factor      numeric;
    v_offset      numeric;
    v_quantity    quantity;
    v_family      unit_family;
    v_unit        unit;
    v_added_q     jsonb := '[]';
    v_existing_q  jsonb := '[]';
    v_added_f     jsonb := '[]';
    v_existing_f  jsonb := '[]';
    v_added_u     jsonb := '[]';
    v_existing_u  jsonb := '[]';
    v_conflicts   jsonb := '[]';
BEGIN
    PERFORM util.check_unit_file_object(p_data, 'The file',
        ARRAY['format', 'version', 'name', 'description', 'quantities'],
        ARRAY['format', 'version', 'quantities']);
    IF p_data ->> 'format' IS DISTINCT FROM 'wtf-units' THEN
        PERFORM util.raise_invalid('This is not a WtF unit file: "format" must be "wtf-units"');
    END IF;
    IF jsonb_typeof(p_data -> 'version') <> 'number' THEN
        PERFORM util.raise_invalid('"version" must be a number');
    END IF;
    v_version := (p_data ->> 'version')::numeric;
    IF v_version > 1 THEN
        PERFORM util.raise_invalid(format(
            'This unit file is version %s, made for a newer WtF; this one reads version 1', v_version));
    END IF;
    IF v_version <> 1 THEN
        PERFORM util.raise_invalid('"version" must be 1');
    END IF;
    IF p_data ? 'name' AND jsonb_typeof(p_data -> 'name') <> 'string' THEN
        PERFORM util.raise_invalid('"name" must be text');
    END IF;
    IF p_data ? 'description' AND jsonb_typeof(p_data -> 'description') <> 'string' THEN
        PERFORM util.raise_invalid('"description" must be text');
    END IF;
    v_quantities := util.unit_file_list(p_data, 'quantities', 'The file');

    BEGIN -- a subtransaction, rolled back for a dry run or a conflict
        FOR v_q IN SELECT jsonb_array_elements(v_quantities) LOOP
            v_where := format('quantities[%s]', v_qi);
            v_qi := v_qi + 1;
            PERFORM util.check_unit_file_object(v_q, v_where,
                ARRAY['name', 'datatype', 'base_unit', 'families'], ARRAY['name', 'base_unit']);
            v_qname := util.unit_file_text(v_q, 'name', v_where);
            v_where := v_qname;
            v_datatype := COALESCE(v_q ->> 'datatype', 'float');
            IF v_datatype NOT IN ('float', 'integer') THEN
                PERFORM util.raise_invalid(format('%s: "datatype" must be "float" or "integer"', v_where));
            END IF;
            PERFORM util.check_unit_file_object(v_q -> 'base_unit', v_where || ': "base_unit"',
                ARRAY['symbol', 'name'], ARRAY['symbol', 'name']);
            v_base_symbol := util.unit_file_text(v_q -> 'base_unit', 'symbol', v_where || ': "base_unit"');
            v_base_name := util.unit_file_text(v_q -> 'base_unit', 'name', v_where || ': "base_unit"');
            v_families := util.unit_file_list(v_q, 'families', v_where);

            SELECT * INTO v_quantity FROM quantity q
            WHERE lower(q.name) = lower(v_qname)
              AND (q.tenant IS NULL OR q.tenant = p_tenant);
            IF FOUND THEN
                IF v_quantity.datatype::text <> v_datatype OR v_quantity.base_symbol <> v_base_symbol THEN
                    v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', format(
                        'There is a quantity %s already, with base unit %s and datatype %s; the file has %s and %s',
                        v_quantity.name, v_quantity.base_symbol, v_quantity.datatype, v_base_symbol, v_datatype));
                    CONTINUE;
                END IF;
                v_existing_q := v_existing_q || jsonb_build_object('name', v_quantity.name);
            ELSE
                BEGIN
                    INSERT INTO quantity (tenant, name, datatype, base_symbol, base_name)
                    VALUES (p_tenant, v_qname, v_datatype::datatype, v_base_symbol, v_base_name)
                    RETURNING * INTO v_quantity;
                EXCEPTION WHEN unique_violation THEN
                    -- A global import: some tenant has a quantity of this name.
                    v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', SQLERRM);
                    CONTINUE;
                END;
                v_added_q := v_added_q || jsonb_build_object('name', v_quantity.name);
            END IF;

            v_fi := 0;
            FOR v_f IN SELECT jsonb_array_elements(v_families) LOOP
                v_where := format('%s: families[%s]', v_quantity.name, v_fi);
                v_fi := v_fi + 1;
                PERFORM util.check_unit_file_object(v_f, v_where, ARRAY['name', 'units'], ARRAY['name']);
                v_fname := util.unit_file_text(v_f, 'name', v_where);
                v_where := v_quantity.name || ' › ' || v_fname;
                v_units := util.unit_file_list(v_f, 'units', v_where);

                SELECT * INTO v_family FROM unit_family f
                WHERE lower(f.name) = lower(v_fname)
                  AND (f.tenant IS NULL OR f.tenant = p_tenant);
                IF FOUND THEN
                    IF v_family.quantity <> v_quantity.id THEN
                        v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', format(
                            'There is a unit family %s already, of quantity %s',
                            v_family.name, (SELECT name FROM quantity WHERE id = v_family.quantity)));
                        CONTINUE;
                    END IF;
                    v_existing_f := v_existing_f || jsonb_build_object('quantity', v_quantity.name, 'name', v_family.name);
                ELSE
                    BEGIN
                        INSERT INTO unit_family (tenant, quantity, name) VALUES (p_tenant, v_quantity.id, v_fname)
                        RETURNING * INTO v_family;
                    EXCEPTION WHEN unique_violation THEN
                        v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', SQLERRM);
                        CONTINUE;
                    END;
                    v_added_f := v_added_f || jsonb_build_object('quantity', v_quantity.name, 'name', v_family.name);
                END IF;

                v_ui := 0;
                FOR v_u IN SELECT jsonb_array_elements(v_units) LOOP
                    v_where := format('%s › %s: units[%s]', v_quantity.name, v_family.name, v_ui);
                    v_ui := v_ui + 1;
                    PERFORM util.check_unit_file_object(v_u, v_where,
                        ARRAY['symbol', 'name', 'factor', 'offset'], ARRAY['symbol', 'name', 'factor']);
                    v_symbol := util.unit_file_text(v_u, 'symbol', v_where);
                    v_uname := util.unit_file_text(v_u, 'name', v_where);
                    v_where := format('%s › %s › %s', v_quantity.name, v_family.name, v_symbol);
                    v_factor := util.unit_file_decimal(v_u -> 'factor', v_where || ': "factor"');
                    v_offset := CASE WHEN v_u ? 'offset'
                                     THEN util.unit_file_decimal(v_u -> 'offset', v_where || ': "offset"')
                                     ELSE 0 END;
                    IF v_factor <= 0 THEN
                        PERFORM util.raise_invalid(format('%s: "factor" must be more than 0', v_where));
                    END IF;
                    IF v_symbol = v_quantity.base_symbol AND (v_factor <> 1 OR v_offset <> 0) THEN
                        PERFORM util.raise_invalid(format(
                            '%s is the base unit of %s, so its factor must be 1 and its offset 0', v_where, v_quantity.name));
                    END IF;

                    SELECT * INTO v_unit FROM unit u
                    WHERE u.family = v_family.id AND u.symbol = v_symbol
                      AND (u.tenant IS NULL OR u.tenant = p_tenant);
                    IF FOUND THEN
                        IF lower(v_unit.name) <> lower(v_uname)
                           OR v_unit.base_factor <> v_factor OR v_unit.base_offset <> v_offset
                        THEN
                            v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', format(
                                'There is a unit %s already: %s, factor %s, offset %s; the file has %s, factor %s, offset %s',
                                v_unit.symbol, v_unit.name, v_unit.base_factor, v_unit.base_offset,
                                v_uname, v_factor, v_offset));
                        ELSE
                            v_existing_u := v_existing_u || jsonb_build_object(
                                'quantity', v_quantity.name, 'family', v_family.name,
                                'symbol', v_unit.symbol, 'name', v_unit.name);
                        END IF;
                        CONTINUE;
                    END IF;
                    BEGIN
                        INSERT INTO unit (tenant, family, name, symbol, base_factor, base_offset)
                        VALUES (p_tenant, v_family.id, v_uname, v_symbol, v_factor, v_offset);
                        v_added_u := v_added_u || jsonb_build_object(
                            'quantity', v_quantity.name, 'family', v_family.name,
                            'symbol', v_symbol, 'name', v_uname);
                    EXCEPTION WHEN unique_violation OR check_violation THEN
                        -- Another unit of the family has this name (or, for
                        -- a global import, some tenant's unit has), or the
                        -- symbol means another unit elsewhere in the quantity.
                        v_conflicts := v_conflicts || jsonb_build_object('where', v_where, 'message', SQLERRM);
                    END;
                END LOOP;
            END LOOP;
        END LOOP;

        IF v_dry_run OR jsonb_array_length(v_conflicts) > 0 THEN
            RAISE EXCEPTION 'unit import rolled back' USING ERRCODE = 'WTF01';
        END IF;
    EXCEPTION WHEN SQLSTATE 'WTF01' THEN
        NULL; -- the report is in the variables, which keep their values
    END;

    RETURN jsonb_build_object(
        'applied',    NOT v_dry_run AND jsonb_array_length(v_conflicts) = 0,
        'dry_run',    v_dry_run,
        'quantities', jsonb_build_object('added', v_added_q, 'existing', v_existing_q),
        'families',   jsonb_build_object('added', v_added_f, 'existing', v_existing_f),
        'units',      jsonb_build_object('added', v_added_u, 'existing', v_existing_u),
        'conflicts',  v_conflicts
    );
END;
$$;

-- Imports a unit file as the tenant's own units (util.unit_import).
CREATE FUNCTION unit_import(p_data jsonb, p_dry_run boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('model', 'write');
    RETURN util.unit_import(util.tenant(), p_data, p_dry_run);
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
