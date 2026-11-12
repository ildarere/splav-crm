begin;
alter table splav.people add column parameters jsonb not null default '{}'::jsonb;
create or replace function splav.person_json(p splav.people) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('parameters',p.parameters,'id',p.id,'team_id',p.team_id,'name',p.name,'phone',p.phone,
    'birth_date',p.birth_date,'notes',p.notes,'archived',p.archived,'merged_into',p.merged_into,
    'version',p.version);
$$;
create or replace function splav.people_command_v2(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,
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
    perform splav.validate_parameters(coalesce(p_payload->'parameters','{}'::jsonb));
    new_name:=btrim(p_payload->>'name'); birth:=nullif(p_payload->>'birth_date','')::date;
    if person_id is null or new_name is null or char_length(new_name) not between 1 and 100
      or char_length(coalesce(p_payload->>'phone',''))>100
      or char_length(coalesce(p_payload->>'notes',''))>2000 then
      raise exception 'Invalid person fields' using errcode='22023';
    end if;
    if person.id is null then
      insert into splav.people(id,team_id,name,phone,phone_normalized,birth_date,notes,archived,created_by,parameters)
        values(person_id,p_team_id,new_name,coalesce(p_payload->>'phone',''),
          splav.phone_digits(p_payload->>'phone'),birth,
          coalesce(p_payload->>'notes',''),coalesce((p_payload->>'archived')::boolean,false),caller,coalesce(p_payload->'parameters','{}'::jsonb));
    else
      update splav.people set name=new_name,phone=coalesce(p_payload->>'phone',''),
        phone_normalized=splav.phone_digits(p_payload->>'phone'),
        parameters=coalesce(p_payload->'parameters',person.parameters),birth_date=birth,notes=coalesce(p_payload->>'notes',''),
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
commit;
