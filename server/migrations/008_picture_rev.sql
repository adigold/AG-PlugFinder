-- A picture replaced by hand counts up, so every app downloads the new one (Adi, 2026-10-31).
alter table plugins add column if not exists picture_rev int not null default 0;
