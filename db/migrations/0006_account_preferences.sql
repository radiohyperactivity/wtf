-- An account's preferences: only those the user changed, by name. The
-- others have their defaults, which live in one place,
-- account.preference_defaults, so a new preference needs no migration, and
-- every account has its default until it is changed.

ALTER TABLE public.account
    ADD COLUMN preferences jsonb NOT NULL DEFAULT '{}'
        CHECK (jsonb_typeof(preferences) = 'object');
