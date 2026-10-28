-- API: tenants by host, sessions, logging in and out, and accounts. Explained
-- in api/account.md, ACCOUNTS.md and TENANTS.md.

-- ---------------------------------------------------------------------------
-- Tenants and sessions (see TENANTS.md)
-- ---------------------------------------------------------------------------

-- The tenant whose host is p_host, the first label of a request's hostname
-- ("bob" for bob.wtf.example); NULL when there is none.
CREATE FUNCTION util.tenant_of_host(p_host text) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT id FROM tenant WHERE host = lower(p_host));
END;
$$;

-- Whether a tenant has host p_host. wtfd answers 404 to every request whose
-- hostname picks no tenant.
CREATE FUNCTION tenant_known(p_host text) RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN util.tenant_of_host(p_host) IS NOT NULL;
END;
$$;

-- Starts using a session for the current transaction: checks that p_token
-- is a session of the tenant of p_host that hasn't been unused for 30 days,
-- renews it (at most once a minute) and remembers the token until the end
-- of the transaction. wtfd calls this before every API function except
-- login.
CREATE FUNCTION session_use(p_token text, p_host text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_hash      bytea := util.token_hash(p_token);
    v_last_used timestamptz;
BEGIN
    SELECT s.last_used INTO v_last_used
    FROM session s
    WHERE s.token_hash = v_hash
      AND s.tenant = util.tenant_of_host(p_host)
      AND s.last_used > now() - interval '30 days';
    IF NOT FOUND THEN
        PERFORM util.raise_unauthenticated('Not logged in, or the session has expired');
    END IF;

    IF v_last_used < now() - interval '1 minute' THEN
        UPDATE session SET last_used = now() WHERE token_hash = v_hash;
    END IF;
    PERFORM set_config('wtf.token', p_token, true);
END;
$$;

-- Logs in to the tenant of p_host with email and password. Returns {ok:
-- true, token, account}, or {ok: false, reason} with reason
-- 'invalid' (unknown email or wrong password) or 'locked' (after 5 failed
-- attempts, one attempt per minute is allowed until a login succeeds).
-- Failures are returned rather than raised, so the failed-login count is
-- committed.
CREATE FUNCTION login(p_host text, p_email text, p_password text) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_account account;
    v_token   text;
BEGIN
    SELECT a.* INTO v_account
    FROM account a
    WHERE a.tenant = util.tenant_of_host(p_host)
      AND lower(a.email) = lower(btrim(p_email))
      AND NOT a.deleted
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Spend about as long as a real check, so the response time doesn't
        -- reveal which emails exist.
        PERFORM extensions.crypt(COALESCE(p_password, ''), extensions.gen_salt('bf'));
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;

    IF v_account.failed_logins >= 5 AND v_account.last_failed_login > now() - interval '1 minute' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'locked');
    END IF;

    IF v_account.password_hash IS NULL
       OR p_password IS NULL
       OR extensions.crypt(p_password, v_account.password_hash) <> v_account.password_hash
    THEN
        UPDATE account
        SET failed_logins = failed_logins + 1, last_failed_login = now()
        WHERE id = v_account.id;
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;

    UPDATE account SET failed_logins = 0, last_failed_login = NULL WHERE id = v_account.id;
    DELETE FROM session WHERE account = v_account.id AND last_used <= now() - interval '30 days';

    v_token := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    INSERT INTO session (token_hash, tenant, account)
    VALUES (util.token_hash(v_token), v_account.tenant, v_account.id);

    RETURN jsonb_build_object(
        'ok',      true,
        'token',   v_token,
        'account', util.account_json(v_account.id)
    );
END;
$$;

-- Ends the current session.
CREATE FUNCTION logout() RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require_login();
    DELETE FROM session WHERE token_hash = util.token_hash(current_setting('wtf.token'));
END;
$$;

-- The logged-in account.
CREATE FUNCTION me() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_session record;
BEGIN
    SELECT * INTO v_session FROM util.current_session();
    RETURN util.account_json(v_session.account);
END;
$$;

-- Changes the logged-in account's password, and ends its other sessions.
CREATE FUNCTION password_change(p_current text, p_new text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_account uuid := (SELECT account FROM util.current_session());
    v_hash    text := (SELECT password_hash FROM account WHERE id = v_account);
BEGIN
    IF v_hash IS NULL OR p_current IS NULL OR extensions.crypt(p_current, v_hash) <> v_hash THEN
        PERFORM util.raise_invalid('The current password is wrong');
    END IF;

    UPDATE account SET password_hash = util.password_hash(p_new) WHERE id = v_account;
    DELETE FROM session
    WHERE account = v_account
      AND token_hash <> util.token_hash(current_setting('wtf.token'));
END;
$$;

-- ---------------------------------------------------------------------------
-- account
-- ---------------------------------------------------------------------------

-- The accounts, by email.
CREATE FUNCTION account_list() RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('account', 'read');
    RETURN (
        SELECT COALESCE(jsonb_agg(util.account_json(a.id) ORDER BY lower(a.email), a.id), '[]'::jsonb)
        FROM account a
        WHERE a.tenant = util.tenant()
          AND NOT a.deleted
    );
END;
$$;

-- Deleted accounts can still be fetched (with deleted: true), because
-- history entries refer to them.
CREATE FUNCTION account_get(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('account', 'read');
    IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_id AND tenant = util.tenant()) THEN
        PERFORM util.raise_not_found('account', p_id);
    END IF;
    RETURN util.account_json(p_id);
END;
$$;

-- Raises unless p_email looks like an email address.
CREATE FUNCTION util.check_email(p_email text) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_email IS NULL OR btrim(p_email) !~ '^[^@\s]+@[^@\s]+$' THEN
        PERFORM util.raise_invalid(format('%L is not an email address', p_email));
    END IF;
END;
$$;

-- Creates an account. p_password NULL creates it without a password: it
-- can't log in until one is set.
CREATE FUNCTION account_create(
    p_email             text,
    p_password          text      DEFAULT NULL,
    p_data_privilege    privilege DEFAULT 'none',
    p_model_privilege   privilege DEFAULT 'none',
    p_account_privilege privilege DEFAULT 'none',
    p_history_privilege privilege DEFAULT 'none'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     uuid;
BEGIN
    PERFORM util.require('account', 'write');
    PERFORM util.check_email(p_email);
    INSERT INTO account (tenant, email, password_hash,
                         data_privilege, model_privilege, account_privilege, history_privilege)
    VALUES (util.tenant(), btrim(p_email), util.password_hash(p_password),
            p_data_privilege, p_model_privilege, p_account_privilege, p_history_privilege)
    RETURNING id INTO v_id;

    RETURN util.account_json(v_id);
END;
$$;

-- Changes the fields present in p_patch: email, password (null removes it:
-- the account can't log in), data_privilege, model_privilege,
-- account_privilege, history_privilege. Changing the password ends the
-- account's sessions (except the caller's own). You can't remove your own
-- account privilege. Deleted accounts can't be changed.
CREATE FUNCTION account_patch(p_id uuid, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_self   uuid := (SELECT account FROM util.current_session());
BEGIN
    PERFORM util.require('account', 'write');
    PERFORM util.check_patch(p_patch,
        ARRAY['email', 'password', 'data_privilege', 'model_privilege', 'account_privilege', 'history_privilege'],
        ARRAY['email', 'data_privilege', 'model_privilege', 'account_privilege', 'history_privilege']);

    IF NOT EXISTS (SELECT 1 FROM account WHERE id = p_id AND tenant = util.tenant() AND NOT deleted) THEN
        PERFORM util.raise_not_found('account', p_id);
    END IF;
    IF p_id = v_self AND p_patch ? 'account_privilege'
       AND (p_patch ->> 'account_privilege')::privilege <> 'read_write'
    THEN
        RAISE EXCEPTION 'You can''t remove your own account privilege'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_patch ? 'email' THEN
        PERFORM util.check_email(p_patch ->> 'email');
    END IF;

    UPDATE account
    SET email             = CASE WHEN p_patch ? 'email'
                                 THEN btrim(p_patch ->> 'email') ELSE email END,
        password_hash     = CASE WHEN p_patch ? 'password'
                                 THEN util.password_hash(p_patch ->> 'password') ELSE password_hash END,
        data_privilege    = CASE WHEN p_patch ? 'data_privilege'
                                 THEN (p_patch ->> 'data_privilege')::privilege ELSE data_privilege END,
        model_privilege   = CASE WHEN p_patch ? 'model_privilege'
                                 THEN (p_patch ->> 'model_privilege')::privilege ELSE model_privilege END,
        account_privilege = CASE WHEN p_patch ? 'account_privilege'
                                 THEN (p_patch ->> 'account_privilege')::privilege ELSE account_privilege END,
        history_privilege = CASE WHEN p_patch ? 'history_privilege'
                                 THEN (p_patch ->> 'history_privilege')::privilege ELSE history_privilege END
    WHERE id = p_id;

    IF p_patch ? 'password' THEN
        DELETE FROM session
        WHERE account = p_id
          AND token_hash <> util.token_hash(current_setting('wtf.token'));
    END IF;
    RETURN util.account_json(p_id);
END;
$$;

-- Deletes an account: it is marked deleted (history keeps referring to it),
-- loses its password and privileges, and its sessions end. Its email can be
-- used for a new account. You can't delete your own account.
CREATE FUNCTION account_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM util.require('account', 'write');
    IF p_id = (SELECT account FROM util.current_session()) THEN
        RAISE EXCEPTION 'You can''t delete your own account'
            USING ERRCODE = 'check_violation';
    END IF;
    UPDATE account
    SET deleted           = true,
        password_hash     = NULL,
        data_privilege    = 'none',
        model_privilege   = 'none',
        account_privilege = 'none',
        history_privilege = 'none'
    WHERE id = p_id
      AND tenant = util.tenant()
      AND NOT deleted;

    IF NOT FOUND THEN
        PERFORM util.raise_not_found('account', p_id);
    END IF;
    DELETE FROM session WHERE account = p_id;
END;
$$;
