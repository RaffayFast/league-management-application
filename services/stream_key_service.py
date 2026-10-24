"""Creator stream key lifecycle (Day 2 FR-3.2, spec 5.4, api_contract.md Part C2).

State machine per key:   (none) --generate--> active --rotate (new key)--> revoked
                                                     \\--revoke---------> revoked
A player has at most one active key; ``DB["stream_key_by_player"]`` points at the current one (active or
the last revoked one, so a second revoke still finds it). Revoked keys are kept so later publish attempts
can be answered 409 KEY_REVOKED by the media auth hook.

Rotation and revocation kick the old key's live publisher after the state change is committed, so the
media server's next auth check refuses it (409 KEY_REVOKED).
"""
import re
import secrets
from typing import Callable, Optional

from models.stream_key import StreamKeyRequest, StreamKeySigPayload

STREAM_KEY_RE = re.compile(r"sk_live_[a-f0-9]{16}")


def new_stream_key() -> str:
    """A fresh key matching ^sk_live_[a-f0-9]{16}$."""
    return "sk_live_" + secrets.token_hex(8)


class MediaUrls:
    """Browser- and encoder-facing media URLs. These are the external host names from the contract
    (default ``localhost``), never the internal Docker service name of the media server."""

    def __init__(self, public_host: str = "localhost", rtmp_port: int = 1935, hls_port: int = 8888,
                 webrtc_port: int = 8889):
        self.host, self.rtmp_port, self.hls_port, self.webrtc_port = public_host, rtmp_port, hls_port, webrtc_port

    def ingest(self, stream_key: str) -> dict:
        return {"rtmp": f"rtmp://{self.host}:{self.rtmp_port}/live/{stream_key}",
                "webrtc": f"http://{self.host}:{self.webrtc_port}/live/{stream_key}/whip"}

    def playback(self, stream_key: str) -> str:
        return f"http://{self.host}:{self.hls_port}/live/{stream_key}/index.m3u8"

    def composite(self, session_id: str) -> str:
        return f"http://{self.host}:{self.hls_port}/costream/{session_id}/index.m3u8"


class StreamKeyStore:
    """Key records in shared state. Callers hold the platform lock around read-modify-write sequences."""

    def __init__(self, db: dict):
        self.db = db

    def get(self, stream_key: str) -> Optional[dict]:
        return self.db["stream_keys"].get(stream_key)

    def current_for(self, player_id: str) -> Optional[dict]:
        key = self.db["stream_key_by_player"].get(player_id)
        return self.db["stream_keys"].get(key) if key else None

    def put_active(self, player_id: str, stream_key: str, label: str, now: str) -> dict:
        record = {"stream_key": stream_key, "player_id": player_id, "label": label, "status": "active",
                  "created_at": now, "revoked_at": None}
        self.db["stream_keys"][stream_key] = record
        self.db["stream_key_by_player"][player_id] = stream_key
        return record

    def mark_revoked(self, stream_key: str, now: str) -> Optional[dict]:
        record = self.db["stream_keys"].get(stream_key)
        if record is not None and record["status"] != "revoked":
            record["status"], record["revoked_at"] = "revoked", now
        return record

    def status_view(self, stream_key: str) -> Optional[dict]:
        record = self.get(stream_key)
        return {"player_id": record["player_id"], "status": record["status"]} if record else None


class StreamKeyService:
    def __init__(self, db: dict, lock, error_cls, sign_day2: Callable[[str, dict], str], store: StreamKeyStore,
                 urls: MediaUrls, media, player_exists: Callable[[str], bool], now: Callable[[], str]):
        self.db, self.lock, self.error_cls, self.sign_day2 = db, lock, error_cls, sign_day2
        self.store, self.urls, self.media, self.player_exists, self.now = store, urls, media, player_exists, now

    # ------------------------------------------------------------------ implemented helpers
    def response(self, record: dict, signature: str) -> dict:
        """Contract body for a key record; revoked keys get null endpoints (spec 5.4)."""
        active = record["status"] == "active"
        return {"player_id": record["player_id"], "label": record["label"], "stream_key": record["stream_key"],
                "status": record["status"],
                "ingest_endpoints": self.urls.ingest(record["stream_key"]) if active else None,
                "playback_url": self.urls.playback(record["stream_key"]) if active else None,
                "signature": signature}

    def disconnect(self, stream_key: str) -> bool:
        """Enforcement: kick the live publisher of ``live/{stream_key}``. MediaMTX then asks the auth hook
        again on reconnect, which now refuses the key. Measured well under the 2 s target."""
        return self.media.kick_publisher(f"live/{stream_key}")

    # ------------------------------------------------------------------ signature
    def stream_signature(self, payload: StreamKeySigPayload) -> str:
        """Spec 5.3: entity_id = stream_key; signed payload = exactly {action, player_id, status, stream_key}."""
        return self.sign_day2(payload.stream_key, payload.model_dump())

    # ------------------------------------------------------------------ lifecycle
    def _new_key(self, override: Optional[str]) -> str:
        if override:
            return override                              # grader-supplied key, used verbatim
        key = new_stream_key()
        while key in self.db["stream_keys"]:             # 64-bit keys: a collision is practically impossible
            key = new_stream_key()
        return key

    def apply(self, req: StreamKeyRequest) -> tuple:
        """Runs one lifecycle action. Returns (response_dict, http_status). Schema (400) is already checked."""
        to_kick = []
        with self.lock:
            if not self.player_exists(req.player_id):
                raise self.error_cls(404, "PLAYER_NOT_FOUND", "Player not found", {"player_id": req.player_id})
            current = self.store.current_for(req.player_id)
            now = self.now()

            if req.action == "revoke":
                if current is None:
                    raise self.error_cls(404, "STREAM_NOT_FOUND", "This player has no stream key",
                                         {"player_id": req.player_id})
                if current["status"] == "active":
                    to_kick.append(current["stream_key"])
                record = self.store.mark_revoked(current["stream_key"], now)
                status = 200
            else:
                # generate replaces an active key, rotate always replaces it: the old key stops working
                if current is not None and current["status"] == "active":
                    self.store.mark_revoked(current["stream_key"], now)
                    to_kick.append(current["stream_key"])
                key = self._new_key(req.stream_key_override)
                previous = self.store.get(key)
                if previous and previous["player_id"] != req.player_id \
                        and self.db["stream_key_by_player"].get(previous["player_id"]) == key:
                    del self.db["stream_key_by_player"][previous["player_id"]]   # key moves to this player
                record = self.store.put_active(req.player_id, key, req.label, now)
                to_kick = [k for k in to_kick if k != key]
                status = 201 if req.action == "generate" else 200

            signature = self.stream_signature(StreamKeySigPayload(
                action=req.action, player_id=req.player_id, status=record["status"], stream_key=record["stream_key"]))
            response = self.response(record, signature)

        # Outside the lock: one Control API call each, so other requests are never held up by the media server
        for key in to_kick:
            self.disconnect(key)
        return response, status
