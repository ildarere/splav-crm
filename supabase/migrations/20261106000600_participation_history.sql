-- Author metadata and an append-only history survive cancellation/restoration.
alter table splav.people add column modified_by uuid references auth.users(id);
alter table splav.bookings add column modified_by uuid references auth.users(id);
alter table splav.registrations
  add column created_by uuid references auth.users(id),
  add column modified_by uuid references auth.users(id),
  add column updated_at timestamptz not null default now();

create table splav.participation_history (
  id bigint generated always as identity primary key,
  group_id uuid not null,
  registration_id uuid not null,
  from_status text,
  to_status text not null,
  from_role text,
  to_role text not null,
  author_id uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  foreign key(group_id,registration_id) references splav.registrations(group_id,id)
);
create index participation_history_trip_idx on splav.participation_history(group_id,id);
insert into splav.participation_history(group_id,registration_id,to_status,to_role)
  select group_id,id,status,role from splav.registrations;

create function splav.stamp_change() returns trigger language plpgsql set search_path='' as $$
begin
  new.modified_by := auth.uid();
  new.updated_at := now();
  if tg_op='INSERT' then new.created_by := coalesce(new.created_by,auth.uid()); end if;
  return new;
end;
$$;
create trigger stamp_person before insert or update on splav.people
  for each row execute function splav.stamp_change();
create trigger stamp_booking before insert or update on splav.bookings
  for each row execute function splav.stamp_change();
create trigger stamp_participation before insert or update on splav.registrations
  for each row execute function splav.stamp_change();
create function splav.record_participation_history() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' then
    insert into splav.participation_history(group_id,registration_id,to_status,to_role,author_id)
      values(new.group_id,new.id,new.status,new.role,auth.uid());
  elsif old.status is distinct from new.status or old.role is distinct from new.role then
    insert into splav.participation_history(group_id,registration_id,from_status,to_status,from_role,to_role,author_id)
      values(new.group_id,new.id,old.status,new.status,old.role,new.role,auth.uid());
  end if;
  return new;
end;
$$;
create trigger record_participation_history after insert or update on splav.registrations
  for each row execute function splav.record_participation_history();

create or replace function splav.person_json(p splav.people) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('id',p.id,'team_id',p.team_id,'name',p.name,'phone',p.phone,
    'birth_date',p.birth_date,'notes',p.notes,'archived',p.archived,'merged_into',p.merged_into,
    'version',p.version,'created_by',p.created_by,'modified_by',p.modified_by,'updated_at',p.updated_at);
$$;
create or replace function splav.registration_json(r splav.registrations) returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_build_object('id',r.id,'trip_id',r.group_id,'booking_id',r.booking_id,
    'person_id',r.person_id,'role',r.role,'status',r.status,'parameters',r.parameters,
    'agreed_price_kopeks',r.agreed_price_kopeks,'version',r.version,'waiting_at',r.waiting_at,
    'created_by',r.created_by,'modified_by',r.modified_by,'updated_at',r.updated_at);
$$;
create or replace function splav.booking_json(b splav.bookings) returns jsonb
language sql immutable set search_path='' as $$
  select jsonb_build_object('id',b.id,'trip_id',b.group_id,'contact_person_id',b.contact_person_id,
    'contact_name',b.contact_name,'phone',b.phone,'notes',b.notes,'version',b.version,
    'created_by',b.created_by,'modified_by',b.modified_by,'updated_at',b.updated_at);
$$;
create or replace function public.roster_snapshot(p_trip_id uuid,p_after_revision bigint default -1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g splav.groups%rowtype; revision bigint;
begin
  select * into g from splav.groups where id=p_trip_id;
  if not exists(select 1 from splav.group_members gm join splav.team_members tm
    on tm.team_id=g.team_id and tm.user_id=gm.user_id
    where gm.group_id=p_trip_id and gm.user_id=auth.uid()) then
    raise exception 'Trip access denied' using errcode='42501';
  end if;
  select people_revision into revision from splav.teams where id=g.team_id;
  if p_after_revision = revision then
    return jsonb_build_object('trip_id',g.id,'team_id',g.team_id,'revision',revision,'unchanged',true);
  end if;
  return jsonb_build_object('trip_id',g.id,'team_id',g.team_id,'revision',revision,'unchanged',false,
    'people',coalesce((select jsonb_agg(splav.person_json(p)) from splav.people p
      where exists(select 1 from splav.registrations r where r.group_id=p_trip_id and r.person_id=p.id)
      or exists(select 1 from splav.bookings b where b.group_id=p_trip_id and b.contact_person_id=p.id)),'[]'::jsonb),
    'bookings',coalesce((select jsonb_agg(splav.booking_json(b) order by b.id)
      from splav.bookings b where b.group_id=p_trip_id),'[]'::jsonb),
    'participations',coalesce((select jsonb_agg(splav.registration_json(r)
      order by r.waiting_at nulls last,r.id) from splav.registrations r where r.group_id=p_trip_id),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.id)
      from splav.participation_history h where h.group_id=p_trip_id),'[]'::jsonb));
end;
$$;
revoke all on splav.participation_history from public,anon,authenticated;
revoke all on function splav.stamp_change(),splav.record_participation_history() from public,anon,authenticated;
-- Force existing cursors to receive the extended snapshot, even without an edit.
update splav.teams set people_revision=people_revision+1;
notify pgrst, 'reload schema';
