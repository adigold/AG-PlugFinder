-- Optional name and email on feedback, so Adi knows who wrote it (BL-85).
alter table feedback add column if not exists name text;
alter table feedback add column if not exists email text;
