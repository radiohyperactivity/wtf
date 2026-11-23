-- How the stock of a class's items is counted is the class's, not each
-- item's (2026-11-22-stock-rules-on-classes.md): not counted, counted with
-- the amount optional, or counted with it required; and the unit amounts
-- are in (a label; NULL for pieces, whose amounts are whole). A class has a
-- rule of its own or inherits its parent's, and is stored with it resolved,
-- as its attributes are; a top-level class without one of its own counts,
-- optionally, in pieces, which is what every item did until now.
--
-- Every item was counted in pieces when this was made, so there is nothing
-- to carry over: an item with a unit stops the migration, to be sorted out
-- by hand.

CREATE TYPE public.counting AS ENUM ('none', 'optional', 'required');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.item WHERE unit IS NOT NULL) THEN
        RAISE EXCEPTION '% item(s) have a unit of their own; units are now the class''s',
                        (SELECT count(*) FROM public.item WHERE unit IS NOT NULL)
            USING HINT = 'Set those items'' unit to null (pieces) first, or move them to classes '
                         'and give the classes their unit after the update.';
    END IF;
END;
$$;

ALTER TABLE public.class
    -- How its items' stock is counted.
    ADD COLUMN counting   public.counting  NOT NULL DEFAULT 'optional',
    -- What their amounts are counted in, a label; NULL = pieces. None when
    -- nothing is counted.
    ADD COLUMN unit       public.name_text NULL,
    -- The class whose rule this is: itself when its own, an ancestor when
    -- inherited, NULL for the default (counted, optional, in pieces).
    ADD COLUMN stock_from uuid             NULL REFERENCES public.class (id),
    ADD CHECK (counting <> 'none' OR unit IS NULL);

ALTER TABLE public.item
    DROP COLUMN unit;
