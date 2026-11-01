-- Tenants (schema tenant): their label codes. See TENANTS.md.

CREATE SCHEMA tenant;

-- Hands out p_count label codes of tenant p_tenant at once, and returns the
-- first: the codes are that one and the p_count - 1 after it. One counter
-- for items, locations and stock rows, so a code is unique across all three
-- within the tenant, as only this function hands codes out. One write of
-- the tenant's row, however many codes. The row stays locked until commit,
-- so the tenant's other creating transactions wait their turn, and the
-- codes have no gaps (a rollback undoes the count). Other tenants never
-- wait.
--
-- The caller must give every code it takes to a new item, location or
-- stock row, in the same transaction: then every code up to tenant.code
-- belonged to something, and code.resolve can tell a deleted thing's code
-- (410) from one never handed out (404).
CREATE FUNCTION tenant.take_codes(p_tenant uuid, p_count integer)
RETURNS bigint
LANGUAGE sql AS $$
    UPDATE public.tenant t SET code = t.code + p_count
    WHERE t.id = p_tenant
    RETURNING t.code - p_count + 1;
$$;
