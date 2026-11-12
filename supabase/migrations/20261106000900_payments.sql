-- Add an immutable cash ledger and versioned allocation history. Existing IDs and queues survive.
alter table splav.bookings add constraint booking_trip_identity unique(group_id,id);
create table splav.payments (
  id uuid primary key,
  team_id uuid not null references splav.teams(id),
  group_id uuid not null references splav.groups(id),
  booking_id uuid not null,
  signed_kopeks bigint not null check(signed_kopeks<>0 and abs(signed_kopeks)<=1000000000000),
  direction text not null check(direction in ('income','refund','reversal')),
  occurred_at timestamptz not null,
  method text not null check(method in ('cash','transfer','card','other')),
  notes text not null default '',
  reason text not null default '',
  reverses uuid unique references splav.payments(id),
  correction_of uuid references splav.payments(id),
  version bigint not null default 1,
  author_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(group_id,booking_id) references splav.bookings(group_id,id),
  check ((direction='income' and signed_kopeks>0 and reverses is null) or
    (direction='refund' and signed_kopeks<0 and reverses is null) or (direction='reversal' and reverses is not null))
);
create index payments_booking_idx on splav.payments(group_id,booking_id);
create table splav.payment_allocations (
  payment_id uuid not null references splav.payments(id),
  version bigint not null,
  lines jsonb not null,
  reason text not null,
  author_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key(payment_id,version)
);
create table splav.price_history (
  id bigint generated always as identity primary key,
  group_id uuid not null,registration_id uuid not null,
  old_kopeks bigint not null,new_kopeks bigint not null,
  reason text not null,author_id uuid not null references auth.users(id),created_at timestamptz not null default now(),
  foreign key(group_id,registration_id) references splav.registrations(group_id,id)
);
create function splav.immutable_financial_record() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_table_name='payments' and tg_op='UPDATE' then
    if (to_jsonb(new)-'version')=(to_jsonb(old)-'version') and new.version=old.version+1 then return new; end if;
  end if;
  raise exception 'Financial records are append-only' using errcode='22023';
end;
$$;
create trigger immutable_payment before update or delete on splav.payments for each row execute function splav.immutable_financial_record();
create trigger immutable_allocations before update or delete on splav.payment_allocations for each row execute function splav.immutable_financial_record();
create trigger immutable_prices before update or delete on splav.price_history for each row execute function splav.immutable_financial_record();

create function splav.payment_json(p splav.payments) returns jsonb language sql stable set search_path='' as $$
  select to_jsonb(p)||jsonb_build_object('trip_id',p.group_id,'allocations',coalesce((select lines
    from splav.payment_allocations where payment_id=p.id order by version desc limit 1),'[]'::jsonb));
$$;
create function splav.check_allocations(p_booking uuid,p_amount bigint,p_lines jsonb) returns void
language plpgsql stable set search_path='' as $$
declare item jsonb; total numeric:=0;
begin
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)>100 then
    raise exception 'Invalid allocations' using errcode='22023'; end if;
  if (select count(distinct value->>'participation_id') from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then
    raise exception 'Duplicate allocation' using errcode='22023'; end if;
  for item in select value from jsonb_array_elements(p_lines) loop
    if not exists(select 1 from splav.registrations where booking_id=p_booking and id=(item->>'participation_id')::uuid) then
      raise exception 'Allocation participation access denied' using errcode='42501'; end if;
    if jsonb_typeof(item->'amount_kopeks') is distinct from 'number' or
       (item->>'amount_kopeks')::numeric<>trunc((item->>'amount_kopeks')::numeric) or
       (item->>'amount_kopeks')::numeric<=0 then raise exception 'Invalid allocation amount' using errcode='22023'; end if;
    total:=total+(item->>'amount_kopeks')::numeric;
  end loop;
  if total>p_amount then raise exception 'Allocated sum exceeds payment' using errcode='22023'; end if;
end;
$$;
create function splav.insert_payment(p_data jsonb,p_team uuid,p_trip uuid,p_booking uuid,p_reason text,p_correction uuid default null)
returns uuid language plpgsql set search_path='' as $$
declare amount numeric; sign integer; payment_id uuid; lines jsonb;
begin
  amount:=(p_data->>'amount_kopeks')::numeric;
  if jsonb_typeof(p_data->'amount_kopeks') is distinct from 'number' or amount is null or amount<>trunc(amount) or amount<=0 or amount>1000000000000 or
    p_data->>'direction' is null or p_data->>'direction' not in ('income','refund') or
    p_data->>'method' is null or p_data->>'method' not in ('cash','transfer','card','other') or
    nullif(p_data->>'occurred_at','') is null or char_length(coalesce(p_data->>'notes',''))>2000 then
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

-- Keep the established command contract, UUID namespace and receipt store.
alter function public.people_command(uuid,uuid,uuid,text,jsonb,bigint) set schema splav;
alter function splav.people_command(uuid,uuid,uuid,text,jsonb,bigint) rename to people_command_v2;
revoke all on function splav.people_command_v2(uuid,uuid,uuid,text,jsonb,bigint) from public,anon,authenticated;
create function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
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
        from splav.payments p join lateral(select lines from splav.payment_allocations where payment_id=p.id order by version desc limit 1) a on true,
          lateral jsonb_array_elements(a.lines) e where p.booking_id=b;
      if allocated>total then raise exception 'refund_allocation_required' using errcode='P0001'; end if;
      if exists(select e.value->>'participation_id' from splav.payments p
        join lateral(select lines from splav.payment_allocations where payment_id=p.id order by version desc limit 1) a on true,
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
alter function public.roster_snapshot(uuid,bigint) set schema splav;
alter function splav.roster_snapshot(uuid,bigint) rename to roster_snapshot_v2;
revoke all on function splav.roster_snapshot_v2(uuid,bigint) from public,anon,authenticated;
create function public.roster_snapshot(p_trip_id uuid,p_after_revision bigint default -1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  result:=splav.roster_snapshot_v2(p_trip_id,p_after_revision);
  if result->>'unchanged'='true' then return result; end if;
  return result||jsonb_build_object('finance_protocol',1,
    'payments',coalesce((select jsonb_agg(splav.payment_json(p) order by p.created_at,p.id) from splav.payments p where group_id=p_trip_id),'[]'::jsonb),
    'allocation_history',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at,a.payment_id,a.version)
      from splav.payment_allocations a join splav.payments p on p.id=a.payment_id where p.group_id=p_trip_id),'[]'::jsonb),
    'price_history',coalesce((select jsonb_agg(to_jsonb(h) order by h.id) from splav.price_history h where group_id=p_trip_id),'[]'::jsonb));
end;
$$;
revoke all on all tables in schema splav from public,anon,authenticated;
revoke all on function splav.immutable_financial_record(),splav.payment_json(splav.payments),splav.check_allocations(uuid,bigint,jsonb),
  splav.insert_payment(jsonb,uuid,uuid,uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint),public.roster_snapshot(uuid,bigint) from public,anon;
grant execute on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint),public.roster_snapshot(uuid,bigint) to authenticated;
update splav.teams set people_revision=people_revision+1;
notify pgrst,'reload schema';
