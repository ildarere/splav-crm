-- Capacity is now a planning target. Keep locks, versions, access checks and receipts.
-- Old rejected receipts remain immutable; an explicit retry uses a new operation UUID.
create or replace function splav.trip_json(g splav.groups) returns jsonb
language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'id', g.id, 'team_id', g.team_id, 'route_id', g.route_id,
    'title', g.title, 'route', g.route, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
    'timezone', g.timezone, 'meeting_point', g.meeting_point, 'meeting_at', g.meeting_at,
    'responsible_names', g.responsible_names, 'capacity', g.capacity,
    'base_price_kopeks', g.base_price_kopeks, 'notes', g.notes, 'status', g.status,
    'metadata_version', g.metadata_version, 'updated_at', g.updated_at, 'updated_by', g.updated_by
  ) || (select jsonb_build_object(
    'booked_clients',count(*) filter(where role='client' and status in ('application','confirmed')),
    'confirmed_clients',count(*) filter(where role='client' and status='confirmed'),
    'waiting_clients',count(*) filter(where role='client' and status='waiting'),
    'instructors',count(*) filter(where role='instructor' and status='confirmed'),
    'capacity_exceeded',count(*) filter(where role='client' and status in ('application','confirmed'))>g.capacity)
    from splav.registrations where group_id=g.id);
$$;

create or replace function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
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
    or p_kind is null or p_kind not in ('save_person','merge_people','save_booking','set_status','edit_participation') then
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
          splav.phone_digits(p_payload->>'phone'),birth,
          coalesce(p_payload->>'notes',''),coalesce((p_payload->>'archived')::boolean,false),caller);
    else
      update splav.people set name=new_name,phone=coalesce(p_payload->>'phone',''),
        phone_normalized=splav.phone_digits(p_payload->>'phone'),
        birth_date=birth,notes=coalesce(p_payload->>'notes',''),
        archived=coalesce((p_payload->>'archived')::boolean,false),version=version+1,updated_at=now()
        where id=person_id;
    end if;
  elsif reason is null and p_kind='merge_people' then
    if nullif(p_payload->>'target_version','') is null then
      raise exception 'Target version is required' using errcode='22023';
    end if;
    select * into target from splav.people where id=(p_payload->>'target_id')::uuid and team_id=p_team_id;
    if person.id is null or target.id is null or target.id=person.id or target.archived or target.merged_into is not null then
      reason:='invalid_merge';
    elsif target.version<>(p_payload->>'target_version')::bigint then reason:='version_conflict';
    elsif exists(select 1 from splav.registrations a join splav.registrations b on a.group_id=b.group_id
      where a.person_id=person.id and b.person_id=target.id) then reason:='duplicate_participation';
    else
      update splav.registrations set person_id=target.id,version=version+1 where registrations.person_id=person.id;
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
      perform splav.validate_parameters(coalesce(item->'parameters','{}'));
      if target.archived or target.merged_into is not null then reason:='person_archived'; end if;
      if exists(select 1 from splav.registrations where registrations.group_id=p_trip_id and (registrations.person_id=target.id or registrations.id=(item->>'id')::uuid))
        then reason:='already_registered'; end if;
      if (item->>'id')::uuid is null or coalesce(item->>'role','client') not in ('client','instructor')
        or jsonb_typeof(coalesce(item->'parameters','{}'))<>'object' then
        raise exception 'Invalid participant' using errcode='22023';
      end if;
    end loop;
    if (select count(distinct value->>'id') from jsonb_array_elements(members))<>jsonb_array_length(members) then
      raise exception 'Duplicate participation IDs' using errcode='22023';
    end if;
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
    perform splav.validate_parameters(params);
    if attendance.version<>p_expected_version then reason:='version_conflict';
    else
      update splav.registrations set role=desired_role,parameters=params,version=version+1
        where group_id=p_trip_id and id=attendance.id;
    end if;
  end if;

  if reason is null then
    update splav.teams set people_revision=people_revision+1 where id=p_team_id returning people_revision into revision;
    if p_trip_id is not null then update splav.groups set roster_revision=roster_revision+1 where id=p_trip_id; end if;
    result:=jsonb_build_object('status','accepted','revision',revision);
    if p_trip_id is not null then
      result:=result || jsonb_build_object('occupancy',splav.trip_json(g));
    end if;
  else result:=jsonb_build_object('status','rejected','reason',reason); end if;
  insert into splav.people_receipts(operation_id,user_id,team_id,group_id,payload,result)
    values(p_operation_id,caller,p_team_id,p_trip_id,full_payload,result);
  return result;
end;
$$;

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

notify pgrst, 'reload schema';
