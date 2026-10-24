"""Anonymous guest viewer tokens (Day 2 FR-4.2).

A guest token is an opaque bearer string ``guest_anon_tok_<hex>``. It identifies a read-only viewer: it can
read public scores and streams and stage a cart on its own device, and nothing else. Write protection
itself lives in ``middleware/guest_boundary.py`` and applies to every guest-prefixed bearer, valid or not.

Records live in the shared state under ``DB["guest_tokens"]`` with the same shape as the reset seed
(``guest_anon_tok_7721`` never expires); issued tokens also carry ``expires_at`` (epoch seconds).
"""
import secrets
import time
from datetime import datetime, timezone
from typing import Callable, Optional

GUEST_TOKEN_PREFIX = "guest_anon_tok_"


def is_guest_token(token: Optional[str]) -> bool:
    return isinstance(token, str) and token.startswith(GUEST_TOKEN_PREFIX)


class GuestSessionService:
    def __init__(self, db: dict, lock, ttl_seconds: int = 2 * 3600, max_tokens: int = 10_000,
                 clock: Callable[[], float] = time.time):
        self.db = db
        self.lock = lock
        self.ttl_seconds = ttl_seconds
        self.max_tokens = max_tokens
        self.clock = clock

    def _expired(self, record: dict, now: float) -> bool:
        return record.get("expires_at") is not None and record["expires_at"] <= now

    @staticmethod
    def public_view(record: dict) -> dict:
        expires = record.get("expires_at")
        return {
            "guest_token": record["guest_token"],
            "role": record["role"],
            "read_only": record["read_only"],
            "expires_at": (datetime.fromtimestamp(expires, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                           if expires is not None else None),
        }

    def issue(self) -> dict:
        """Creates a fresh short-lived guest token. Expired tokens are pruned and the store is capped."""
        now = self.clock()
        with self.lock:
            tokens = self.db["guest_tokens"]
            for token in [t for t, rec in tokens.items() if self._expired(rec, now)]:
                del tokens[token]
            issued = [t for t, rec in tokens.items() if rec.get("expires_at") is not None]
            for token in sorted(issued, key=lambda t: tokens[t]["expires_at"])[:max(0, len(issued) - self.max_tokens + 1)]:
                del tokens[token]
            token = GUEST_TOKEN_PREFIX + secrets.token_hex(8)
            record = {"guest_token": token, "role": "guest", "read_only": True, "merged": False,
                      "merged_into": None, "expires_at": now + self.ttl_seconds}
            tokens[token] = record
            return self.public_view(record)

    def lookup(self, token: Optional[str]) -> Optional[dict]:
        """The stored record for a known, unexpired guest token, else None."""
        if not is_guest_token(token):
            return None
        with self.lock:
            record = self.db["guest_tokens"].get(token)
            if record is None or self._expired(record, self.clock()):
                return None
            return record
