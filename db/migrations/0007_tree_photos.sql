-- Class and location tree nodes include their photo (util.class_tree,
-- util.location_tree). The photo's title can change without the class or
-- location changing, so every change to their attachments also moves the
-- tree's version on (see data_version), and a cached tree is never stale.

CREATE FUNCTION bump_data_version_of() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE data_version
    SET version = version + 1
    WHERE name = TG_ARGV[0];
    RETURN NULL;
END;
$$;

CREATE TRIGGER class_attachment_bump_data_version
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON class_attachment
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version_of('class');

CREATE TRIGGER location_attachment_bump_data_version
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON location_attachment
    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version_of('location');
