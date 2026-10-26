-- API: resolving label codes. Explained in api/code.md.

-- What a scanned or typed code belongs to: {type, object}, where type is
-- 'location', 'item' or 'stock' and object is what the matching _get
-- function returns. Case and hyphens in p_code are ignored.
CREATE FUNCTION code_resolve(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant uuid   := util.require('data', 'read');
    v_code   bigint := util.code_value(p_code);
    v_id     uuid;
BEGIN
    SELECT id INTO v_id FROM location WHERE code = v_code AND tenant = v_tenant;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'location', 'object', location_get(v_id));
    END IF;

    SELECT id INTO v_id FROM item WHERE code = v_code AND tenant = v_tenant;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'item', 'object', item_get(v_id));
    END IF;

    SELECT id INTO v_id FROM stock WHERE code = v_code AND tenant = v_tenant;
    IF FOUND THEN
        RETURN jsonb_build_object('type', 'stock', 'object', stock_get(v_id));
    END IF;

    RAISE EXCEPTION 'Code % not found', upper(p_code)
        USING ERRCODE = 'no_data_found';
END;
$$;
