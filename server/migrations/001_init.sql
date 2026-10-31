-- Shared plugin database (BL-71). A plugin is known by its Audio Unit code
-- (type, subtype, manufacturer) and version. Pictures shared by users wait
-- in submissions until Adi approves them.
create table if not exists plugins (
  id            bigint generated always as identity primary key,
  au_type       text not null,
  au_subtype    text not null,
  au_maker      text not null,
  name          text not null,
  manufacturer  text not null,
  version       text,
  category      text,
  picture       bytea,
  picture_type  text,
  approved_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (au_type, au_subtype, au_maker)
);

create table if not exists submissions (
  id            bigint generated always as identity primary key,
  au_type       text not null,
  au_subtype    text not null,
  au_maker      text not null,
  name          text not null,
  manufacturer  text not null,
  version       text,
  picture       bytea not null,
  picture_type  text not null check (picture_type in ('image/jpeg', 'image/png')),
  status        text not null default 'waiting' check (status in ('waiting', 'approved', 'rejected')),
  created_at    timestamptz not null default now()
);
create index if not exists submissions_waiting on submissions (status, created_at);
