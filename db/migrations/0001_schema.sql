-- The tables, with their types, constraints and indexes. Explained in
-- SCHEMA.md. One database is one installation of WtF.
--
-- Only what holds data is here. The rules (trigger functions and their
-- triggers) and the functions the API calls are in db/repeatable/, one
-- schema per area (item, class, unit, …), which "wtfd schema" drops and
-- makes again whenever a script changes. Nothing here uses them.

-- ---------------------------------------------------------------------------
-- pgcrypto, in a schema of its own that wtf_api has no access to. It is used
-- for bcrypt, the hashing of passwords, only.
-- ---------------------------------------------------------------------------

CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Domains and types
-- ---------------------------------------------------------------------------

-- Text that must not be blank: names, symbols, titles, and the like.
CREATE DOMAIN public.name_text AS text
    CHECK (btrim(VALUE) <> '');

-- A name that is joined with "/" into paths ("Garage/Shelf 2"), so it can't
-- contain "/": then a path always means one thing.
CREATE DOMAIN public.path_name AS public.name_text
    CHECK (strpos(VALUE, '/') = 0);

-- The SHA-256 of a file's content, as hex: its file name in wtfd's files
-- directory, where the same content is stored once however often it's
-- used.
CREATE DOMAIN public.file_hash AS text
    CHECK (VALUE ~ '^[0-9a-f]{64}$');

-- A JSON object, the shape of every column of attributes or values.
CREATE DOMAIN public.json_object AS jsonb
    CHECK (jsonb_typeof(VALUE) = 'object');

-- The types an attribute can have. Its values are stored in JSON: numbers
-- (integer and decimal) as JSON numbers, a date as "2026-11-02", a choice
-- as its text, an attachment as its file's hash, url and text as strings.
CREATE TYPE public.datatype AS ENUM (
    'text', 'integer', 'decimal', 'date', 'boolean', 'url', 'choice', 'attachment'
);

-- Where an attribute's values live: on the item, or on each stock row.
CREATE TYPE public.scope AS ENUM ('item', 'stock');

-- What an account may do. Each role can do what the ones before it can, so
-- the order of the values matters: a new role is added in its place.
CREATE TYPE public.role AS ENUM ('viewer', 'user', 'admin');

-- Where a session has been used from, and when last.
CREATE TYPE public.session_usage AS (address inet, seen timestamptz);

-- Who is calling, as wtfd saw the request: its session token (NULL when it
-- has none), and the address it came from (NULL when wtfd can't tell). The
-- first argument of every function the API calls.
CREATE TYPE public.request AS (token text, address inet);

-- Sorts text as people expect: numbers by their value ("Item 2" before
-- "Item 10"), and letter case only where the text is otherwise the same.
CREATE COLLATION public.natural (provider = icu, locale = 'und-u-kn-true');

-- ---------------------------------------------------------------------------
-- The installation
-- ---------------------------------------------------------------------------

-- What belongs to the installation as a whole, in one row; columns are
-- added as they are needed.
CREATE TABLE public.meta (
    -- Always true: the primary key, so that there is only ever the one row.
    one              boolean NOT NULL PRIMARY KEY DEFAULT true CHECK (one),
    -- The last label code handed out to an item, location or stock row
    -- (util.take_codes). Every code from the first up to it was given to one
    -- of them, so a code up to it that nothing has belonged to something
    -- deleted (code.resolve). The first is 32768 = 32^3, the smallest number
    -- whose Crockford Base32 rendering has four characters ("1000"); codes
    -- grow to five characters after "ZZZZ" (1048575).
    code             bigint  NOT NULL DEFAULT 32767 CHECK (code >= 32767),
    -- The versions of the class tree and the location tree, which every
    -- change of a tree moves on (util.bump_version), so that a client can
    -- cheaply tell whether its copy is still current.
    class_version    bigint  NOT NULL DEFAULT 1,
    location_version bigint  NOT NULL DEFAULT 1
);

INSERT INTO public.meta DEFAULT VALUES;

-- ---------------------------------------------------------------------------
-- Accounts and sessions (see ACCOUNTS.md)
-- ---------------------------------------------------------------------------

-- A user. The email address is the user name.
CREATE TABLE public.account (
    id                uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- Always in lower case, as the accessors store it.
    email             public.name_text NOT NULL CHECK (email = lower(email)),
    -- bcrypt hash (pgcrypto); NULL = the account can't log in.
    password_hash     text             NULL,
    role              public.role      NOT NULL DEFAULT 'viewer',
    -- Lockout after repeated failed logins (see ACCOUNTS.md).
    failed_logins     integer          NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    last_failed_login timestamptz      NULL
);

-- Email addresses are unique (in lower case, so letter case is ignored).
CREATE UNIQUE INDEX account_email_unique ON public.account (email);

-- A login. Only the SHA-256 hash of the token is stored, so a copy of the
-- table gives no working tokens.
CREATE TABLE public.session (
    token_hash bytea                  NOT NULL PRIMARY KEY CHECK (length(token_hash) = 32),
    account    uuid                   NOT NULL REFERENCES public.account (id) ON DELETE CASCADE,
    -- What the client called itself when logging in ("WtF on Pixel 9").
    client     public.name_text       NULL,
    created    timestamptz            NOT NULL DEFAULT now(),
    -- Written at most once a minute.
    last_used  timestamptz            NOT NULL DEFAULT now(),
    -- How long the session may sit unused before it expires, as the user
    -- chose when logging in; NULL = it never expires, and only logging out
    -- or deleting the account ends it.
    max_idle   interval               NULL CHECK (max_idle > interval '0'),
    -- The last 8 addresses the session was used from, with when each was
    -- last seen.
    usage      public.session_usage[] NOT NULL DEFAULT '{}' CHECK (cardinality(usage) <= 8)
);

CREATE INDEX session_account_idx ON public.session (account);

-- ---------------------------------------------------------------------------
-- The model: classes
-- ---------------------------------------------------------------------------
-- Deleting removes a row (see api/deleting.md). What others still use can't
-- be deleted (RESTRICT), and the delete functions say what is in the way
-- first.
--
-- Nothing here checks one row against another: a value against its
-- attribute, an item against its class. The accessors do, as they are the
-- only way to change a row (see 2026-11-02-attributes-in-json.md).

-- A category in a tree (Tools → Power tools → Drills). Its attributes are
-- inherited down the tree.
CREATE TABLE public.class (
    id         uuid               NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    parent     uuid               NULL     REFERENCES public.class (id) ON DELETE RESTRICT,
    name       public.path_name   NOT NULL,
    -- A container holds only other classes, no items.
    container  boolean            NOT NULL DEFAULT false,
    -- Every attribute the class has, its own and those it inherits, by name:
    -- {"Length": {"class": <the class that defines it>, "scope": "item",
    -- "type": "decimal", "unit": "mm", "required": true, "default": 100,
    -- "order": 1}, …}. A choice also has "choices", an attachment may have
    -- "media". Changing a class rewrites the classes below it.
    attributes public.json_object NOT NULL DEFAULT '{}',
    CHECK (parent <> id)
);

-- Names are unique, letter case ignored, among siblings, and among the
-- top-level classes (parent NULL). Starting with parent, it also finds a
-- class's children, and the top-level classes.
CREATE UNIQUE INDEX class_parent_name_unique
    ON public.class (parent, lower(name)) NULLS NOT DISTINCT;

-- ---------------------------------------------------------------------------
-- The data: items, locations and stock
-- ---------------------------------------------------------------------------

-- A kind of thing ("M3x10 hex screw", "Makita DHP482 drill"), in one class.
-- Its physical things are its stock rows.
CREATE TABLE public.item (
    id        uuid               NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- The label code, from util.take_codes.
    code      bigint             NOT NULL,
    class     uuid               NOT NULL REFERENCES public.class (id) ON DELETE RESTRICT,
    name      public.name_text   NOT NULL,
    -- What its stock amounts are counted in ("m" for cable), only a label;
    -- NULL = pieces.
    unit      public.name_text   NULL,
    -- Its values, by attribute name ({"Length": 100, "Colour": "Green"}).
    -- An attribute with no value is left out.
    values    public.json_object NOT NULL DEFAULT '{}',
    -- The names of the values that follow their class's default, and are
    -- rewritten when it changes.
    defaulted text[]             NOT NULL DEFAULT '{}',
    -- What a search reads: in lower case, its name, the names of the
    -- classes in its path, and its text, url and choice values.
    search    text               NOT NULL DEFAULT '',
    photo     public.file_hash   NULL
);

-- Resolving a label.
CREATE UNIQUE INDEX item_code_unique ON public.item (code);
-- Lists read the items in this order and stop after the page.
CREATE INDEX item_name_idx ON public.item (name COLLATE public.natural);
-- A class's items.
CREATE INDEX item_class_idx ON public.item (class);

-- A place in a tree (House → Garage → Shelf 2 → Bin 4).
CREATE TABLE public.location (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- The label code, from util.take_codes.
    code      bigint           NOT NULL,
    parent    uuid             NULL     REFERENCES public.location (id) ON DELETE RESTRICT,
    name      public.path_name NOT NULL,
    -- A container holds only other locations, no stock.
    container boolean          NOT NULL DEFAULT false,
    CHECK (parent <> id)
);

CREATE UNIQUE INDEX location_code_unique ON public.location (code);
-- As class_parent_name_unique.
CREATE UNIQUE INDEX location_parent_name_unique
    ON public.location (parent, lower(name)) NULLS NOT DISTINCT;

-- The physical things: one row per physical thing or batch of things. The
-- same item may have several rows at one location (two identical drills).
CREATE TABLE public.stock (
    id        uuid               NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- The label code, from util.take_codes.
    code      bigint             NOT NULL,
    item      uuid               NOT NULL REFERENCES public.item (id) ON DELETE RESTRICT,
    location  uuid               NOT NULL REFERENCES public.location (id) ON DELETE RESTRICT,
    -- In the item's unit.
    -- NULL = present, but not counted ("some cable ties");
    -- 0    = none left, but this is where they belong.
    amount    numeric            NULL CHECK (amount >= 0),
    -- An order number, an invoice, …; neither is unique.
    reference public.name_text   NULL,
    serial    public.name_text   NULL,
    -- As item.values and item.defaulted, for the stock attributes.
    values    public.json_object NOT NULL DEFAULT '{}',
    defaulted text[]             NOT NULL DEFAULT '{}',
    photo     public.file_hash   NULL
);

-- Resolving a label.
CREATE UNIQUE INDEX stock_code_unique ON public.stock (code);
CREATE INDEX stock_item_idx     ON public.stock (item);
CREATE INDEX stock_location_idx ON public.stock (location);
