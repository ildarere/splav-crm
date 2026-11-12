begin;
create or replace function splav.fill_bus(p_trip uuid,p_direction text,p_preferred uuid default null) returns void language plpgsql security definer set search_path=splav,public as $$
#variable_conflict use_variable
declare t splav.groups; r splav.ops_resources; ride splav.ops_reservations; p splav.registrations; author uuid; pos integer; point text; begin_at timestamptz; end_at timestamptz;
begin
 select * into t from splav.groups where id=p_trip;
 if t.id is null or t.status in ('completed','cancelled') then return; end if;
 perform 1 from splav.teams where id=t.team_id for update;
 if not exists(select 1 from splav.registrations x where x.group_id=p_trip and x.status='confirmed' and not exists(select 1 from splav.ops_travel tr where tr.group_id=p_trip and tr.subject_kind='participant' and tr.subject_id=x.id and tr.direction=p_direction and tr.mode in ('bus','self'))) then return; end if;
 select user_id into author from splav.team_members where team_id=t.team_id order by role limit 1;
 if p_preferred is not null then
  select * into ride from splav.ops_reservations where id=p_preferred and group_id=p_trip and active and kind='ride' and data->>'direction'=p_direction;
  if not found then return; end if;
 else
  select * into r from splav.ops_resources where team_id=t.team_id and kind='vehicle' and data->>'model'='own_bus' order by id limit 1;
  if r.id is null then
   insert into splav.ops_resources(id,team_id,kind,data,author_id) values(gen_random_uuid(),t.team_id,'vehicle',jsonb_build_object('name','Наш автобус','code','АВТ-30','model','own_bus','capacity',30,'available',true,'roles','[]'::jsonb),author) returning * into r;
  end if;
  if r.data->>'available'='false' then return; end if;
  select * into ride from splav.ops_reservations where group_id=p_trip and resource_id=r.id and kind='ride' and active and data->>'direction'=p_direction order by id limit 1;
  if ride.id is null then
   begin_at:=case when p_direction='outbound' then least(t.meeting_at,t.starts_at-interval '1 hour') else t.ends_at end;
   end_at:=case when p_direction='outbound' then t.starts_at else t.ends_at+interval '1 hour' end;
   if exists(select 1 from splav.ops_reservations b where b.resource_id=r.id and b.active and b.busy_start<end_at and b.busy_end>begin_at) then return; end if;
   point:='auto-meeting';
   insert into splav.ops_reservations(id,team_id,group_id,resource_id,kind,starts_at,ends_at,busy_start,busy_end,capacity,data,author_id)
   values(gen_random_uuid(),t.team_id,t.id,r.id,'ride',begin_at,end_at,begin_at,end_at,(r.data->>'capacity')::integer,jsonb_build_object('direction',p_direction,'auto_bus',true,'points',jsonb_build_array(jsonb_build_object('id',point,'name',coalesce(nullif(t.meeting_point,''),'Общий сбор'))),'prep_minutes',0,'return_minutes',0),author) returning * into ride;
  end if;
 end if;
 point:=ride.data->'points'->0->>'id';
 if point is null then return; end if;
 for p in select * from splav.registrations x where x.group_id=p_trip and x.status='confirmed' and not exists(select 1 from splav.ops_travel tr where tr.group_id=p_trip and tr.subject_kind='participant' and tr.subject_id=x.id and tr.direction=p_direction and tr.mode in ('bus','self')) order by x.id loop
  select s into pos from generate_series(1,ride.capacity) s where not exists(select 1 from splav.ops_travel tr where tr.reservation_id=ride.id and tr.seat=s and tr.mode='bus') and not exists(select 1 from splav.ops_latest_presence(p_trip) f where f.reservation_id=ride.id and f.seat=s and f.present) order by s limit 1;
  if pos is null then exit; end if;
  insert into splav.ops_travel(id,group_id,subject_kind,subject_id,direction,mode,reservation_id,seat,point_id,author_id)
  values(gen_random_uuid(),t.id,'participant',p.id,p_direction,'bus',ride.id,pos,point,author)
  on conflict on constraint ops_travel_subject_key do update set mode='bus',reservation_id=excluded.reservation_id,seat=excluded.seat,point_id=excluded.point_id,version=splav.ops_travel.version+1,author_id=excluded.author_id,updated_at=now();
 end loop;
end $$;
create function splav.auto_bus_registration() returns trigger language plpgsql security definer set search_path=splav,public as $$
begin perform splav.fill_bus(new.group_id,'outbound'); perform splav.fill_bus(new.group_id,'return'); return null; end $$;
create constraint trigger auto_bus_registration after insert or update of status on splav.registrations deferrable initially deferred for each row execute function splav.auto_bus_registration();
create function splav.auto_bus_ride() returns trigger language plpgsql security definer set search_path=splav,public as $$
begin if new.kind='ride' and new.active then perform splav.fill_bus(new.group_id,new.data->>'direction',new.id); end if; return null; end $$;
create constraint trigger auto_bus_ride after insert on splav.ops_reservations deferrable initially deferred for each row execute function splav.auto_bus_ride();
revoke all on function splav.fill_bus(uuid,text,uuid),splav.auto_bus_registration(),splav.auto_bus_ride() from public,anon,authenticated;
-- Fill existing confirmed rosters, without overwriting manual/self travel.
do $$ declare t record; begin for t in select distinct group_id from splav.registrations where status='confirmed' loop perform splav.fill_bus(t.group_id,'outbound'); perform splav.fill_bus(t.group_id,'return'); end loop; end $$;
commit;
