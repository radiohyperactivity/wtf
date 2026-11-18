-- A stock row has no reference or serial number of its own any more: where
-- they are wanted, the class gives its stock an attribute for them. What
-- the two columns held is not kept.

ALTER TABLE public.stock
    DROP COLUMN reference,
    DROP COLUMN serial;
