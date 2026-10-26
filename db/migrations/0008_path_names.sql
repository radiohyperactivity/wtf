-- Class and location names can't contain "/": it separates the names in a
-- path ("Garage/Shelf 2"), so a path always means one thing. Explained in
-- SCHEMA.md.

-- Existing names with "/" must be renamed first; list them all.
DO $$
DECLARE
    v_names text;
BEGIN
    SELECT string_agg(format('%s %L (id %s)', n.kind, n.name, n.id), ', ' ORDER BY n.kind, n.name)
    INTO v_names
    FROM (
        SELECT 'class' AS kind, c.name, c.id FROM class c WHERE strpos(c.name, '/') > 0
        UNION ALL
        SELECT 'location', l.name, l.id FROM location l WHERE strpos(l.name, '/') > 0
    ) n;
    IF v_names IS NOT NULL THEN
        RAISE EXCEPTION 'Class and location names may no longer contain "/". Rename these first: %', v_names;
    END IF;
END;
$$;

ALTER TABLE class    ADD CONSTRAINT class_name_slash_check    CHECK (strpos(name, '/') = 0);
ALTER TABLE location ADD CONSTRAINT location_name_slash_check CHECK (strpos(name, '/') = 0);
