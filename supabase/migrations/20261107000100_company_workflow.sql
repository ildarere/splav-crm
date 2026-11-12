begin;
create or replace function splav.company_confirm_new() returns trigger language plpgsql set search_path=splav,public as $$
begin if new.booking_id is not null and new.status='application' then new.status:='confirmed'; end if; return new; end $$;
create trigger company_confirm_new before insert on splav.registrations for each row execute function splav.company_confirm_new();
create or replace function splav.company_plan_kayaks() returns trigger language plpgsql security definer set search_path=splav,public as $$
declare ids uuid[]; children integer; n integer; cap integer; take_n integer; rid uuid; bid uuid; author uuid; t splav.groups; i integer; child_seat boolean;
begin
 if new.booking_id is null then return null; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.booking_id::text,0));
 select * into t from splav.groups where id=new.group_id;
 if t.status in ('completed','cancelled') then return null; end if;
 select created_by into author from splav.bookings where id=new.booking_id;
 select array_agg(r.id order by coalesce((r.parameters->>'age_years')::numeric,99) desc,r.id),count(*) filter(where (r.parameters->>'age_years')::numeric<18)
 into ids,children from splav.registrations r where r.booking_id=new.booking_id and r.status='confirmed'
 and not exists(select 1 from splav.ops_crews c where c.registration_id=r.id and c.reservation_id is not null);
 n:=coalesce(array_length(ids,1),0);
 while n>0 loop
  child_seat:=n=4 and children=2;
  take_n:=case when child_seat then 4 when n=4 then 2 when n>=3 then 3 else n end;
  cap:=greatest(2,take_n);
  rid:=gen_random_uuid(); bid:=gen_random_uuid();
  insert into splav.ops_resources(id,team_id,kind,data,author_id) values(rid,t.team_id,'boat',jsonb_build_object('name',case when child_seat then 'План · трёшка + детское место' when cap=3 then 'План · трёшка' else 'План · двушка' end,'code','ПЛАН-'||rid::text,'model','big','capacity',cap,'available',true,'planned',true,'roles','[]'::jsonb),author);
  insert into splav.ops_reservations(id,team_id,group_id,resource_id,kind,starts_at,ends_at,busy_start,busy_end,capacity,data,author_id)
   values(bid,t.team_id,t.id,rid,'boat',t.starts_at,t.ends_at,t.starts_at,t.ends_at,cap,jsonb_build_object('planned',true,'company_id',new.booking_id,'child_extra',child_seat,'prep_minutes',0,'return_minutes',0,'notes','Автоматический план компании. Физическая лодка пока не выбрана.'),author);
  for i in 1..take_n loop
   insert into splav.ops_crews(registration_id,group_id,reservation_id,seat,author_id) values(ids[i],t.id,bid,i,author)
   on conflict(group_id,registration_id) do update set reservation_id=excluded.reservation_id,seat=excluded.seat,version=splav.ops_crews.version+1,author_id=excluded.author_id;
  end loop;
  ids:=ids[take_n+1:]; n:=coalesce(array_length(ids,1),0);
 end loop;
 return null;
end $$;
create constraint trigger company_plan_kayaks after insert on splav.registrations deferrable initially deferred for each row execute function splav.company_plan_kayaks();
revoke all on function splav.company_plan_kayaks() from public;
revoke all on function splav.company_confirm_new() from public;
commit;
