-- API: resolving label codes. Explained in api/code.md.

-- What a scanned or typed code of the tenant's belongs to: {type, object},
-- where type is 'location', 'item' or 'stock' and object is what the matching _get
-- function returns. Case and hyphens in p_code are ignored.
CREATE FUNCTION code_resolve(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid;
    v_code   bigint;
    v_id     uuid;
BEGIN
    PERFORM util.require('viewer');
    v_tenant := util.tenant();
    v_code := util.code_value(p_code);
    SELECT id INTO v_id FROM location WHERE tenant = v_tenant AND code = v_code;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'location', 'object', location_get(v_id));
    END IF;

    SELECT id INTO v_id FROM item WHERE tenant = v_tenant AND code = v_code;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'item', 'object', item_get(v_id));
    END IF;

    SELECT id INTO v_id FROM stock WHERE tenant = v_tenant AND code = v_code;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'stock', 'object', stock_get(v_id));
    END IF;

    RAISE EXCEPTION 'Code % not found', upper(p_code)
        USING ERRCODE = 'no_data_found';
END;
$$;
