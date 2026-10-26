-- API: information about the database itself. Explained in api/meta.md.

-- The applied migration version and the checksums (hex SHA-256) of the applied
-- repeatable scripts, from wtfd's bookkeeping. "wtfd serve" compares this with
-- the scripts embedded in the binary and refuses to start on a mismatch.
CREATE FUNCTION schema_version() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN jsonb_build_object(
        'version',     (SELECT COALESCE(max(version), 0) FROM wtfd.migration),
        'repeatables', (
            SELECT COALESCE(jsonb_object_agg(name, encode(checksum, 'hex')), '{}'::jsonb)
            FROM wtfd.repeatable
        )
    );
END;
$$;
