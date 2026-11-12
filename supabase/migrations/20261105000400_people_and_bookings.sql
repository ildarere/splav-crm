-- Existing identities, registrations and receipts remain valid.
alter table splav.teams add column people_revision bigint not null default 0;
alter table splav.groups add column roster_revision bigint not null default 0;
alter table splav.people
  add column team_id uuid references splav.teams(id),
  add column phone text not null default '',
  add column phone_normalized text not null default '',
  add column birth_date date,
  add column notes text not null default '',
  add column archived boolean not null default false,
  add column merged_into uuid references splav.people(id),
  add column version bigint not null default 1,
  add column created_by uuid references auth.users(id),
  add column updated_at timestamptz not null default now();
update splav.people p set team_id = coalesce(
  (select g.team_id from splav.registrations r join splav.groups g on g.id=r.group_id
    where r.person_id=p.id order by g.id limit 1),
  '00000000-0000-4000-8000-000000000010'::uuid);
alter table splav.people alter column team_id set not null;

create table splav.bookings (
  id uuid primary key,
  group_id uuid not null references splav.groups(id),
  contact_person_id uuid references splav.people(id),
  contact_name text not null,
  phone text not null default '',
  notes text not null default '',
  version bigint not null default 1,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
alter table splav.registrations
  add column booking_id uuid references splav.bookings(id),
  add column role text not null default 'client' check(role in ('client','instructor')),
  add column status text not null default 'confirmed'
    check(status in ('application','confirmed','waiting','cancelled')),
  add column parameters jsonb not null default '{}',
  add column agreed_price_kopeks bigint not null default 0 check(agreed_price_kopeks>=0),
  add column version bigint not null default 1,
  add column waiting_at timestamptz;
do $$
declare legacy record; booking uuid;
begin
  for legacy in select r.group_id,r.id,p.id person_id,p.name,g.base_price_kopeks
    from splav.registrations r join splav.people p on p.id=r.person_id
    join splav.groups g on g.id=r.group_id loop
    booking := gen_random_uuid();
    insert into splav.bookings(id,group_id,contact_person_id,contact_name)
      values(booking,legacy.group_id,legacy.person_id,legacy.name);
    update splav.registrations set booking_id=booking,agreed_price_kopeks=legacy.base_price_kopeks
      where group_id=legacy.group_id and id=legacy.id;
  end loop;
end $$;
-- Kept nullable for the legacy command while it is upgraded below.
create table splav.people_receipts (
  operation_id uuid primary key, user_id uuid not null, team_id uuid not null,
  group_id uuid, payload jsonb not null, result jsonb not null,
  created_at timestamptz not null default now()
);
create index registrations_booking_idx on splav.registrations(booking_id);
create index people_search_idx on splav.people(team_id,phone_normalized);
revoke all on all tables in schema splav from public,anon,authenticated;

create function splav.person_visible(p splav.people) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from splav.team_members m where m.team_id=p.team_id and m.user_id=auth.uid()
    and (m.role='admin' or p.created_by=auth.uid() or exists(
      select 1 from splav.registrations r join splav.group_members gm on gm.group_id=r.group_id
      where r.person_id=p.id and gm.user_id=auth.uid()) or exists(
      select 1 from splav.bookings b join splav.group_members gm on gm.group_id=b.group_id
      where b.contact_person_id=p.id and gm.user_id=auth.uid())));
$$;
create function splav.person_json(p splav.people) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('id',p.id,'team_id',p.team_id,'name',p.name,'phone',p.phone,
    'birth_date',p.birth_date,'notes',p.notes,'archived',p.archived,'merged_into',p.merged_into,
    'version',p.version);
$$;
create function splav.registration_json(r splav.registrations) returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_build_object('id',r.id,'trip_id',r.group_id,'booking_id',r.booking_id,
    'person_id',r.person_id,'role',r.role,'status',r.status,'parameters',r.parameters,
    'agreed_price_kopeks',r.agreed_price_kopeks,'version',r.version,'waiting_at',r.waiting_at);
$$;
create function splav.booking_json(b splav.bookings) returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_build_object('id',b.id,'trip_id',b.group_id,'contact_person_id',b.contact_person_id,
    'contact_name',b.contact_name,'phone',b.phone,'notes',b.notes,'version',b.version);
$$;
revoke all on function splav.person_visible(splav.people),splav.person_json(splav.people),
  splav.registration_json(splav.registrations),splav.booking_json(splav.bookings) from public,anon,authenticated;

create function public.people_catalog() returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'teams',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'revision',t.people_revision))
      from splav.teams t join splav.team_members m on m.team_id=t.id where m.user_id=auth.uid()),'[]'::jsonb),
    'people',coalesce((select jsonb_agg(splav.person_json(p) order by p.name,p.id)
      from splav.people p where splav.person_visible(p)),'[]'::jsonb));
$$;
create function public.roster_snapshot(p_trip_id uuid,p_after_revision bigint default -1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g splav.groups%rowtype; revision bigint;
begin
  select * into g from splav.groups where id=p_trip_id;
  if not exists(select 1 from splav.group_members gm join splav.team_members tm
    on tm.team_id=g.team_id and tm.user_id=gm.user_id
    where gm.group_id=p_trip_id and gm.user_id=auth.uid()) then
    raise exception 'Trip access denied' using errcode='42501';
  end if;
  select people_revision into revision from splav.teams where id=g.team_id;
  if p_after_revision = revision then
    return jsonb_build_object('trip_id',g.id,'team_id',g.team_id,'revision',revision,'unchanged',true);
  end if;
  return jsonb_build_object('trip_id',g.id,'team_id',g.team_id,'revision',revision,'unchanged',false,
    'people',coalesce((select jsonb_agg(splav.person_json(p)) from splav.people p
      where exists(select 1 from splav.registrations r where r.group_id=p_trip_id and r.person_id=p.id)
      or exists(select 1 from splav.bookings b where b.group_id=p_trip_id and b.contact_person_id=p.id)),'[]'::jsonb),
    'bookings',coalesce((select jsonb_agg(splav.booking_json(b) order by b.updated_at,b.id)
      from splav.bookings b where b.group_id=p_trip_id),'[]'::jsonb),
    'participations',coalesce((select jsonb_agg(splav.registration_json(r)
      order by r.waiting_at nulls last,r.id) from splav.registrations r where r.group_id=p_trip_id),'[]'::jsonb));
end;
$$;

create function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
  p_kind text,p_payload jsonb,p_expected_version bigint default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  caller uuid := auth.uid(); member_role text; g splav.groups%rowtype;
  person splav.people%rowtype; target splav.people%rowtype; booking splav.bookings%rowtype;
  attendance splav.registrations%rowtype; receipt splav.people_receipts%rowtype;
  full_payload jsonb; result jsonb; reason text; revision bigint; item jsonb;
  person_id uuid; booking_id uuid; member_id uuid; members jsonb;
  desired_status text; desired_role text; params jsonb; selected uuid[];
  confirmed integer; extra integer; price bigint; birth date; new_name text;
begin
  if p_operation_id is null or p_team_id is null or p_expected_version is null or p_expected_version<0
    or p_payload is null or jsonb_typeof(p_payload)<>'object'
    or p_kind not in ('save_person','merge_people','save_booking','set_status','edit_participation') then
    raise exception 'Invalid command' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,4));
  select role into member_role from splav.team_members where team_id=p_team_id and user_id=caller for share;
  if not found then raise exception 'Team access denied' using errcode='42501'; end if;
  -- One team revision serializes these small operations and gives snapshot acknowledgements a stable order.
  perform 1 from splav.teams where id=p_team_id for update;
  if p_kind in ('save_booking','set_status','edit_participation') then
    select * into g from splav.groups where id=p_trip_id and team_id=p_team_id for update;
    if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
    perform 1 from splav.group_members where group_id=p_trip_id and user_id=caller for key share;
    if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
  elsif p_trip_id is not null then
    raise exception 'Unexpected trip scope' using errcode='22023';
  end if;
  if p_kind in ('save_person','merge_people') then
    person_id := (p_payload->>'id')::uuid;
    select * into person from splav.people where id=person_id and team_id=p_team_id;
    if person.id is not null and not splav.person_visible(person) then
      raise exception 'Person access denied' using errcode='42501';
    end if;
    if person.id is null and p_expected_version<>0 then
      raise exception 'Person access denied' using errcode='42501';
    end if;
    if p_kind='merge_people' and member_role<>'admin' then
      raise exception 'Administrator required' using errcode='42501';
    end if;
  end if;
  full_payload := jsonb_build_object('team_id',p_team_id,'trip_id',p_trip_id,'kind',p_kind,
    'payload',p_payload,'expected_version',p_expected_version);
  select * into receipt from splav.people_receipts where operation_id=p_operation_id;
  if found then
    if receipt.user_id<>caller or receipt.payload<>full_payload then
      raise exception 'Operation ID is bound to another command' using errcode='22023';
    end if;
    return receipt.result;
  end if;

  if p_kind in ('save_person','merge_people') and person.id is not null
    and person.version<>p_expected_version then reason:='version_conflict';
  elsif p_kind in ('save_person','merge_people') and person.merged_into is not null then reason:='person_merged';
  elsif p_kind in ('save_booking','set_status','edit_participation') and g.status in ('completed','cancelled') then
    reason:='trip_finalized';
  end if;

  if reason is null and p_kind='save_person' then
    new_name:=btrim(p_payload->>'name'); birth:=nullif(p_payload->>'birth_date','')::date;
    if person_id is null or new_name is null or char_length(new_name) not between 1 and 100
      or char_length(coalesce(p_payload->>'phone',''))>100
      or char_length(coalesce(p_payload->>'notes',''))>2000 then
      raise exception 'Invalid person fields' using errcode='22023';
    end if;
    if person.id is null then
      insert into splav.people(id,team_id,name,phone,phone_normalized,birth_date,notes,archived,created_by)
        values(person_id,p_team_id,new_name,coalesce(p_payload->>'phone',''),
          regexp_replace(coalesce(p_payload->>'phone',''),'[^0-9]','','g'),birth,
          coalesce(p_payload->>'notes',''),coalesce((p_payload->>'archived')::boolean,false),caller);
    else
      update splav.people set name=new_name,phone=coalesce(p_payload->>'phone',''),
        phone_normalized=regexp_replace(coalesce(p_payload->>'phone',''),'[^0-9]','','g'),
        birth_date=birth,notes=coalesce(p_payload->>'notes',''),
        archived=coalesce((p_payload->>'archived')::boolean,false),version=version+1,updated_at=now()
        where id=person_id;
    end if;
  elsif reason is null and p_kind='merge_people' then
    select * into target from splav.people where id=(p_payload->>'target_id')::uuid and team_id=p_team_id;
    if person.id is null or target.id is null or target.id=person.id or target.archived or target.merged_into is not null then
      reason:='invalid_merge';
    elsif target.version<>(p_payload->>'target_version')::bigint then reason:='version_conflict';
    elsif exists(select 1 from splav.registrations a join splav.registrations b on a.group_id=b.group_id
      where a.person_id=person.id and b.person_id=target.id) then reason:='duplicate_participation';
    else
      update splav.registrations set person_id=target.id,version=version+1 where person_id=person.id;
      update splav.bookings set contact_person_id=target.id,version=version+1,updated_at=now()
        where contact_person_id=person.id;
      update splav.people set archived=true,merged_into=target.id,version=version+1,updated_at=now()
        where id=person.id;
      update splav.people set version=version+1,updated_at=now() where id=target.id;
    end if;
  elsif reason is null and p_kind='save_booking' then
    booking_id:=(p_payload->>'id')::uuid;
    select * into booking from splav.bookings where id=booking_id;
    members:=coalesce(p_payload->'members','[]'::jsonb);
    if booking.id is not null and booking.group_id<>p_trip_id then
      raise exception 'Booking access denied' using errcode='42501';
    end if;
    if coalesce(booking.version,0)<>p_expected_version then reason:='version_conflict';
    elsif g.status<>'open' and jsonb_array_length(members)>0 then reason:='trip_not_open';
    elsif booking.id is null and jsonb_array_length(members)=0 then reason:='empty_booking';
    end if;
    if booking_id is null or nullif(btrim(p_payload->>'contact_name'),'') is null
      or char_length(p_payload->>'contact_name')>150 or char_length(coalesce(p_payload->>'phone',''))>100
      or char_length(coalesce(p_payload->>'notes',''))>2000
      or jsonb_typeof(members)<>'array' or jsonb_array_length(members)>100 then
      raise exception 'Invalid booking fields' using errcode='22023';
    end if;
    if nullif(p_payload->>'contact_person_id','') is not null and not exists(
      select 1 from splav.people p where p.id=(p_payload->>'contact_person_id')::uuid
        and p.team_id=p_team_id and splav.person_visible(p) and p.merged_into is null) then
      raise exception 'Contact access denied' using errcode='42501';
    end if;
    for item in select value from jsonb_array_elements(members) loop
      select * into target from splav.people where id=(item->>'person_id')::uuid and team_id=p_team_id;
      if target.id is null or not splav.person_visible(target) then
        raise exception 'Person access denied' using errcode='42501';
      end if;
      if target.archived or target.merged_into is not null then reason:='person_archived'; end if;
      if exists(select 1 from splav.registrations where group_id=p_trip_id and person_id=target.id)
        then reason:='already_registered'; end if;
      if (item->>'id')::uuid is null or coalesce(item->>'role','client') not in ('client','instructor')
        or jsonb_typeof(coalesce(item->'parameters','{}'))<>'object' then
        raise exception 'Invalid participant' using errcode='22023';
      end if;
    end loop;
    if (select count(distinct value->>'person_id') from jsonb_array_elements(members))<>jsonb_array_length(members)
      then reason:='already_registered'; end if;
    if reason is null then
      if booking.id is null then
        insert into splav.bookings(id,group_id,contact_person_id,contact_name,phone,notes,created_by)
          values(booking_id,p_trip_id,nullif(p_payload->>'contact_person_id','')::uuid,
            btrim(p_payload->>'contact_name'),coalesce(p_payload->>'phone',''),coalesce(p_payload->>'notes',''),caller);
      else
        update splav.bookings set contact_person_id=nullif(p_payload->>'contact_person_id','')::uuid,
          contact_name=btrim(p_payload->>'contact_name'),phone=coalesce(p_payload->>'phone',''),
          notes=coalesce(p_payload->>'notes',''),version=version+1,updated_at=now() where id=booking_id;
      end if;
      for item in select value from jsonb_array_elements(members) loop
        insert into splav.registrations(id,group_id,person_id,booking_id,role,status,parameters,agreed_price_kopeks)
          values((item->>'id')::uuid,p_trip_id,(item->>'person_id')::uuid,booking_id,
            coalesce(item->>'role','client'),'application',coalesce(item->'parameters','{}'),
            case when item->>'role'='instructor' then 0 else g.base_price_kopeks end);
      end loop;
    end if;
  elsif reason is null and p_kind='set_status' then
    desired_status:=p_payload->>'status';
    select array_agg(value::uuid) into selected from jsonb_array_elements_text(p_payload->'ids');
    if desired_status is null or desired_status not in ('application','confirmed','waiting','cancelled')
      or coalesce(cardinality(selected),0)=0 or cardinality(selected)>100
      or (select count(distinct x) from unnest(selected) x)<>cardinality(selected) then
      raise exception 'Invalid status selection' using errcode='22023';
    end if;
    if (select count(*) from splav.registrations where group_id=p_trip_id and id=any(selected))<>cardinality(selected) then
      raise exception 'Participation access denied' using errcode='42501';
    end if;
    if exists(select 1 from splav.registrations where group_id=p_trip_id and id=any(selected)
      and version is distinct from (p_payload->'versions'->>id::text)::bigint) then reason:='version_conflict';
    elsif desired_status in ('confirmed','waiting','application') and g.status<>'open' then reason:='trip_not_open';
    elsif desired_status='confirmed' then
      select count(*) into confirmed from splav.registrations where group_id=p_trip_id and status='confirmed' and role='client';
      select count(*) into extra from splav.registrations where group_id=p_trip_id and id=any(selected)
        and role='client' and status<>'confirmed';
      if confirmed+extra>g.capacity then reason:='capacity_reached'; end if;
    end if;
    if reason is null then
      update splav.registrations set status=desired_status,version=version+1,
        waiting_at=case when desired_status='waiting' then coalesce(waiting_at,now()) else null end
        where group_id=p_trip_id and id=any(selected);
    end if;
  elsif reason is null and p_kind='edit_participation' then
    select * into attendance from splav.registrations where group_id=p_trip_id and id=(p_payload->>'id')::uuid;
    if attendance.id is null then raise exception 'Participation access denied' using errcode='42501'; end if;
    desired_role:=p_payload->>'role'; params:=p_payload->'parameters';
    if desired_role is null or desired_role not in ('client','instructor') or params is null or jsonb_typeof(params)<>'object' then
      raise exception 'Invalid participant fields' using errcode='22023';
    end if;
    if attendance.version<>p_expected_version then reason:='version_conflict';
    elsif attendance.status='confirmed' and attendance.role='instructor' and desired_role='client'
      and (select count(*) from splav.registrations where group_id=p_trip_id and status='confirmed' and role='client')>=g.capacity
      then reason:='capacity_reached';
    else
      update splav.registrations set role=desired_role,parameters=params,version=version+1
        where group_id=p_trip_id and id=attendance.id;
    end if;
  end if;

  if reason is null then
    update splav.teams set people_revision=people_revision+1 where id=p_team_id returning people_revision into revision;
    if p_trip_id is not null then update splav.groups set roster_revision=roster_revision+1 where id=p_trip_id; end if;
    result:=jsonb_build_object('status','accepted','revision',revision);
  else result:=jsonb_build_object('status','rejected','reason',reason); end if;
  insert into splav.people_receipts(operation_id,user_id,team_id,group_id,payload,result)
    values(p_operation_id,caller,p_team_id,p_trip_id,full_payload,result);
  return result;
end;
$$;
revoke all on function public.people_catalog(),public.roster_snapshot(uuid,bigint),
  public.people_command(uuid,uuid,uuid,text,jsonb,bigint) from public,anon,authenticated;
grant execute on function public.people_catalog(),public.roster_snapshot(uuid,bigint),
  public.people_command(uuid,uuid,uuid,text,jsonb,bigint) to authenticated;

-- Upgrade existing command entry points.
create or replace function public.save_trip(
  p_operation_id uuid,
  p_team_id uuid,
  p_trip_id uuid,
  p_expected_version bigint,
  p_trip jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  caller_role text;
  current_trip splav.groups%rowtype;
  saved_trip splav.groups%rowtype;
  receipt splav.trip_operation_receipts%rowtype;
  command_payload jsonb;
  result jsonb;
  route_name text;
  target_route uuid;
  start_time timestamptz;
  end_time timestamptz;
  meeting_time timestamptz;
  target_capacity integer;
  target_price bigint;
  target_status text;
  zone_name text;
  title_value text;
begin
  if p_operation_id is null or p_team_id is null or p_trip_id is null
    or p_expected_version is null or p_expected_version < 0
    or p_trip is null or jsonb_typeof(p_trip) <> 'object' then
    raise exception 'Invalid trip command' using errcode = '22023';
  end if;

  -- A UUID cannot be repurposed across trips or callers, even on concurrent requests.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_operation_id::text, 0));
  select role into caller_role from splav.team_members
    where team_id = p_team_id and user_id = caller_id for share;
  if not found or (p_expected_version = 0 and caller_role <> 'admin') then
    raise exception 'Team access denied' using errcode = '42501';
  end if;

  -- The second lock orders simultaneous creation of the same trip UUID.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_trip_id::text, 1));
  select * into current_trip from splav.groups where id = p_trip_id for update;
  if found then
    if current_trip.team_id <> p_team_id then
      raise exception 'Trip access denied' using errcode = '42501';
    end if;
    perform 1 from splav.group_members where group_id = p_trip_id and user_id = caller_id
      for key share;
    if not found then
      raise exception 'Trip access denied' using errcode = '42501';
    end if;
  elsif p_expected_version <> 0 then
    raise exception 'Trip access denied' using errcode = '42501';
  end if;

  command_payload := jsonb_build_object('expected_version', p_expected_version,
    'trip_id', p_trip_id, 'team_id', p_team_id, 'trip', p_trip);
  select * into receipt from splav.trip_operation_receipts where operation_id = p_operation_id;
  if found then
    if receipt.user_id <> caller_id or receipt.payload <> command_payload then
      raise exception 'Operation ID is already bound to another command' using errcode = '22023';
    end if;
    return receipt.result;
  end if;

  title_value := btrim(p_trip->>'title');
  target_route := (p_trip->>'route_id')::uuid;
  start_time := (p_trip->>'starts_at')::timestamptz;
  end_time := (p_trip->>'ends_at')::timestamptz;
  meeting_time := (p_trip->>'meeting_at')::timestamptz;
  target_capacity := (p_trip->>'capacity')::integer;
  target_price := (p_trip->>'base_price_kopeks')::bigint;
  target_status := p_trip->>'status';
  zone_name := p_trip->>'timezone';

  if title_value is null or char_length(title_value) not between 1 and 200
    or start_time is null or end_time is null or meeting_time is null
    or end_time <= start_time or meeting_time > start_time
    or target_capacity is null or target_capacity < 1
    or target_price is null or target_price < 0
    or target_status is null or target_status not in ('draft', 'open', 'closed', 'in_progress', 'completed', 'cancelled')
    or zone_name is null or not exists (select 1 from pg_catalog.pg_timezone_names where name = zone_name)
    or (zone_name <> 'UTC' and position('/' in zone_name) = 0)
    or char_length(coalesce(p_trip->>'meeting_point', '')) > 500
    or char_length(coalesce(p_trip->>'responsible_names', '')) > 500
    or char_length(coalesce(p_trip->>'notes', '')) > 5000 then
    raise exception 'Invalid trip fields' using errcode = '22023';
  end if;
  select name into route_name from splav.routes where id = target_route and team_id = p_team_id;
  if not found then
    raise exception 'Route access denied' using errcode = '42501';
  end if;

  if current_trip.id is not null and p_expected_version = 0 then
    result := jsonb_build_object('status', 'rejected', 'reason', 'trip_exists',
      'current', splav.trip_json(current_trip));
  elsif current_trip.id is not null and current_trip.metadata_version <> p_expected_version then
    result := jsonb_build_object('status', 'rejected', 'reason', 'version_conflict',
      'current', splav.trip_json(current_trip));
  elsif current_trip.status in ('completed', 'cancelled') then
    result := jsonb_build_object('status', 'rejected', 'reason', 'trip_finalized',
      'current', splav.trip_json(current_trip));
  elsif target_capacity < (select count(*) from splav.registrations where group_id = p_trip_id and status = 'confirmed' and role = 'client') then
    result := jsonb_build_object('status', 'rejected', 'reason', 'capacity_below_confirmed',
      'current', splav.trip_json(current_trip));
  elsif (current_trip.id is null and target_status not in ('draft', 'open'))
    or (current_trip.id is not null and target_status <> current_trip.status and not (
      (current_trip.status = 'draft' and target_status = 'open')
      or (current_trip.status = 'open' and target_status = 'closed')
      or (current_trip.status = 'closed' and target_status = 'open')
      or (caller_role = 'admin' and (
        (current_trip.status = 'closed' and target_status = 'in_progress')
        or (current_trip.status = 'in_progress' and target_status = 'completed')
        or target_status = 'cancelled'
      ))
    )) then
    result := jsonb_build_object('status', 'rejected', 'reason', 'invalid_transition',
      'current', case when current_trip.id is not null then splav.trip_json(current_trip) else null end);
  else
    if current_trip.id is null then
      insert into splav.groups (id, team_id, route_id, title, route, starts_at, ends_at,
        timezone, meeting_point, meeting_at, responsible_names, capacity, base_price_kopeks,
        notes, status, metadata_version, updated_at, updated_by)
      values (p_trip_id, p_team_id, target_route, title_value, route_name, start_time, end_time,
        zone_name, coalesce(p_trip->>'meeting_point', ''), meeting_time,
        coalesce(p_trip->>'responsible_names', ''), target_capacity, target_price,
        coalesce(p_trip->>'notes', ''), target_status, 1, now(), caller_id)
      returning * into saved_trip;
      insert into splav.group_members (group_id, user_id)
        select p_trip_id, user_id from splav.team_members where team_id = p_team_id and role = 'admin';
    else
      update splav.groups set route_id = target_route, title = title_value, route = route_name,
        starts_at = start_time, ends_at = end_time, timezone = zone_name,
        meeting_point = coalesce(p_trip->>'meeting_point', ''), meeting_at = meeting_time,
        responsible_names = coalesce(p_trip->>'responsible_names', ''), capacity = target_capacity,
        base_price_kopeks = target_price, notes = coalesce(p_trip->>'notes', ''), status = target_status,
        metadata_version = metadata_version + 1, updated_at = now(), updated_by = caller_id
      where id = p_trip_id returning * into saved_trip;
    end if;
    result := jsonb_build_object('status', 'accepted', 'trip', splav.trip_json(saved_trip));
  end if;

  insert into splav.trip_operation_receipts (operation_id, trip_id, team_id, user_id, payload, result)
    values (p_operation_id, p_trip_id, p_team_id, caller_id, command_payload, result);
  return result;
end;
$$;

create or replace function public.submit_registration(
  p_group_id uuid,
  p_operation_id uuid,
  p_person_id uuid,
  p_registration_id uuid,
  p_name text
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  normalized_name text := btrim(p_name, E' \t\r\n');
  group_capacity integer;
  group_status text;
  group_team uuid;
  group_price bigint;
  new_booking uuid;
  next_revision bigint;
  command_payload jsonb;
  receipt splav.operation_receipts%rowtype;
  result jsonb;
begin
  perform 1 from splav.team_members tm join splav.groups g on g.team_id = tm.team_id
    where g.id = p_group_id and tm.user_id = caller_id for share of tm;
  if not found then
    raise exception 'Group access denied' using errcode = '42501';
  end if;
  perform 1 from splav.group_members
    where group_id = p_group_id and user_id = caller_id for key share;
  if not found then
    raise exception 'Group access denied' using errcode = '42501';
  end if;
  if p_operation_id is null or p_person_id is null or p_registration_id is null
    or normalized_name is null or char_length(normalized_name) not between 1 and 100 then
    raise exception 'Invalid registration command' using errcode = '22023';
  end if;

  command_payload := jsonb_build_object(
    'person_id', p_person_id, 'registration_id', p_registration_id, 'name', normalized_name);
  perform 1 from splav.teams t join splav.groups g on g.team_id=t.id
    where g.id=p_group_id for update of t;
  select capacity, status, team_id, base_price_kopeks into group_capacity, group_status, group_team, group_price from splav.groups
    where id = p_group_id for update;
  select * into receipt from splav.operation_receipts
    where group_id = p_group_id and operation_id = p_operation_id;
  if found then
    if receipt.user_id <> caller_id or receipt.payload <> command_payload then
      raise exception 'Operation ID is already bound to another command' using errcode = '22023';
    end if;
    return receipt.result;
  end if;

  if group_status <> 'open' then
    result := jsonb_build_object('status', 'rejected', 'reason', 'trip_not_open');
  elsif exists (select 1 from splav.registrations where group_id = p_group_id
      and (id = p_registration_id or person_id = p_person_id)) then
    result := jsonb_build_object('status', 'rejected', 'reason', 'already_registered');
  elsif (select count(*) from splav.registrations where group_id = p_group_id and status='confirmed' and role='client') >= group_capacity then
    result := jsonb_build_object('status', 'rejected', 'reason', 'capacity_reached');
  else
    insert into splav.people (id, name, team_id, created_by) values (p_person_id, normalized_name, group_team, caller_id)
      on conflict (id) do nothing;
    if not found then
      result := jsonb_build_object('status', 'rejected', 'reason', 'already_registered');
    else
      new_booking := gen_random_uuid();
      insert into splav.bookings(id,group_id,contact_person_id,contact_name,created_by)
        values(new_booking,p_group_id,p_person_id,normalized_name,caller_id);
      insert into splav.registrations (group_id, id, person_id,booking_id,agreed_price_kopeks)
        values (p_group_id, p_registration_id, p_person_id,new_booking,group_price);
      update splav.groups set revision = revision + 1 where id = p_group_id
        returning revision into next_revision;
      insert into splav.group_changes (group_id, revision, event)
        values (p_group_id, next_revision, jsonb_build_object(
          'revision', next_revision, 'operation_id', p_operation_id,
          'person', jsonb_build_object('id', p_person_id, 'name', normalized_name),
          'registration', jsonb_build_object('id', p_registration_id, 'person_id', p_person_id,
            'group_id', p_group_id, 'status', 'confirmed')));
      result := jsonb_build_object('status', 'accepted', 'revision', next_revision);
    end if;
  end if;
  insert into splav.operation_receipts (group_id, operation_id, user_id, payload, result)
    values (p_group_id, p_operation_id, caller_id, command_payload, result);
  if result->>'status'='accepted' then
    update splav.teams set people_revision=people_revision+1 where id=group_team;
    update splav.groups set roster_revision=roster_revision+1 where id=p_group_id;
  end if;
  return result;
end;
$$;

alter table splav.registrations alter column booking_id set not null;
