-- Use the actual transition time after acquiring the team lock, rather than
-- the transaction start time of a request that may have waited for that lock.
create or replace function splav.stamp_change() returns trigger language plpgsql set search_path='' as $$
begin
  new.modified_by := auth.uid();
  new.updated_at := now();
  if tg_op='INSERT' then new.created_by := coalesce(new.created_by,auth.uid()); end if;
  if tg_table_name='registrations' then
    if new.status='waiting' then
      if tg_op='INSERT' then
        new.waiting_at := clock_timestamp();
      elsif old.status is distinct from 'waiting' then
        new.waiting_at := clock_timestamp();
      end if;
    end if;
  end if;
  return new;
end;
$$;
