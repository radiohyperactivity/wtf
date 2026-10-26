-- Short codes for labels on locations, items and stock rows. Explained in SCHEMA.md.

-- One sequence for all three tables, so every code is unique across all of
-- them by construction. It starts at 32768 = 32^3, the smallest number whose
-- Crockford Base32 rendering has four characters ("1000"); codes grow to five
-- characters after "ZZZZ" (1048575).
CREATE SEQUENCE code_sequence START WITH 32768;

-- Adding a column with a volatile default gives every existing row its own code.
ALTER TABLE location ADD COLUMN code bigint NOT NULL DEFAULT nextval('code_sequence');
ALTER TABLE item     ADD COLUMN code bigint NOT NULL DEFAULT nextval('code_sequence');
ALTER TABLE stock    ADD COLUMN code bigint NOT NULL DEFAULT nextval('code_sequence');

CREATE UNIQUE INDEX location_code_unique ON location (code);
CREATE UNIQUE INDEX item_code_unique     ON item (code);
CREATE UNIQUE INDEX stock_code_unique    ON stock (code);
