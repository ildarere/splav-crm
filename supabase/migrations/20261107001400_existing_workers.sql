begin;
create or replace function splav.worker_resource() returns trigger language plpgsql security definer set search_path=splav,public as $$
declare owner uuid; resource_id uuid;
begin
 if new.is_worker then
  owner:=new.created_by;
  if owner is null then select user_id into owner from splav.team_members where team_id=new.team_id order by role limit 1;end if;
  select id into resource_id from splav.ops_resources where team_id=new.team_id and kind='employee' and data->>'person_id'=new.id::text order by id limit 1;
  resource_id:=coalesce(resource_id,new.id);
  insert into splav.ops_resources(id,team_id,kind,data,author_id) values(resource_id,new.team_id,'employee',jsonb_build_object('name',new.name,'code','СОТР-'||resource_id,'model','employee','capacity',0,'available',not new.archived,'roles',new.work_roles,'person_id',new.id,'notes',new.notes),owner)
  on conflict(id) do update set data=splav.ops_resources.data||excluded.data,version=splav.ops_resources.version+1,updated_at=now() where splav.ops_resources.data is distinct from splav.ops_resources.data||excluded.data;
 end if;return new;
end $$;
do $$ declare r record; linked uuid;begin
 for r in select * from splav.ops_resources where kind='employee' loop
  select id into linked from splav.people where team_id=r.team_id and (id::text=r.data->>'person_id' or id=r.id) order by id limit 1;
  if linked is null then
   insert into splav.people(id,team_id,name,notes,archived,created_by,is_worker,work_roles) values(r.id,r.team_id,r.data->>'name',coalesce(r.data->>'notes',''),not coalesce((r.data->>'available')::boolean,true),r.author_id,true,coalesce(r.data->'roles','[]'::jsonb));
  else
   update splav.people set is_worker=true,work_roles=coalesce(r.data->'roles','[]'::jsonb),version=version+1 where id=linked;
  end if;
 end loop;
end $$;
update splav.ops_reservations b set starts_at=g.starts_at,ends_at=g.ends_at,busy_start=g.starts_at,busy_end=g.ends_at,version=b.version+1 from splav.groups g where b.group_id=g.id and b.kind='boat' and b.active and (b.starts_at,b.ends_at,b.busy_start,b.busy_end) is distinct from (g.starts_at,g.ends_at,g.starts_at,g.ends_at);
update splav.teams set people_revision=people_revision+1;
commit;
