-- Disposable accounts and groups for local development only.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, reauthentication_token,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000', demo.id, 'authenticated', 'authenticated',
  demo.email, extensions.crypt('local-splav-demo-2026', extensions.gen_salt('bf')), now(),
  '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', '{}', now(), now()
from (values
  ('00000000-0000-4000-8000-0000000000a1'::uuid, 'organizer-a@example.com'),
  ('00000000-0000-4000-8000-0000000000b1'::uuid, 'organizer-b@example.com')
) as demo(id, email);

insert into auth.identities (
  id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select gen_random_uuid(), id::text, id,
  jsonb_build_object('sub', id, 'email', email, 'email_verified', true), 'email', now(), now(), now()
from auth.users where id in ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b1');

insert into splav.routes (id, team_id, name) values
  (gen_random_uuid(), '00000000-0000-4000-8000-000000000010', 'Река Медведица · учебный маршрут'),
  (gen_random_uuid(), '00000000-0000-4000-8000-000000000010', 'Тестовый маршрут')
on conflict (team_id, name) do nothing;

insert into splav.groups (id, title, route, starts_at, capacity, route_id, ends_at, meeting_at)
select fixture.id::uuid, fixture.title, fixture.route, fixture.starts_at::timestamptz, fixture.capacity,
  r.id, fixture.starts_at::timestamptz + interval '1 day', fixture.starts_at::timestamptz - interval '30 minutes'
from (values
  ('00000000-0000-4000-8000-000000000001', 'Субботний сплав', 'Река Медведица · учебный маршрут', '2030-06-15T09:00:00+04:00', 1),
  ('00000000-0000-4000-8000-000000000002', 'Проверка конкуренции', 'Тестовый маршрут', '2030-06-15T09:00:00+04:00', 1),
  ('00000000-0000-4000-8000-000000000003', 'Проверка повтора', 'Тестовый маршрут', '2030-06-15T09:00:00+04:00', 1),
  ('00000000-0000-4000-8000-000000000004', 'Интеграционная проверка Flutter', 'Тестовый маршрут', '2030-06-15T09:00:00+04:00', 1)
) as fixture(id, title, route, starts_at, capacity)
join splav.routes r on r.name = fixture.route and r.team_id = '00000000-0000-4000-8000-000000000010';

insert into splav.group_members (group_id, user_id)
select g.id, u.id from splav.groups as g cross join auth.users as u
where u.id in ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b1');
