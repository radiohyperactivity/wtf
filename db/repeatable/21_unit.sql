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
