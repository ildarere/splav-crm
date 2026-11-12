-- Qualify allocation columns independently of PL/pgSQL local variables.
create or replace function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
  p_kind text,p_payload jsonb,p_expected_version bigint default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid(); full_payload jsonb; receipt splav.people_receipts%rowtype;
  g splav.groups%rowtype; original splav.payments%rowtype; item jsonb; ids uuid[]; b uuid; reason text;
  revision bigint; result jsonb; lines jsonb; reversal_id uuid; replacement uuid; total bigint; allocated bigint;
begin
  if p_kind is null or p_kind not in ('set_prices','add_payment','allocate_payment','correct_payment') then
    return splav.people_command_v2(p_operation_id,p_team_id,p_trip_id,p_kind,p_payload,p_expected_version);
  end if;
  if p_operation_id is null or p_trip_id is null or p_team_id is null or p_expected_version is null or p_expected_version<0
    or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Invalid financial command' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,4));
  perform 1 from splav.team_members where team_id=p_team_id and user_id=caller for share;
  if not found then raise exception 'Team access denied' using errcode='42501'; end if;
  perform 1 from splav.teams where id=p_team_id for update;
  select * into g from splav.groups where id=p_trip_id and team_id=p_team_id for update;
  if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
  perform 1 from splav.group_members where group_id=p_trip_id and user_id=caller for key share;
  if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
  full_payload:=jsonb_build_object('team_id',p_team_id,'trip_id',p_trip_id,'kind',p_kind,'payload',p_payload,'expected_version',p_expected_version);
  select * into receipt from splav.people_receipts where operation_id=p_operation_id;
  if found then
    if receipt.user_id<>caller or receipt.payload<>full_payload then raise exception 'Operation ID is bound to another command' using errcode='22023'; end if;
    return receipt.result;
  end if;
  -- A subtransaction rolls back every ledger/allocation change on a business rejection.
  begin
    if p_kind='set_prices' then
      lines:=p_payload->'lines';
      if lines is null or jsonb_typeof(lines)<>'array' or jsonb_array_length(lines) not between 1 and 100 or
        nullif(btrim(p_payload->>'reason'),'') is null or char_length(p_payload->>'reason')>2000 then
        raise exception 'Invalid agreed price fields' using errcode='22023'; end if;
      if (select count(distinct value->>'id') from jsonb_array_elements(lines))<>jsonb_array_length(lines) then
        raise exception 'Duplicate prices' using errcode='22023'; end if;
      for item in select value from jsonb_array_elements(lines) loop
        if not exists(select 1 from splav.registrations where group_id=p_trip_id and id=(item->>'id')::uuid) then
          raise exception 'Participation access denied' using errcode='42501'; end if;
        if jsonb_typeof(item->'amount_kopeks') is distinct from 'number' or (item->>'amount_kopeks')::numeric<0 or
          (item->>'amount_kopeks')::numeric>1000000000000 or (item->>'amount_kopeks')::numeric<>trunc((item->>'amount_kopeks')::numeric) then
          raise exception 'Invalid price' using errcode='22023'; end if;
        if not exists(select 1 from splav.registrations where group_id=p_trip_id and id=(item->>'id')::uuid and version=(item->>'version')::bigint) then
          raise exception 'version_conflict' using errcode='P0001'; end if;
      end loop;
      for item in select value from jsonb_array_elements(lines) loop
        insert into splav.price_history(group_id,registration_id,old_kopeks,new_kopeks,reason,author_id)
          select group_id,id,agreed_price_kopeks,(item->>'amount_kopeks')::bigint,p_payload->>'reason',caller
          from splav.registrations where group_id=p_trip_id and id=(item->>'id')::uuid;
        update splav.registrations set agreed_price_kopeks=(item->>'amount_kopeks')::bigint,version=version+1
          where group_id=p_trip_id and id=(item->>'id')::uuid;
      end loop;
    else
      b:=(p_payload->>'booking_id')::uuid;
      if b is null or not exists(select 1 from splav.bookings where id=b and group_id=p_trip_id) then
        raise exception 'Booking access denied' using errcode='42501'; end if;
      if p_kind='add_payment' then
        perform splav.insert_payment(p_payload,p_team_id,p_trip_id,b,'');
      else
        select * into original from splav.payments where id=(p_payload->>'id')::uuid and group_id=p_trip_id and booking_id=b for update;
        if not found then raise exception 'Payment access denied' using errcode='42501'; end if;
        if original.version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
        if original.direction='reversal' or exists(select 1 from splav.payments where reverses=original.id) then
          raise exception 'payment_reversed' using errcode='P0001'; end if;
        if nullif(btrim(p_payload->>'reason'),'') is null or char_length(p_payload->>'reason')>2000 then
          raise exception 'Reason required' using errcode='22023'; end if;
        if p_kind='allocate_payment' then
          lines:=p_payload->'allocations';
          perform splav.check_allocations(b,abs(original.signed_kopeks),lines);
          insert into splav.payment_allocations(payment_id,version,lines,reason,author_id)
            values(original.id,original.version+1,lines,p_payload->>'reason',caller);
          update splav.payments set version=version+1 where id=original.id;
        else
          reversal_id:=(p_payload->>'reversal_id')::uuid;
          select a.lines into lines from splav.payment_allocations a where a.payment_id=original.id order by a.version desc limit 1;
          insert into splav.payments(id,team_id,group_id,booking_id,signed_kopeks,direction,occurred_at,method,reason,reverses,author_id)
            values(reversal_id,p_team_id,p_trip_id,b,-original.signed_kopeks,'reversal',now(),original.method,p_payload->>'reason',original.id,caller);
          insert into splav.payment_allocations(payment_id,version,lines,reason,author_id) values(reversal_id,1,lines,p_payload->>'reason',caller);
          update splav.payments set version=version+1 where id=original.id;
          if p_payload->'replacement' is not null and jsonb_typeof(p_payload->'replacement')<>'null' then
            replacement:=splav.insert_payment(p_payload->'replacement',p_team_id,p_trip_id,b,p_payload->>'reason',original.id);
          end if;
        end if;
      end if;
      select coalesce(sum(signed_kopeks),0) into total from splav.payments where booking_id=b;
      if total<0 then raise exception 'refund_exceeds_received' using errcode='P0001'; end if;
      select coalesce(sum(sign(p.signed_kopeks)*(e.value->>'amount_kopeks')::bigint),0) into allocated
        from splav.payments p join lateral(select pa.lines from splav.payment_allocations pa where pa.payment_id=p.id order by pa.version desc limit 1) a on true,
          lateral jsonb_array_elements(a.lines) e where p.booking_id=b;
      if allocated>total then raise exception 'refund_allocation_required' using errcode='P0001'; end if;
      if exists(select e.value->>'participation_id' from splav.payments p
        join lateral(select pa.lines from splav.payment_allocations pa where pa.payment_id=p.id order by pa.version desc limit 1) a on true,
        lateral jsonb_array_elements(a.lines) e where p.booking_id=b group by e.value->>'participation_id'
        having sum(sign(p.signed_kopeks)*(e.value->>'amount_kopeks')::bigint)<0) then
        raise exception 'refund_exceeds_allocation' using errcode='P0001'; end if;
    end if;
  exception when sqlstate 'P0001' then reason:=sqlerrm;
  end;
  if reason is null then
    update splav.teams set people_revision=people_revision+1 where id=p_team_id returning people_revision into revision;
    update splav.groups set roster_revision=roster_revision+1 where id=p_trip_id;
    result:=jsonb_build_object('status','accepted','revision',revision);
  else result:=jsonb_build_object('status','rejected','reason',reason); end if;
  insert into splav.people_receipts(operation_id,user_id,team_id,group_id,payload,result)
    values(p_operation_id,caller,p_team_id,p_trip_id,full_payload,result);
  return result;
end;
$$;
