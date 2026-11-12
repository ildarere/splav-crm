-- Historical imports preserve provenance and distinguish missing source values.
alter table splav.groups add column import_metadata jsonb not null default '{}';
alter table splav.registrations add column import_metadata jsonb not null default '{}';
alter table splav.payments add column source_date_unknown boolean not null default false;
create table splav.excel_import_batches (
 id uuid primary key,team_id uuid not null references splav.teams(id),author_id uuid not null references auth.users(id),
 payload_hash text not null,files jsonb not null,result jsonb not null,created_at timestamptz not null default now()
);
create table splav.excel_import_records (
 batch_id uuid not null references splav.excel_import_batches(id),file_name text not null,sheet text not null,source_row integer not null,
 cell text not null default '',kind text not null,entity_id uuid,data jsonb not null,
 primary key(batch_id,file_name,sheet,source_row,cell,kind)
);
create table splav.excel_import_issues (
 id bigint generated always as identity primary key,batch_id uuid not null references splav.excel_import_batches(id),
 file_name text not null,sheet text not null,source_row integer not null,kind text not null,detail jsonb not null
);
create table splav.excel_historical_crews (
 batch_id uuid not null references splav.excel_import_batches(id),group_id uuid not null references splav.groups(id),
 label text not null,participation_ids jsonb not null,note text not null,primary key(batch_id,group_id,label)
);
create or replace function splav.trip_json(g splav.groups) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',g.id,'team_id',g.team_id,'route_id',g.route_id,'title',g.title,'route',g.route,
 'starts_at',g.starts_at,'ends_at',g.ends_at,'timezone',g.timezone,'meeting_point',g.meeting_point,'meeting_at',g.meeting_at,
 'responsible_names',g.responsible_names,'capacity',g.capacity,'base_price_kopeks',g.base_price_kopeks,'notes',g.notes,'status',g.status,
 'metadata_version',g.metadata_version,'updated_at',g.updated_at,'updated_by',g.updated_by,'import_metadata',g.import_metadata)
 ||(select jsonb_build_object('booked_clients',count(*) filter(where role='client' and status in ('application','confirmed')),
 'confirmed_clients',count(*) filter(where role='client' and status='confirmed'),'waiting_clients',count(*) filter(where role='client' and status='waiting'),
 'instructors',count(*) filter(where role='instructor' and status='confirmed'),
 'capacity_exceeded',coalesce((g.import_metadata->>'capacity_known')::boolean,true) and count(*) filter(where role='client' and status in ('application','confirmed'))>g.capacity)
 from splav.registrations where group_id=g.id);
$$;
create or replace function splav.registration_json(r splav.registrations) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('id',r.id,'trip_id',r.group_id,'booking_id',r.booking_id,'person_id',r.person_id,'role',r.role,'status',r.status,
 'parameters',r.parameters,'agreed_price_kopeks',r.agreed_price_kopeks,'version',r.version,'waiting_at',r.waiting_at,
 'created_by',r.created_by,'modified_by',r.modified_by,'updated_at',r.updated_at,'import_metadata',r.import_metadata);
$$;
alter function public.roster_snapshot(uuid,bigint) set schema splav;
alter function splav.roster_snapshot(uuid,bigint) rename to roster_snapshot_v45;
revoke all on function splav.roster_snapshot_v45(uuid,bigint) from public,anon,authenticated;
create function public.roster_snapshot(p_trip_id uuid,p_after_revision bigint default -1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=splav.roster_snapshot_v45(p_trip_id,p_after_revision);
 if result->>'unchanged'='true' then return result;end if;
 return jsonb_set(result,'{operations,imported_crews}',coalesce((select jsonb_agg(jsonb_build_object(
 'label',label,'participation_ids',participation_ids,'note',note) order by label)
 from splav.excel_historical_crews where group_id=p_trip_id),'[]'::jsonb));
end $$;
create function public.import_excel_batch(p_batch_id uuid,p_team_id uuid,p_manifest jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid(); fingerprint text; previous splav.excel_import_batches%rowtype; item jsonb; allocation jsonb;
 trip uuid; booking uuid; person uuid; payment uuid; route uuid; outcome jsonb; amount bigint; file_name text;
begin
 if p_batch_id is null or p_team_id is null or p_manifest->>'version'<>'1' or (p_manifest->>'team_id')::uuid<>p_team_id
   or (p_manifest->>'batch_id')::uuid<>p_batch_id then raise exception 'Invalid import envelope' using errcode='22023';end if;
 perform 1 from splav.team_members where team_id=p_team_id and user_id=caller and role='admin' for share;
 if not found then raise exception 'Import administrator required' using errcode='42501';end if;
 perform 1 from splav.teams where id=p_team_id for update;
 fingerprint:=encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex');
 select * into previous from splav.excel_import_batches where id=p_batch_id;
 if found then
  if previous.team_id<>p_team_id or previous.payload_hash<>fingerprint then raise exception 'Batch bound to another payload' using errcode='22023';end if;
  return previous.result||jsonb_build_object('replayed',true);
 end if;
 if jsonb_array_length(p_manifest->'trips') not between 1 and 1000 or jsonb_array_length(p_manifest->'people')>10000
   or jsonb_array_length(p_manifest->'payments')>20000 or jsonb_array_length(p_manifest->'records')>50000 then
   raise exception 'Import bounds exceeded' using errcode='22023';end if;
 route:=(p_manifest->>'route_id')::uuid;
 if exists(select 1 from splav.routes where id=route and team_id<>p_team_id) then raise exception 'Route access denied' using errcode='42501';end if;
 insert into splav.routes(id,team_id,name) values(route,p_team_id,p_manifest->>'route_name') on conflict(id) do nothing;
 insert into splav.excel_import_batches values(p_batch_id,p_team_id,caller,fingerprint,p_manifest->'files','{}',now());
 for item in select value from jsonb_array_elements(p_manifest->'trips') loop
  trip:=(item->>'id')::uuid;
  if exists(select 1 from splav.groups where id=trip) then raise exception 'Trip ID exists outside this batch' using errcode='22023';end if;
  if (item->>'ends_on')::date<(item->>'starts_on')::date then raise exception 'Invalid import dates' using errcode='22023';end if;
  insert into splav.groups(id,team_id,route_id,title,route,starts_at,ends_at,timezone,meeting_point,meeting_at,responsible_names,
    capacity,base_price_kopeks,notes,status,updated_by,import_metadata)
   values(trip,p_team_id,route,item->>'title',p_manifest->>'route_name',
    (item->>'starts_on')::date::timestamp at time zone 'Europe/Saratov',
    ((item->>'ends_on')::date::timestamp+interval '23 hours 59 minutes 59 seconds') at time zone 'Europe/Saratov',
    'Europe/Saratov','',(item->>'starts_on')::date::timestamp at time zone 'Europe/Saratov','',1,(item->>'base_price_kopeks')::bigint,
    item->>'notes','completed',caller,jsonb_build_object('batch_id',p_batch_id,'date_only',true,'capacity_known',false));
  insert into splav.group_members(group_id,user_id) values(trip,caller);
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'people') loop
  person:=(item->>'id')::uuid;
  if exists(select 1 from splav.people where id=person) then raise exception 'Person ID exists outside batch' using errcode='22023';end if;
  if char_length(btrim(item->>'name')) not between 1 and 100 then raise exception 'Invalid imported name' using errcode='22023';end if;
  insert into splav.people(id,team_id,name,phone,phone_normalized,notes,created_by)
   values(person,p_team_id,item->>'name',coalesce(item->>'phone',''),regexp_replace(coalesce(item->>'phone',''),'[^0-9]','','g'),coalesce(item->>'notes',''),caller);
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'bookings') loop
  trip:=(item->>'trip_id')::uuid;
  if not exists(select 1 from splav.groups where id=trip and team_id=p_team_id and import_metadata->>'batch_id'=p_batch_id::text) then
   raise exception 'Trip outside import' using errcode='42501';end if;
  insert into splav.bookings(id,group_id,contact_person_id,contact_name,phone,notes,created_by)
   values((item->>'id')::uuid,trip,(item->>'contact_person_id')::uuid,item->>'contact_name',coalesce(item->>'phone',''),coalesce(item->>'notes',''),caller);
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'participations') loop
  trip:=(item->>'trip_id')::uuid;person:=(item->>'person_id')::uuid;booking:=(item->>'booking_id')::uuid;
  if not exists(select 1 from splav.bookings b join splav.groups g on g.id=b.group_id where b.id=booking and b.group_id=trip
     and g.team_id=p_team_id and g.import_metadata->>'batch_id'=p_batch_id::text)
    or not exists(select 1 from splav.people where id=person and team_id=p_team_id) then raise exception 'Participation outside import' using errcode='42501';end if;
  insert into splav.registrations(id,group_id,person_id,booking_id,role,status,parameters,agreed_price_kopeks,created_by,import_metadata)
   values((item->>'id')::uuid,trip,person,booking,item->>'role',item->>'status',item->'parameters',(item->>'price')::bigint,caller,
    jsonb_build_object('batch_id',p_batch_id,'payment_recorded',coalesce((item->>'payment_recorded')::boolean,false)));
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'payments') loop
  payment:=(item->>'id')::uuid;trip:=(item->>'trip_id')::uuid;booking:=(item->>'booking_id')::uuid;amount:=(item->>'amount')::bigint;
  if not exists(select 1 from splav.bookings b join splav.groups g on g.id=b.group_id where b.id=booking and b.group_id=trip
    and g.team_id=p_team_id and g.import_metadata->>'batch_id'=p_batch_id::text) then raise exception 'Payment outside import' using errcode='42501';end if;
  perform splav.check_allocations(booking,amount,item->'allocations');
  insert into splav.payments(id,team_id,group_id,booking_id,signed_kopeks,direction,occurred_at,method,notes,author_id,source_date_unknown)
    select payment,p_team_id,trip,booking,amount,'income',starts_at,'other',item->>'notes',caller,true from splav.groups where id=trip;
  insert into splav.payment_allocations(payment_id,version,lines,reason,author_id) values(payment,1,item->'allocations','Импорт исходных колонок Excel',caller);
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'crews') loop
  trip:=(item->>'trip_id')::uuid;
  if not exists(select 1 from splav.groups where id=trip and import_metadata->>'batch_id'=p_batch_id::text and team_id=p_team_id) then
    raise exception 'Crew outside import' using errcode='42501';end if;
  insert into splav.excel_historical_crews values(p_batch_id,trip,item->>'label',item->'participation_ids',item->>'note');
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'records') loop
  file_name:=regexp_replace(item->>'file','^.*[\\/]','');
  insert into splav.excel_import_records values(p_batch_id,file_name,item->>'sheet',(item->>'row')::integer,coalesce(item->>'cell',''),
    item->>'kind',nullif(item->>'entity_id','')::uuid,item->'data');
 end loop;
 for item in select value from jsonb_array_elements(p_manifest->'issues') loop
  insert into splav.excel_import_issues(batch_id,file_name,sheet,source_row,kind,detail) values(p_batch_id,
    regexp_replace(item->>'file','^.*[\\/]',''),item->>'sheet',(item->>'row')::integer,item->>'kind',item->'detail');
 end loop;
 update splav.teams set people_revision=people_revision+1 where id=p_team_id;
 outcome:=jsonb_build_object('batch_id',p_batch_id,'trips',jsonb_array_length(p_manifest->'trips'),'people',jsonb_array_length(p_manifest->'people'),
  'bookings',jsonb_array_length(p_manifest->'bookings'),'participations',jsonb_array_length(p_manifest->'participations'),
  'payments',jsonb_array_length(p_manifest->'payments'),'issues',jsonb_array_length(p_manifest->'issues'),'replayed',false);
 update splav.excel_import_batches set result=outcome where id=p_batch_id;
 return outcome;
end $$;
revoke all on all tables in schema splav from public,anon,authenticated;
revoke all on all sequences in schema splav from public,anon,authenticated;
revoke all on function public.import_excel_batch(uuid,uuid,jsonb),public.roster_snapshot(uuid,bigint) from public,anon;
grant execute on function public.import_excel_batch(uuid,uuid,jsonb),public.roster_snapshot(uuid,bigint) to authenticated;
update splav.teams set people_revision=people_revision+1;
notify pgrst,'reload schema';
