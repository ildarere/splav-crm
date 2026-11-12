"""Repeatable Stage 2 checks against a local Supabase. Uses synthetic data only."""
import argparse
import concurrent.futures
import json
import os
import threading
import urllib.error
import uuid

from server_acceptance import Client, command as legacy_command, expect_rpc_error, require
from stage1_acceptance import save


def uid():
    return str(uuid.uuid4())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:54321')
    parser.add_argument('--key', default=os.environ.get('SPLAV_SUPABASE_KEY'))
    args = parser.parse_args()
    if not args.key:
        parser.error('provide --key or SPLAV_SUPABASE_KEY')
    admin = Client(args.url, args.key, 'organizer-a@example.com')
    second = Client(args.url, args.key, 'organizer-a@example.com')
    limited = Client(args.url, args.key, 'organizer-c@example.com')
    catalog = admin.post('/rest/v1/rpc/list_trips', {})
    team = next(t['id'] for t in catalog['teams'] if t['role'] == 'admin')
    route = next(r['id'] for r in catalog['routes'] if r['team_id'] == team)

    def trip(capacity=2):
        trip_id = uid()
        result, _ = save(admin, team, trip_id, {
            'title': 'Этап 2 · ' + trip_id, 'route_id': route,
            'starts_at': '2032-08-01T09:00:00+04:00', 'ends_at': '2032-08-02T18:00:00+04:00',
            'timezone': 'Europe/Saratov', 'meeting_point': 'Тестовый причал',
            'meeting_at': '2032-08-01T08:30:00+04:00', 'responsible_names': 'Организатор',
            'capacity': capacity, 'base_price_kopeks': 700000, 'notes': 'Проверка этапа 2', 'status': 'open',
        })
        require(result['status'] == 'accepted', result)
        return trip_id

    def action(kind, payload, trip_id=None, version=0, client=admin, operation=None):
        envelope = {'p_operation_id': operation or uid(), 'p_team_id': team, 'p_trip_id': trip_id,
                    'p_kind': kind, 'p_payload': payload, 'p_expected_version': version}
        return client.post('/rest/v1/rpc/people_command', envelope), envelope

    def person(name, phone=''):
        person_id = uid()
        result, _ = action('save_person', {'id': person_id, 'name': name, 'phone': phone, 'notes': '', 'archived': False})
        require(result['status'] == 'accepted', result)
        return person_id

    def roster(trip_id, client=admin):
        return client.post('/rest/v1/rpc/roster_snapshot', {'p_trip_id': trip_id, 'p_after_revision': -1})

    def book(trip_id, people, contact, parameters=None):
        booking_id = uid()
        members = [{'id': uid(), 'person_id': p, 'role': 'client', 'parameters': parameters or {}} for p in people]
        result, envelope = action('save_booking', {'id': booking_id, 'contact_person_id': contact,
            'contact_name': 'Контакт семьи', 'phone': '+7 (900) 111-22-33', 'notes': 'Семья', 'members': members}, trip_id)
        require(result['status'] == 'accepted', result)
        return booking_id, members, envelope

    def statuses(trip_id, ids, status, client=admin, operation=None):
        versions = {p['id']: p['version'] for p in roster(trip_id)['participations'] if p['id'] in ids}
        return action('set_status', {'ids': ids, 'status': status, 'versions': versions}, trip_id, client=client, operation=operation)

    first = trip()
    people = [person('Родитель А ' + uid(), '+7 900 111-22-33'), person('Родитель Б ' + uid(), '8 (900) 111-22-33'), person('Ребёнок ' + uid())]
    contact = person('Контакт вне сплава ' + uid(), '+7 900 111-22-33')
    booking, members, booking_command = book(first, people, contact, {'clothing_size': '48', 'height_cm': 175})
    snapshot = roster(first)
    require(len(snapshot['bookings']) == 1 and len(snapshot['participations']) == 3, 'Family split or lost')
    require(contact not in [p['person_id'] for p in snapshot['participations']], 'Contact was added as a participant')
    require(all(p['status'] == 'application' for p in snapshot['participations']), 'Applications were auto-confirmed')
    ids = [p['id'] for p in members]
    rejected, _ = statuses(first, ids, 'confirmed')
    require(rejected['status'] == 'accepted', rejected)
    require(all(p['status'] == 'confirmed' for p in roster(first)['participations']), 'Family confirmation was incomplete')
    require(rejected['occupancy']['capacity_exceeded'], 'Missing advisory capacity warning')
    require(statuses(first, ids[:2], 'confirmed')[0]['status'] == 'accepted', 'Two-seat confirmation failed')
    require(statuses(first, ids[2:], 'waiting')[0]['status'] == 'accepted', 'Waitlist failed')
    require(statuses(first, ids[:1], 'cancelled')[0]['status'] == 'accepted', 'Cancellation failed')
    require(statuses(first, ids[2:], 'confirmed')[0]['status'] == 'accepted', 'Promotion failed')
    require(statuses(first, ids[:1], 'application')[0]['status'] == 'accepted', 'Restore failed')
    require(len(roster(first)['participations']) == 3, 'Restore created another participation')
    restored_history = [h for h in roster(first)['history'] if h['registration_id'] == ids[0]]
    require([h['to_status'] for h in restored_history] == ['application', 'confirmed', 'cancelled', 'application'],
            'Cancellation/restoration history was lost')
    require(all(h['author_id'] and h['changed_at'] for h in restored_history), 'History lost its author or time')
    require(admin.post('/rest/v1/rpc/people_command', booking_command)['status'] == 'accepted', 'Booking replay changed result')
    altered_command = {**booking_command, 'p_payload': {**booking_command['p_payload'], 'notes': 'Different payload'}}
    expect_rpc_error(lambda: admin.post('/rest/v1/rpc/people_command', altered_command), '22023')
    unchanged = admin.post('/rest/v1/rpc/roster_snapshot', {'p_trip_id': first, 'p_after_revision': roster(first)['revision']})
    require(unchanged['unchanged'] and 'participations' not in unchanged, 'Cursor failed to skip an unchanged roster')
    expect_rpc_error(lambda: limited.post('/rest/v1/rpc/people_command', booking_command), '42501')
    expect_rpc_error(lambda: roster(first, limited), '42501')
    limited_people = limited.post('/rest/v1/rpc/people_catalog', {})['people']
    require(not set(people).intersection(p['id'] for p in limited_people), 'Limited account received people from another trip')
    expect_rpc_error(lambda: action('save_person', {'id': people[0], 'name': 'Forbidden'}, version=1, client=limited), '42501')
    print('PASS family, separate contact, atomic capacity, shared phone, cancellation, restoration and scoped access')

    current = next(p for p in roster(first)['participations'] if p['id'] == ids[0])
    instructor, _ = action('edit_participation', {'id': ids[0], 'role': 'instructor', 'parameters': {'height_cm': 175}},
                           first, version=current['version'])
    require(instructor['status'] == 'accepted', instructor)
    require(statuses(first, ids[:1], 'confirmed')[0]['status'] == 'accepted', 'Instructor consumed the client limit')
    current = next(p for p in roster(first)['participations'] if p['id'] == ids[0])
    over_limit, _ = action('edit_participation', {'id': ids[0], 'role': 'client', 'parameters': {}}, first, version=current['version'])
    require(over_limit['status'] == 'accepted' and over_limit['occupancy']['capacity_exceeded'], over_limit)
    statuses(first, ids[:1], 'waiting')
    waiting_at = next(p for p in roster(first)['participations'] if p['id'] == ids[0])['waiting_at']
    statuses(first, ids[:1], 'waiting')
    require(next(p for p in roster(first)['participations'] if p['id'] == ids[0])['waiting_at'] == waiting_at,
            'Updating an existing waitlist entry changed its position')
    expect_rpc_error(lambda: action('edit_participation', {'id': ids[0], 'role': 'instructor', 'parameters': {'height_cm': -1}},
                                   first, version=next(p for p in roster(first)['participations'] if p['id'] == ids[0])['version']), '22023')
    print('PASS separate instructor limit, capacity on role changes, stable waiting order and parameter validation')

    again = trip(4)
    book(again, [people[0]], contact, {'height_cm': 180, 'clothing_size': '50'})
    history = roster(first)['participations'][0]['parameters']
    changed, _ = action('save_person', {'id': people[0], 'name': 'Уточнённое имя', 'phone': '+7 900 111-22-33'}, version=1)
    require(changed['status'] == 'accepted', changed)
    stale, _ = action('save_person', {'id': people[0], 'name': 'Устаревшее имя'}, version=1, client=second)
    require(stale['reason'] == 'version_conflict', stale)
    require(roster(first)['participations'][0]['parameters'] == history, 'Historical parameters changed with person card')
    require(len([p for p in admin.post('/rest/v1/rpc/people_catalog', {})['people'] if p['id'] == people[0]]) == 1, 'Repeat trip cloned person')

    race_trip = trip(1)
    _, race_members, _ = book(race_trip, people[:2], contact)
    barrier = threading.Barrier(2, timeout=10)
    operations = []
    for member in race_members:
        operations.append({'p_operation_id': uid(), 'p_team_id': team, 'p_trip_id': race_trip,
          'p_kind': 'set_status', 'p_expected_version': 0,
          'p_payload': {'ids': [member['id']], 'versions': {member['id']: 1}, 'status': 'confirmed'}})
    def race(client, operation):
        barrier.wait()
        return client.post('/rest/v1/rpc/people_command', operation)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(race, client, operation) for client, operation in zip([admin, second], operations)]
        results = [job.result() for job in jobs]
    require(sum(r['status'] == 'accepted' for r in results) == 2, results)
    winner = results.index(next(r for r in results if r['status'] == 'accepted'))
    require(second.post('/rest/v1/rpc/people_command', operations[winner]) == results[winner], 'Lost response replay differs')
    require(roster(race_trip, admin) == roster(race_trip, second), 'Clients disagree after race')
    require(sum(p['status'] == 'confirmed' for p in roster(race_trip)['participations']) == 2, 'Advisory capacity blocked a registration')
    print('PASS repeat visitor, historical parameters, optimistic conflict, concurrent last seat and lost response replay')

    duplicate = person('Дубликат для объединения ' + uid())
    merge_result, _ = action('merge_people', {'id': duplicate, 'target_id': contact, 'target_version': 1}, version=1)
    require(merge_result['status'] == 'accepted', merge_result)
    cards = {p['id']: p for p in admin.post('/rest/v1/rpc/people_catalog', {})['people']}
    require(cards[duplicate]['merged_into'] == contact and cards[duplicate]['archived'], 'Merge lost alias')
    collision, _ = action('merge_people', {'id': people[1], 'target_id': people[2], 'target_version': 1}, version=1)
    require(collision['reason'] == 'duplicate_participation', collision)
    legacy_trip = trip(2)
    legacy = legacy_command(legacy_trip, 'Очередь прежнего приложения')
    old = admin.submit(legacy)
    require(old['status'] == 'accepted', old)
    require(admin.submit(legacy) == old, 'Legacy replay differs')
    require(len(roster(legacy_trip)['bookings']) == 1, 'Legacy command missed booking')
    require(roster(legacy_trip)['participations'][0]['status'] == 'confirmed', 'Legacy command lost status')
    print('PASS explicit merge, duplicate participation protection and old command compatibility')


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f'HTTP {error.code}: {error.read().decode(errors="replace")}') from None
