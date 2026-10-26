-- Attachments: files (photos, datasheets, receipts, …) on items, stock rows,
-- locations and classes. Explained in SCHEMA.md and api/attachment.md.

-- A stored file, identified by its content. The bytes live on disk, in
-- wtfd's files directory, named by the SHA-256 hash; the same content is
-- stored once however often it is attached.
CREATE TABLE file (
    sha256 bytea  NOT NULL PRIMARY KEY CHECK (length(sha256) = 32),
    size   bigint NOT NULL CHECK (size >= 0)
);

-- A file attached to exactly one item, stock row, location or class.
CREATE TABLE attachment (
    id            uuid    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    file          bytea   NOT NULL REFERENCES file (sha256) ON DELETE RESTRICT,
    file_name     text    NOT NULL CHECK (btrim(file_name) <> ''),
    content_type  text    NOT NULL CHECK (btrim(content_type) <> ''),
    caption       text    NULL,
    -- The main picture of its object; at most one per object, and an image.
    primary_photo boolean NOT NULL DEFAULT false,
    item          uuid    NULL     REFERENCES item (id) ON DELETE CASCADE,
    stock         uuid    NULL     REFERENCES stock (id) ON DELETE CASCADE,
    location      uuid    NULL     REFERENCES location (id) ON DELETE CASCADE,
    class         uuid    NULL     REFERENCES class (id) ON DELETE CASCADE,

    CHECK (num_nonnulls(item, stock, location, class) = 1),
    CHECK (NOT primary_photo OR content_type LIKE 'image/%')
);

CREATE INDEX attachment_file_id_idx     ON attachment (file);
CREATE INDEX attachment_item_id_idx     ON attachment (item);
CREATE INDEX attachment_stock_id_idx    ON attachment (stock);
CREATE INDEX attachment_location_id_idx ON attachment (location);
CREATE INDEX attachment_class_id_idx    ON attachment (class);

CREATE UNIQUE INDEX attachment_item_primary_photo_unique     ON attachment (item)     WHERE primary_photo;
CREATE UNIQUE INDEX attachment_stock_primary_photo_unique    ON attachment (stock)    WHERE primary_photo;
CREATE UNIQUE INDEX attachment_location_primary_photo_unique ON attachment (location) WHERE primary_photo;
CREATE UNIQUE INDEX attachment_class_primary_photo_unique    ON attachment (class)    WHERE primary_photo;

-- Key of the advisory lock that serialises uploads and "wtfd gc" per file:
-- the first 8 bytes of the hash.
CREATE FUNCTION file_lock_key(p_sha256 bytea) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN ('x' || encode(substr(p_sha256, 1, 8), 'hex'))::bit(64)::bigint;
END;
$$;
