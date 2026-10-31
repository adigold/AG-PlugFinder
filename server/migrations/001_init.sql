-- Shared plugin database (BL-71). A plugin is known by the app's id for it
-- ("aufx-Chao-NbsA": Audio Unit type, subtype, maker). Pictures users share
-- wait in submissions until Adi approves one into plugins.
create table if not exists plugins (
  plugin_id     text primary key,
  name          text not null,
  manufacturer  text not null,
  version       text,
  category      text,
  picture       bytea not null,
  picture_type  text not null,
  submission_id bigint,
  approved_at   timestamptz not null default now()
);

create table if not exists submissions (
  id            bigint generated always as identity primary key,
  plugin_id     text not null,
  name          text not null,
  manufacturer  text not null,
  version       text,
  category      text,
  picture       bytea not null,
  picture_type  text not null check (picture_type in ('image/jpeg', 'image/png')),
  install_id    text not null,
  ip_hash       text not null,
  app_version   text,
  status        text not null default 'waiting' check (status in ('waiting', 'approved', 'rejected')),
  created_at    timestamptz not null default now(),
  unique (plugin_id, install_id)
);
create index if not exists submissions_waiting on submissions (status, created_at);
create index if not exists submissions_ip_day on submissions (ip_hash, created_at);
