-- Rendering timestamptz values depends on the session timezone.
alter function splav.trip_json(splav.groups) stable;

create table splav.route_operation_receipts (
  operation_id uuid primary key,
  team_id uuid not null references splav.teams(id),
  user_id uuid not null,
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
revoke all on splav.route_operation_receipts from public, anon, authenticated;

create function public.create_route(
  p_operation_id uuid,
  p_team_id uuid,
  p_route_id uuid,
  p_name text
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  caller_role text;
  normalized_name text := btrim(p_name);
  receipt splav.route_operation_receipts%rowtype;
  command_payload jsonb;
  result jsonb;
begin
  select role into caller_role from splav.team_members
    where team_id = p_team_id and user_id = caller_id for share;
  if not found or caller_role <> 'admin' then
    raise exception 'Team access denied' using errcode = '42501';
  end if;
  if p_operation_id is null or p_route_id is null or normalized_name is null
    or char_length(normalized_name) not between 1 and 200 then
    raise exception 'Invalid route command' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_operation_id::text, 0));
  command_payload := jsonb_build_object('team_id', p_team_id, 'route_id', p_route_id, 'name', normalized_name);
  select * into receipt from splav.route_operation_receipts where operation_id = p_operation_id;
  if found then
    if receipt.user_id <> caller_id or receipt.payload <> command_payload then
      raise exception 'Operation ID is already bound to another command' using errcode = '22023';
    end if;
    return receipt.result;
  end if;
  insert into splav.routes (id, team_id, name) values (p_route_id, p_team_id, normalized_name)
    on conflict do nothing;
  if found then
    result := jsonb_build_object('status', 'accepted', 'route',
      jsonb_build_object('id', p_route_id, 'team_id', p_team_id, 'name', normalized_name));
  else
    result := jsonb_build_object('status', 'rejected', 'reason', 'route_exists');
  end if;
  insert into splav.route_operation_receipts (operation_id, team_id, user_id, payload, result)
    values (p_operation_id, p_team_id, caller_id, command_payload, result);
  return result;
end;
$$;

revoke all on function public.create_route(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.create_route(uuid, uuid, uuid, text) to authenticated;
