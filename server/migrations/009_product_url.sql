-- Each plugin's page on its maker's own site and its exact kind (Limiter, Compressor …), found
-- with a search of the maker's site and checked before being stored (BL-119, BL-120).
alter table plugins add column if not exists product_url text;
alter table plugins add column if not exists kind text;
