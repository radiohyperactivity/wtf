-- Information about the database itself (schema meta). Explained in
-- api/meta.md.

CREATE SCHEMA meta;

-- The applied migration version and the checksums (hex SHA-256) of the
-- applied repeatable scripts, from wtfd's bookkeeping. "wtfd serve" compares
-- this with the scripts embedded in the binary when it starts, and refuses
-- to start on a mismatch. It takes no request: wtfd calls it for itself,
-- before any request, and it tells nothing about any tenant.
CREATE FUNCTION meta.schema_version()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN jsonb_build_object(
        'version',     (SELECT coalesce(max(m.version), 0) FROM wtfd.migration m),
        'repeatables', (
            SELECT coalesce(jsonb_object_agg(r.name, encode(r.checksum, 'hex')), '{}'::jsonb)
            FROM wtfd.repeatable r
        )
    );
END;
$$;
