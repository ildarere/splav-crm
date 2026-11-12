begin;

alter function public.people_command(uuid,uuid,uuid,text,jsonb,bigint) set schema splav;
alter function splav.people_command(uuid,uuid,uuid,text,jsonb,bigint) rename to people_command_before_reschedule;
revoke all on function splav.people_command_before_reschedule(uuid,uuid,uuid,text,jsonb,bigint)
  from public,anon,authenticated;

create function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
  p_kind text,p_payload jsonb,p_expected_version bigint default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  caller uuid:=auth.uid();
  target_id uuid;
  source_trip splav.groups%rowtype;
  target_trip splav.groups%rowtype;
  registration splav.registrations%rowtype;
  receipt splav.people_receipts%rowtype;
  duty splav.ops_reservations%rowtype;
  command_payload jsonb;
  result jsonb;
  reason text;
  revision bigint;
  versions jsonb;
  escort_roles text[]:=array['water_instructor','uaz_driver','camp_worker','relief'];
  shift_by interval;
  paid jsonb;
begin
  if p_kind is null or p_kind not in ('move_participant','ops_move_escort') then
    if p_kind='ops_reservation' and p_payload->>'kind'='duty' then
      if p_payload ? 'paid' and jsonb_typeof(p_payload->'paid') is distinct from 'boolean' then
        raise exception 'Invalid work payment flag' using errcode='22023';
      end if;
      -- Use the same lock order as reservation commands.
      perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,4));
      perform 1 from splav.team_members where team_id=p_team_id and user_id=caller for share;
      if not found then raise exception 'Team access denied' using errcode='42501'; end if;
      perform 1 from splav.teams where id=p_team_id for update;
      select data->'paid' into paid from splav.ops_reservations
        where id=(p_payload->>'id')::uuid and group_id=p_trip_id and kind='duty';
      result:=splav.people_command_before_reschedule(
        p_operation_id,p_team_id,p_trip_id,p_kind,p_payload,p_expected_version);
      paid:=coalesce(p_payload->'paid',paid);
      if paid is not null and result->>'status'='accepted' then
        update splav.ops_reservations set data=jsonb_set(data,'{paid}',paid)
          where id=(p_payload->>'id')::uuid and group_id=p_trip_id
            and kind='duty' and version=p_expected_version+1;
      end if;
      return result;
    end if;
    return splav.people_command_before_reschedule(
      p_operation_id,p_team_id,p_trip_id,p_kind,p_payload,p_expected_version);
  end if;

  target_id:=(p_payload->>'target_trip_id')::uuid;
  if p_operation_id is null or p_team_id is null or p_trip_id is null
     or target_id is null or target_id=p_trip_id
     or p_expected_version is null or p_expected_version<0 then
    raise exception 'Invalid move' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,4));
  perform 1 from splav.team_members where team_id=p_team_id and user_id=caller for share;
  if not found then raise exception 'Team access denied' using errcode='42501'; end if;
  perform 1 from splav.teams where id=p_team_id for update;
  select * into source_trip from splav.groups where id=p_trip_id and team_id=p_team_id for update;
  select * into target_trip from splav.groups where id=target_id and team_id=p_team_id for update;
  if source_trip.id is null or target_trip.id is null or
    (select count(*) from splav.group_members
      where user_id=caller and group_id in (p_trip_id,target_id))<>2 then
    raise exception 'Trip access denied' using errcode='42501';
  end if;
  command_payload:=jsonb_build_object('team_id',p_team_id,'trip_id',p_trip_id,
    'kind',p_kind,'payload',p_payload,'expected_version',p_expected_version);
  select * into receipt from splav.people_receipts where operation_id=p_operation_id;
  if found then
    if receipt.user_id<>caller or receipt.payload<>command_payload then
      raise exception 'Operation ID is bound to another command' using errcode='22023';
    end if;
    return receipt.result;
  end if;

  begin
    if source_trip.status in ('completed','cancelled') then
      raise exception 'trip_finalized' using errcode='P0001';
    end if;
    if p_kind='move_participant' then
      if target_trip.status<>'open' then raise exception 'trip_not_open' using errcode='P0001'; end if;
      select * into registration from splav.registrations
        where group_id=p_trip_id and id=(p_payload->>'id')::uuid;
      if not found or registration.role<>'client' or registration.status='cancelled' then
        raise exception 'participant_unavailable' using errcode='P0001';
      end if;
      if registration.version<>p_expected_version then
        raise exception 'version_conflict' using errcode='P0001';
      end if;
      if exists(select 1 from splav.registrations
        where group_id=target_id and person_id=registration.person_id) then
        raise exception 'already_registered' using errcode='P0001';
      end if;
      insert into splav.bookings(id,group_id,contact_person_id,contact_name,phone,created_by)
        select (p_payload->>'new_booking_id')::uuid,target_id,p.id,p.name,p.phone,caller
        from splav.people p where p.id=registration.person_id;
      insert into splav.registrations(group_id,id,person_id,booking_id,role,status,parameters,
        agreed_price_kopeks,waiting_at)
      values(target_id,(p_payload->>'new_registration_id')::uuid,registration.person_id,
        (p_payload->>'new_booking_id')::uuid,'client',registration.status,registration.parameters,
        registration.agreed_price_kopeks,
        case when registration.status='waiting' then now() end);
      update splav.registrations set status='cancelled',waiting_at=null,version=version+1
        where group_id=p_trip_id and id=registration.id;
    else
      if target_trip.status in ('draft','completed','cancelled') then
        raise exception 'trip_locked' using errcode='P0001';
      end if;
      select jsonb_object_agg(id,version) into versions from splav.ops_reservations
        where group_id=p_trip_id and kind='duty' and active
          and data->>'role'=any(escort_roles);
      if versions is null then raise exception 'escort_empty' using errcode='P0001'; end if;
      if versions is distinct from p_payload->'versions' then
        raise exception 'version_conflict' using errcode='P0001';
      end if;
      if exists(select 1 from splav.ops_reservations
        where group_id=target_id and kind='duty' and active
          and data->>'role'=any(escort_roles)) then
        raise exception 'escort_already_assigned' using errcode='P0001';
      end if;
      shift_by:=target_trip.starts_at-source_trip.starts_at;
      for duty in select * from splav.ops_reservations
        where group_id=p_trip_id and versions ? id::text
      loop
        if exists(select 1 from splav.ops_resources r where r.id=duty.resource_id and
          (r.data->>'available' is distinct from 'true' or not (r.data->'roles' ? (duty.data->>'role')))) then
          raise exception 'resource_unavailable' using errcode='P0001';
        end if;
        if exists(select 1 from splav.ops_reservations other join splav.groups g on g.id=other.group_id
          where other.resource_id=duty.resource_id and other.active and g.status<>'cancelled'
            and not (versions ? other.id::text)
            and other.busy_start<duty.busy_end+shift_by and duty.busy_start+shift_by<other.busy_end) then
          raise exception 'resource_overlap' using errcode='P0001';
        end if;
        if exists(select 1 from splav.ops_resources r
          join splav.people p on p.id::text=r.data->>'person_id'
          cross join lateral jsonb_array_elements(p.work_schedule) s
          where r.id=duty.resource_id and (s->>'starts_at')::timestamptz<duty.busy_end+shift_by
            and duty.busy_start+shift_by<(s->>'ends_at')::timestamptz) then
          raise exception 'work_schedule_overlap' using errcode='P0001';
        end if;
      end loop;
      update splav.ops_reservations
        set group_id=target_id, starts_at=starts_at+shift_by, ends_at=ends_at+shift_by,
          busy_start=busy_start+shift_by,busy_end=busy_end+shift_by,
          version=version+1,author_id=caller,updated_at=now()
        where group_id=p_trip_id and versions ? id::text;
    end if;
  exception when sqlstate 'P0001' then
    reason:=sqlerrm;
  end;
  if reason is null then
    update splav.teams set people_revision=people_revision+1
      where id=p_team_id returning people_revision into revision;
    update splav.groups set roster_revision=roster_revision+1 where id in (p_trip_id,target_id);
    result:=jsonb_build_object('status','accepted','revision',revision);
  else
    result:=jsonb_build_object('status','rejected','reason',reason);
  end if;
  insert into splav.people_receipts(operation_id,user_id,team_id,group_id,payload,result)
    values(p_operation_id,caller,p_team_id,p_trip_id,command_payload,result);
  return result;
end;
$$;

revoke all on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint) from public,anon;
grant execute on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
