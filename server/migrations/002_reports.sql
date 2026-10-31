-- Crash reports and error logs users send to Goldi (BL-73).
create table if not exists reports (
  id           bigint generated always as identity primary key,
  kind         text not null check (kind in ('crash', 'log')),
  install_id   text not null,
  app_version  text,
  macos        text,
  note         text,
  report       text,
  log          text,
  ip_hash      text not null,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists reports_new on reports (read_at, created_at);
