-- The errors the database raises on purpose (schema error). Each raises one
-- SQLSTATE, which the API turns into an HTTP status in one place
-- (internal/serve/problem.go): which code means what is decided here and
-- nowhere else.

CREATE SCHEMA error;

-- How an error message names a row: Item "Drill", Location "Shelf 2",
-- Stock row 1A7K of "Drill", …
CREATE FUNCTION error.row_label(p_table text, p_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN CASE p_table
        WHEN 'class'            THEN (SELECT format('Class "%s"', c.name) FROM public.class c WHERE c.id = p_id)
        WHEN 'location'         THEN (SELECT format('Location "%s"', l.name) FROM public.location l WHERE l.id = p_id)
        WHEN 'item'             THEN (SELECT format('Item "%s"', i.name) FROM public.item i WHERE i.id = p_id)
        WHEN 'stock'            THEN (SELECT format('Stock row %s of "%s"', util.code_text(s.code), i.name)
                                      FROM public.stock s JOIN public.item i ON i.id = s.item WHERE s.id = p_id)
        WHEN 'attribute'        THEN (SELECT format('Attribute "%s"', a.name) FROM public.attribute a WHERE a.id = p_id)
        WHEN 'attribute_option' THEN (SELECT format('Option "%s"', o.name) FROM public.attribute_option o WHERE o.id = p_id)
        WHEN 'attachment'       THEN (SELECT format('Attachment "%s"', a.title) FROM public.attachment a WHERE a.id = p_id)
        WHEN 'account'          THEN (SELECT format('Account %s', a.email) FROM public.account a WHERE a.id = p_id)
    END;
END;
$$;

-- The names of the attributes p_attributes, in alphabetical order and
-- separated by commas, for error messages such as "Item "Drill" is missing
-- required attributes: Colour, Voltage".
CREATE FUNCTION error.attribute_names(p_attributes uuid[])
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT string_agg(a.name, ', ' ORDER BY lower(a.name))
    FROM public.attribute a
    WHERE a.id = ANY (p_attributes);
$$;

-- Raises "invalid input" (22023, 400): the request itself is wrong.
CREATE FUNCTION error.invalid(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'invalid_parameter_value';
END;
$$;

-- Raises "not found" (P0002, 404), for the object a request is about (in
-- its path) when it doesn't exist or is another tenant's. The id is text,
-- as it isn't always a uuid (a session's id is its token's hash).
CREATE FUNCTION error.not_found(p_entity text, p_id text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% % not found', p_entity, p_id USING ERRCODE = 'no_data_found';
END;
$$;

-- Raises "no tenant has this host" (P0002, 404), for a request to a
-- hostname that picks no tenant.
CREATE FUNCTION error.unknown_host(p_host text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'No tenant has the host "%"', p_host USING ERRCODE = 'no_data_found';
END;
$$;

-- Raises "bad reference" (23503, 422), as a foreign key would, for a
-- reference in a request's body to something that isn't there or is
-- another tenant's. A missing object in the path is error.not_found's.
CREATE FUNCTION error.bad_reference(p_entity text, p_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% % not found', p_entity, p_id USING ERRCODE = 'foreign_key_violation';
END;
$$;

-- Raises "not allowed by the rules" (23514, 422), as the rules themselves
-- do, for a request the rules would refuse, said before anything changes.
CREATE FUNCTION error.not_allowed(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'check_violation';
END;
$$;

-- Raises "already exists" (23505, 409), for a name or address that must be
-- unique and is taken, with a message that says which.
CREATE FUNCTION error.duplicate(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'unique_violation';
END;
$$;

-- Raises "still in use" (23001, 409), for something that can't be deleted
-- or turned off while other things use it, with a hint of what to do.
CREATE FUNCTION error.in_use(p_message text, p_hint text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'restrict_violation', HINT = p_hint;
END;
$$;

-- Raises "not possible in this state" (55000, 409), with a message that
-- says why and, where there is one, the way out: a unit that is turned off.
CREATE FUNCTION error.wrong_state(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'object_not_in_prerequisite_state';
END;
$$;

-- Raises "gone" (WT001, 410), for a label code that was handed out but that
-- nothing has any more: what had it was deleted. It has a code of its own,
-- outside PostgreSQL's, as no standard one means "deleted".
CREATE FUNCTION error.gone(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'WT001';
END;
$$;

-- Raises "not logged in" (28000, 401).
CREATE FUNCTION error.unauthenticated(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'invalid_authorization_specification';
END;
$$;

-- Raises "not allowed" (42501, 403): logged in, but the account's role is
-- too low for this.
CREATE FUNCTION error.forbidden(p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'insufficient_privilege';
END;
$$;
