-- The tables, with their types, constraints and indexes. Explained in
-- SCHEMA.md and, for tenants, TENANTS.md.
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

-- What an attribute's values are. Numbers (integer and decimal) are stored in
-- the number column, url in text.
CREATE TYPE public.datatype AS ENUM (
    'text', 'integer', 'decimal', 'date', 'boolean', 'url', 'choice'
);

-- Where an attribute's values live: on the item, or on each stock row.
CREATE TYPE public.scope AS ENUM ('item', 'stock');

-- What an account may do. Each role can do what the ones before it can, so
-- the order of the values matters: a new role is added in its place.
CREATE TYPE public.role AS ENUM ('viewer', 'user', 'admin');

-- Where a session has been used from, and when last.
CREATE TYPE public.session_usage AS (address inet, seen timestamptz);

-- Who is calling, as wtfd saw the request: its session token (NULL when it
-- has none), the first label of its hostname, and the address it came from
-- (NULL when wtfd can't tell). The first argument of every function the API
-- calls.
CREATE TYPE public.request AS (token text, host text, address inet);

-- The kinds of object an attachment can belong to.
CREATE TYPE public.owner_kind AS ENUM ('item', 'stock', 'location', 'class');

-- Sorts text as people expect: numbers by their value ("Item 2" before
-- "Item 10"), and letter case only where the text is otherwise the same.
CREATE COLLATION public.natural (provider = icu, locale = 'und-u-kn-true');

-- ---------------------------------------------------------------------------
-- Tenants (see TENANTS.md)
-- ---------------------------------------------------------------------------

-- An independent inventory. The first label of a request's hostname picks
-- it: "bob" for bob.wtf.example. The label starts with a letter, so an IP
-- address never picks a tenant.
CREATE TABLE public.tenant (
    id   uuid   NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    host text   NOT NULL CHECK (host ~ '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'),
    -- The last label code handed out to the tenant's items, locations and
    -- stock rows (tenant.take_codes). Every code from the first up to it
    -- was given to one of them, so a code up to it that nothing has belonged
    -- to something deleted (code.resolve). The first is 32768 = 32^3, the
    -- smallest number whose Crockford Base32 rendering has four characters
    -- ("1000"); codes grow to five characters after "ZZZZ" (1048575).
    code bigint NOT NULL DEFAULT 32767 CHECK (code >= 32767)
);

CREATE UNIQUE INDEX tenant_host_unique ON public.tenant (host);

-- ---------------------------------------------------------------------------
-- Accounts and sessions (see ACCOUNTS.md)
-- ---------------------------------------------------------------------------

-- A user of one tenant. The email address is the user name.
CREATE TABLE public.account (
    id                uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant            uuid             NOT NULL REFERENCES public.tenant (id) ON DELETE RESTRICT,
    email             public.name_text NOT NULL,
    -- bcrypt hash (pgcrypto); NULL = the account can't log in.
    password_hash     text             NULL,
    role              public.role      NOT NULL DEFAULT 'viewer',
    -- Lockout after repeated failed logins (see ACCOUNTS.md).
    failed_logins     integer          NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    last_failed_login timestamptz      NULL
);

-- Email addresses are unique within a tenant, letter case ignored.
CREATE UNIQUE INDEX account_tenant_email_unique
    ON public.account (tenant, lower(email));

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
-- Quantities, unit families and units (see seed/units.md and TENANTS.md)
-- ---------------------------------------------------------------------------
-- tenant NULL = global: every tenant sees it. Otherwise only the tenant that
-- owns it does. A unit family owned by a tenant may be in a global quantity,
-- and a unit owned by a tenant in a global family, but nothing global is in
-- anything owned by a tenant.

-- A physical quantity: Length, Weight, Count. Numbers of a quantity are
-- stored in its base unit.
CREATE TABLE public.quantity (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant    uuid             NULL     REFERENCES public.tenant (id) ON DELETE RESTRICT,
    name      public.name_text NOT NULL,
    -- Whether its numbers are whole (Count) or not.
    datatype  public.datatype  NOT NULL CHECK (datatype IN ('integer', 'decimal')),
    -- Numbers of this quantity are stored in this unit, whose factor is 1
    -- and offset 0. The unit's family refers back to this quantity, so the
    -- foreign key is added after the unit table, and checked at commit.
    base_unit uuid             NOT NULL,
    -- Global ones only: whether a tenant has it without having chosen.
    standard  boolean          NULL,
    CHECK ((tenant IS NULL) = (standard IS NOT NULL))
);

-- Unique among the global ones, and within each tenant. That a tenant's own
-- name differs from the global ones is a rule (unit.check_quantity).
CREATE UNIQUE INDEX quantity_tenant_name_unique
    ON public.quantity (tenant, lower(name)) NULLS NOT DISTINCT;

-- A set of units of one quantity that are used together (Metric length:
-- nm … km); numbers are scaled between them when shown.
CREATE TABLE public.unit_family (
    id       uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant   uuid             NULL     REFERENCES public.tenant (id) ON DELETE RESTRICT,
    quantity uuid             NOT NULL REFERENCES public.quantity (id) ON DELETE RESTRICT,
    name     public.name_text NOT NULL,
    -- Global ones only: whether a tenant has it without having chosen.
    standard boolean          NULL,
    CHECK ((tenant IS NULL) = (standard IS NOT NULL))
);

CREATE UNIQUE INDEX unit_family_tenant_name_unique
    ON public.unit_family (tenant, lower(name)) NULLS NOT DISTINCT;
CREATE INDEX unit_family_quantity_idx ON public.unit_family (quantity);

-- A unit of measure in one family. base = value × base_factor + base_offset
-- converts a number in this unit to its quantity's base unit; the offset is
-- only non-zero for temperature scales (°C, °F).
CREATE TABLE public.unit (
    id          uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant      uuid             NULL     REFERENCES public.tenant (id) ON DELETE RESTRICT,
    family      uuid             NOT NULL REFERENCES public.unit_family (id) ON DELETE RESTRICT,
    name        public.name_text NOT NULL,
    symbol      public.name_text NOT NULL,
    base_factor numeric          NOT NULL CHECK (base_factor > 0),
    base_offset numeric          NOT NULL DEFAULT 0
);

-- Symbols are case-sensitive (mS millisiemens, ms millisecond), names not.
-- Starting with family, these also find a family's units. (The name index
-- says "lower" in its name, as unit_family_tenant_name_unique is the unit
-- families' own.)
CREATE UNIQUE INDEX unit_family_tenant_symbol_unique
    ON public.unit (family, tenant, symbol) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX unit_family_tenant_lower_name_unique
    ON public.unit (family, tenant, lower(name)) NULLS NOT DISTINCT;

-- quantity was created before unit, which it refers to. Checked at commit,
-- so a quantity, its family and its base unit can be inserted in one
-- transaction, in any order.
ALTER TABLE public.quantity
    ADD FOREIGN KEY (base_unit) REFERENCES public.unit (id) DEFERRABLE INITIALLY DEFERRED;

-- A tenant's choices of which quantities and families it uses, kept only
-- where they differ from the default (see TENANTS.md).
CREATE TABLE public.tenant_quantity (
    tenant    uuid    NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
    quantity  uuid    NOT NULL REFERENCES public.quantity (id) ON DELETE CASCADE,
    available boolean NOT NULL,
    PRIMARY KEY (tenant, quantity)
);

CREATE TABLE public.tenant_unit_family (
    tenant    uuid    NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
    family    uuid    NOT NULL REFERENCES public.unit_family (id) ON DELETE CASCADE,
    available boolean NOT NULL,
    PRIMARY KEY (tenant, family)
);

-- ---------------------------------------------------------------------------
-- The model: classes and attributes
-- ---------------------------------------------------------------------------
-- Deleting removes a row (see api/deleting.md). What belongs to it alone goes
-- with it (ON DELETE CASCADE); what others still use can't be deleted
-- (RESTRICT), and the delete functions say what is in the way first.

-- A category in a tree (Tools → Power tools → Drills). Attributes are
-- inherited down the tree.
CREATE TABLE public.class (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant    uuid             NOT NULL REFERENCES public.tenant (id) ON DELETE RESTRICT,
    parent    uuid             NULL     REFERENCES public.class (id) ON DELETE RESTRICT,
    name      public.path_name NOT NULL,
    -- A container holds only other classes, no items.
    container boolean          NOT NULL DEFAULT false,
    -- One of its own image attachments (the foreign key is added after the
    -- attachment table).
    photo     uuid             NULL,
    CHECK (parent <> id)
);

-- Names are unique, letter case ignored, among siblings; top-level classes
-- (parent NULL) among the tenant's top-level classes.
CREATE UNIQUE INDEX class_tenant_parent_name_unique
    ON public.class (tenant, parent, lower(name)) NULLS NOT DISTINCT;
CREATE INDEX class_parent_idx ON public.class (parent);
CREATE INDEX class_photo_idx  ON public.class (photo);

-- A reusable property of the tenant's ("Weight", "Voltage"), assigned to
-- classes in class_attribute. Its datatype never changes.
CREATE TABLE public.attribute (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant    uuid             NOT NULL REFERENCES public.tenant (id) ON DELETE RESTRICT,
    name      public.name_text NOT NULL,
    datatype  public.datatype  NOT NULL,
    -- Numbers of this attribute are stored in the base unit of the unit's
    -- quantity. They're entered in this unit by default, and shown in it
    -- with unit_lock; otherwise scaled between the units of its family.
    unit      uuid             NULL     REFERENCES public.unit (id) ON DELETE RESTRICT,
    unit_lock boolean          NOT NULL DEFAULT false,
    CHECK (unit IS NOT NULL OR NOT unit_lock)
);

CREATE UNIQUE INDEX attribute_tenant_name_unique
    ON public.attribute (tenant, lower(name));
CREATE INDEX attribute_unit_idx ON public.attribute (unit);

-- An allowed value of a choice attribute ("0805", "0603", "THT").
CREATE TABLE public.attribute_option (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    attribute uuid             NOT NULL REFERENCES public.attribute (id) ON DELETE CASCADE,
    name      public.name_text NOT NULL,
    -- Target of the (attribute, option) foreign keys from values and
    -- defaults, which keep an option within its own attribute. It also
    -- finds an attribute's options.
    CONSTRAINT attribute_option_attribute_id_unique UNIQUE (attribute, id)
);

CREATE UNIQUE INDEX attribute_option_attribute_name_unique
    ON public.attribute_option (attribute, lower(name));

-- Assigns an attribute to a class, and so to all the classes below it; the
-- assignment nearest to a class in its path decides.
CREATE TABLE public.class_attribute (
    class           uuid         NOT NULL REFERENCES public.class (id) ON DELETE CASCADE,
    attribute       uuid         NOT NULL REFERENCES public.attribute (id) ON DELETE RESTRICT,
    -- Where the values live: on the item, or on each stock row.
    scope           public.scope NOT NULL DEFAULT 'item',
    -- New items (or stock rows) need a value, unless there's a default.
    required        boolean      NOT NULL DEFAULT false,
    -- The default value: at most one is set, matching the attribute's
    -- datatype (a rule, class.check_default).
    default_text    text         NULL,
    default_number  numeric      NULL,
    default_date    date         NULL,
    default_boolean boolean      NULL,
    default_option  uuid         NULL,

    PRIMARY KEY (class, attribute),
    FOREIGN KEY (attribute, default_option)
        REFERENCES public.attribute_option (attribute, id) ON DELETE RESTRICT,
    CHECK (num_nonnulls(default_text, default_number, default_date,
                        default_boolean, default_option) <= 1)
);

CREATE INDEX class_attribute_attribute_idx ON public.class_attribute (attribute);

-- ---------------------------------------------------------------------------
-- The data: items, locations and stock
-- ---------------------------------------------------------------------------

-- A kind of thing ("M3x10 hex screw", "Makita DHP482 drill"), in one class.
-- Its physical things are its stock rows.
CREATE TABLE public.item (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- The label code, from tenant.take_codes: unique within the tenant, as
    -- only that function hands out codes.
    code      bigint           NOT NULL,
    class     uuid             NOT NULL REFERENCES public.class (id) ON DELETE RESTRICT,
    name      public.name_text NOT NULL,
    -- Stock amounts are stored in the base unit of this unit's quantity,
    -- and entered and shown as for an attribute's unit. NULL = counted.
    unit      uuid             NULL     REFERENCES public.unit (id) ON DELETE RESTRICT,
    unit_lock boolean          NOT NULL DEFAULT false,
    photo     uuid             NULL,
    CHECK (unit IS NOT NULL OR NOT unit_lock)
);

CREATE INDEX item_code_idx  ON public.item (code);
CREATE INDEX item_class_idx ON public.item (class);
CREATE INDEX item_unit_idx  ON public.item (unit);
CREATE INDEX item_photo_idx ON public.item (photo);

-- The value of one item attribute for one item. No row = no value.
CREATE TABLE public.item_value (
    item      uuid    NOT NULL REFERENCES public.item (id) ON DELETE CASCADE,
    attribute uuid    NOT NULL REFERENCES public.attribute (id) ON DELETE RESTRICT,
    -- Exactly one is set, the one matching the attribute's datatype (a
    -- rule); numbers with a unit are in the base unit, url is in text.
    text      text    NULL,
    number    numeric NULL,
    date      date    NULL,
    boolean   boolean NULL,
    option    uuid    NULL,

    PRIMARY KEY (item, attribute),
    FOREIGN KEY (attribute, option)
        REFERENCES public.attribute_option (attribute, id) ON DELETE RESTRICT,
    CHECK (num_nonnulls(text, number, date, boolean, option) = 1)
);

CREATE INDEX item_value_attribute_idx ON public.item_value (attribute);
CREATE INDEX item_value_option_idx    ON public.item_value (option) WHERE option IS NOT NULL;

-- A place in a tree (House → Garage → Shelf 2 → Bin 4).
CREATE TABLE public.location (
    id        uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    tenant    uuid             NOT NULL REFERENCES public.tenant (id) ON DELETE RESTRICT,
    -- The label code, from tenant.take_codes.
    code      bigint           NOT NULL,
    parent    uuid             NULL     REFERENCES public.location (id) ON DELETE RESTRICT,
    name      public.path_name NOT NULL,
    -- A container holds only other locations, no stock.
    container boolean          NOT NULL DEFAULT false,
    photo     uuid             NULL,
    CHECK (parent <> id)
);

CREATE UNIQUE INDEX location_tenant_code_unique ON public.location (tenant, code);
CREATE UNIQUE INDEX location_tenant_parent_name_unique
    ON public.location (tenant, parent, lower(name)) NULLS NOT DISTINCT;
CREATE INDEX location_parent_idx ON public.location (parent);
CREATE INDEX location_photo_idx  ON public.location (photo);

-- The physical things: one row per physical thing or batch of things. The
-- same item may have several rows at one location (two identical drills).
CREATE TABLE public.stock (
    id          uuid    NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    -- The label code, from tenant.take_codes: unique within the tenant, as
    -- only that function hands out codes.
    code        bigint  NOT NULL,
    item        uuid    NOT NULL REFERENCES public.item (id) ON DELETE RESTRICT,
    location    uuid    NOT NULL REFERENCES public.location (id) ON DELETE RESTRICT,
    -- In the base unit of the item's unit (counted if none).
    -- NULL = present, but not counted ("some cable ties");
    -- 0    = none left, but this is where they belong.
    amount      numeric NULL     CHECK (amount >= 0),
    photo       uuid    NULL
);

CREATE INDEX stock_code_idx     ON public.stock (code);
CREATE INDEX stock_item_idx     ON public.stock (item);
CREATE INDEX stock_location_idx ON public.stock (location);
CREATE INDEX stock_photo_idx    ON public.stock (photo);

-- The value of one stock attribute for one stock row (serial number,
-- purchase date, …). The same rules as item_value.
CREATE TABLE public.stock_value (
    stock     uuid    NOT NULL REFERENCES public.stock (id) ON DELETE CASCADE,
    attribute uuid    NOT NULL REFERENCES public.attribute (id) ON DELETE RESTRICT,
    text      text    NULL,
    number    numeric NULL,
    date      date    NULL,
    boolean   boolean NULL,
    option    uuid    NULL,

    PRIMARY KEY (stock, attribute),
    FOREIGN KEY (attribute, option)
        REFERENCES public.attribute_option (attribute, id) ON DELETE RESTRICT,
    CHECK (num_nonnulls(text, number, date, boolean, option) = 1)
);

CREATE INDEX stock_value_attribute_idx ON public.stock_value (attribute);
CREATE INDEX stock_value_option_idx    ON public.stock_value (option) WHERE option IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Attachments (see api/attachment.md)
-- ---------------------------------------------------------------------------

-- A file attached to an item, a stock row, a location or a class: exactly
-- one of them. The content is in the tenant's directory of wtfd's files
-- directory, named by its hash, so the same content is stored once per
-- tenant however often it's attached.
CREATE TABLE public.attachment (
    id         uuid             NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    item       uuid             NULL     REFERENCES public.item (id) ON DELETE CASCADE,
    stock      uuid             NULL     REFERENCES public.stock (id) ON DELETE CASCADE,
    location   uuid             NULL     REFERENCES public.location (id) ON DELETE CASCADE,
    class      uuid             NULL     REFERENCES public.class (id) ON DELETE CASCADE,
    media_type public.name_text NOT NULL,
    -- SHA-256 of the content, as hex: its file name.
    hash       text             NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$'),
    size       bigint           NOT NULL CHECK (size >= 0),
    title      public.name_text NOT NULL,
    CHECK (num_nonnulls(item, stock, location, class) = 1),

    -- Targets of the owners' photo keys; they also find an owner's
    -- attachments.
    CONSTRAINT attachment_item_id_unique     UNIQUE (item, id),
    CONSTRAINT attachment_stock_id_unique    UNIQUE (stock, id),
    CONSTRAINT attachment_location_id_unique UNIQUE (location, id),
    CONSTRAINT attachment_class_id_unique    UNIQUE (class, id)
);

-- "wtfd gc" looks files up by hash.
CREATE INDEX attachment_hash_idx ON public.attachment (hash);

-- A photo is one of the owner's own attachments; removing that attachment
-- clears it. (That it's an image is a rule.)
ALTER TABLE public.item
    ADD FOREIGN KEY (id, photo) REFERENCES public.attachment (item, id) ON DELETE SET NULL (photo);
ALTER TABLE public.stock
    ADD FOREIGN KEY (id, photo) REFERENCES public.attachment (stock, id) ON DELETE SET NULL (photo);
ALTER TABLE public.location
    ADD FOREIGN KEY (id, photo) REFERENCES public.attachment (location, id) ON DELETE SET NULL (photo);
ALTER TABLE public.class
    ADD FOREIGN KEY (id, photo) REFERENCES public.attachment (class, id) ON DELETE SET NULL (photo);

-- ---------------------------------------------------------------------------
-- Bookkeeping
-- ---------------------------------------------------------------------------

-- One change counter per tenant and kind, so clients can cheaply tell
-- whether their copy of the class tree, the location tree or the units the
-- tenant sees is still current. A tenant's row appears with its first
-- change; until then the version is 1.
CREATE TABLE public.data_version (
    tenant  uuid   NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
    name    text   NOT NULL CHECK (name IN ('class', 'location', 'unit')),
    version bigint NOT NULL DEFAULT 2,
    PRIMARY KEY (tenant, name)
);
