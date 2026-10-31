-- Categories users chose for a plugin and shared with the community (BL-82). One vote per
-- plugin per Mac; when users agree, everyone can get that category.
create table if not exists category_votes (
  id            bigint generated always as identity primary key,
  plugin_id     text not null,
  name          text not null,
  manufacturer  text not null,
  category      text not null,
  install_id    text not null,
  ip_hash       text not null,
  created_at    timestamptz not null default now(),
  unique (plugin_id, install_id)
);
create index if not exists category_votes_plugin on category_votes (plugin_id);
