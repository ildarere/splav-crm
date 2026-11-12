begin;
alter table splav.people add column is_worker boolean not null default false, add column work_roles jsonb not null default '[]'::jsonb, add column work_schedule jsonb not null default '[]'::jsonb;
create function splav.validate_worker(p_roles jsonb,p_schedule jsonb,p_id uuid) returns void language plpgsql set search_path=splav,public as $$
declare s jsonb; other jsonb; begin_at timestamptz; end_at timestamptz;
begin
 if jsonb_typeof(p_roles) is distinct from 'array' or jsonb_array_length(p_roles) not between 1 and 10 or jsonb_typeof(p_schedule) is distinct from 'array' or jsonb_array_length(p_schedule)>1000 then raise exception 'Invalid worker fields' using errcode='22023'; end if;
 if exists(select 1 from jsonb_array_elements_text(p_roles) r where r not in ('warehouse','camp_kitchen','relief','uaz_driver','trip_cook','water_instructor','camp_worker')) then raise exception 'Invalid worker role' using errcode='22023'; end if;
 if (select count(distinct x->>'id') from jsonb_array_elements(p_schedule) x)<>jsonb_array_length(p_schedule) then raise exception 'Shift ids must be unique' using errcode='22023'; end if;
 for s in select value from jsonb_array_elements(p_schedule) loop
  if jsonb_typeof(s) is distinct from 'object' or nullif(s->>'id','')::uuid is null or not (p_roles ? (s->>'role')) or char_length(coalesce(s->>'notes',''))>2000 then raise exception 'Invalid worker shift' using errcode='22023'; end if;
  begin_at:=(s->>'starts_at')::timestamptz;end_at:=(s->>'ends_at')::timestamptz;
  if begin_at is null or end_at is null or not isfinite(begin_at) or not isfinite(end_at) or begin_at>=end_at then raise exception 'Invalid shift dates' using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements(p_schedule) x where x->>'id'<>s->>'id' and (x->>'starts_at')::timestamptz<end_at and (x->>'ends_at')::timestamptz>begin_at) then raise exception 'work_schedule_overlap' using errcode='P0001';end if;
  if exists(select 1 from splav.ops_reservations b join splav.ops_resources r on r.id=b.resource_id where r.data->>'person_id'=p_id::text and b.kind='duty' and b.active and b.busy_start<end_at and b.busy_end>begin_at) then raise exception 'work_schedule_overlap' using errcode='P0001'; end if;
 end loop;
end $$;
create function splav.worker_resource() returns trigger language plpgsql security definer set search_path=splav,public as $$
declare owner uuid;
begin
 if new.is_worker then
  owner:=new.created_by;
  if owner is null then select user_id into owner from splav.team_members where team_id=new.team_id order by role limit 1;end if;
  insert into splav.ops_resources(id,team_id,kind,data,author_id) values(new.id,new.team_id,'employee',jsonb_build_object('name',new.name,'code','СОТР-'||new.id,'model','employee','capacity',0,'available',not new.archived,'roles',new.work_roles,'person_id',new.id,'notes',new.notes),owner)
  on conflict(id) do update set data=excluded.data,version=splav.ops_resources.version+1,updated_at=now() where splav.ops_resources.data is distinct from excluded.data;
 end if;return new;
end $$;
create trigger worker_resource after insert or update of name,is_worker,work_roles,archived,notes on splav.people for each row execute function splav.worker_resource();
revoke all on function splav.validate_worker(jsonb,jsonb,uuid),splav.worker_resource() from public,anon,authenticated;
commit;
