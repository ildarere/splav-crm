create schema splav;
revoke all on schema splav from public, anon, authenticated;

create table splav.groups (
  id uuid primary key,
  title text not null,
  route text not null,
  starts_at timestamptz not null,
  capacity integer not null check (capacity > 0),
  revision bigint not null default 0
);

create table splav.group_members (
  group_id uuid not null references splav.groups(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (group_id, user_id)
);

create table splav.people (
  id uuid primary key,
  name text not null check (char_length(name) between 1 and 100)
);

create table splav.registrations (
  group_id uuid not null references splav.groups(id),
  id uuid not null,
  person_id uuid not null references splav.people(id),
  primary key (group_id, id),
  unique (group_id, person_id)
);

create table splav.operation_receipts (
  group_id uuid not null references splav.groups(id),
  operation_id uuid not null,
  user_id uuid not null,
  payload jsonb not null,
  result jsonb not null,
  primary key (group_id, operation_id)
);

create table splav.group_changes (
  group_id uuid not null references splav.groups(id),
  revision bigint not null,
  event jsonb not null,
  primary key (group_id, revision)
);

revoke all on all tables in schema splav from public, anon, authenticated;

create function public.submit_registration(
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
  next_revision bigint;
  command_payload jsonb;
  receipt splav.operation_receipts%rowtype;
  result jsonb;
begin
  -- Hold membership through commit so a concurrent deletion is ordered with this command.
  perform 1 from splav.group_members
    where group_id = p_group_id and user_id = caller_id
    for key share;
  if not found then
    raise exception 'Group access denied' using errcode = '42501';
  end if;

  if p_operation_id is null or p_person_id is null or p_registration_id is null
    or normalized_name is null or char_length(normalized_name) not between 1 and 100 then
    raise exception 'Invalid registration command' using errcode = '22023';
  end if;

  command_payload := jsonb_build_object(
    'person_id', p_person_id, 'registration_id', p_registration_id, 'name', normalized_name
  );

  -- All commands for one group serialize here, including retries and rejected requests.
  select capacity into group_capacity from splav.groups
    where id = p_group_id for update;

  select * into receipt from splav.operation_receipts
    where group_id = p_group_id and operation_id = p_operation_id;
  if found then
    if receipt.user_id <> caller_id or receipt.payload <> command_payload then
      raise exception 'Operation ID is already bound to another command' using errcode = '22023';
    end if;
    return receipt.result;
  end if;

  if exists (select 1 from splav.registrations where group_id = p_group_id
      and (id = p_registration_id or person_id = p_person_id)) then
    result := jsonb_build_object('status', 'rejected', 'reason', 'already_registered');
  elsif (select count(*) from splav.registrations where group_id = p_group_id) >= group_capacity then
    result := jsonb_build_object('status', 'rejected', 'reason', 'capacity_reached');
  else
    insert into splav.people (id, name) values (p_person_id, normalized_name)
      on conflict (id) do nothing;
    if not found then
      -- This prototype creates a person and their registration in one operation.
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
            'group_id', p_group_id, 'status', 'confirmed')
        ));
      result := jsonb_build_object('status', 'accepted', 'revision', next_revision);
    end if;
  end if;

  insert into splav.operation_receipts (group_id, operation_id, user_id, payload, result)
    values (p_group_id, p_operation_id, caller_id, command_payload, result);
  return result;
end;
$$;

create function public.pull_group(
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
  if not exists (select 1 from splav.group_members
      where group_id = p_group_id and user_id = auth.uid()) then
    raise exception 'Group access denied' using errcode = '42501';
  end if;

  -- STABLE uses one statement snapshot for authorization, metadata and journal reads.
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

  return jsonb_build_object(
    'group', jsonb_build_object('id', group_row.id, 'title', group_row.title,
      'route', group_row.route, 'starts_at', group_row.starts_at, 'capacity', group_row.capacity),
    'changes', events,
    'cursor', next_cursor,
    'has_more', next_cursor < group_row.revision
  );
end;
$$;

revoke all on function public.submit_registration(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.pull_group(uuid, bigint, integer) from public, anon, authenticated;
grant execute on function public.submit_registration(uuid, uuid, uuid, uuid, text) to authenticated;
grant execute on function public.pull_group(uuid, bigint, integer) to authenticated;
