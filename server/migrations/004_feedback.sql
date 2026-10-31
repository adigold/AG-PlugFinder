-- Feedback users send from the app (BL-85). Adi gets it on Telegram and marks it fixed there;
-- the user's app then shows it as fixed.
create table if not exists feedback (
  id           bigint generated always as identity primary key,
  kind         text not null check (kind in ('bug', 'idea', 'question')),
  message      text not null,
  install_id   text not null,
  app_version  text,
  macos        text,
  log          text,
  ip_hash      text not null,
  status       text not null default 'open' check (status in ('open', 'seen', 'fixed', 'closed')),
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists feedback_install on feedback (install_id, created_at);
