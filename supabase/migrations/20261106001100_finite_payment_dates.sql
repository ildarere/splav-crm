-- Reject non-calendar dates before they enter the client snapshot.
create or replace function splav.insert_payment(p_data jsonb,p_team uuid,p_trip uuid,p_booking uuid,p_reason text,p_correction uuid default null)
returns uuid language plpgsql set search_path='' as $$
declare amount numeric; sign integer; payment_id uuid; lines jsonb;
begin
  amount:=(p_data->>'amount_kopeks')::numeric;
  if jsonb_typeof(p_data->'amount_kopeks') is distinct from 'number' or amount is null or amount<>trunc(amount) or amount<=0 or amount>1000000000000 or
    p_data->>'direction' is null or p_data->>'direction' not in ('income','refund') or
    p_data->>'method' is null or p_data->>'method' not in ('cash','transfer','card','other') or
    nullif(p_data->>'occurred_at','') is null or not isfinite((p_data->>'occurred_at')::timestamptz) or char_length(coalesce(p_data->>'notes',''))>2000 then
    raise exception 'Invalid payment fields' using errcode='22023'; end if;
  payment_id:=(p_data->>'id')::uuid;
  if payment_id is null or exists(select 1 from splav.payments where id=payment_id) then
    raise exception 'Payment ID already used or missing' using errcode='22023'; end if;
  lines:=coalesce(p_data->'allocations','[]'::jsonb);
  perform splav.check_allocations(p_booking,amount::bigint,lines);
  sign:=case when p_data->>'direction'='income' then 1 else -1 end;
  insert into splav.payments(id,team_id,group_id,booking_id,signed_kopeks,direction,occurred_at,method,notes,reason,correction_of,author_id)
    values(payment_id,p_team,p_trip,p_booking,sign*amount::bigint,p_data->>'direction',(p_data->>'occurred_at')::timestamptz,
      p_data->>'method',coalesce(p_data->>'notes',''),p_reason,p_correction,auth.uid());
  insert into splav.payment_allocations(payment_id,version,lines,reason,author_id) values(payment_id,1,lines,p_reason,auth.uid());
  return payment_id;
end;
$$;

