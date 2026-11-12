-- Instructors have their own kayak and do not consume client/transfer capacity.
begin;
create function splav.ensure_instructor_kayak(p_registration uuid) returns void language plpgsql security definer set search_path=splav,public as $$
declare p splav.registrations; t splav.groups; owner uuid; resource uuid; reservation uuid; person_name text;
begin
 select * into p from splav.registrations where id=p_registration;
 if p.id is null or p.role<>'instructor' or p.status<>'confirmed' then return; end if;
 select * into t from splav.groups where id=p.group_id;
 if t.status in ('completed','cancelled') then return; end if;
 perform 1 from splav.teams where id=t.team_id for update;
 if exists(select 1 from splav.ops_crews c join splav.ops_reservations b on b.id=c.reservation_id where c.registration_id=p.id and c.group_id=p.group_id and b.active and b.data->>'instructor_boat'='true') then return; end if;
 select created_by into owner from splav.bookings where id=p.booking_id;
 if owner is null then select user_id into owner from splav.team_members where team_id=t.team_id order by role limit 1; end if;
 select name into person_name from splav.people where id=p.person_id;
 resource:=gen_random_uuid();reservation:=gen_random_uuid();
 insert into splav.ops_resources(id,team_id,kind,data,author_id) values(resource,t.team_id,'boat',jsonb_build_object('name','Инструктор · '||person_name,'code','ИНСТ-'||resource,'model','maigun','capacity',2,'available',true,'planned',true,'instructor_boat',true,'roles','[]'::jsonb),owner);
 insert into splav.ops_reservations(id,team_id,group_id,resource_id,kind,starts_at,ends_at,busy_start,busy_end,capacity,data,author_id) values(reservation,t.team_id,t.id,resource,'boat',t.starts_at,t.ends_at,t.starts_at,t.ends_at,2,jsonb_build_object('instructor_boat',true,'planned',true,'instructor_id',p.id,'prep_minutes',0,'return_minutes',0),owner);
 insert into splav.ops_crews(registration_id,group_id,reservation_id,seat,author_id) values(p.id,t.id,reservation,1,owner)
 on conflict(group_id,registration_id) do update set reservation_id=excluded.reservation_id,seat=1,version=splav.ops_crews.version+1,author_id=excluded.author_id,updated_at=now();
end $$;
create function splav.instructor_changed() returns trigger language plpgsql security definer set search_path=splav,public as $$
begin
 if new.role='instructor' then
  update splav.ops_travel set mode='unset',reservation_id=null,seat=null,point_id=null,version=version+1,updated_at=now() where group_id=new.group_id and subject_kind='participant' and subject_id=new.id and mode<>'unset';
  perform splav.ensure_instructor_kayak(new.id);
 end if;
 return null;
end $$;
create constraint trigger instructor_changed after insert or update of role,status on splav.registrations deferrable initially deferred for each row execute function splav.instructor_changed();
revoke all on function splav.ensure_instructor_kayak(uuid),splav.instructor_changed() from public,anon,authenticated;
create function splav.boat_uses_trip_time() returns trigger language plpgsql set search_path=splav,public as $$
declare t splav.groups;
begin
 if new.kind='boat' then
  select * into t from splav.groups where id=new.group_id;
  new.starts_at:=t.starts_at;new.ends_at:=t.ends_at;new.busy_start:=t.starts_at;new.busy_end:=t.ends_at;
  new.data:=new.data||'{"prep_minutes":0,"return_minutes":0}'::jsonb;
 end if;
 return new;
end $$;
create trigger boat_uses_trip_time before insert or update on splav.ops_reservations for each row execute function splav.boat_uses_trip_time();
create function splav.update_boat_trip_time() returns trigger language plpgsql set search_path=splav,public as $$
begin
 if (new.starts_at,new.ends_at) is distinct from (old.starts_at,old.ends_at) then
  if exists(select 1 from splav.ops_reservations a join splav.ops_reservations b on b.resource_id=a.resource_id and b.group_id<>new.id where a.group_id=new.id and a.kind='boat' and a.active and b.active and b.busy_start<new.ends_at and b.busy_end>new.starts_at) then raise exception 'resource_overlap' using errcode='P0001'; end if;
  update splav.ops_reservations set starts_at=new.starts_at,ends_at=new.ends_at,busy_start=new.starts_at,busy_end=new.ends_at,version=version+1,updated_at=now() where group_id=new.id and kind='boat' and active;
 end if;return new;
end $$;
create trigger update_boat_trip_time after update of starts_at,ends_at on splav.groups for each row execute function splav.update_boat_trip_time();
update splav.ops_travel tr set mode='unset',reservation_id=null,seat=null,point_id=null,version=tr.version+1,updated_at=now() from splav.registrations r where r.id=tr.subject_id and r.group_id=tr.group_id and tr.subject_kind='participant' and r.role='instructor' and tr.mode<>'unset';
do $$ declare p record;begin for p in select id from splav.registrations where role='instructor' and status='confirmed' loop perform splav.ensure_instructor_kayak(p.id);end loop;end $$;
commit;
