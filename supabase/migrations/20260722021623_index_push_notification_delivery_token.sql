-- Cover the delivery table foreign key used for token cleanup and joins.
create index if not exists push_notification_deliveries_push_token_id_idx
  on public.push_notification_deliveries (push_token_id);
