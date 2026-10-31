-- A screenshot the user attached to feedback (BL-85).
alter table feedback add column if not exists picture bytea;
alter table feedback add column if not exists picture_type text;
