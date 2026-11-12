"""Additive Stage 1 acceptance against local Supabase. Creates unique fixtures on each run."""

import argparse
import concurrent.futures
import os
import threading
import urllib.error
import uuid

from server_acceptance import Client, expect_rpc_error, require


def identifier():
    return str(uuid.uuid4())


def save(client, team, trip_id, fields, version=0, operation_id=None):
    payload = {
        "p_operation_id": operation_id or identifier(),
        "p_team_id": team,
        "p_trip_id": trip_id,
        "p_expected_version": version,
        "p_trip": fields,
    }
    return client.post("/rest/v1/rpc/save_trip", payload), payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:54321")
    parser.add_argument("--key", default=os.environ.get("SPLAV_SUPABASE_KEY"))
    args = parser.parse_args()
    if not args.key:
        parser.error("provide --key or set SPLAV_SUPABASE_KEY")

    admin = Client(args.url, args.key, "organizer-a@example.com")
    other_device = Client(args.url, args.key, "organizer-a@example.com")
    limited = Client(args.url, args.key, "organizer-c@example.com")
    catalog = admin.post("/rest/v1/rpc/list_trips", {})
    team = next(t["id"] for t in catalog["teams"] if t["role"] == "admin")
    route_id = identifier()
    route_command = {"p_operation_id": identifier(), "p_team_id": team,
                     "p_route_id": route_id, "p_name": f"Тестовый маршрут {route_id}"}
    route_result = admin.post("/rest/v1/rpc/create_route", route_command)
    require(route_result["status"] == "accepted", f"Route create failed: {route_result}")
    require(admin.post("/rest/v1/rpc/create_route", route_command) == route_result,
            "Route replay changed its result")
    expect_rpc_error(lambda: limited.post("/rest/v1/rpc/create_route", route_command), "42501")
    duplicate_route = {**route_command, "p_operation_id": identifier(), "p_route_id": identifier()}
    require(admin.post("/rest/v1/rpc/create_route", duplicate_route)["reason"] == "route_exists",
            "A duplicate route changed the queued route identifier")
    expect_rpc_error(lambda: admin.post("/rest/v1/rpc/create_route",
                     {**route_command, "p_name": "Different payload"}), "22023")

    fields = {
        "title": "Выезд приёмки " + identifier(),
        "route_id": route_id,
        "starts_at": "2031-05-31T09:00:00+04:00",
        "ends_at": "2031-06-01T18:00:00+04:00",
        "timezone": "Europe/Saratov",
        "meeting_point": "Тестовая площадь",
        "meeting_at": "2031-05-31T08:30:00+04:00",
        "responsible_names": "Тестовый организатор",
        "capacity": 1,
        "base_price_kopeks": 345050,
        "notes": "Вымышленные данные для проверки",
        "status": "open",
    }
    first_id, second_id = identifier(), identifier()
    first, first_command = save(admin, team, first_id, fields)
    require(first["status"] == "accepted", f"First trip create failed: {first}")
    require(admin.post("/rest/v1/rpc/save_trip", first_command) == first,
            "Create replay changed its result")
    second_fields = {**fields, "title": fields["title"] + " · второй", "capacity": 2,
                     "starts_at": "2031-06-07T09:00:00+04:00",
                     "ends_at": "2031-06-08T18:00:00+04:00",
                     "meeting_at": "2031-06-07T08:30:00+04:00"}
    second, _ = save(admin, team, second_id, second_fields)
    require(second["status"] == "accepted", f"Second trip create failed: {second}")
    visible = admin.post("/rest/v1/rpc/list_trips", {})["trips"]
    require({first_id, second_id}.issubset({t["id"] for t in visible}), "Created trips missing")
    restricted = limited.post("/rest/v1/rpc/list_trips", {})["trips"]
    require({t["id"] for t in restricted} == {"00000000-0000-4000-8000-000000000001"},
            "Restricted catalog exposed other trips")
    expect_rpc_error(lambda: limited.pull(first_id), "42501")
    expect_rpc_error(lambda: limited.post("/rest/v1/rpc/save_trip", first_command), "42501")
    expect_rpc_error(lambda: save(limited, team, first_id, fields, version=1), "42501")
    expect_rpc_error(lambda: save(limited, team, identifier(), fields), "42501")
    require(admin.pull(first_id)["group"]["base_price_kopeks"] == 345050,
            "Price lost integer kopeks")
    print("PASS: unique routes and trips, exact-price metadata, restricted catalog/read/write/replay")

    # Two independent sessions read version 1 and race to edit it.
    barrier = threading.Barrier(2, timeout=10)

    def edit_together(client, suffix):
        barrier.wait()
        return save(client, team, first_id, {**fields, "title": fields["title"] + suffix}, version=1)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        a = executor.submit(edit_together, admin, " А")
        b = executor.submit(edit_together, other_device, " Б")
        edits = [a.result(), b.result()]
    winner = next(pair for pair in edits if pair[0]["status"] == "accepted")
    loser = next(pair for pair in edits if pair[0]["status"] == "rejected")
    require(winner[0]["trip"]["metadata_version"] == 2, "Incorrect metadata version")
    require(loser[0]["reason"] == "version_conflict", f"Wrong stale-edit result: {loser[0]}")
    require(admin.post("/rest/v1/rpc/save_trip", winner[1]) == winner[0],
            "Lost-response replay changed metadata again")
    require(admin.post("/rest/v1/rpc/save_trip", loser[1]) == loser[0],
            "Conflict replay changed its stored result")
    expect_rpc_error(lambda: admin.post("/rest/v1/rpc/save_trip",
                     {**winner[1], "p_trip": {**winner[1]["p_trip"], "notes": "changed payload"}}), "22023")
    require(other_device.pull(first_id)["group"]["metadata_version"] == 2,
            "Other device did not receive edited metadata")
    print("PASS: concurrent metadata edits, version conflict and replay after discarded response")

    for name in ("Первый участник", "Второй участник"):
        registration = {"p_group_id": second_id, "p_operation_id": identifier(),
                        "p_person_id": identifier(), "p_registration_id": identifier(), "p_name": name}
        result = admin.post("/rest/v1/rpc/submit_registration", registration)
        require(result["status"] == "accepted", f"Registration failed: {result}")
    require(admin.pull(second_id)["group"]["metadata_version"] == 1,
            "Registration revisions changed the metadata version")
    lowered, _ = save(admin, team, second_id, {**second_fields, "capacity": 1}, version=1)
    require(lowered['status'] == 'accepted' and lowered['trip']['capacity_exceeded'], f'Advisory limit warning missing: {lowered}')
    require(len(admin.pull(second_id)["changes"]) == 1, "Expected pagination limit of 1")
    page = admin.pull(second_id, 1)
    require(page["cursor"] == 2 and not page["has_more"], "Registration cursor lost a revision")

    closed_fields = {**second_fields, "status": "closed"}
    closed, _ = save(admin, team, second_id, closed_fields, version=2)
    require(closed["status"] == "accepted", f"Closing trip failed: {closed}")
    require(admin.post("/rest/v1/rpc/submit_registration", registration)["status"] == "accepted",
            "Old accepted registration receipt changed after closing")
    fresh = {**registration, "p_operation_id": identifier(), "p_person_id": identifier(),
             "p_registration_id": identifier()}
    require(admin.post("/rest/v1/rpc/submit_registration", fresh)["reason"] == "trip_not_open",
            "Closed trip accepted a fresh registration")
    expect_rpc_error(lambda: limited.post("/rest/v1/rpc/submit_registration", fresh), "42501")
    print("PASS: capacity validation, separate registration/metadata revisions, closed-trip rules")

    in_progress_fields = {**second_fields, "status": "in_progress"}
    in_progress, _ = save(admin, team, second_id, in_progress_fields, version=3)
    require(in_progress["status"] == "accepted", "Admin could not start the closed trip")
    completed_fields = {**second_fields, "status": "completed"}
    completed, completed_command = save(admin, team, second_id, completed_fields, version=4)
    require(completed["status"] == "accepted", "Admin could not complete the trip")
    require(admin.post("/rest/v1/rpc/save_trip", completed_command) == completed,
            "Completed-trip receipt could not be replayed")
    frozen, _ = save(admin, team, second_id, {**completed_fields, "notes": "Late edit"}, version=5)
    require(frozen["reason"] == "trip_finalized", "Completed trip allowed a late metadata edit")
    print("PASS: lifecycle transitions, finalization and replay of the completion command")

    expect_rpc_error(lambda: save(admin, team, identifier(), {**fields, "timezone": "+04"}), "22023")
    expect_rpc_error(lambda: save(admin, team, identifier(), {**fields, "ends_at": fields["starts_at"]}), "22023")
    expect_rpc_error(lambda: save(admin, team, identifier(), {**fields, "base_price_kopeks": -1}), "22023")
    print("PASS: invalid timezone, date interval and negative price rejected")
    print(f"Created rerunnable fixtures {first_id} and {second_id}")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"HTTP {error.code}: {error.read().decode(errors='replace')}") from None
