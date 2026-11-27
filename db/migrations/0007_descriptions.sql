-- A description of a class, item, location or stock row: text of any
-- length and any number of lines, NULL for none (never empty or blank;
-- util.description). An item's is in its search text (item.search), which
-- needs no rewriting here, as no item has one yet.

ALTER TABLE public.class    ADD COLUMN description public.name_text NULL;
ALTER TABLE public.item     ADD COLUMN description public.name_text NULL;
ALTER TABLE public.location ADD COLUMN description public.name_text NULL;
ALTER TABLE public.stock    ADD COLUMN description public.name_text NULL;
