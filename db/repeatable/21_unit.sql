-- Quantities, unit families and units (schema unit): their rules, and the
-- functions the API calls for them. See seed/units.md and TENANTS.md.
--
-- Quantities, unit families and units are either global (their tenant
-- column is NULL, and every tenant sees them) or owned by one tenant (only
-- that tenant sees them). A unit family owned by a tenant may belong to a
-- global quantity, and a unit owned by a tenant to a global family; a
-- global one never belongs to one owned by a tenant, so that no tenant sees
-- a unit or family whose parent it can't see.

CREATE SCHEMA unit;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- Checks a quantity's name against the names of the other quantities: it
-- must be unique among the quantities a tenant sees, which are its own and
-- the global ones (letter case ignored). The unique index
-- quantity_tenant_name_unique already makes names unique among the global
-- quantities, and within each tenant. What only this rule can check: a
-- quantity owned by a tenant must not have a global quantity's name, and a
-- new global quantity must not have the name of any tenant's own.
CREATE FUNCTION unit.check_quantity()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owners text;
BEGIN
    -- Two transactions adding the same name at once, one globally and one
    -- for a tenant, would each pass the check below without seeing the
    -- other. Locking the name until commit makes the second wait for the
    -- first, and then see its row.
    PERFORM pg_advisory_xact_lock('public.quantity'::regclass::oid::integer,
                                  hashtext(lower(NEW.name)));

    SELECT string_agg(DISTINCT coalesce(t.host, 'global'), ', ') INTO v_owners
    FROM public.quantity q
    LEFT JOIN public.tenant t ON t.id = q.tenant
    WHERE lower(q.name) = lower(NEW.name)
      AND q.id <> NEW.id
      AND (NEW.tenant IS NULL OR q.tenant IS NULL OR q.tenant = NEW.tenant);
    IF v_owners IS NOT NULL THEN
        RAISE EXCEPTION 'A quantity named "%" already exists (%)', NEW.name, v_owners
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_quantity
    BEFORE INSERT ON public.quantity
    FOR EACH ROW EXECUTE FUNCTION unit.check_quantity();

CREATE TRIGGER check_quantity_change
    BEFORE UPDATE OF name ON public.quantity
    FOR EACH ROW
    WHEN (lower(OLD.name) <> lower(NEW.name))
    EXECUTE FUNCTION unit.check_quantity();

-- Checks a unit family against the quantity it belongs to and against the
-- names of the other families.
--
-- The quantity must be global, or owned by the same tenant as the family:
-- a global family can only be in a global quantity, and a family owned by
-- a tenant can be in a global quantity or one of that tenant's own.
--
-- The name must be unique among the families a tenant sees, which are its
-- own and the global ones (letter case ignored). The unique index
-- unit_family_tenant_name_unique already makes names unique among the
-- global families, and within each tenant. What only this rule can check:
-- a family owned by a tenant must not have a global family's name, and a
-- new global family must not have the name of any tenant's own.
CREATE FUNCTION unit.check_family()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owners text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.quantity q
        WHERE q.id = NEW.quantity
          AND (q.tenant IS NULL OR q.tenant = NEW.tenant)
    ) THEN
        RAISE EXCEPTION 'Unit family "%" can''t be in another tenant''s quantity', NEW.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same lock on the name as in unit.check_quantity, for the same
    -- reason.
    PERFORM pg_advisory_xact_lock('public.unit_family'::regclass::oid::integer,
                                  hashtext(lower(NEW.name)));

    SELECT string_agg(DISTINCT coalesce(t.host, 'global'), ', ') INTO v_owners
    FROM public.unit_family f
    LEFT JOIN public.tenant t ON t.id = f.tenant
    WHERE lower(f.name) = lower(NEW.name)
      AND f.id <> NEW.id
      AND (NEW.tenant IS NULL OR f.tenant IS NULL OR f.tenant = NEW.tenant);
    IF v_owners IS NOT NULL THEN
        RAISE EXCEPTION 'A unit family named "%" already exists (%)', NEW.name, v_owners
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_family
    BEFORE INSERT ON public.unit_family
    FOR EACH ROW EXECUTE FUNCTION unit.check_family();

CREATE TRIGGER check_family_change
    BEFORE UPDATE OF quantity, name ON public.unit_family
    FOR EACH ROW
    WHEN (OLD.quantity <> NEW.quantity OR lower(OLD.name) <> lower(NEW.name))
    EXECUTE FUNCTION unit.check_family();

-- Checks a unit against the family it belongs to and against the other
-- units its tenant sees, which are its tenant's own and the global ones.
--
-- The family must be global, or owned by the same tenant as the unit: a
-- global unit can only be in a global family, and a unit owned by a tenant
-- can be in a global family or one of that tenant's own.
--
-- Within a family, a unit's symbol and its name (letter case ignored) must
-- be unique among the units a tenant sees. The unique indexes on (family,
-- tenant, symbol) and (family, tenant, lower(name)) already make them
-- unique among the global units, and within each tenant. What only this
-- rule can check: a tenant's unit against a global one, and a new global
-- unit against every tenant's.
--
-- The same symbol may appear in several families of one quantity (B in
-- both Decimal bytes and Binary bytes), but it must then mean the same
-- unit, with the same factor and offset, so that a number typed with that
-- symbol converts the same whichever of them is picked.
CREATE FUNCTION unit.check_unit()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_family record;
    v_other  text;
BEGIN
    SELECT f.tenant, f.quantity INTO v_family
    FROM public.unit_family f
    WHERE f.id = NEW.family;
    IF v_family.tenant IS NOT NULL AND v_family.tenant IS DISTINCT FROM NEW.tenant THEN
        RAISE EXCEPTION 'Unit "%" can''t be in another tenant''s family', NEW.symbol
            USING ERRCODE = 'check_violation';
    END IF;

    -- Two transactions adding units to the same quantity at once, one
    -- globally and one for a tenant, would each pass the checks below
    -- without seeing the other. Locking the quantity's units until commit
    -- makes the second wait for the first, and then see its rows.
    PERFORM pg_advisory_xact_lock('public.unit'::regclass::oid::integer,
                                  hashtext(v_family.quantity::text));

    SELECT f.name INTO v_other
    FROM public.unit u
    JOIN public.unit_family f ON f.id = u.family
    WHERE f.quantity = v_family.quantity
      AND u.symbol = NEW.symbol
      AND u.id <> NEW.id
      AND (NEW.tenant IS NULL OR u.tenant IS NULL OR u.tenant = NEW.tenant)
      AND (u.base_factor <> NEW.base_factor OR u.base_offset <> NEW.base_offset)
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Unit symbol "%" already means a different unit in family "%"',
            NEW.symbol, v_other
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.unit u
        WHERE u.family = NEW.family
          AND u.id <> NEW.id
          AND (u.symbol = NEW.symbol OR lower(u.name) = lower(NEW.name))
          AND (NEW.tenant IS NULL OR u.tenant IS NULL OR u.tenant = NEW.tenant)
    ) THEN
        RAISE EXCEPTION 'Its family already has a unit named "%" or "%"', NEW.name, NEW.symbol
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER check_unit
    BEFORE INSERT ON public.unit
    FOR EACH ROW EXECUTE FUNCTION unit.check_unit();

CREATE TRIGGER check_unit_change
    BEFORE UPDATE OF family, name, symbol, base_factor, base_offset ON public.unit
    FOR EACH ROW
    WHEN (OLD.family <> NEW.family
          OR lower(OLD.name) <> lower(NEW.name)
          OR OLD.symbol <> NEW.symbol
          OR OLD.base_factor <> NEW.base_factor
          OR OLD.base_offset <> NEW.base_offset)
    EXECUTE FUNCTION unit.check_unit();

-- Checks that a quantity's base unit really is its base unit: a unit in one
-- of the quantity's own families, with factor 1 and offset 0, so that
-- converting a number in it to the base unit leaves it unchanged.
--
-- It runs at commit, because a quantity and its base unit refer to each
-- other (quantity → base unit → its family → quantity) and so are inserted
-- one after the other in the same transaction; only at commit are both
-- there. It is checked again when something it depends on changes: the
-- quantity's base unit, that unit's family, factor or offset, or the
-- quantity that family belongs to. A base unit that doesn't exist at all is
-- the deferred foreign key's to report.
CREATE FUNCTION unit.check_base_unit()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_quantities uuid[];
    v_wrong      record;
BEGIN
    -- The quantities whose base unit this change could affect.
    IF TG_TABLE_NAME = 'quantity' THEN
        v_quantities := ARRAY[NEW.id];
    ELSIF TG_TABLE_NAME = 'unit' THEN
        v_quantities := ARRAY(SELECT q.id FROM public.quantity q
                              WHERE q.base_unit = NEW.id);
    ELSE  -- unit_family
        v_quantities := ARRAY(SELECT q.id FROM public.quantity q
                              JOIN public.unit u ON u.id = q.base_unit
                              WHERE u.family = NEW.id);
    END IF;

    SELECT q.name, u.symbol, f.quantity = q.id AS own_quantity
    INTO v_wrong
    FROM public.quantity q
    JOIN public.unit u        ON u.id = q.base_unit
    JOIN public.unit_family f ON f.id = u.family
    WHERE q.id = ANY (v_quantities)
      AND (f.quantity <> q.id OR u.base_factor <> 1 OR u.base_offset <> 0)
    LIMIT 1;
    IF FOUND THEN
        IF v_wrong.own_quantity THEN
            RAISE EXCEPTION 'The base unit of % (%) must have factor 1 and offset 0',
                v_wrong.name, v_wrong.symbol
                USING ERRCODE = 'check_violation';
        ELSE
            RAISE EXCEPTION 'The base unit of % (%) must be one of its own units',
                v_wrong.name, v_wrong.symbol
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_base_unit
    AFTER INSERT ON public.quantity
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION unit.check_base_unit();

CREATE CONSTRAINT TRIGGER check_base_unit_change
    AFTER UPDATE OF base_unit ON public.quantity
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.base_unit <> NEW.base_unit)
    EXECUTE FUNCTION unit.check_base_unit();

CREATE CONSTRAINT TRIGGER check_base_unit_change
    AFTER UPDATE OF family, base_factor, base_offset ON public.unit
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.family <> NEW.family
          OR OLD.base_factor <> NEW.base_factor
          OR OLD.base_offset <> NEW.base_offset)
    EXECUTE FUNCTION unit.check_base_unit();

CREATE CONSTRAINT TRIGGER check_base_unit_change
    AFTER UPDATE OF quantity ON public.unit_family
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.quantity <> NEW.quantity)
    EXECUTE FUNCTION unit.check_base_unit();

-- An item's or attribute's unit can only change to another unit of the
-- same quantity, such as millimetres to inches. Numbers are stored in the
-- quantity's base unit, so the stored numbers stay right and nothing needs
-- converting. Adding a unit where there was none, or removing one, isn't
-- allowed: that would change what the stored numbers mean.
CREATE FUNCTION unit.check_same_quantity()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.unit IS NULL
       OR NEW.unit IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM public.unit old_unit
           JOIN public.unit_family old_family ON old_family.id = old_unit.family
           JOIN public.unit new_unit          ON new_unit.id = NEW.unit
           JOIN public.unit_family new_family ON new_family.id = new_unit.family
           WHERE old_unit.id = OLD.unit
             AND new_family.quantity = old_family.quantity
       )
    THEN
        RAISE EXCEPTION 'The unit of "%" can only change to another unit of the same quantity',
            NEW.name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER check_same_quantity
    BEFORE UPDATE OF unit ON public.item
    FOR EACH ROW
    WHEN (OLD.unit IS DISTINCT FROM NEW.unit)
    EXECUTE FUNCTION unit.check_same_quantity();

CREATE TRIGGER check_same_quantity
    BEFORE UPDATE OF unit ON public.attribute
    FOR EACH ROW
    WHEN (OLD.unit IS DISTINCT FROM NEW.unit)
    EXECUTE FUNCTION unit.check_same_quantity();

-- Moves on the version of the units a tenant sees, once per statement that
-- changes them, as util.bump_tree_version does for the trees, so that a
-- client holding a copy of the unit families knows when to fetch them
-- again. A change to a tenant's own quantities, families or units, or to
-- its choices of which it uses, moves that tenant's version on; a change to
-- a global one moves every tenant's, as every tenant sees it.
CREATE FUNCTION unit.bump_version()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.data_version (tenant, name)
        SELECT t.id, 'unit'
        FROM public.tenant t
        WHERE EXISTS (SELECT 1 FROM old_rows r WHERE r.tenant IS NULL OR r.tenant = t.id)
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    ELSE
        INSERT INTO public.data_version (tenant, name)
        SELECT t.id, 'unit'
        FROM public.tenant t
        WHERE EXISTS (SELECT 1 FROM new_rows r WHERE r.tenant IS NULL OR r.tenant = t.id)
        ON CONFLICT (tenant, name) DO UPDATE SET version = data_version.version + 1;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER bump_version_insert AFTER INSERT ON public.quantity
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_update AFTER UPDATE ON public.quantity
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_delete AFTER DELETE ON public.quantity
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();

CREATE TRIGGER bump_version_insert AFTER INSERT ON public.unit_family
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_update AFTER UPDATE ON public.unit_family
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_delete AFTER DELETE ON public.unit_family
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();

CREATE TRIGGER bump_version_insert AFTER INSERT ON public.unit
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_update AFTER UPDATE ON public.unit
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_delete AFTER DELETE ON public.unit
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();

CREATE TRIGGER bump_version_insert AFTER INSERT ON public.tenant_quantity
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_update AFTER UPDATE ON public.tenant_quantity
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_delete AFTER DELETE ON public.tenant_quantity
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();

CREATE TRIGGER bump_version_insert AFTER INSERT ON public.tenant_unit_family
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_update AFTER UPDATE ON public.tenant_unit_family
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();
CREATE TRIGGER bump_version_delete AFTER DELETE ON public.tenant_unit_family
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION unit.bump_version();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Clients keep the unit families (unit.family_list) and look units up there
-- by id; everything else gives a unit as its id only.

-- A quantity as the units' lists show it: its name, datatype, base unit
-- (an id, found in the same lists) and whether it is global. Built from
-- its row, so it queries nothing.
CREATE FUNCTION unit.quantity_json(p_quantity public.quantity)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_quantity.id,
        'name',      p_quantity.name,
        'datatype',  p_quantity.datatype,
        'base_unit', p_quantity.base_unit,
        'global',    p_quantity.tenant IS NULL
    );
$$;

-- A quantity as the tenant sees it: unit.quantity_json, plus whether it is
-- available to the tenant, the default (its standard for a global one, and
-- available for the tenant's own), and the tenant's own choice (null: it
-- follows the default). p_choice is the tenant's tenant_quantity row, or
-- NULL.
CREATE FUNCTION unit.quantity_entry_json(p_quantity public.quantity, p_choice public.tenant_quantity)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT unit.quantity_json(p_quantity) || jsonb_build_object(
        'available', coalesce(p_choice.available, p_quantity.standard, true),
        'standard',  coalesce(p_quantity.standard, true),
        'choice',    p_choice.available
    );
$$;

-- A unit inside its family's list: with the conversion to its quantity's
-- base unit (base = value × base_factor + base_offset), so clients can
-- convert themselves. Its family and quantity are the list's.
CREATE FUNCTION unit.member_json(p_unit public.unit)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',          p_unit.id,
        'name',        p_unit.name,
        'symbol',      p_unit.symbol,
        'base_factor', p_unit.base_factor,
        'base_offset', p_unit.base_offset,
        'global',      p_unit.tenant IS NULL
    );
$$;

-- A unit on its own, as unit.get and unit.list show it: unit.member_json
-- with its family ({id, name}) and its quantity.
CREATE FUNCTION unit.json(p_unit public.unit, p_family public.unit_family, p_quantity public.quantity)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT unit.member_json(p_unit) || jsonb_build_object(
        'family',   jsonb_build_object('id', p_family.id, 'name', p_family.name),
        'quantity', unit.quantity_json(p_quantity)
    );
$$;

-- A unit family as the tenant sees it: its name, quantity and whether it
-- is global, whether it is available (only while its quantity is:
-- p_quantity_available), the default, the tenant's own choice (p_choice, or
-- NULL), and its units, as the caller has built them.
CREATE FUNCTION unit.family_entry_json(
    p_family             public.unit_family,
    p_quantity           public.quantity,
    p_choice             public.tenant_unit_family,
    p_quantity_available boolean,
    p_units              jsonb
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',        p_family.id,
        'name',      p_family.name,
        'quantity',  unit.quantity_json(p_quantity),
        'global',    p_family.tenant IS NULL,
        'available', p_quantity_available
                     AND coalesce(p_choice.available, p_family.standard, true),
        'standard',  coalesce(p_family.standard, true),
        'choice',    p_choice.available,
        'units',     p_units
    );
$$;

-- Every unit family tenant p_tenant sees, with its entry as the units'
-- lists show it (unit.family_entry_json, with its units, smallest first),
-- and what callers filter and sort by. A plain SQL query, so PostgreSQL
-- inlines it into the caller's and applies the caller's filter first.
CREATE FUNCTION unit.family_entries(p_tenant uuid)
RETURNS TABLE (family uuid, family_name text, quantity uuid, quantity_name text, entry jsonb)
LANGUAGE sql STABLE AS $$
    SELECT f.id, f.name, q.id, q.name,
           unit.family_entry_json(f, q, fc,
               coalesce(qc.available, q.standard, true),
               (SELECT coalesce(jsonb_agg(unit.member_json(u) ORDER BY u.base_factor, u.id), '[]')
                FROM public.unit u
                WHERE u.family = f.id AND (u.tenant IS NULL OR u.tenant = p_tenant)))
    FROM public.unit_family f
    JOIN public.quantity q ON q.id = f.quantity
    LEFT JOIN public.tenant_quantity qc    ON qc.quantity = q.id AND qc.tenant = p_tenant
    LEFT JOIN public.tenant_unit_family fc ON fc.family = f.id AND fc.tenant = p_tenant
    WHERE f.tenant IS NULL OR f.tenant = p_tenant;
$$;

-- Quantity p_quantity as unit.quantity_get shows it: unit.quantity_entry_json
-- with its unit families that tenant p_tenant sees, by name, each with its
-- units (without their quantity, which is the page's). NULL when the tenant
-- doesn't see it.
CREATE FUNCTION unit.quantity_detail_json(p_tenant uuid, p_quantity uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT unit.quantity_entry_json(q, qc) || jsonb_build_object(
               'families', coalesce((
                   SELECT jsonb_agg(e.entry - 'quantity'
                                    ORDER BY e.family_name COLLATE public.natural, e.family)
                   FROM unit.family_entries(p_tenant) e
                   WHERE e.quantity = q.id), '[]'))
    FROM public.quantity q
    LEFT JOIN public.tenant_quantity qc ON qc.quantity = q.id AND qc.tenant = p_tenant
    WHERE q.id = p_quantity
      AND (q.tenant IS NULL OR q.tenant = p_tenant);
$$;

-- The attributes and items of tenant p_tenant whose unit is of
-- quantity p_quantity, or of family p_family (the other one NULL), as text
-- for a message: at most five names, and how many more. NULL when nothing
-- uses them.
CREATE FUNCTION unit.used_by(p_tenant uuid, p_quantity uuid, p_family uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
    WITH used (what) AS (
        SELECT format('attribute "%s"', a.name)
        FROM public.attribute a
        JOIN public.unit u        ON u.id = a.unit
        JOIN public.unit_family f ON f.id = u.family
        WHERE a.tenant = p_tenant
          AND (f.quantity = p_quantity OR f.id = p_family)
        UNION ALL
        SELECT format('item "%s"', i.name)
        FROM public.item i
        JOIN public.class c       ON c.id = i.class
        JOIN public.unit u        ON u.id = i.unit
        JOIN public.unit_family f ON f.id = u.family
        WHERE c.tenant = p_tenant
          AND (f.quantity = p_quantity OR f.id = p_family)
    ),
    first AS (SELECT what FROM used ORDER BY what COLLATE public.natural LIMIT 5)
    SELECT (SELECT string_agg(what, ', ' ORDER BY what COLLATE public.natural) FROM first)
           || CASE WHEN (SELECT count(*) FROM used) > 5
                   THEN format(' and %s more', (SELECT count(*) FROM used) - 5) ELSE '' END;
$$;

-- Refuses a unit that the tenant can't choose for an attribute or an item:
-- one it doesn't see (a bad reference, 422), or one whose family or
-- quantity it has turned off (409). NULL, no unit, is fine.
CREATE FUNCTION unit.check_choosable(p_tenant uuid, p_unit uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_unit record;
BEGIN
    IF p_unit IS NULL THEN
        RETURN;
    END IF;
    SELECT u.symbol, f.name AS family,
           coalesce(qc.available, q.standard, true)
           AND coalesce(fc.available, f.standard, true) AS available
    INTO v_unit
    FROM public.unit u
    JOIN public.unit_family f ON f.id = u.family
    JOIN public.quantity q    ON q.id = f.quantity
    LEFT JOIN public.tenant_quantity qc    ON qc.quantity = q.id AND qc.tenant = p_tenant
    LEFT JOIN public.tenant_unit_family fc ON fc.family = f.id AND fc.tenant = p_tenant
    WHERE u.id = p_unit AND (u.tenant IS NULL OR u.tenant = p_tenant);
    IF NOT FOUND THEN
        PERFORM error.bad_reference('unit', p_unit);
    END IF;
    IF NOT v_unit.available THEN
        PERFORM error.wrong_state(format('The unit %s (%s) isn''t available: its family or quantity is turned off',
                                         v_unit.symbol, v_unit.family));
    END IF;
END;
$$;

-- p_value (in the base unit) as it is shown with unit p_unit: in that unit
-- with p_lock, otherwise in the unit of its family that suits it best (the
-- largest in which it is at least 1, or else the smallest), among the units
-- tenant p_tenant sees. Zero is shown in p_unit. No row when there is no
-- number or no unit. A single SQL query, so that used in a LATERAL join it
-- is inlined and planned with the caller's query.
CREATE FUNCTION unit.display(p_tenant uuid, p_value numeric, p_unit uuid, p_lock boolean)
RETURNS TABLE (value numeric, unit uuid)
LANGUAGE sql STABLE AS $$
    SELECT trim_scale((p_value - u.base_offset) / u.base_factor), u.id
    FROM public.unit chosen
    JOIN public.unit u ON u.family = chosen.family
                      AND (u.tenant IS NULL OR u.tenant = p_tenant)
    WHERE chosen.id = p_unit AND p_value IS NOT NULL
      AND (u.id = p_unit OR (NOT p_lock AND p_value <> 0))
    ORDER BY u.id = p_unit AND (p_lock OR p_value = 0) DESC,
             abs((p_value - u.base_offset) / u.base_factor) >= 1 DESC,
             CASE WHEN abs((p_value - u.base_offset) / u.base_factor) >= 1 THEN u.base_factor END DESC,
             u.base_factor, u.id
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Functions the API calls
-- ---------------------------------------------------------------------------

-- The quantities the tenant sees, the global ones and its own, by name, each
-- with whether the tenant has it available.
CREATE FUNCTION unit.quantity_list(p_request public.request)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(unit.quantity_entry_json(q, c)
                                  ORDER BY q.name COLLATE public.natural, q.id), '[]')
        FROM public.quantity q
        LEFT JOIN public.tenant_quantity c ON c.quantity = q.id AND c.tenant = v_session.tenant
        WHERE q.tenant IS NULL OR q.tenant = v_session.tenant
    );
END;
$$;

-- One quantity the tenant sees, with its unit families that the tenant
-- sees, by name, each with its units, smallest first. A family is available
-- only while its quantity is.
CREATE FUNCTION unit.quantity_get(p_request public.request, p_quantity uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb := unit.quantity_detail_json(v_session.tenant, p_quantity);
BEGIN
    IF v_result IS NULL THEN
        PERFORM error.not_found('quantity', p_quantity::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Turns a quantity on or off for the tenant: p_patch is {"available":
-- true, false or null}, null meaning "follow the default again". A choice
-- that is the default anyway isn't kept, so the tenant has a choice only
-- where it differs. A quantity whose units something uses can't be
-- turned off (409), and turning one off turns its families off too.
-- Returns the quantity as unit.quantity_get does. For admins.
CREATE FUNCTION unit.quantity_patch(p_request public.request, p_quantity uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'admin');
    v_quantity public.quantity;
    v_choice   boolean;
    v_used     text;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['available'], ARRAY[]::text[]);
    SELECT q.* INTO v_quantity
    FROM public.quantity q
    WHERE q.id = p_quantity AND (q.tenant IS NULL OR q.tenant = v_session.tenant);
    IF NOT FOUND THEN
        PERFORM error.not_found('quantity', p_quantity::text);
    END IF;

    IF p_patch ? 'available' THEN
        IF jsonb_typeof(p_patch -> 'available') NOT IN ('boolean', 'null') THEN
            PERFORM error.invalid('available must be true, false or null');
        END IF;
        v_choice := nullif((p_patch ->> 'available')::boolean,
                           coalesce(v_quantity.standard, true));

        IF v_choice IS NULL THEN
            DELETE FROM public.tenant_quantity c
            WHERE c.tenant = v_session.tenant AND c.quantity = p_quantity;
        ELSE
            INSERT INTO public.tenant_quantity (tenant, quantity, available)
            VALUES (v_session.tenant, p_quantity, v_choice)
            ON CONFLICT (tenant, quantity) DO UPDATE SET available = EXCLUDED.available;
        END IF;

        -- Refused after the write, in the same transaction, which the error
        -- rolls back.
        IF NOT coalesce(v_choice, v_quantity.standard, true) THEN
            v_used := unit.used_by(v_session.tenant, p_quantity, NULL);
            IF v_used IS NOT NULL THEN
                PERFORM error.in_use(format('%s can''t be turned off: %s uses it', v_quantity.name, v_used),
                                     'Change the unit of what uses it first.');
            END IF;
        END IF;
    END IF;

    RETURN unit.quantity_detail_json(v_session.tenant, p_quantity);
END;
$$;

-- The unit families the tenant sees, by quantity and then by name, each
-- with its units, smallest first; only those of quantity p_quantity, when
-- given. Clients keep them, and ask again with the version they have
-- (p_known_version): when it is the tenant's current one, the answer is
-- {version, unchanged: true} without the families.
CREATE FUNCTION unit.family_list(
    p_request       public.request,
    p_known_version bigint DEFAULT NULL,
    p_quantity      uuid   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_version bigint;
BEGIN
    IF p_quantity IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.quantity q
        WHERE q.id = p_quantity AND (q.tenant IS NULL OR q.tenant = v_session.tenant)
    ) THEN
        PERFORM error.not_found('quantity', p_quantity::text);
    END IF;

    v_version := coalesce((SELECT v.version FROM public.data_version v
                           WHERE v.tenant = v_session.tenant AND v.name = 'unit'), 1);
    IF p_known_version IS NOT DISTINCT FROM v_version THEN
        RETURN jsonb_build_object('version', v_version, 'unchanged', true);
    END IF;
    RETURN jsonb_build_object(
        'version',   v_version,
        'unchanged', false,
        'families',  (SELECT coalesce(jsonb_agg(e.entry ORDER BY e.quantity_name COLLATE public.natural,
                                                                 e.family_name COLLATE public.natural,
                                                                 e.family), '[]')
                      FROM unit.family_entries(v_session.tenant) e
                      WHERE p_quantity IS NULL OR e.quantity = p_quantity));
END;
$$;

-- One unit family the tenant sees, with its units, smallest first.
CREATE FUNCTION unit.family_get(p_request public.request, p_family uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT e.entry INTO v_result
    FROM unit.family_entries(v_session.tenant) e
    WHERE e.family = p_family;
    IF NOT FOUND THEN
        PERFORM error.not_found('unit family', p_family::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Turns a unit family on or off for the tenant, as unit.quantity_patch
-- does for a quantity. A family of a quantity that is off stays off,
-- whatever its own choice. Returns the family as unit.family_get does. For
-- admins.
CREATE FUNCTION unit.family_patch(p_request public.request, p_family uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_family  public.unit_family;
    v_choice  boolean;
    v_used    text;
    v_result  jsonb;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['available'], ARRAY[]::text[]);
    SELECT f.* INTO v_family
    FROM public.unit_family f
    WHERE f.id = p_family AND (f.tenant IS NULL OR f.tenant = v_session.tenant);
    IF NOT FOUND THEN
        PERFORM error.not_found('unit family', p_family::text);
    END IF;

    IF p_patch ? 'available' THEN
        IF jsonb_typeof(p_patch -> 'available') NOT IN ('boolean', 'null') THEN
            PERFORM error.invalid('available must be true, false or null');
        END IF;
        v_choice := nullif((p_patch ->> 'available')::boolean,
                           coalesce(v_family.standard, true));

        IF v_choice IS NULL THEN
            DELETE FROM public.tenant_unit_family c
            WHERE c.tenant = v_session.tenant AND c.family = p_family;
        ELSE
            INSERT INTO public.tenant_unit_family (tenant, family, available)
            VALUES (v_session.tenant, p_family, v_choice)
            ON CONFLICT (tenant, family) DO UPDATE SET available = EXCLUDED.available;
        END IF;

        IF NOT coalesce(v_choice, v_family.standard, true) THEN
            v_used := unit.used_by(v_session.tenant, NULL, p_family);
            IF v_used IS NOT NULL THEN
                PERFORM error.in_use(format('%s can''t be turned off: %s uses it', v_family.name, v_used),
                                     'Change the unit of what uses it first.');
            END IF;
        END IF;
    END IF;

    SELECT e.entry INTO v_result
    FROM unit.family_entries(v_session.tenant) e
    WHERE e.family = p_family;
    RETURN v_result;
END;
$$;

-- The units the tenant sees, by family name and then by size; only those
-- of quantity p_quantity, or of family p_family, when given.
CREATE FUNCTION unit.list(
    p_request  public.request,
    p_quantity uuid DEFAULT NULL,
    p_family   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    IF p_quantity IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.quantity q
        WHERE q.id = p_quantity AND (q.tenant IS NULL OR q.tenant = v_session.tenant)
    ) THEN
        PERFORM error.not_found('quantity', p_quantity::text);
    END IF;
    IF p_family IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.unit_family f
        WHERE f.id = p_family AND (f.tenant IS NULL OR f.tenant = v_session.tenant)
    ) THEN
        PERFORM error.not_found('unit family', p_family::text);
    END IF;

    RETURN (
        SELECT coalesce(jsonb_agg(unit.json(u, f, q)
                                  ORDER BY f.name COLLATE public.natural, f.id,
                                           u.base_factor, u.id), '[]')
        FROM public.unit u
        JOIN public.unit_family f ON f.id = u.family
        JOIN public.quantity q    ON q.id = f.quantity
        WHERE (u.tenant IS NULL OR u.tenant = v_session.tenant)
          AND (p_quantity IS NULL OR f.quantity = p_quantity)
          AND (p_family IS NULL OR u.family = p_family)
    );
END;
$$;

-- One unit the tenant sees, with its family and quantity.
CREATE FUNCTION unit.get(p_request public.request, p_unit uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_result  jsonb;
BEGIN
    SELECT unit.json(u, f, q) INTO v_result
    FROM public.unit u
    JOIN public.unit_family f ON f.id = u.family
    JOIN public.quantity q    ON q.id = f.quantity
    WHERE u.id = p_unit AND (u.tenant IS NULL OR u.tenant = v_session.tenant);
    IF NOT FOUND THEN
        PERFORM error.not_found('unit', p_unit::text);
    END IF;
    RETURN v_result;
END;
$$;
