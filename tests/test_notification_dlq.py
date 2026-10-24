"""Bounded retry and the persistent Dead-Letter Queue (Day 2 FR-5.2)."""
import threading
import time

import pytest

import main
from services.notification_dlq import (DeadLetterStore, DeliveryFailed, Notification, NotificationDispatcher,
                                       RetryPolicy, always_fail)


@pytest.fixture()
def store(tmp_path):
    dlq = DeadLetterStore(str(tmp_path / "dlq.sqlite3"))
    yield dlq
    dlq.close()


def _note(i=0):
    return Notification(kind="costream_invite", channel="user:player-alpha-2", payload={"i": i}, event_id=f"ntf-{i}")


# ---------------------------------------------------------------- schema, helpers, plumbing
def test_store_is_inspectable_and_idempotent(store):
    assert store.add(_note(1), 3, "timeout", [{"attempt": 1, "error": "timeout"}]) is True
    assert store.add(_note(1), 3, "timeout", []) is False          # same event_id never counted twice
    assert store.depth() == 1
    assert store.list()[0]["event_id"] == "ntf-1" and store.list()[0]["attempts"] == 3
    assert store.get("ntf-1")["payload"] == {"i": 1} and store.get("ntf-1")["attempt_log"][0]["error"] == "timeout"
    store.clear()
    assert store.depth() == 0


def test_store_survives_a_restart(tmp_path):
    path = str(tmp_path / "persist.sqlite3")
    first = DeadLetterStore(path)
    first.add(_note(7), 3, "down", [])
    first.close()                                                     # the "process" goes away
    second = DeadLetterStore(path)
    assert second.depth() == 1                                        # a new one sees the same queue
    second.close()


def test_concurrent_failures_keep_an_exact_depth(store):
    threads = [threading.Thread(target=store.add, args=(_note(i), 3, "x", [])) for i in range(50)]
    threads += [threading.Thread(target=store.add, args=(_note(i), 3, "x", [])) for i in range(50)]  # duplicates
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert store.depth() == 50 and store.healthy()


def test_reset_empties_the_platform_queue(client):
    main.DLQ_STORE.add(_note(99), 3, "x", [])
    assert main.DLQ_STORE.depth() == 1
    client.post("/audit/v1/reset", json={})
    assert main.DLQ_STORE.depth() == 0


def test_default_policy_is_three_attempts_with_exponential_backoff():
    assert RetryPolicy() == RetryPolicy(max_attempts=3, base_delay=0.2, factor=2.0)


# ---------------------------------------------------------------- contract behaviour
def test_success_on_first_attempt_is_not_dead_lettered(store):
    result = NotificationDispatcher(store).deliver(_note(), lambda n: None, sleep=lambda s: None)
    assert (result.delivered, result.attempts, result.dead_lettered) == (True, 1, False) and store.depth() == 0


def test_retries_are_bounded_and_back_off_exponentially(store):
    calls, waits = [], []

    def transport(note):
        calls.append(note.event_id)
        raise DeliveryFailed("subscriber offline")

    result = NotificationDispatcher(store).deliver(_note(), transport, sleep=waits.append)
    assert len(calls) == 3 and waits == [0.2, 0.4]                    # no wait after the final attempt
    assert (result.delivered, result.dead_lettered) == (False, True) and store.depth() == 1
    assert [a["attempt"] for a in store.get("ntf-0")["attempt_log"]] == [1, 2, 3]


def test_flaky_delivery_recovers_within_the_budget(store):
    outcomes = iter([DeliveryFailed("blip"), DeliveryFailed("blip"), None])

    def transport(_note):
        err = next(outcomes)
        if err:
            raise err

    result = NotificationDispatcher(store).deliver(_note(), transport, sleep=lambda s: None)
    assert (result.delivered, result.attempts, store.depth()) == (True, 3, 0)


def test_simulated_failures_are_deterministic_and_never_sleep(store):
    started = time.perf_counter()
    NotificationDispatcher(store, sleep=lambda s: (_ for _ in ()).throw(AssertionError("slept"))).simulate_failures(5, "chat-x")
    assert store.depth() == 5 and time.perf_counter() - started < 1.0


def test_async_dispatch_runs_off_the_request_thread(store):
    future = NotificationDispatcher(store, policy=RetryPolicy(base_delay=0.01)).dispatch_async(_note(), always_fail)
    assert future.result(timeout=5).dead_lettered is True and store.depth() == 1
