-- Additive fixtures for the local development stack. Safe to apply again without resetting data.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, reauthentication_token,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000c1',
  'authenticated', 'authenticated', 'organizer-c@example.com',
  extensions.crypt('local-splav-demo-2026', extensions.gen_salt('bf')), now(),
  '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', '{}', now(), now())
on conflict (id) do nothing;

insert into auth.identities (
  id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select gen_random_uuid(), id::text, id,
  jsonb_build_object('sub', id, 'email', email, 'email_verified', true), 'email', now(), now(), now()
from auth.users u where id = '00000000-0000-4000-8000-0000000000c1'
  and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');

insert into splav.team_members (team_id, user_id, role)
select '00000000-0000-4000-8000-000000000010', u.id,
  case when u.email = 'organizer-a@example.com' then 'admin' else 'organizer' end
from auth.users u
where u.id in ('00000000-0000-4000-8000-0000000000a1',
  '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000c1')
on conflict (team_id, user_id) do nothing;

insert into splav.group_members (group_id, user_id)
select '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000000c1'
where exists (select 1 from splav.groups where id = '00000000-0000-4000-8000-000000000001')
on conflict (group_id, user_id) do nothing;

insert into splav.routes (id, team_id, name)
values ('00000000-0000-4000-8000-000000000020',
  '00000000-0000-4000-8000-000000000010', 'Река Хопёр · двухдневный маршрут')
on conflict (team_id, name) do nothing;
