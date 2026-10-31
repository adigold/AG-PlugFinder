-- "In progress" from the Telegram buttons (BL-85).
alter table feedback drop constraint if exists feedback_status_check;
alter table feedback add constraint feedback_status_check check (status in ('open', 'seen', 'progress', 'fixed', 'closed'));
