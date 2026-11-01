-- Label codes (schema code). Explained in api/code.md.

CREATE SCHEMA code;

-- What a scanned or typed label code of the tenant's belongs to: {type,
-- object}, where type is 'location', 'item' or 'stock' and object is what
-- that kind's get returns. Letter case and hyphens in p_code are ignored.
-- Codes are unique within a tenant across the three kinds, so at most one
-- matches. Deleted ones are found too, as their labels still exist.
CREATE FUNCTION code.resolve(p_request public.request, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_session  record := util.session(p_request, 'viewer');
    v_code     bigint := util.code_value(p_code);
    v_location public.location;
    v_item     public.item;
    v_stock    public.stock;
    v_deleted  jsonb;
BEGIN
    SELECT l.* INTO v_location
    FROM public.location l
    WHERE l.tenant = v_session.tenant AND l.code = v_code;
    IF FOUND THEN
        SELECT util.deleted_json(d, db) INTO v_deleted
        FROM public.action d LEFT JOIN public.account db ON db.id = d.account
        WHERE d.id = v_location.deleted;
        RETURN jsonb_build_object('type', 'location', 'object', location.detail_json(v_location, v_deleted));
    END IF;

    SELECT i.* INTO v_item
    FROM public.item i JOIN public.class c ON c.id = i.class
    WHERE i.code = v_code AND c.tenant = v_session.tenant;
    IF FOUND THEN
        SELECT util.deleted_json(d, db) INTO v_deleted
        FROM public.action d LEFT JOIN public.account db ON db.id = d.account
        WHERE d.id = v_item.deleted;
        RETURN jsonb_build_object('type', 'item', 'object',
                                  item.detail_json(v_session.tenant, v_item, v_deleted));
    END IF;

    SELECT s.* INTO v_stock
    FROM public.stock s JOIN public.location l ON l.id = s.location
    WHERE s.code = v_code AND l.tenant = v_session.tenant;
    IF FOUND THEN
        SELECT util.deleted_json(d, db) INTO v_deleted
        FROM public.action d LEFT JOIN public.account db ON db.id = d.account
        WHERE d.id = v_stock.deleted;
        RETURN jsonb_build_object('type', 'stock', 'object',
                                  stock.detail_json(v_session.tenant, v_stock, v_deleted));
    END IF;

    PERFORM error.not_found('code', upper(p_code));
END;
$$;
