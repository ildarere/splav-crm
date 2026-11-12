-- Explicitly qualify active: the command also has a local active variable.
create or replace function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,p_kind text,p_payload jsonb,p_expected_version bigint default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare caller uuid:=auth.uid(); envelope jsonb; receipt splav.people_receipts%rowtype; g splav.groups%rowtype;
 resource splav.ops_resources%rowtype; booking splav.ops_reservations%rowtype; old_booking splav.ops_reservations%rowtype;
 swap_crew splav.ops_crews%rowtype; source_booking splav.ops_reservations%rowtype; swap_registration splav.registrations%rowtype;
 old_crew splav.ops_crews%rowtype; old_travel splav.ops_travel%rowtype; fact splav.ops_presence%rowtype;
 item jsonb; before_data jsonb; after_data jsonb; identifier uuid; resource_id uuid; registration splav.registrations%rowtype;
 k text; direction text; mode text; subject_kind text; subject_id uuid; person uuid; chosen_seat integer; point text;
 begin_at timestamptz; end_at timestamptz; prep integer; tail integer; cap integer; active boolean; revision bigint;
 reason text; result jsonb; signature text; admin boolean; role_value text; current_version bigint;
begin
 if p_kind is null or p_kind not like 'ops_%' then
  return splav.people_command_v3(p_operation_id,p_team_id,p_trip_id,p_kind,p_payload,p_expected_version); end if;
 if p_operation_id is null or p_team_id is null or p_trip_id is null or p_expected_version is null or p_expected_version<0
 or jsonb_typeof(p_payload) is distinct from 'object' or p_kind not in
 ('ops_setup','ops_resources','ops_reservation','ops_crew','ops_travel','ops_presence','ops_resolve','ops_settings') then
 raise exception 'Invalid operations command' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,4));
 select role='admin' into admin from splav.team_members where team_id=p_team_id and user_id=caller for share;
 if not found then raise exception 'Team access denied' using errcode='42501'; end if;
 -- The team row serializes reservations across different trips, as well as CAS
 -- and participant cancellation. Clients cannot bypass this through table APIs.
 perform 1 from splav.teams where id=p_team_id for update;
 select * into g from splav.groups where id=p_trip_id and team_id=p_team_id for update;
 if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
 perform 1 from splav.group_members where group_id=p_trip_id and user_id=caller for key share;
 if not found then raise exception 'Trip access denied' using errcode='42501'; end if;
 envelope:=jsonb_build_object('team_id',p_team_id,'trip_id',p_trip_id,'kind',p_kind,'payload',p_payload,'expected_version',p_expected_version);
 select * into receipt from splav.people_receipts where operation_id=p_operation_id;
 if found then
  if receipt.user_id<>caller or receipt.payload<>envelope then raise exception 'Operation ID bound to another command' using errcode='22023'; end if;
  return receipt.result;
 end if;
 begin
  if g.status in ('completed','cancelled') and p_kind not in ('ops_resolve','ops_presence','ops_resources','ops_setup') then
   raise exception 'trip_locked' using errcode='P0001'; end if;
  identifier:=nullif(p_payload->>'id','')::uuid;
  if p_kind in ('ops_setup','ops_resources') then
   if not admin then raise exception 'Resource administration denied' using errcode='42501'; end if;
   if p_kind='ops_setup' and exists(select 1 from splav.ops_setup where team_id=p_team_id) then
    raise exception 'already_initialized' using errcode='P0001'; end if;
   if jsonb_typeof(p_payload->'items') is distinct from 'array' or jsonb_array_length(p_payload->'items') not between 1 and 500 then
    raise exception 'Resource list required' using errcode='22023'; end if;
   for item in select value from jsonb_array_elements(p_payload->'items') loop perform splav.ops_save_resource(p_team_id,item); end loop;
   if p_kind='ops_setup' then insert into splav.ops_setup values(p_team_id,coalesce(p_payload->'reference','{}'::jsonb),caller,now()); end if;
  elsif p_kind='ops_settings' then
   select version into current_version from splav.ops_settings where group_id=p_trip_id;
   if coalesce(current_version,0)<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
   if jsonb_typeof(p_payload->'many_children') is distinct from 'boolean' or char_length(coalesce(p_payload->>'notes',''))>2000 then
    raise exception 'Invalid settings' using errcode='22023'; end if;
   insert into splav.ops_settings values(p_trip_id,(p_payload->>'many_children')::boolean,coalesce(p_payload->>'notes',''),p_expected_version+1,caller)
    on conflict(group_id) do update set many_children=excluded.many_children,notes=excluded.notes,version=excluded.version,author_id=excluded.author_id;
  elsif p_kind='ops_reservation' then
   select * into old_booking from splav.ops_reservations where id=identifier;
   if found and old_booking.group_id<>p_trip_id then raise exception 'Reservation access denied' using errcode='42501'; end if;
   if coalesce(old_booking.version,0)<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
   before_data:=case when old_booking.id is not null then splav.ops_reservation_json(old_booking) end;
   k:=p_payload->>'kind'; resource_id:=(p_payload->>'resource_id')::uuid;
   select * into resource from splav.ops_resources where id=resource_id and team_id=p_team_id;
   if not found then raise exception 'Resource access denied' using errcode='42501'; end if;
   if k is null or not ((k='boat' and resource.kind='boat') or (k='ride' and resource.kind='vehicle') or (k='duty' and resource.kind='employee')) then
    raise exception 'Invalid reservation type' using errcode='22023'; end if;
   if old_booking.id is not null and old_booking.kind<>k then raise exception 'Invalid reservation type change' using errcode='22023'; end if;
   active:=coalesce((p_payload->>'active')::boolean,true);
   if active and not (resource.data->>'available')::boolean then raise exception 'resource_unavailable' using errcode='P0001'; end if;
   begin_at:=(p_payload->>'starts_at')::timestamptz; end_at:=(p_payload->>'ends_at')::timestamptz;
   prep:=coalesce((p_payload->>'prep_minutes')::integer,0); tail:=coalesce((p_payload->>'return_minutes')::integer,0);
   cap:=(p_payload->>'capacity')::integer;
   if k='boat' then begin_at:=g.starts_at;end_at:=g.ends_at;prep:=0;tail:=0;end if;
   if identifier is null or begin_at is null or end_at is null or not isfinite(begin_at) or not isfinite(end_at) or begin_at>=end_at
    or prep not between 0 and 10080 or tail not between 0 and 10080 or cap is null or cap not between 1 and 100
    or char_length(coalesce(p_payload->>'notes',''))>2000 then raise exception 'Invalid reservation fields' using errcode='22023'; end if;
   if k='duty' and active and exists(select 1 from splav.people p cross join lateral jsonb_array_elements(p.work_schedule) shift where p.id::text=resource.data->>'person_id' and (shift->>'starts_at')::timestamptz<end_at+make_interval(mins=>tail) and (shift->>'ends_at')::timestamptz>begin_at-make_interval(mins=>prep)) then raise exception 'work_schedule_overlap' using errcode='P0001';end if;
   if k='boat' and not ((resource.data->>'planned'='true' and cap between 2 and (resource.data->>'capacity')::integer) or case resource.data->>'model' when 'big' then cap in (3,4) when 'rf' then cap in (2,3)
      when 'maigun' then cap=2 else cap between 2 and (resource.data->>'capacity')::integer end) then
    raise exception 'Invalid boat configuration' using errcode='22023'; end if;
   direction:=p_payload->>'direction'; role_value:=p_payload->>'role';
   if k='ride' then
    if direction is null or direction not in ('outbound','return') or cap>(resource.data->>'capacity')::integer or
      (resource.data->>'model'='secondary_bus' and cap not in (16,17,19,20)) or
      jsonb_typeof(p_payload->'points') is distinct from 'array' or jsonb_array_length(p_payload->'points') not between 1 and 30 then
      raise exception 'Invalid ride fields' using errcode='22023'; end if;
    if (select count(distinct value->>'id') from jsonb_array_elements(p_payload->'points'))<>jsonb_array_length(p_payload->'points') then
      raise exception 'Duplicate boarding points' using errcode='22023'; end if;
    for item in select value from jsonb_array_elements(p_payload->'points') loop
     if nullif(btrim(item->>'id'),'') is null or nullif(btrim(item->>'name'),'') is null or char_length(item->>'name')>300
      or char_length(item->>'id')>60 then raise exception 'Invalid boarding point' using errcode='22023'; end if;
    end loop;
    if nullif(p_payload->>'responsible_id','') is not null and not exists(select 1 from splav.ops_resources where
      id=(p_payload->>'responsible_id')::uuid and team_id=p_team_id and kind='employee') then
      raise exception 'Responsible employee access denied' using errcode='42501'; end if;
   end if;
   if k='duty' and (cap<>1 or role_value is null or not (resource.data->'roles' ? role_value)) then
    raise exception 'employee_role' using errcode='P0001'; end if;
   if active and exists(select 1 from splav.ops_reservations r join splav.groups other on other.id=r.group_id
     where r.resource_id=resource_id and r.id<>identifier and r.active and other.status<>'cancelled'
       and r.busy_start<end_at+tail*interval '1 minute' and begin_at-prep*interval '1 minute'<r.busy_end) then
     raise exception 'resource_overlap' using errcode='P0001'; end if;
   if exists(select 1 from splav.ops_crews c join splav.registrations r on r.id=c.registration_id and r.group_id=c.group_id where c.reservation_id=identifier
     and not splav.ops_check_seat(resource.data,cap,c.seat,r.parameters)) then raise exception 'seat_restriction' using errcode='P0001'; end if;
   if exists(select 1 from splav.ops_travel t where t.reservation_id=identifier and
     (t.seat>cap or (old_booking.data->>'direction' is distinct from direction) or not exists
      (select 1 from jsonb_array_elements(p_payload->'points') x where x->>'id'=t.point_id))) then
     raise exception 'passengers_assigned' using errcode='P0001'; end if;
   after_data:=jsonb_build_object('direction',direction,'points',coalesce(p_payload->'points','[]'::jsonb),
    'role',role_value,'responsible_id',nullif(p_payload->>'responsible_id',''),'prep_minutes',prep,'return_minutes',tail,'notes',coalesce(p_payload->>'notes',''));
   insert into splav.ops_reservations(id,team_id,group_id,resource_id,kind,starts_at,ends_at,busy_start,busy_end,capacity,active,data,version,author_id)
    values(identifier,p_team_id,p_trip_id,resource_id,k,begin_at,end_at,begin_at-prep*interval '1 minute',end_at+tail*interval '1 minute',cap,active,after_data,p_expected_version+1,caller)
    on conflict(id) do update set resource_id=excluded.resource_id,starts_at=excluded.starts_at,ends_at=excluded.ends_at,busy_start=excluded.busy_start,
      busy_end=excluded.busy_end,capacity=excluded.capacity,active=excluded.active,data=excluded.data,version=excluded.version,author_id=caller,updated_at=now();
   if not active then
    update splav.ops_crews set reservation_id=null,seat=null,version=version+1,author_id=caller,updated_at=now() where reservation_id=identifier;
    update splav.ops_travel set mode='unset',reservation_id=null,seat=null,point_id=null,version=version+1,author_id=caller,updated_at=now() where reservation_id=identifier;
   end if;
  elsif p_kind in ('ops_crew','ops_travel') then
   subject_kind:=coalesce(p_payload->>'subject_kind','participant'); subject_id:=(p_payload->>'subject_id')::uuid;
   if subject_kind='participant' then
    select * into registration from splav.registrations where id=subject_id and group_id=p_trip_id;
    if not found then raise exception 'Participation access denied' using errcode='42501'; end if;
   elsif subject_kind='employee' and p_kind='ops_travel' then
    if not exists(select 1 from splav.ops_resources where id=subject_id and team_id=p_team_id and kind='employee') then
     raise exception 'Employee access denied' using errcode='42501'; end if;
   else raise exception 'Invalid subject' using errcode='22023'; end if;
   if p_kind='ops_travel' and coalesce(p_payload->>'mode','unset')<>'unset' and
     ((subject_kind='participant' and registration.role='instructor') or (subject_kind='employee' and exists(select 1 from splav.registrations ir join splav.ops_resources er on er.data->>'person_id'=ir.person_id::text where er.id=subject_id and ir.group_id=p_trip_id and ir.role='instructor' and ir.status<>'cancelled'))) then raise exception 'instructor_transport_excluded' using errcode='P0001';end if;
   identifier:=nullif(p_payload->>'reservation_id','')::uuid; chosen_seat:=(p_payload->>'seat')::integer;
   if identifier is not null then
    select * into booking from splav.ops_reservations r where r.id=identifier and r.group_id=p_trip_id and r.active;
    if not found or booking.kind<>(case when p_kind='ops_crew' then 'boat' else 'ride' end) then
     raise exception 'reservation_unavailable' using errcode='P0001'; end if;
    if subject_kind='participant' and registration.status<>'confirmed' then raise exception 'participation_not_confirmed' using errcode='P0001'; end if;
    if chosen_seat is null or chosen_seat not between 1 and booking.capacity then raise exception 'Invalid seat' using errcode='22023'; end if;
    if exists(select 1 from splav.ops_latest_presence(p_trip_id) f where f.reservation_id=identifier and f.present and f.seat=chosen_seat
      and (f.subject_kind<>subject_kind or f.subject_id<>subject_id)) then raise exception 'physical_seat_occupied' using errcode='P0001'; end if;
   end if;
   if p_kind='ops_crew' then
    select * into old_crew from splav.ops_crews where registration_id=subject_id and group_id=p_trip_id;
    if coalesce(old_crew.version,0)<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
    before_data:=to_jsonb(old_crew);
    if identifier is not null then
     select * into resource from splav.ops_resources where id=booking.resource_id;
     if not splav.ops_check_seat(resource.data,booking.capacity,chosen_seat,registration.parameters) then
      raise exception 'seat_restriction' using errcode='P0001'; end if;
     select * into swap_crew from splav.ops_crews where reservation_id=identifier and seat=chosen_seat and registration_id<>subject_id;
     if found then
      if nullif(p_payload->>'swap_id','')::uuid is distinct from swap_crew.registration_id or
         (p_payload->>'swap_version')::bigint is distinct from swap_crew.version or old_crew.reservation_id is null then
       raise exception 'seat_occupied' using errcode='P0001'; end if;
      select * into source_booking from splav.ops_reservations src where src.id=old_crew.reservation_id and src.active and src.group_id=p_trip_id;
      if not found then raise exception 'reservation_unavailable' using errcode='P0001'; end if;
      select * into swap_registration from splav.registrations where id=swap_crew.registration_id and group_id=p_trip_id;
      select * into resource from splav.ops_resources where id=source_booking.resource_id;
      if swap_registration.status<>'confirmed' or not splav.ops_check_seat(resource.data,source_booking.capacity,old_crew.seat,swap_registration.parameters) then
       raise exception 'seat_restriction' using errcode='P0001'; end if;
      if exists(select 1 from splav.ops_latest_presence(p_trip_id) f where f.present and
        ((f.reservation_id=old_crew.reservation_id and f.seat=old_crew.seat) or (f.reservation_id=identifier and f.seat=chosen_seat))) then
       raise exception 'physical_seat_occupied' using errcode='P0001'; end if;
      before_data:=jsonb_build_object('source',to_jsonb(old_crew),'target',to_jsonb(swap_crew));
      update splav.ops_crews set reservation_id=null,seat=null where registration_id=subject_id and group_id=p_trip_id;
      update splav.ops_crews set reservation_id=old_crew.reservation_id,seat=old_crew.seat,version=version+1,author_id=caller,updated_at=now()
        where registration_id=swap_crew.registration_id and group_id=p_trip_id;
     elsif p_payload->>'swap_id' is not null then raise exception 'version_conflict' using errcode='P0001';
     end if;
    end if;
    insert into splav.ops_crews values(subject_id,p_trip_id,identifier,case when identifier is not null then chosen_seat end,p_expected_version+1,caller,now())
     on conflict(group_id,registration_id) do update set reservation_id=excluded.reservation_id,seat=excluded.seat,version=excluded.version,author_id=caller,updated_at=now();
   else
    direction:=p_payload->>'direction'; mode:=p_payload->>'mode'; point:=p_payload->>'point_id';
    if direction is null or direction not in ('outbound','return') or mode is null or mode not in ('self','bus','unset') then
     raise exception 'Invalid travel fields' using errcode='22023'; end if;
    select * into old_travel from splav.ops_travel where group_id=p_trip_id and ops_travel.subject_kind=subject_kind
      and ops_travel.subject_id=subject_id and ops_travel.direction=direction;
    if coalesce(old_travel.version,0)<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
    if old_travel.id is not null and nullif(p_payload->>'id','')::uuid<>old_travel.id then raise exception 'Invalid travel ID' using errcode='22023'; end if;
    before_data:=to_jsonb(old_travel);
    if mode='bus' then
     if identifier is null or booking.data->>'direction'<>direction or not exists(select 1 from jsonb_array_elements(booking.data->'points') x where x->>'id'=point) then
      raise exception 'Invalid ride or point' using errcode='22023'; end if;
     if exists(select 1 from splav.ops_travel t where t.reservation_id=identifier and t.seat=chosen_seat
       and (t.subject_kind<>subject_kind or t.subject_id<>subject_id)) then raise exception 'seat_occupied' using errcode='P0001'; end if;
     person:=splav.ops_subject_person(subject_kind,subject_id,p_trip_id);
     if person is not null and exists(select 1 from splav.ops_travel t where t.group_id=p_trip_id and t.direction=direction and t.mode='bus'
       and (t.subject_kind<>subject_kind or t.subject_id<>subject_id) and splav.ops_subject_person(t.subject_kind,t.subject_id,p_trip_id)=person) then
      raise exception 'duplicate_person' using errcode='P0001'; end if;
    elsif identifier is not null then raise exception 'Self travel cannot reserve a seat' using errcode='22023'; end if;
    insert into splav.ops_travel values(coalesce(old_travel.id,(p_payload->>'id')::uuid),p_trip_id,subject_kind,subject_id,direction,mode,
      identifier,case when mode='bus' then chosen_seat end,case when mode='bus' then point end,p_expected_version+1,caller,now())
     on conflict on constraint ops_travel_subject_key do update set mode=excluded.mode,reservation_id=excluded.reservation_id,
       seat=excluded.seat,point_id=excluded.point_id,version=excluded.version,author_id=caller,updated_at=now();
   end if;
  elsif p_kind='ops_presence' then
   identifier:=(p_payload->>'id')::uuid; subject_kind:=p_payload->>'subject_kind'; subject_id:=(p_payload->>'subject_id')::uuid;
   select * into booking from splav.ops_reservations where id=(p_payload->>'reservation_id')::uuid and group_id=p_trip_id and kind in ('boat','ride');
   if not found then raise exception 'Reservation access denied' using errcode='42501'; end if;
   if jsonb_typeof(p_payload->'present') is distinct from 'boolean' or nullif(btrim(p_payload->>'device_id'),'') is null
    or char_length(p_payload->>'device_id')>200 or nullif(p_payload->>'occurred_at','') is null or not isfinite((p_payload->>'occurred_at')::timestamptz)
    or char_length(coalesce(p_payload->>'reason',''))>2000 then raise exception 'Invalid presence fields' using errcode='22023'; end if;
   select * into fact from splav.ops_presence f where f.group_id=p_trip_id and f.reservation_id=booking.id and f.subject_kind=subject_kind and f.subject_id=subject_id order by sequence desc limit 1;
   if fact.id is distinct from nullif(p_payload->>'previous_id','')::uuid then raise exception 'version_conflict' using errcode='P0001'; end if;
   chosen_seat:=null;
   if (p_payload->>'present')::boolean then
    if not booking.active or g.status in ('completed','cancelled') then raise exception 'reservation_unavailable' using errcode='P0001'; end if;
    if subject_kind='participant' and not exists(select 1 from splav.registrations where id=subject_id and group_id=p_trip_id and status='confirmed') then
     raise exception 'participation_not_confirmed' using errcode='P0001'; end if;
    if booking.kind='boat' then select seat into chosen_seat from splav.ops_crews where registration_id=subject_id and group_id=p_trip_id and reservation_id=booking.id and subject_kind='participant';
    else select seat into chosen_seat from splav.ops_travel t where t.reservation_id=booking.id and t.subject_kind=subject_kind and t.subject_id=subject_id and t.mode='bus'; end if;
    if chosen_seat is null then raise exception 'passenger_not_assigned' using errcode='P0001'; end if;
    if exists(select 1 from splav.ops_latest_presence(p_trip_id) f where f.reservation_id=booking.id and f.present and f.seat=chosen_seat
     and (f.subject_kind<>subject_kind or f.subject_id<>subject_id)) then raise exception 'physical_seat_occupied' using errcode='P0001'; end if;
   else
    if fact.id is null then raise exception 'presence_missing' using errcode='P0001'; end if;
    chosen_seat:=fact.seat;
   end if;
   insert into splav.ops_presence(id,group_id,reservation_id,subject_kind,subject_id,present,seat,reason,device_id,occurred_at,author_id)
    values(identifier,p_trip_id,booking.id,subject_kind,subject_id,(p_payload->>'present')::boolean,chosen_seat,coalesce(p_payload->>'reason',''),p_payload->>'device_id',(p_payload->>'occurred_at')::timestamptz,caller);
  elsif p_kind='ops_resolve' then
   select * into fact from splav.ops_latest_presence(p_trip_id) where id=(p_payload->>'fact_id')::uuid;
   if not found then raise exception 'version_conflict' using errcode='P0001'; end if;
   signature:=splav.ops_signature(fact);
   if signature is distinct from p_payload->>'signature' then raise exception 'version_conflict' using errcode='P0001'; end if;
   if nullif(btrim(p_payload->>'reason'),'') is null or char_length(p_payload->>'reason')>2000 or
      p_payload->>'decision' is null or p_payload->>'decision' not in ('keep','error') then raise exception 'Reason required' using errcode='22023'; end if;
   insert into splav.ops_resolutions values(identifier,p_trip_id,fact.id,signature,p_payload->>'decision',p_payload->>'reason',caller,clock_timestamp());
   if p_payload->>'decision'='error' then
    insert into splav.ops_presence(id,group_id,reservation_id,subject_kind,subject_id,present,seat,reason,device_id,occurred_at,author_id)
     values((p_payload->>'correction_id')::uuid,p_trip_id,fact.reservation_id,fact.subject_kind,fact.subject_id,false,fact.seat,p_payload->>'reason',
       coalesce(p_payload->>'device_id','resolution'),clock_timestamp(),caller);
   end if;
  end if;
  insert into splav.ops_history(group_id,kind,entity_id,before_data,after_data,reason,author_id)
    values(p_trip_id,p_kind,identifier,before_data,p_payload,coalesce(p_payload->>'reason',''),caller);
 exception when sqlstate 'P0001' then reason:=sqlerrm;
 when unique_violation then reason:='duplicate_or_occupied';
 end;
 if reason is null then
  update splav.teams set people_revision=people_revision+1 where id=p_team_id returning people_revision into revision;
  update splav.groups set roster_revision=roster_revision+1 where id=p_trip_id;
  result:=jsonb_build_object('status','accepted','revision',revision);
 else result:=jsonb_build_object('status','rejected','reason',reason); end if;
 insert into splav.people_receipts(operation_id,user_id,team_id,group_id,payload,result) values(p_operation_id,caller,p_team_id,p_trip_id,envelope,result);
 return result;
end $$;
notify pgrst,'reload schema';

