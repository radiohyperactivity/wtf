-- Roles (ACCOUNTS.md): an account is a viewer, a user or an admin, in place
-- of the four privileges. Each role can do what the ones before it can.

CREATE TYPE role AS ENUM ('viewer', 'user', 'admin');

ALTER TABLE account ADD COLUMN role role NOT NULL DEFAULT 'viewer';

-- Writing the model or the accounts made an admin, writing the data a user.
UPDATE account
SET role = CASE
    WHEN model_privilege = 'read_write' OR account_privilege = 'read_write' THEN 'admin'
    WHEN data_privilege = 'read_write' THEN 'user'
    ELSE 'viewer'
END::role;

ALTER TABLE account
    DROP COLUMN data_privilege,
    DROP COLUMN model_privilege,
    DROP COLUMN account_privilege,
    DROP COLUMN history_privilege;

-- The two functions that use the type in their signatures; the repeatable
-- scripts create the new ones.
DROP FUNCTION IF EXISTS account_create(text, text, privilege, privilege, privilege, privilege);
DROP FUNCTION IF EXISTS util.current_session();
DROP TYPE privilege;
