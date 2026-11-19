-- A location has a photo, as an item and a stock row have: its file's hash,
-- or null. A stock row without a photo of its own shows its location's in
-- lists.

ALTER TABLE public.location
    ADD COLUMN photo public.file_hash NULL;
