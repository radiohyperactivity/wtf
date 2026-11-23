-- Whether the stock rows at a location may have a photo of their own:
-- false for every location there is, as for a new one at the top. A new
-- location below another starts with its parent's (location.create), and
-- each is changed on its own afterwards.

ALTER TABLE public.location
    ADD COLUMN stock_photos boolean NOT NULL DEFAULT false;
