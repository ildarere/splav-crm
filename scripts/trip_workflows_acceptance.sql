-- Run as postgres after applying migrations. All fixtures are rolled back.
begin;

do $$
declare
 author uuid := gen_random_uuid();
 team uuid := gen_random_uuid();
 trip uuid := gen_random_uuid();
 route uuid := gen_random_uuid();
 company_a uuid := gen_random_uuid();
 company_b uuid := gen_random_uuid();
 person uuid;
 participant uuid;
 participants uuid[] := array[]::uuid[];
 bus uuid := gen_random_uuid();
 outbound uuid := gen_random_uuid();
 outbound_assignment uuid := gen_random_uuid();
 cabin_operation uuid := gen_random_uuid();
 restore_operation uuid := gen_random_uuid();
 separate_company uuid := gen_random_uuid();
 worker uuid := gen_random_uuid();
 other_worker uuid := gen_random_uuid();
 parallel_trip uuid := gen_random_uuid();
 move_trip uuid := gen_random_uuid();
 moved_booking uuid := gen_random_uuid();
 moved_participant uuid := gen_random_uuid();
 move_operation uuid := gen_random_uuid();
 move_payload jsonb;
 worker_resource uuid;
 duty uuid := gen_random_uuid();
 payment uuid := gen_random_uuid();
 cabin_plan jsonb;
 result jsonb;
 replay jsonb;
 starts timestamptz := '2038-08-01 09:00+04';
 ends timestamptz := '2038-08-02 18:00+04';
begin
 if splav.ops_check_seat('{}',4,1,'{"height_cm":130,"age_years":10}')
    or splav.ops_check_seat('{}',4,2,'{"height_cm":120,"age_years":18}')
    or splav.ops_check_seat('{}',4,3,'{"age_years":10}')
    or not splav.ops_check_seat('{}',4,4,'{"height_cm":129.9,"age_years":10}') then
  raise exception 'Four-seat boat eligibility failed';
 end if;

 insert into auth.users(id,email) values(author,author::text||'@example.invalid');
 perform set_config('request.jwt.claim.sub',author::text,true);
 insert into splav.teams(id,name) values(team,'Trip workflows test');
 insert into splav.team_members values(team,author,'admin');
 insert into splav.routes(id,team_id,name) values(route,team,'Test route');
 insert into splav.groups(id,team_id,route_id,title,route,starts_at,ends_at,meeting_at,capacity,status)
 values(trip,team,route,'Test trip','Test route',starts,ends,starts-interval '1 hour',50,'open');
 insert into splav.group_members values(trip,author);
 insert into splav.bookings(id,group_id,contact_name,created_by) values
 (company_a,trip,'Company A',author),(company_b,trip,'Company B',author);

 for i in 1..4 loop
  person := gen_random_uuid();
  participant := gen_random_uuid();
  participants := array_append(participants,participant);
  insert into splav.people(id,team_id,name,created_by) values(person,team,'Passenger '||i,author);
  insert into splav.registrations(group_id,id,person_id,booking_id,status,parameters)
  values(trip,participant,person,case when i=4 then company_b else company_a end,
    'confirmed','{"height_cm":129,"age_years":10}');
 end loop;

 cabin_plan:=jsonb_build_object('extra_beds','[]'::jsonb,
   'assignments',jsonb_build_object(participants[1]::text,7,participants[2]::text,7));
 result := public.people_command(cabin_operation,team,trip,'ops_cabins',cabin_plan,0);
 if result->>'status' is distinct from 'accepted' then
  raise exception 'Cabin assignment failed: %',result;
 end if;
 replay := public.people_command(cabin_operation,team,trip,'ops_cabins',cabin_plan,0);
 if replay is distinct from result then raise exception 'Cabin replay changed result'; end if;

 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',cabin_plan,0);
 if result->>'reason' is distinct from 'version_conflict' then
  raise exception 'Stale cabin version accepted: %',result;
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',
   jsonb_set(cabin_plan,array['assignments',participants[3]::text],'7'),1);
 if result->>'reason' is distinct from 'invalid_cabins' then
  raise exception 'Two-bed cabin capacity bypassed: %',result;
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',
   jsonb_set(cabin_plan,'{assignments}',jsonb_build_object(participants[1]::text,1,participants[4]::text,1)),1);
 if result->>'reason' is distinct from 'invalid_cabins' then
  raise exception 'Cabin mixed companies: %',result;
 end if;
 result := public.roster_snapshot(trip,-1);
 if result#>>'{operations,settings,cabins_version}' is distinct from '1' then
  raise exception 'Cabins missing from roster snapshot';
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',
   jsonb_set(cabin_plan,array['assignments',participants[3]::text],'13'),1);
 if result->>'reason' is distinct from 'invalid_cabins' then
  raise exception 'Removed cabin was accepted: %',result;
 end if;
 cabin_plan:=jsonb_set(jsonb_set(cabin_plan,'{extra_beds}','[7,21]'),
   array['assignments',participants[3]::text],'7');
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',cabin_plan,1);
 if result->>'status' is distinct from 'accepted' then
  raise exception 'Extra bed was rejected: %',result;
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',
   jsonb_set(cabin_plan,'{extra_beds}','[]'),2);
 if result->>'reason' is distinct from 'invalid_cabins' then
  raise exception 'Occupied extra bed was removed: %',result;
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'edit_participation',
   jsonb_build_object('id',participants[3],'role','instructor','parameters','{}'::jsonb),1);
 if result->>'status' is distinct from 'accepted' or exists(
    select from splav.ops_settings where group_id=trip
    and (cabins->'assignments') ? participants[3]::text) then
  raise exception 'Instructor retained a cabin: %',result;
 end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_cabins',cabin_plan,3);
 if result->>'reason' is distinct from 'invalid_cabins' then
  raise exception 'Instructor cabin was accepted: %',result;
 end if;

 insert into splav.ops_resources(id,team_id,kind,data,author_id)
 values(bus,team,'vehicle','{"name":"Test bus","code":"test-bus","model":"custom","capacity":4,"available":true}',author);
 result := public.people_command(gen_random_uuid(),team,trip,'ops_reservation',jsonb_build_object(
   'id',outbound,'resource_id',bus,'kind','ride','active',true,'capacity',4,'direction','outbound',
   'starts_at',starts-interval '1 hour','ends_at',starts,'prep_minutes',0,'return_minutes',0,
   'points',jsonb_build_array(jsonb_build_object('id','free-seating','name','Free seating'))),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Outbound ride failed: %',result; end if;
 result := public.people_command(gen_random_uuid(),team,trip,'ops_travel',jsonb_build_object(
   'id',outbound_assignment,'subject_id',participants[1],'subject_kind','participant',
   'direction','outbound','mode','bus','reservation_id',outbound,'free_seating',true),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Outbound assignment failed: %',result; end if;
 if not exists(select from splav.ops_travel t join splav.ops_reservations r on r.id=t.reservation_id
   where t.group_id=trip and t.subject_id=participants[1] and t.direction='return'
     and t.mode='bus' and r.resource_id=bus and r.starts_at=ends) then
  raise exception 'Return bus was not assigned';
 end if;

 result := public.people_command(gen_random_uuid(),team,trip,'set_status',jsonb_build_object(
   'ids',jsonb_build_array(participants[1]),'status','cancelled',
   'versions',jsonb_build_object(participants[1]::text,1)),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Participant removal failed: %',result; end if;
 if exists(select from splav.ops_travel where group_id=trip and subject_id=participants[1] and mode='bus')
    or exists(select from splav.ops_crews where group_id=trip and registration_id=participants[1] and reservation_id is not null)
    or exists(select from splav.ops_settings where group_id=trip and (cabins->'assignments') ? participants[1]::text) then
  raise exception 'Removing participant did not release all assignments';
 end if;

 result:=public.people_command(gen_random_uuid(),team,trip,'add_payment',jsonb_build_object(
   'id',payment,'booking_id',company_a,'amount_kopeks',50000,'direction','income',
   'occurred_at',starts,'method','cash','allocations',jsonb_build_array(
   jsonb_build_object('participation_id',participants[1],'amount_kopeks',50000))),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Payment setup failed: %',result; end if;
 result:=public.people_command(restore_operation,team,trip,'set_status',jsonb_build_object(
   'ids',jsonb_build_array(participants[1]),'status','confirmed','separate_booking_id',separate_company,
   'versions',jsonb_build_object(participants[1]::text,2)),0);
 if result->>'status' is distinct from 'accepted'
    or not exists(select from splav.registrations r join splav.bookings b on b.id=r.booking_id
      where r.id=participants[1] and b.id=separate_company and b.contact_person_id=r.person_id
        and r.status='confirmed' and r.version=3)
    or not exists(select from splav.payments p join splav.payment_allocations a on a.payment_id=p.id
      where p.id=payment and p.booking_id=company_a
        and a.lines @> jsonb_build_array(jsonb_build_object('participation_id',participants[1]))) then
  raise exception 'Separate restoration did not preserve participation and payment: %',result;
 end if;
 replay:=public.people_command(restore_operation,team,trip,'set_status',jsonb_build_object(
   'ids',jsonb_build_array(participants[1]),'status','confirmed','separate_booking_id',separate_company,
   'versions',jsonb_build_object(participants[1]::text,2)),0);
 if replay is distinct from result then raise exception 'Separate restore replay changed result'; end if;
 result:=public.people_command(gen_random_uuid(),team,trip,'allocate_payment',jsonb_build_object(
   'id',payment,'booking_id',company_a,'reason','Recheck original allocation',
   'allocations',jsonb_build_array(jsonb_build_object(
     'participation_id',participants[1],'amount_kopeks',50000))),1);
 if result->>'status' is distinct from 'accepted' then
  raise exception 'Historical allocation could not be corrected: %',result;
 end if;
 result:=public.people_command(gen_random_uuid(),team,trip,'set_status',jsonb_build_object(
   'ids',jsonb_build_array(participants[4]),'status','waiting',
   'versions',jsonb_build_object(participants[4]::text,1)),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Reserve failed: %',result; end if;
 result:=public.people_command(gen_random_uuid(),team,trip,'set_status',jsonb_build_object(
   'ids',jsonb_build_array(participants[4]),'status','confirmed',
   'versions',jsonb_build_object(participants[4]::text,2)),0);
 if result->>'status' is distinct from 'accepted' or not exists(
   select from splav.registrations where id=participants[4] and booking_id=company_b
     and status='confirmed' and waiting_at is null) then
  raise exception 'Original company was not retained: %',result;
 end if;

 insert into splav.people(id,team_id,name,created_by,is_worker,work_roles)
 values(worker,team,'Schedule worker',author,true,'["water_instructor","camp_kitchen"]');
 select id into worker_resource from splav.ops_resources
 where team_id=team and data->>'person_id'=worker::text;
 result:=public.people_command(gen_random_uuid(),team,trip,'ops_reservation',jsonb_build_object(
   'id',duty,'kind','duty','resource_id',worker_resource,'role','water_instructor',
   'starts_at',starts,'ends_at',ends,'capacity',1,'paid',true),0);
 if result->>'status' is distinct from 'accepted' then raise exception 'Duty failed: %',result; end if;
 if not exists(select from jsonb_array_elements(public.people_catalog()->'people') p
   where p->>'id'=worker::text and p->>'work_resource_id'=worker_resource::text
     and p->'work_assignments' @> jsonb_build_array(jsonb_build_object(
       'id',duty,'trip_id',trip,'version',1,'title','Test trip'))) then
  raise exception 'Duty missing from the common schedule';
 end if;
 insert into splav.groups(id,team_id,route_id,title,route,starts_at,ends_at,meeting_at,capacity,status)
 values(parallel_trip,team,route,'Parallel trip','Test route',starts,ends,starts-interval '1 hour',50,'open');
 insert into splav.group_members values(parallel_trip,author);
 result:=public.people_command(gen_random_uuid(),team,parallel_trip,'ops_reservation',jsonb_build_object(
   'id',gen_random_uuid(),'kind','duty','resource_id',worker_resource,'role','water_instructor',
   'starts_at',starts,'ends_at',ends,'capacity',1),0);
 if result->>'reason' is distinct from 'resource_overlap' then
  raise exception 'Parallel duty conflict was missed: %',result;
 end if;
 insert into splav.people(id,team_id,name,created_by,is_worker,work_roles)
 values(other_worker,team,'Parallel worker',author,true,'["water_instructor"]');
 result:=public.people_command(gen_random_uuid(),team,parallel_trip,'ops_reservation',jsonb_build_object(
   'id',gen_random_uuid(),'kind','duty','resource_id',other_worker,'role','water_instructor',
   'starts_at',starts,'ends_at',ends,'capacity',1),0);
 if result->>'status' is distinct from 'accepted' then
  raise exception 'Parallel duty for a different worker failed: %',result;
 end if;
 begin
  perform public.people_command(gen_random_uuid(),team,null,'save_person',jsonb_build_object(
    'id',worker,'name','Schedule worker','is_worker',true,'work_schedule',jsonb_build_array(
      jsonb_build_object('id',gen_random_uuid(),'role','camp_kitchen','starts_at',starts,'ends_at',ends))),1);
  raise exception 'Overlapping kitchen shift was accepted';
 exception when sqlstate 'P0001' then
  if sqlerrm<>'work_schedule_overlap' then raise; end if;
 end;
 result:=public.people_command(gen_random_uuid(),team,null,'save_person',jsonb_build_object(
   'id',worker,'name','Schedule worker','is_worker',true,'work_schedule',jsonb_build_array(
     jsonb_build_object('id',gen_random_uuid(),'role','camp_kitchen',
       'starts_at',ends,'ends_at',ends+interval '1 hour'))),1);
 if result->>'status' is distinct from 'accepted' then raise exception 'Adjacent kitchen shift failed: %',result; end if;

 insert into splav.groups(id,team_id,route_id,title,route,starts_at,ends_at,meeting_at,capacity,status)
 values(move_trip,team,route,'New date','Test route',starts+interval '7 days',
   ends+interval '7 days',starts+interval '167 hours',50,'open');
 insert into splav.group_members values(move_trip,author);

 move_payload:=jsonb_build_object('id',participants[2],'target_trip_id',move_trip,
   'new_booking_id',moved_booking,'new_registration_id',moved_participant);
 result:=public.people_command(move_operation,team,trip,'move_participant',move_payload,1);
 if result->>'status' is distinct from 'accepted'
    or not exists(select from splav.registrations old
      join splav.registrations moved on moved.person_id=old.person_id
      where old.group_id=trip and old.id=participants[2] and old.status='cancelled'
        and moved.group_id=move_trip and moved.id=moved_participant
        and moved.booking_id=moved_booking and moved.status='confirmed'
        and moved.agreed_price_kopeks=old.agreed_price_kopeks)
    or exists(select from splav.ops_settings where group_id=trip
      and (cabins->'assignments') ? participants[2]::text) then
  raise exception 'Participant transfer did not complete cleanly: %',result;
 end if;
 replay:=public.people_command(move_operation,team,trip,'move_participant',move_payload,1);
 if replay is distinct from result then raise exception 'Participant transfer replay changed'; end if;

 move_payload:=jsonb_build_object('target_trip_id',parallel_trip,'versions',jsonb_build_object(duty,1));
 result:=public.people_command(gen_random_uuid(),team,trip,'ops_move_escort',move_payload,0);
 if result->>'reason' is distinct from 'escort_already_assigned' then
   raise exception 'Team was moved onto an occupied trip: %',result;
 end if;
 move_payload:=jsonb_set(move_payload,'{target_trip_id}',to_jsonb(move_trip));
 move_operation:=gen_random_uuid();
 result:=public.people_command(move_operation,team,trip,'ops_move_escort',move_payload,0);
 if result->>'status' is distinct from 'accepted' or not exists(
   select from splav.ops_reservations b where b.id=duty and b.group_id=move_trip
     and b.starts_at=starts+interval '7 days' and b.ends_at=ends+interval '7 days'
     and b.data->'paid'='true'::jsonb and b.version=2) then
   raise exception 'Escort did not move with paid status: %',result;
 end if;
 replay:=public.people_command(move_operation,team,trip,'ops_move_escort',move_payload,0);
 if replay is distinct from result then raise exception 'Escort transfer replay changed'; end if;
end $$;

-- Check deferred assignment triggers while the test fixtures still exist.
set constraints all immediate;
rollback;
select 'PASS: cabins, transfer, participant restoration and rescheduling, worker schedule and paid status';
