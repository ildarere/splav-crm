-- Stages 4 and 5. All operations retain the established durable command UUIDs,
-- receipts and team revision cursor. No existing ledger or queue is replaced.
create table splav.ops_resources (
  id uuid primary key, team_id uuid not null references splav.teams(id),
  kind text not null check(kind in ('boat','vehicle','employee')),
  data jsonb not null, version bigint not null default 1,
  author_id uuid not null references auth.users(id), updated_at timestamptz not null default now()
);
create unique index ops_resource_code on splav.ops_resources(team_id,kind,(data->>'code'));
create table splav.ops_setup (
  team_id uuid primary key references splav.teams(id), data jsonb not null,
  author_id uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table splav.ops_reservations (
  id uuid primary key, team_id uuid not null references splav.teams(id), group_id uuid not null references splav.groups(id),
  resource_id uuid not null references splav.ops_resources(id), kind text not null check(kind in ('boat','ride','duty')),
  starts_at timestamptz not null, ends_at timestamptz not null, busy_start timestamptz not null, busy_end timestamptz not null,
  capacity integer not null check(capacity between 1 and 100), active boolean not null default true,
  data jsonb not null, version bigint not null default 1, author_id uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  check(isfinite(starts_at) and isfinite(ends_at) and busy_start<=starts_at and starts_at<ends_at and ends_at<=busy_end)
);
create index ops_resource_intervals on splav.ops_reservations(resource_id,busy_start,busy_end) where active;
create table splav.ops_crews (
  registration_id uuid not null, group_id uuid not null references splav.groups(id),
  reservation_id uuid references splav.ops_reservations(id), seat integer,
  version bigint not null default 1, author_id uuid not null references auth.users(id), updated_at timestamptz not null default now(),
  check((reservation_id is null and seat is null) or (reservation_id is not null and seat between 1 and 4)),
  primary key(group_id,registration_id), foreign key(group_id,registration_id) references splav.registrations(group_id,id),
  unique(reservation_id,seat)
);
create table splav.ops_travel (
  id uuid primary key, group_id uuid not null references splav.groups(id),
  subject_kind text not null check(subject_kind in ('participant','employee')), subject_id uuid not null,
  direction text not null check(direction in ('outbound','return')),
  mode text not null check(mode in ('bus','self','unset')), reservation_id uuid references splav.ops_reservations(id),
  seat integer, point_id text, version bigint not null default 1,
  author_id uuid not null references auth.users(id), updated_at timestamptz not null default now(),
  constraint ops_travel_subject_key unique(group_id,subject_kind,subject_id,direction), unique(reservation_id,seat),
  check((mode='bus' and reservation_id is not null and seat between 1 and 100 and point_id is not null)
    or (mode<>'bus' and reservation_id is null and seat is null))
);
create table splav.ops_presence (
  id uuid primary key, group_id uuid not null references splav.groups(id), reservation_id uuid not null references splav.ops_reservations(id),
  subject_kind text not null check(subject_kind in ('participant','employee')), subject_id uuid not null,
  present boolean not null, seat integer, reason text not null default '',
  device_id text not null, occurred_at timestamptz not null, author_id uuid not null references auth.users(id),
  created_at timestamptz not null default clock_timestamp(), sequence bigint generated always as identity unique
);
create table splav.ops_resolutions (
  id uuid primary key, group_id uuid not null references splav.groups(id), fact_id uuid not null references splav.ops_presence(id),
  signature text not null, decision text not null check(decision in ('keep','error')), reason text not null,
  author_id uuid not null references auth.users(id), created_at timestamptz not null default clock_timestamp()
);
create table splav.ops_settings (
  group_id uuid primary key references splav.groups(id), many_children boolean not null default false,
  notes text not null default '', version bigint not null default 1, author_id uuid not null references auth.users(id)
);
create table splav.ops_history (
  id bigint generated always as identity primary key, group_id uuid not null references splav.groups(id),
  kind text not null, entity_id uuid, before_data jsonb, after_data jsonb, reason text not null default '',
  author_id uuid, created_at timestamptz not null default clock_timestamp()
);
create function splav.ops_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Operational facts are append-only' using errcode='22023'; end $$;
create trigger ops_presence_immutable before update or delete on splav.ops_presence for each row execute function splav.ops_immutable();
create trigger ops_resolutions_immutable before update or delete on splav.ops_resolutions for each row execute function splav.ops_immutable();
create trigger ops_history_immutable before update or delete on splav.ops_history for each row execute function splav.ops_immutable();

create function splav.ops_resource_json(r splav.ops_resources) returns jsonb language sql immutable set search_path='' as $$
 select r.data||jsonb_build_object('id',r.id,'team_id',r.team_id,'kind',r.kind,'version',r.version);
$$;
create function splav.ops_reservation_json(r splav.ops_reservations) returns jsonb language sql immutable set search_path='' as $$
 select r.data||jsonb_build_object('id',r.id,'trip_id',r.group_id,'resource_id',r.resource_id,'kind',r.kind,
 'starts_at',r.starts_at,'ends_at',r.ends_at,'busy_start',r.busy_start,'busy_end',r.busy_end,
 'capacity',r.capacity,'active',r.active,'version',r.version);
$$;
create function splav.ops_check_seat(p_resource jsonb,p_capacity integer,p_seat integer,p_parameters jsonb) returns boolean
language sql immutable set search_path='' as $$
 select p_seat between 1 and p_capacity and case
 when p_resource->>'model'='big' and p_capacity=4 and p_seat=4 then
   coalesce((p_parameters->>'height_cm')::numeric>0 and (p_parameters->>'height_cm')::numeric<=130
     and (p_parameters->>'age_years')::numeric>=0 and (p_parameters->>'age_years')::numeric<18,false)
 when p_resource->>'model'='rf' and p_seat=3 then
   coalesce((p_parameters->>'height_cm')::numeric>0 and (p_parameters->>'height_cm')::numeric<=155
     and (p_parameters->>'weight_kg')::numeric>0 and (p_parameters->>'weight_kg')::numeric<=50,false)
 else true end;
$$;
create function splav.ops_subject_person(p_kind text,p_id uuid,p_trip uuid) returns uuid language plpgsql stable set search_path='' as $$
declare person uuid;
begin
 if p_kind='participant' then select person_id into person from splav.registrations where id=p_id and group_id=p_trip;
 elsif p_kind='employee' then select nullif(data->>'person_id','')::uuid into person from splav.ops_resources
   where id=p_id and kind='employee' and team_id=(select team_id from splav.groups where id=p_trip);
 else raise exception 'Invalid passenger kind' using errcode='22023'; end if;
 return person;
end $$;
create function splav.ops_latest_presence(p_trip uuid) returns setof splav.ops_presence language sql stable set search_path='' as $$
 select distinct on (reservation_id,subject_kind,subject_id) * from splav.ops_presence
 where group_id=p_trip order by reservation_id,subject_kind,subject_id,sequence desc;
$$;
create function splav.ops_signature(f splav.ops_presence) returns text language sql stable set search_path='' as $$
 select f.id::text||'|'||coalesce((select status||':'||version from splav.registrations where id=f.subject_id and group_id=f.group_id and f.subject_kind='participant'),'employee')
 ||'|'||coalesce((select mode||':'||version||':'||coalesce(reservation_id::text,'') from splav.ops_travel
 where group_id=f.group_id and subject_kind=f.subject_kind and subject_id=f.subject_id
 and direction=(select data->>'direction' from splav.ops_reservations where id=f.reservation_id)),'none')
 ||'|'||coalesce((select coalesce(reservation_id::text,'')||':'||version from splav.ops_crews where registration_id=f.subject_id and group_id=f.group_id),'none')
 ||'|'||(select active::text||':'||version from splav.ops_reservations where id=f.reservation_id);
$$;
create function splav.ops_issues(p_trip uuid) returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('fact_id',f.id,'reservation_id',f.reservation_id,'subject_kind',f.subject_kind,
 'subject_id',f.subject_id,'seat',f.seat,'signature',splav.ops_signature(f),'reason','presence_plan_mismatch') order by f.sequence),'[]'::jsonb)
 from splav.ops_latest_presence(p_trip) f join splav.ops_reservations b on b.id=f.reservation_id
 where f.present and (not b.active or
  (f.subject_kind='participant' and not exists(select 1 from splav.registrations r where r.id=f.subject_id and r.group_id=p_trip and r.status='confirmed')) or
  (b.kind='ride' and not exists(select 1 from splav.ops_travel t where t.subject_id=f.subject_id and t.subject_kind=f.subject_kind
    and t.group_id=p_trip and t.reservation_id=b.id and t.mode='bus' and t.seat=f.seat)) or
  (b.kind='boat' and not exists(select 1 from splav.ops_crews c where c.registration_id=f.subject_id and c.reservation_id=b.id and c.seat=f.seat)))
 and not exists(select 1 from splav.ops_resolutions r where r.fact_id=f.id and r.signature=splav.ops_signature(f));
$$;

create function splav.ops_save_resource(p_team uuid,p_item jsonb) returns void language plpgsql set search_path='' as $$
declare old splav.ops_resources%rowtype; identifier uuid:=(p_item->>'id')::uuid; properties jsonb; k text:=p_item->>'kind';
 v bigint:=coalesce((p_item->>'version')::bigint,0); cap integer; role_item text;
begin
 if identifier is null or k is null or k not in ('boat','vehicle','employee') or nullif(btrim(p_item->>'name'),'') is null
 or char_length(p_item->>'name')>150 or nullif(btrim(p_item->>'code'),'') is null or char_length(p_item->>'code')>60
 or char_length(coalesce(p_item->>'notes',''))>2000 or (p_item ? 'available' and jsonb_typeof(p_item->'available')<>'boolean') then
 raise exception 'Invalid resource fields' using errcode='22023'; end if;
 select * into old from splav.ops_resources where id=identifier;
 if found and (old.team_id<>p_team or old.kind<>k) then raise exception 'Resource access denied' using errcode='42501'; end if;
 if coalesce(old.version,0)<>v then raise exception 'version_conflict' using errcode='P0001'; end if;
 cap:=coalesce((p_item->>'capacity')::integer,0);
 if k='boat' and (p_item->>'model' is null or p_item->>'model' not in ('big','rf','maigun','custom') or cap not between 2 and 4) then
 raise exception 'Invalid boat' using errcode='22023'; end if;
 if k='vehicle' and cap not between 1 and 100 then raise exception 'Invalid vehicle capacity' using errcode='22023'; end if;
 if k='boat' and ((p_item->>'model'='big' and cap<>4) or (p_item->>'model'='rf' and cap<>3) or (p_item->>'model'='maigun' and cap<>2)) then
  raise exception 'Invalid boat model capacity' using errcode='22023'; end if;
 if k='employee' then
  if jsonb_typeof(p_item->'roles') is distinct from 'array' or jsonb_array_length(p_item->'roles')=0 then
   raise exception 'Employee roles required' using errcode='22023'; end if;
  for role_item in select jsonb_array_elements_text(p_item->'roles') loop
   if role_item not in ('warehouse','camp_kitchen','relief','uaz_driver','trip_cook','water_instructor','camp_worker') then
    raise exception 'Invalid employee role' using errcode='22023'; end if;
  end loop;
  if nullif(p_item->>'person_id','') is not null and not exists(select 1 from splav.people where id=(p_item->>'person_id')::uuid and team_id=p_team) then
   raise exception 'Person access denied' using errcode='42501'; end if;
 end if;
 properties:=jsonb_build_object('name',btrim(p_item->>'name'),'code',btrim(p_item->>'code'),'model',coalesce(p_item->>'model','custom'),
  'capacity',cap,'available',coalesce((p_item->>'available')::boolean,true),'roles',coalesce(p_item->'roles','[]'::jsonb),
  'person_id',nullif(p_item->>'person_id',''),'notes',coalesce(p_item->>'notes',''));
 if old.id is not null and exists(select 1 from splav.ops_reservations where resource_id=identifier and active) and
  (old.data->>'model' is distinct from properties->>'model' or (k<>'employee' and (old.data->>'capacity')::integer<>cap)
   or (k='employee' and (old.data->'roles'<>properties->'roles' or old.data->'person_id' is distinct from properties->'person_id'))) then
   raise exception 'resource_in_use' using errcode='P0001'; end if;
 insert into splav.ops_resources(id,team_id,kind,data,version,author_id) values(identifier,p_team,k,properties,v+1,auth.uid())
 on conflict(id) do update set data=excluded.data,version=excluded.version,author_id=excluded.author_id,updated_at=now();
end $$;

alter function public.people_command(uuid,uuid,uuid,text,jsonb,bigint) set schema splav;
alter function splav.people_command(uuid,uuid,uuid,text,jsonb,bigint) rename to people_command_v3;
create function public.people_command(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,p_kind text,p_payload jsonb,p_expected_version bigint default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare caller uuid:=auth.uid(); envelope jsonb; receipt splav.people_receipts%rowtype; g splav.groups%rowtype;
 resource splav.ops_resources%rowtype; booking splav.ops_reservations%rowtype; old_booking splav.ops_reservations%rowtype;
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
   if identifier is null or begin_at is null or end_at is null or not isfinite(begin_at) or not isfinite(end_at) or begin_at>=end_at
    or prep not between 0 and 10080 or tail not between 0 and 10080 or cap is null or cap not between 1 and 100
    or char_length(coalesce(p_payload->>'notes',''))>2000 then raise exception 'Invalid reservation fields' using errcode='22023'; end if;
   if k='boat' and not (case resource.data->>'model' when 'big' then cap in (3,4) when 'rf' then cap in (2,3)
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
   identifier:=nullif(p_payload->>'reservation_id','')::uuid; chosen_seat:=(p_payload->>'seat')::integer;
   if identifier is not null then
    select * into booking from splav.ops_reservations where id=identifier and group_id=p_trip_id and active;
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
     if exists(select 1 from splav.ops_crews where reservation_id=identifier and seat=chosen_seat and registration_id<>subject_id) then
      raise exception 'seat_occupied' using errcode='P0001'; end if;
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

-- Cancellation frees the plan, retaining immutable boarding/water facts. A change
-- of measurements can also invalidate a conditional extra seat.
create function splav.ops_participation_changed() returns trigger language plpgsql set search_path='' as $$
begin
 if new.status<>'confirmed' then
  update splav.ops_crews set reservation_id=null,seat=null,version=version+1,author_id=coalesce(auth.uid(),author_id),updated_at=now()
    where registration_id=new.id and group_id=new.group_id and reservation_id is not null;
  update splav.ops_travel set mode='unset',reservation_id=null,seat=null,point_id=null,version=version+1,author_id=coalesce(auth.uid(),author_id),updated_at=now()
    where subject_kind='participant' and subject_id=new.id and group_id=new.group_id and mode<>'unset';
 elsif new.parameters is distinct from old.parameters then
  update splav.ops_crews c set reservation_id=null,seat=null,version=version+1,author_id=coalesce(auth.uid(),c.author_id),updated_at=now()
    from splav.ops_reservations b join splav.ops_resources r on r.id=b.resource_id
    where c.registration_id=new.id and c.group_id=new.group_id and c.reservation_id=b.id and not splav.ops_check_seat(r.data,b.capacity,c.seat,new.parameters);
 end if;
 return new;
end $$;
create trigger ops_participation_changed after update of status,parameters on splav.registrations for each row execute function splav.ops_participation_changed();
create function splav.ops_trip_changed() returns trigger language plpgsql set search_path='' as $$
begin
 if new.status='cancelled' and old.status<>'cancelled' then
  update splav.ops_crews c set reservation_id=null,seat=null,version=version+1,updated_at=now() where c.group_id=new.id and reservation_id is not null;
  update splav.ops_travel set mode='unset',reservation_id=null,seat=null,point_id=null,version=version+1,updated_at=now() where group_id=new.id and mode<>'unset';
  update splav.ops_reservations set active=false,version=version+1,updated_at=now() where group_id=new.id and active;
 end if;
 if (new.starts_at,new.ends_at,new.status) is distinct from (old.starts_at,old.ends_at,old.status) then
  update splav.teams set people_revision=people_revision+1 where id=new.team_id;
 end if;
 return new;
end $$;
create trigger ops_trip_changed after update of starts_at,ends_at,status on splav.groups for each row execute function splav.ops_trip_changed();
-- Keep a single lock order for metadata and resource commands.
alter function public.save_trip(uuid,uuid,uuid,bigint,jsonb) set schema splav;
alter function splav.save_trip(uuid,uuid,uuid,bigint,jsonb) rename to save_trip_v3;
create function public.save_trip(p_operation_id uuid,p_team_id uuid,p_trip_id uuid,p_expected_version bigint,p_trip jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform 1 from splav.team_members where team_id=p_team_id and user_id=auth.uid() for share;
 if not found then raise exception 'Team access denied' using errcode='42501'; end if;
 perform 1 from splav.teams where id=p_team_id for update;
 return splav.save_trip_v3(p_operation_id,p_team_id,p_trip_id,p_expected_version,p_trip);
end $$;

alter function public.roster_snapshot(uuid,bigint) set schema splav;
alter function splav.roster_snapshot(uuid,bigint) rename to roster_snapshot_v3;
create function public.roster_snapshot(p_trip_id uuid,p_after_revision bigint default -1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; team uuid;
begin
 result:=splav.roster_snapshot_v3(p_trip_id,p_after_revision);
 if result->>'unchanged'='true' then return result; end if;
 select team_id into team from splav.groups where id=p_trip_id;
 return result||jsonb_build_object('operations_protocol',1,'operations',jsonb_build_object(
  'setup',(select data from splav.ops_setup where team_id=team),
  'resources',coalesce((select jsonb_agg(splav.ops_resource_json(r) order by r.kind,r.data->>'code',r.id) from splav.ops_resources r where team_id=team),'[]'::jsonb),
  'reservations',coalesce((select jsonb_agg(splav.ops_reservation_json(r) order by r.starts_at,r.id) from splav.ops_reservations r where group_id=p_trip_id),'[]'::jsonb),
  -- Busy windows contain no contacts, manifests or titles of other trips.
  'busy',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'resource_id',r.resource_id,'starts_at',r.busy_start,'ends_at',r.busy_end))
    from splav.ops_reservations r join splav.groups g on g.id=r.group_id where r.team_id=team and r.group_id<>p_trip_id and r.active and g.status<>'cancelled'),'[]'::jsonb),
  'crews',coalesce((select jsonb_agg(to_jsonb(c)) from splav.ops_crews c where group_id=p_trip_id),'[]'::jsonb),
  'travel',coalesce((select jsonb_agg(to_jsonb(t)) from splav.ops_travel t where group_id=p_trip_id),'[]'::jsonb),
  'presence',coalesce((select jsonb_agg(to_jsonb(f) order by sequence) from splav.ops_presence f where group_id=p_trip_id),'[]'::jsonb),
  'resolutions',coalesce((select jsonb_agg(to_jsonb(r) order by created_at) from splav.ops_resolutions r where group_id=p_trip_id),'[]'::jsonb),
  'settings',coalesce((select to_jsonb(s) from splav.ops_settings s where group_id=p_trip_id),'{}'::jsonb),
  'history',coalesce((select jsonb_agg(to_jsonb(h) order by id) from splav.ops_history h where group_id=p_trip_id),'[]'::jsonb),
  'issues',splav.ops_issues(p_trip_id)));
end $$;
revoke all on all tables in schema splav from public,anon,authenticated;
revoke all on all sequences in schema splav from public,anon,authenticated;
revoke all on function splav.people_command_v3(uuid,uuid,uuid,text,jsonb,bigint),splav.roster_snapshot_v3(uuid,bigint),
 splav.save_trip_v3(uuid,uuid,uuid,bigint,jsonb),splav.ops_immutable(),splav.ops_resource_json(splav.ops_resources),
 splav.ops_reservation_json(splav.ops_reservations),splav.ops_check_seat(jsonb,integer,integer,jsonb),splav.ops_subject_person(text,uuid,uuid),
 splav.ops_latest_presence(uuid),splav.ops_signature(splav.ops_presence),splav.ops_issues(uuid),splav.ops_save_resource(uuid,jsonb),
 splav.ops_participation_changed(),splav.ops_trip_changed() from public,anon,authenticated;
revoke all on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint),public.roster_snapshot(uuid,bigint),public.save_trip(uuid,uuid,uuid,bigint,jsonb) from public,anon;
grant execute on function public.people_command(uuid,uuid,uuid,text,jsonb,bigint),public.roster_snapshot(uuid,bigint),public.save_trip(uuid,uuid,uuid,bigint,jsonb) to authenticated;
update splav.teams set people_revision=people_revision+1;
notify pgrst,'reload schema';
