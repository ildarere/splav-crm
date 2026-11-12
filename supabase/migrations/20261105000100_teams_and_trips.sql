create table splav.teams (
  id uuid primary key,
  name text not null check (char_length(name) between 1 and 150)
);

create table splav.team_members (
  team_id uuid not null references splav.teams(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'organizer')),
  primary key (team_id, user_id)
);

create table splav.routes (
  id uuid primary key,
  team_id uuid not null references splav.teams(id),
  name text not null,
  unique (team_id, name),
  unique (team_id, id)
);

-- Retain every existing group UUID, registration journal and command receipt.
insert into splav.teams (id, name)
  values ('00000000-0000-4000-8000-000000000010', 'Команда организаторов');

insert into splav.team_members (team_id, user_id, role)
select distinct '00000000-0000-4000-8000-000000000010'::uuid, m.user_id,
  case when u.email = 'organizer-a@example.com' then 'admin' else 'organizer' end
from splav.group_members m join auth.users u on u.id = m.user_id;

-- An existing installation with other account names still gets one administrator.
update splav.team_members set role = 'admin'
where user_id = (select user_id from splav.team_members order by user_id limit 1)
  and not exists (select 1 from splav.team_members where role = 'admin');

insert into splav.routes (id, team_id, name)
select gen_random_uuid(), '00000000-0000-4000-8000-000000000010', route
from (select distinct route from splav.groups) existing_routes;

alter table splav.groups
  add column team_id uuid not null default '00000000-0000-4000-8000-000000000010' references splav.teams(id),
  add column route_id uuid,
  add column ends_at timestamptz,
  add column timezone text not null default 'Europe/Saratov',
  add column meeting_point text not null default '',
  add column meeting_at timestamptz,
  add column responsible_names text not null default '',
  add column base_price_kopeks bigint not null default 0 check (base_price_kopeks >= 0),
  add column notes text not null default '',
  add column status text not null default 'open' check (status in ('draft', 'open', 'closed', 'in_progress', 'completed', 'cancelled')),
  add column metadata_version bigint not null default 1 check (metadata_version > 0),
  add column updated_at timestamptz not null default now(),
  add column updated_by uuid references auth.users(id);

update splav.groups g set route_id = r.id, ends_at = g.starts_at + interval '1 day',
  meeting_at = g.starts_at - interval '30 minutes'
from splav.routes r where r.team_id = g.team_id and r.name = g.route;

alter table splav.groups
  alter column route_id set not null,
  alter column ends_at set not null,
  alter column meeting_at set not null,
  add foreign key (team_id, route_id) references splav.routes(team_id, id),
  add constraint trip_time_order check (ends_at > starts_at and meeting_at <= starts_at);

create table splav.trip_operation_receipts (
  operation_id uuid primary key,
  trip_id uuid not null,
  team_id uuid not null references splav.teams(id),
  user_id uuid not null,
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);

revoke all on all tables in schema splav from public, anon, authenticated;

create function splav.trip_json(g splav.groups) returns jsonb
language sql immutable set search_path = ''
as $$
  select jsonb_build_object(
    'id', g.id, 'team_id', g.team_id, 'route_id', g.route_id,
    'title', g.title, 'route', g.route, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
    'timezone', g.timezone, 'meeting_point', g.meeting_point, 'meeting_at', g.meeting_at,
    'responsible_names', g.responsible_names, 'capacity', g.capacity,
    'base_price_kopeks', g.base_price_kopeks, 'notes', g.notes, 'status', g.status,
    'metadata_version', g.metadata_version, 'updated_at', g.updated_at, 'updated_by', g.updated_by
  );
$$;
revoke all on function splav.trip_json(splav.groups) from public, anon, authenticated;

create function public.list_trips() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
      'role', m.role) order by t.name, t.id)
      from splav.teams t join splav.team_members m on m.team_id = t.id
      where m.user_id = auth.uid()), '[]'::jsonb),
    'routes', coalesce((select jsonb_agg(jsonb_build_object('id', r.id,
      'team_id', r.team_id, 'name', r.name) order by r.name, r.id)
      from splav.routes r join splav.team_members m on m.team_id = r.team_id
      where m.user_id = auth.uid()), '[]'::jsonb),
    'trips', coalesce((select jsonb_agg(splav.trip_json(g) order by g.starts_at, g.id)
      from splav.groups g join splav.group_members gm on gm.group_id = g.id
      join splav.team_members tm on tm.team_id = g.team_id and tm.user_id = gm.user_id
      where gm.user_id = auth.uid()), '[]'::jsonb)
  );
$$;

create function public.save_trip(
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
  elsif target_capacity < (select count(*) from splav.registrations where group_id = p_trip_id) then
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

create or replace function public.pull_group(
  p_group_id uuid,
  p_after_revision bigint,
  p_limit integer default 50
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  group_row splav.groups%rowtype;
  events jsonb;
  next_cursor bigint;
begin
  if not exists (select 1 from splav.group_members gm
      join splav.groups g on g.id = gm.group_id
      join splav.team_members tm on tm.team_id = g.team_id and tm.user_id = gm.user_id
      where gm.group_id = p_group_id and gm.user_id = auth.uid()) then
    raise exception 'Group access denied' using errcode = '42501';
  end if;
  select * into group_row from splav.groups where id = p_group_id;
  if p_after_revision is null or p_after_revision not between 0 and group_row.revision
    or p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Invalid group cursor or page size' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(page.event order by page.revision), '[]'::jsonb),
    coalesce(max(page.revision), p_after_revision)
    into events, next_cursor
  from (
    select revision, event from splav.group_changes
      where group_id = p_group_id and revision > p_after_revision
      order by revision limit p_limit
  ) as page;
  return jsonb_build_object('group', splav.trip_json(group_row),
    'changes', events, 'cursor', next_cursor, 'has_more', next_cursor < group_row.revision);
end;
$$;

revoke all on function public.list_trips() from public, anon, authenticated;
revoke all on function public.save_trip(uuid, uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.list_trips() to authenticated;
grant execute on function public.save_trip(uuid, uuid, uuid, bigint, jsonb) to authenticated;

-- Preserve the v1 command payload and receipt semantics for queues created before this migration.
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
  select capacity, status into group_capacity, group_status from splav.groups
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
  elsif (select count(*) from splav.registrations where group_id = p_group_id) >= group_capacity then
    result := jsonb_build_object('status', 'rejected', 'reason', 'capacity_reached');
  else
    insert into splav.people (id, name) values (p_person_id, normalized_name)
      on conflict (id) do nothing;
    if not found then
      result := jsonb_build_object('status', 'rejected', 'reason', 'already_registered');
    else
      insert into splav.registrations (group_id, id, person_id)
        values (p_group_id, p_registration_id, p_person_id);
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
  return result;
end;
$$;
