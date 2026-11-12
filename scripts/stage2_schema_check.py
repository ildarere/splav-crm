from pathlib import Path
import subprocess
import time
import uuid


container = 'splav-stage2-schema-check'


def docker(args, **kwargs):
    return subprocess.run(['docker', *args], capture_output=True, encoding='utf-8', **kwargs)


def sql(query, database='postgres'):
    result = docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres',
                     '-d', database, '-v', 'ON_ERROR_STOP=1'], input=query)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


auth = '''
create schema extensions;
create extension pgcrypto with schema extensions;
create schema auth;
create table auth.users (
  instance_id uuid, id uuid primary key, aud text, role text, email text,
  encrypted_password text, email_confirmed_at timestamptz, confirmation_token text,
  recovery_token text, email_change_token_new text, email_change text,
  email_change_token_current text, reauthentication_token text,
  raw_app_meta_data jsonb, raw_user_meta_data jsonb, created_at timestamptz, updated_at timestamptz
);
create table auth.identities (
  id uuid primary key, provider_id text, user_id uuid references auth.users(id), identity_data jsonb,
  provider text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
'''

start = docker(['run', '--rm', '-d', '--name', container, '-e',
                'POSTGRES_HOST_AUTH_METHOD=trust', 'postgres:16-alpine'])
if start.returncode:
    raise RuntimeError(start.stderr)
try:
    for _ in range(40):
        if not docker(['exec', container, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres']).returncode:
            break
        time.sleep(0.5)
    else:
        raise RuntimeError('PostgreSQL not ready')
    sql('create role anon; create role authenticated; create database clean;')
    migrations = sorted(Path('supabase/migrations').glob('*.sql'))
    sql(auth)
    sql(migrations[0].read_text(encoding='utf-8'))
    sql('''
      insert into auth.users (id, email) values ('99999999-0000-4000-8000-000000000001', 'legacy@example.com');
      insert into splav.groups (id, title, route, starts_at, capacity) values
        ('99999999-0000-4000-8000-000000000002', 'Legacy empty route', '', now(), 5),
        ('99999999-0000-4000-8000-000000000003', 'Legacy long route', repeat('x', 201), now(), 5);
      insert into splav.group_members (group_id, user_id)
      select id, '99999999-0000-4000-8000-000000000001' from splav.groups;
      set request.jwt.claim.sub = '99999999-0000-4000-8000-000000000001';
      select public.submit_registration('99999999-0000-4000-8000-000000000002',
        '99999999-0000-4000-8000-000000000004','99999999-0000-4000-8000-000000000005',
        '99999999-0000-4000-8000-000000000006', 'Legacy participant');
    ''')
    before = sql("select (select count(*) from splav.registrations), (select count(*) from splav.operation_receipts), (select count(*) from splav.group_changes)")
    for migration in migrations[1:]:
        sql(migration.read_text(encoding='utf-8'))
    after = sql("select (select count(*) from splav.registrations), (select count(*) from splav.operation_receipts), (select count(*) from splav.group_changes)")
    assert before == after == '1|1|1', (before, after)
    assert sql('select count(*) from splav.registrations where booking_id is not null and status=\'confirmed\'') == '1'
    assert sql('select count(*) from splav.bookings') == '1'
    assert sql('select count(*) from splav.participation_history') == '1'
    assert sql("select string_agg(char_length(route)::text, ',' order by char_length(route)) from splav.groups") == '0,201'
    assert sql("set request.jwt.claim.sub = '99999999-0000-4000-8000-000000000001'; select public.submit_registration('99999999-0000-4000-8000-000000000002','99999999-0000-4000-8000-000000000004','99999999-0000-4000-8000-000000000005','99999999-0000-4000-8000-000000000006','Legacy participant')->>'status'") == 'accepted'
    print('PASS: v1 migration preserves registrations, receipts, journal, arbitrary route strings and accepted replay')

    for version, status in [(1, 'cancelled'), (2, 'application')]:
        operation = str(uuid.uuid4())
        last_command = f"""public.people_command('{operation}',
            (select team_id from splav.groups where id='99999999-0000-4000-8000-000000000002'),
            '99999999-0000-4000-8000-000000000002','set_status',
            '{{"ids":["99999999-0000-4000-8000-000000000006"],"status":"{status}","versions":{{"99999999-0000-4000-8000-000000000006":{version}}}}}'::jsonb)"""
        result = sql(f"""
          set request.jwt.claim.sub = '99999999-0000-4000-8000-000000000001';
          select {last_command}->>'status';
        """)
        assert result == 'accepted', result
    assert sql("select string_agg(to_status,',' order by id) from splav.participation_history") == 'confirmed,cancelled,application'
    assert sql('select count(*) from splav.registrations') == '1'
    print('PASS: an upgraded participant cancels and restores with the same ID and full transition history')

    sql("delete from splav.group_members where group_id='99999999-0000-4000-8000-000000000002'")
    for expression in [last_command, "public.roster_snapshot('99999999-0000-4000-8000-000000000002',0)"]:
        try:
            sql(f"set request.jwt.claim.sub = '99999999-0000-4000-8000-000000000001'; select {expression};")
        except RuntimeError as error:
            assert 'Trip access denied' in str(error), str(error)
        else:
            raise AssertionError('A revoked membership allowed a snapshot or receipt replay')
    print('PASS: revoking access blocks the same user from snapshots and previously accepted command receipts')

    sql(auth, 'clean')
    for migration in migrations:
        sql(migration.read_text(encoding='utf-8'), 'clean')
    sql(Path('supabase/seed.sql').read_text(encoding='utf-8'), 'clean')
    sql(Path('supabase/seed_stage1.sql').read_text(encoding='utf-8'), 'clean')
    sql(Path('supabase/seed_stage1.sql').read_text(encoding='utf-8'), 'clean')
    assert sql('select (select count(*) from splav.groups), (select count(*) from splav.team_members), (select count(*) from splav.group_members)', 'clean') == '4|3|9'
    print('PASS: clean-install migrations and seed, additive Stage1 seed can be applied twice')
finally:
    docker(['stop', '--time', '1', container])
