-- Label codes (schema code). Explained in api/code.md.

CREATE SCHEMA code;

-- What a scanned or typed label code of the tenant's belongs to: {type,
-- object}, where type is 'location', 'item' or 'stock' and object is what
-- that kind's get returns. Letter case and hyphens in p_code are ignored.
-- Codes are unique within a tenant across the three kinds, so at most one
-- matches.
--
-- A code that nothing has is "gone" (410) when the tenant has handed it out
-- (it is at most tenant.code): every code handed out was given to an item,
-- location or stock row (tenant.take_codes), so what had it was deleted. A
-- code above that, or below the first (32768, "1000"), was never handed out
-- and is not found (404).
CREATE FUNCTION code.resolve(p_request public.request, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session  record := util.session(p_request, 'viewer');
    v_code     bigint := util.code_value(p_code);
    v_location public.location;
    v_item     public.item;
    v_stock    public.stock;
BEGIN
    SELECT l.* INTO v_location
    FROM public.location l
    WHERE l.tenant = v_session.tenant AND l.code = v_code;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'location', 'object', location.detail_json(v_location));
    END IF;

    SELECT i.* INTO v_item
    FROM public.item i JOIN public.class c ON c.id = i.class
    WHERE i.code = v_code AND c.tenant = v_session.tenant;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'item', 'object', item.detail_json(v_session.tenant, v_item));
    END IF;

    SELECT s.* INTO v_stock
    FROM public.stock s JOIN public.location l ON l.id = s.location
    WHERE s.code = v_code AND l.tenant = v_session.tenant;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'stock', 'object', stock.detail_json(v_session.tenant, v_stock));
    END IF;

    IF v_code >= 32768 AND v_code <= (SELECT t.code FROM public.tenant t WHERE t.id = v_session.tenant) THEN
        PERFORM error.gone(format('The item, stock row or location with the label %s has been deleted',
                                  util.code_text(v_code)));
    END IF;
    PERFORM error.not_found('code', upper(p_code));
END;
$$;
