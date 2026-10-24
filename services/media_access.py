"""Who may publish or read which MediaMTX path. Called by MediaMTX's HTTP auth hook for every session.

MediaMTX (authMethod: http) POSTs {user, password, ip, action, path, protocol, id, query} to
/internal/media/auth and admits the session only on a 2xx answer. Paths:

- ``live/{stream_key}``                  solo broadcast; the key in the path is the credential
- ``costream/{session_id}/{player_id}``  one co-stream participant; ``?key=<that player's active key>``
- ``costream/{session_id}``              the composite, published only by the internal compositor

Existing sessions are not re-checked by MediaMTX, so rotation and revocation also kick the live publisher
through the Control API (see StreamKeyService and MediaServerClient). Revoked keys answer 409 KEY_REVOKED.
"""
import hmac
from typing import Callable, Optional
from urllib.parse import parse_qs

PUBLISH, READ = "publish", ("read", "playback")


class MediaAccessPolicy:
    def __init__(self, key_status: Callable[[str], Optional[dict]], session_view: Callable[[str], Optional[dict]],
                 internal_user: str, internal_pass: str):
        self.key_status = key_status      # stream_key -> {"player_id", "status"} or None
        self.session_view = session_view  # session_id -> stored co-stream session or None
        self.internal_user = internal_user
        self.internal_pass = internal_pass

    def _internal(self, req: dict) -> bool:
        return bool(self.internal_user) and hmac.compare_digest(str(req.get("user") or ""), self.internal_user) \
            and hmac.compare_digest(str(req.get("password") or ""), self.internal_pass)

    @staticmethod
    def _deny(status: int, code: str, message: str, **details) -> tuple:
        return status, {"error": {"code": code, "message": message, "details": details}}

    def _key_decision(self, key: str, player_id: Optional[str] = None) -> tuple:
        record = self.key_status(key)
        if record is None:
            return self._deny(404, "STREAM_NOT_FOUND", "Unknown stream key", stream_key=key)
        if record["status"] == "revoked":
            return self._deny(409, "KEY_REVOKED", "This stream key was revoked", stream_key=key)
        if player_id is not None and record["player_id"] != player_id:
            return self._deny(403, "FORBIDDEN", "Stream key belongs to another player", stream_key=key)
        return 200, {"allowed": True}

    def decide(self, req: dict) -> tuple:
        """Returns (http_status, body) for one MediaMTX auth request."""
        action, path = str(req.get("action") or ""), str(req.get("path") or "")
        if self._internal(req):
            return 200, {"allowed": True}          # compositor and other in-cluster tools
        parts = path.split("/")
        if parts[0] == "live" and len(parts) == 2:
            if action == PUBLISH or action in READ:
                return self._key_decision(parts[1])
        elif parts[0] == "costream" and len(parts) == 2 and action in READ:
            return 200, {"allowed": True}          # the public composite
        elif parts[0] == "costream" and len(parts) == 3 and action == PUBLISH:
            session = self.session_view(parts[1])
            if not session or session.get("status") != "active" or parts[2] not in session.get("active_participants", []):
                return self._deny(403, "FORBIDDEN", "Not an active participant of this co-stream", path=path)
            key = (parse_qs(str(req.get("query") or "")).get("key") or [""])[0]
            return self._key_decision(key, player_id=parts[2])
        return self._deny(403, "FORBIDDEN", "Action not allowed on this path", path=path, action=action)
