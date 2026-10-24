"""Notification delivery with bounded retry and a persistent Dead-Letter Queue (Day 2 FR-5.2, spec 5.8).

Backend choice: SQLite (stdlib ``sqlite3``) in WAL mode at ``DLQ_PATH``. It survives application restarts
(the compose file mounts the repo, so ``data/`` persists), needs no extra service, and gives atomic,
de-duplicated inserts (``event_id`` is UNIQUE) so concurrent failures cannot corrupt the depth. Redis was
not needed: nothing else in the stack uses it.

Delivery semantics: at most ``RetryPolicy.max_attempts`` (3) attempts with exponential backoff between
them (base 0.2 s, factor 2 -> waits 0.2 s, 0.4 s); after the last failure the event is dead-lettered with
its attempt log. Production delivery runs on a worker pool so API requests never sleep; the deterministic
test path (``simulate_failures``) uses a no-op sleep.

"""
import json
import os
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Optional


def _utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class DeliveryFailed(Exception):
    """Raised by a transport when a notification could not be delivered."""


@dataclass
class Notification:
    kind: str                      # "score_update" | "costream_invite" | "order_status" | "test"
    channel: str                   # e.g. "match:match-m1", "user:player-alpha-2"
    payload: dict
    event_id: str = field(default_factory=lambda: f"ntf-{uuid.uuid4().hex[:16]}")


@dataclass(frozen=True)
class RetryPolicy:
    max_attempts: int = 3
    base_delay: float = 0.2
    factor: float = 2.0


@dataclass
class DeliveryResult:
    event_id: str
    delivered: bool
    attempts: int
    dead_lettered: bool
    attempt_log: list


class DeadLetterStore:
    """Persistent DLQ. All methods are thread-safe."""

    SCHEMA = """CREATE TABLE IF NOT EXISTS dead_letters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        channel TEXT NOT NULL,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL,
        last_error TEXT NOT NULL,
        attempt_log TEXT NOT NULL,
        dead_lettered_at TEXT NOT NULL)"""

    def __init__(self, path: str):
        self.path = path
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=5)
        if path != ":memory:":
            self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute(self.SCHEMA)

    def add(self, note: Notification, attempts: int, last_error: str, attempt_log: list) -> bool:
        """Dead-letters one event; a repeated event_id is ignored. True when a new row was written."""
        with self._lock:
            cur = self._conn.execute(
                "INSERT OR IGNORE INTO dead_letters (event_id, kind, channel, payload, attempts, last_error, "
                "attempt_log, dead_lettered_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (note.event_id, note.kind, note.channel, json.dumps(note.payload), attempts, last_error,
                 json.dumps(attempt_log), _utc()))
            return cur.rowcount == 1

    def depth(self) -> int:
        with self._lock:
            return self._conn.execute("SELECT COUNT(*) FROM dead_letters").fetchone()[0]

    def list(self, limit: int = 20) -> list:
        with self._lock:
            rows = self._conn.execute(
                "SELECT event_id, kind, channel, attempts, last_error, dead_lettered_at FROM dead_letters "
                "ORDER BY id LIMIT ?", (limit,)).fetchall()
        return [dict(zip(("event_id", "kind", "channel", "attempts", "last_error", "dead_lettered_at"), r))
                for r in rows]

    def get(self, event_id: str) -> Optional[dict]:
        with self._lock:
            row = self._conn.execute("SELECT event_id, kind, channel, payload, attempts, last_error, attempt_log "
                                     "FROM dead_letters WHERE event_id = ?", (event_id,)).fetchone()
        if row is None:
            return None
        keys = ("event_id", "kind", "channel", "payload", "attempts", "last_error", "attempt_log")
        out = dict(zip(keys, row))
        out["payload"], out["attempt_log"] = json.loads(out["payload"]), json.loads(out["attempt_log"])
        return out

    def clear(self) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM dead_letters")

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def healthy(self) -> bool:
        try:
            with self._lock:
                self._conn.execute("SELECT 1").fetchone()
            return True
        except sqlite3.Error:
            return False


def always_fail(_note: Notification) -> None:
    """Transport used by the deterministic DLQ probe: every delivery attempt fails."""
    raise DeliveryFailed("simulated downstream failure")


class NotificationDispatcher:
    def __init__(self, store: DeadLetterStore, policy: RetryPolicy = RetryPolicy(),
                 sleep: Callable[[float], None] = None, workers: int = 4):
        import time
        self.store, self.policy = store, policy
        self.sleep = sleep or time.sleep
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="notify")

    # ------------------------------------------------------------------ bounded retry
    def deliver(self, note: Notification, transport: Callable[[Notification], None],
                sleep: Callable[[float], None] = None) -> DeliveryResult:
        """Delivers one notification with bounded exponential retry, dead-lettering it on exhaustion.

        At most ``max_attempts`` calls to ``transport``; waits base, base*factor, ... between attempts and
        never after the last one. Any exception from the transport counts as a failed attempt."""
        sleep = sleep or self.sleep
        attempts = self.policy.max_attempts
        log = []
        for attempt in range(1, attempts + 1):
            try:
                transport(note)
                return DeliveryResult(note.event_id, True, attempt, False, log)
            except Exception as exc:  # noqa: BLE001 - a broken subscriber must not crash the dispatcher
                log.append({"attempt": attempt, "error": str(exc) or type(exc).__name__})
            if attempt < attempts:
                sleep(self.policy.base_delay * self.policy.factor ** (attempt - 1))
        self.store.add(note, attempts=attempts, last_error=log[-1]["error"], attempt_log=log)
        return DeliveryResult(note.event_id, False, attempts, True, log)

    # ------------------------------------------------------------------ glue
    def dispatch_async(self, note: Notification, transport: Callable[[Notification], None]):
        """Production path: retries (with real sleeps) run on a worker, never on the request thread."""
        return self._pool.submit(self.deliver, note, transport)

    def simulate_failures(self, count: int, context: str) -> list:
        """Deterministic probe: ``count`` test events go through the failure path with no waiting."""
        results = []
        for i in range(count):
            note = Notification(kind="test", channel=context, payload={"probe": i})
            results.append(self.deliver(note, always_fail, sleep=lambda _s: None))
        return results

    def status(self, limit: int = 20) -> dict:
        return {"queue_depth": self.store.depth(), "undelivered_events": self.store.list(limit)}
