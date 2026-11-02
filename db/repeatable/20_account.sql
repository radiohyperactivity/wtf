-- Accounts, logging in and sessions (schema account): the functions the API
-- calls for them. See ACCOUNTS.md.

CREATE SCHEMA account;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- An account as the API shows it, built from the row it is given, so it
-- queries nothing. The password hash is never shown, only whether there is
-- one.
CREATE FUNCTION account.json(p_account public.account)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'id',           p_account.id,
        'email',        p_account.email,
        'has_password', p_account.password_hash IS NOT NULL,
        'role',         p_account.role
    );
$$;

-- p_email trimmed and in lower case, as accounts store it, if it looks like
-- an email address: something, an @, and something, without spaces. Raises
-- "invalid" otherwise.
CREATE FUNCTION account.clean_email(p_email text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_email IS NULL OR btrim(p_email) !~ '^[^@\s]+@[^@\s]+$' THEN
        PERFORM error.invalid(format('%L is not an email address', p_email));
    END IF;
    RETURN lower(btrim(p_email));
END;
$$;

-- The bcrypt hash of a new password, at cost 12, which must have at least 8
-- characters and at most 72 bytes (bcrypt reads no further). NULL for NULL:
-- an account without a password can't log in.
CREATE FUNCTION account.password_hash(p_password text)
RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    IF p_password IS NULL THEN
        RETURN NULL;
    END IF;
    IF char_length(p_password) < 8 THEN
        PERFORM error.invalid('A password needs at least 8 characters');
    END IF;
    IF octet_length(p_password) > 72 THEN
        PERFORM error.invalid('A password can be at most 72 bytes long');
    END IF;
    RETURN extensions.crypt(p_password, extensions.gen_salt('bf', 12));
END;
$$;

-- Ends every session of the session's account except the session itself,
-- and returns how many ended. Used after a new password, and for "log out
-- everywhere else".
CREATE FUNCTION account.end_other_sessions(p_session record)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_ended integer;
BEGIN
    DELETE FROM public.session s
    WHERE s.account = p_session.account
      AND s.token_hash <> p_session.session;
    GET DIAGNOSTICS v_ended = ROW_COUNT;
    RETURN v_ended;
END;
$$;

-- ---------------------------------------------------------------------------
-- Logging in and out, and one's own sessions
-- ---------------------------------------------------------------------------

-- Logs in with an email address and a password, and starts a session for the client p_client ("WtF on Pixel
-- 9"), which may sit unused for p_max_idle before it expires (NULL: never),
-- with the request's address as the first in its trail.
--
-- Returns {ok: true, token, account}, or {ok: false, reason}, where reason
-- is 'invalid' (unknown email or wrong password) or 'locked' (after 5
-- failed attempts, one attempt a minute is allowed until one succeeds).
-- Failures are returned rather than raised, so that the count of failed
-- attempts is committed.
CREATE FUNCTION account.login(
    p_request  public.request,
    p_email    text,
    p_password text,
    p_client   text,
    p_max_idle interval
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_account public.account;
    v_token   text;
BEGIN
    IF p_max_idle <= interval '0' THEN
        PERFORM error.invalid('A session must be allowed to sit unused for some time, or for ever');
    END IF;

    SELECT a.* INTO v_account
    FROM public.account a
    WHERE a.email = lower(btrim(p_email))
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Spend as long as a real check, so that the time taken doesn't
        -- reveal which email addresses have an account.
        PERFORM extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 12));
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;

    IF v_account.failed_logins >= 5 AND v_account.last_failed_login > now() - interval '1 minute' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'locked');
    END IF;

    IF v_account.password_hash IS NULL
       OR p_password IS NULL
       OR extensions.crypt(p_password, v_account.password_hash) <> v_account.password_hash
    THEN
        UPDATE public.account
        SET failed_logins = failed_logins + 1, last_failed_login = now()
        WHERE id = v_account.id;
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;

    UPDATE public.account SET failed_logins = 0, last_failed_login = NULL
    WHERE id = v_account.id AND failed_logins <> 0;

    -- The account's expired sessions go, while we're here.
    DELETE FROM public.session s
    WHERE s.account = v_account.id
      AND s.max_idle IS NOT NULL
      AND s.last_used <= now() - s.max_idle;

    -- 32 random bytes from a cryptographically strong source, as URL-safe
    -- base64 without padding.
    v_token := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    INSERT INTO public.session (token_hash, account, client, max_idle, usage)
    VALUES (util.token_hash(v_token), v_account.id, nullif(btrim(p_client), ''), p_max_idle,
            CASE WHEN (p_request).address IS NULL THEN '{}'
                 ELSE ARRAY[((p_request).address, now())::public.session_usage] END);

    RETURN jsonb_build_object(
        'ok',      true,
        'token',   v_token,
        'account', account.json(v_account)
    );
END;
$$;

-- Ends the session the call is made with.
CREATE FUNCTION account.logout(p_request public.request)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    DELETE FROM public.session s WHERE s.token_hash = v_session.session;
END;
$$;

-- The account the call is made with.
CREATE FUNCTION account.me(p_request public.request)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    RETURN (SELECT account.json(a) FROM public.account a WHERE a.id = v_session.account);
END;
$$;

-- Changes the password of the account the call is made with, which needs
-- its current password. With p_end_other_sessions, its other sessions end
-- too: whoever else was logged in as it has to log in again, with the new
-- password. The choice has no default.
CREATE FUNCTION account.password_change(
    p_request            public.request,
    p_current            text,
    p_new                text,
    p_end_other_sessions boolean
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
    v_hash    text;
BEGIN
    SELECT a.password_hash INTO v_hash
    FROM public.account a
    WHERE a.id = v_session.account
    FOR UPDATE;
    IF v_hash IS NULL OR p_current IS NULL OR extensions.crypt(p_current, v_hash) <> v_hash THEN
        PERFORM error.invalid('The current password is wrong');
    END IF;
    IF p_new IS NULL THEN
        PERFORM error.invalid('A new password is needed');
    END IF;
    IF p_end_other_sessions IS NULL THEN
        PERFORM error.invalid('Say whether the other sessions should end');
    END IF;

    UPDATE public.account SET password_hash = account.password_hash(p_new)
    WHERE id = v_session.account;
    IF p_end_other_sessions THEN
        PERFORM account.end_other_sessions(v_session);
    END IF;
END;
$$;

-- The sessions of the account the call is made with, most recently used
-- first: which client, since when, when last used, how long each may sit
-- unused and so when it expires, the addresses it was used from, and which
-- one is making this call. A session's id is its token's hash in hex, which
-- can't be turned back into the token. Expired sessions not removed yet are
-- left out.
CREATE FUNCTION account.session_list(p_request public.request)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id',        encode(s.token_hash, 'hex'),
                   'client',    s.client,
                   'created',   s.created,
                   'last_used', s.last_used,
                   'max_idle',  extract(epoch FROM s.max_idle)::bigint,
                   'expires',   s.last_used + s.max_idle,
                   'current',   s.token_hash = v_session.session,
                   'usage',     (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                            'address', host((u).address),
                                            'seen',    (u).seen)
                                        ORDER BY (u).seen DESC), '[]')
                                 FROM unnest(s.usage) u))
               ORDER BY s.last_used DESC, s.created DESC), '[]')
        FROM public.session s
        WHERE s.account = v_session.account
          AND (s.max_idle IS NULL OR s.last_used > now() - s.max_idle)
    );
END;
$$;

-- Ends one session of the account the call is made with: p_session is its
-- id, as account.session_list gives it. Another account's session is not
-- found, the same as one that doesn't exist. Ending the session the call
-- is made with is the same as account.logout.
CREATE FUNCTION account.session_logout(p_request public.request, p_session text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    IF p_session IS NULL OR p_session !~ '^[0-9a-f]{64}$' THEN
        PERFORM error.invalid('A session id is 64 hexadecimal digits');
    END IF;
    DELETE FROM public.session s
    WHERE s.token_hash = decode(p_session, 'hex')
      AND s.account = v_session.account;
    IF NOT FOUND THEN
        PERFORM error.not_found('session', p_session);
    END IF;
END;
$$;

-- Ends every session of the account the call is made with, except the one
-- making the call: "log out everywhere else", for a lost phone. Returns how
-- many sessions ended.
CREATE FUNCTION account.session_logout_others(p_request public.request)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'viewer');
BEGIN
    RETURN account.end_other_sessions(v_session);
END;
$$;

-- ---------------------------------------------------------------------------
-- Managing accounts (admins)
-- ---------------------------------------------------------------------------

-- The accounts, by email address.
CREATE FUNCTION account.list(p_request public.request)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(account.json(a)
                                  ORDER BY a.email COLLATE public.natural, a.id), '[]')
        FROM public.account a
    );
END;
$$;

-- An account.
CREATE FUNCTION account.get(p_request public.request, p_account uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_result  jsonb;
BEGIN
    SELECT account.json(a) INTO v_result
    FROM public.account a
    WHERE a.id = p_account;
    IF NOT FOUND THEN
        PERFORM error.not_found('account', p_account::text);
    END IF;
    RETURN v_result;
END;
$$;

-- Creates an account with the role p_role. With a NULL
-- p_password it has none, and can't log in until one is set.
CREATE FUNCTION account.create(
    p_request  public.request,
    p_email    text,
    p_password text,
    p_role     public.role
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_email   text := account.clean_email(p_email);
    v_account public.account;
BEGIN
    IF p_role IS NULL THEN
        PERFORM error.invalid('An account needs a role: viewer, user or admin');
    END IF;
    IF EXISTS (SELECT 1 FROM public.account a
               WHERE a.email = v_email) THEN
        PERFORM error.duplicate(format('There is an account for %s already', v_email));
    END IF;

    INSERT INTO public.account (email, password_hash, role)
    VALUES (v_email, account.password_hash(p_password), p_role)
    RETURNING * INTO v_account;
    RETURN account.json(v_account);
END;
$$;

-- Changes the fields of an account that p_patch has: email, password (null
-- removes it, and the account can't log in) and role. With a password,
-- end_sessions (true or false, and only with it) says whether the
-- account's sessions end too. An admin's own password is changed with
-- account.password_change, which needs the current one, and their own role
-- can't be changed, so that there is always an admin.
CREATE FUNCTION account.patch(p_request public.request, p_account uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
    v_account public.account;
    v_email   text;
BEGIN
    PERFORM util.check_patch(p_patch, ARRAY['email', 'password', 'end_sessions', 'role'],
                             ARRAY['email', 'role', 'end_sessions']);
    IF (p_patch ? 'password') <> (p_patch ? 'end_sessions') THEN
        PERFORM error.invalid(CASE WHEN p_patch ? 'password'
            THEN 'Say whether the account''s sessions should end (end_sessions)'
            ELSE 'end_sessions only goes with a new password' END);
    END IF;

    SELECT a.* INTO v_account
    FROM public.account a
    WHERE a.id = p_account
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM error.not_found('account', p_account::text);
    END IF;
    IF p_account = v_session.account AND p_patch ? 'password' THEN
        PERFORM error.invalid('Change your own password with your current one (password change)');
    END IF;
    IF p_account = v_session.account AND p_patch ? 'role'
       AND (p_patch ->> 'role')::public.role <> v_account.role THEN
        PERFORM error.invalid('You can''t change your own role');
    END IF;
    IF p_patch ? 'email' THEN
        v_email := account.clean_email(p_patch ->> 'email');
        IF EXISTS (SELECT 1 FROM public.account a
                   WHERE a.email = v_email
                     AND a.id <> p_account) THEN
            PERFORM error.duplicate(format('There is an account for %s already', v_email));
        END IF;
    END IF;

    UPDATE public.account a
    SET email         = coalesce(v_email, a.email),
        password_hash = CASE WHEN p_patch ? 'password'
                             THEN account.password_hash(p_patch ->> 'password')
                             ELSE a.password_hash END,
        role          = coalesce((p_patch ->> 'role')::public.role, a.role)
    WHERE a.id = p_account
    RETURNING * INTO v_account;

    IF (p_patch ->> 'end_sessions')::boolean THEN
        DELETE FROM public.session s WHERE s.account = p_account;
    END IF;
    RETURN account.json(v_account);
END;
$$;

-- Deletes an account, and with it its sessions. Its email
-- address can be used for a new account. An admin can't delete their own
-- account, so that there is always an admin.
CREATE FUNCTION account.delete(p_request public.request, p_account uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET jit = off
AS $$
DECLARE
    v_session record := util.session(p_request, 'admin');
BEGIN
    IF p_account = v_session.account THEN
        PERFORM error.invalid('You can''t delete your own account');
    END IF;
    DELETE FROM public.account a
    WHERE a.id = p_account;
    IF NOT FOUND THEN
        PERFORM error.not_found('account', p_account::text);
    END IF;
END;
$$;
