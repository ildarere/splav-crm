"""Run against a fresh local Supabase seed. Uses only the Python standard library."""

import argparse
import concurrent.futures
import http.client
import json
import os
import threading
import urllib.error
import urllib.request
import uuid


RACE_GROUP = "00000000-0000-4000-8000-000000000002"
RETRY_GROUP = "00000000-0000-4000-8000-000000000003"
PASSWORD = "local-splav-demo-2026"


class Client:
    def __init__(self, url, key, email):
        self.url = url.rstrip("/")
        self.key = key
        self.token = None
        self.token = self.post("/auth/v1/token?grant_type=password", {
            "email": email,
            "password": PASSWORD,
        })["access_token"]

    def post(self, path, payload):
        headers = {"apikey": self.key, "Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            self.url + path, data=json.dumps(payload).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    def pull(self, group, cursor=0):
        return self.post("/rest/v1/rpc/pull_group", {
            "p_group_id": group,
            "p_after_revision": cursor,
            "p_limit": 1,
        })

    def submit(self, command, *, lose_response=False):
        result = self.post("/rest/v1/rpc/submit_registration", command)
        if lose_response:
            # The server has completed the RPC, but the simulated client receives no response.
            raise http.client.RemoteDisconnected("Simulated disconnect after server commit")
        return result


def command(group, name):
    return {
        "p_group_id": group,
        "p_operation_id": str(uuid.uuid4()),
        "p_person_id": str(uuid.uuid4()),
        "p_registration_id": str(uuid.uuid4()),
        "p_name": name,
    }


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def expect_rpc_error(call, sqlstate):
    try:
        call()
    except urllib.error.HTTPError as error:
        payload = json.load(error)
        require(payload.get("code") == sqlstate, f"Unexpected RPC error: {payload}")
    else:
        raise RuntimeError(f"Expected SQLSTATE {sqlstate}")


def check_race(first, second):
    barrier = threading.Barrier(2, timeout=10)
    commands = [command(RACE_GROUP, "Участник А"), command(RACE_GROUP, "Участник Б")]

    def submit_together(client, operation):
        barrier.wait()
        return client.submit(operation)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(submit_together, client, operation)
                   for client, operation in zip([first, second], commands)]
        results = [future.result() for future in futures]

    accepted = {"status": "accepted", "revision": 1}
    require(all(r['status']=='accepted' for r in results), f"Unexpected race results: {results}")
    winner = commands[results.index(accepted)]
    first_view = first.pull(RACE_GROUP)
    second_view = second.pull(RACE_GROUP)
    require(first_view == second_view, "Clients disagree on confirmed group state")
    require(first_view['cursor']==1 and first_view['has_more'], 'Incorrect first-page cursor')
    next_page=first.pull(RACE_GROUP,1)
    require(next_page['cursor']==2 and not next_page['has_more'], 'Incorrect second-page cursor')
    changes=first_view['changes']+next_page['changes']
    require({c['operation_id'] for c in changes}=={c['p_operation_id'] for c in commands}, 'A registration was lost')
    print('PASS: simultaneous registrations exceed the advisory limit and converge without duplicates')


def check_retry(first, second):
    operation = command(RETRY_GROUP, "Участник после сбоя")
    try:
        first.submit(operation, lose_response=True)
    except http.client.RemoteDisconnected:
        pass

    before_retry = second.pull(RETRY_GROUP)
    require(before_retry["cursor"] == 1, "The server should commit before the response is lost")
    require(first.submit(operation) == {"status": "accepted", "revision": 1},
            "The retry should return the original receipt")
    require(first.pull(RETRY_GROUP) == before_retry, "Replay changed the journal")
    require(first.pull(RETRY_GROUP, before_retry["cursor"])["changes"] == [],
            "Cursor unexpectedly returned an event after the retry")
    expect_rpc_error(lambda: second.submit(operation), "22023")
    expect_rpc_error(lambda: first.submit({**operation, "p_name": "Другая команда"}), "22023")
    print("PASS: retry after a simulated lost response returns the original receipt without duplication")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:54321")
    parser.add_argument("--key", default=os.environ.get("SPLAV_SUPABASE_KEY"),
                        help="local publishable or anon key, or set SPLAV_SUPABASE_KEY")
    args = parser.parse_args()
    if not args.key:
        parser.error("provide --key or set SPLAV_SUPABASE_KEY")

    first = Client(args.url, args.key, "organizer-a@example.com")
    second = Client(args.url, args.key, "organizer-b@example.com")
    for group in (RACE_GROUP, RETRY_GROUP):
        initial = first.pull(group)
        require(initial["cursor"] == 0 and initial["group"]["capacity"] == 1,
                "Acceptance fixtures must be fresh. Reset the disposable local Supabase database.")
    expect_rpc_error(lambda: first.pull(str(uuid.uuid4())), "42501")
    check_race(first, second)
    check_retry(first, second)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"HTTP {error.code}: {error.read().decode(errors='replace')}") from None
