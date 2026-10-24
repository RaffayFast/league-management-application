"""Room chat behind POST /api/v1/chat, GET /api/v1/chat/{room_id} and its SSE stream.

Room identity: a match page uses ``chat-{match_id}``; a co-stream uses exactly one room ``chat-{session_id}``
shared by every host and viewer (Day 2 FR-3.3), never one room per host.

Guests never reach ``post``: the guest boundary middleware answers 403 first. Members are authenticated
by the router. Every message passes synchronous moderation before broadcast (FR-5.3): main.py plugs in
ModerationService.moderate_live, which masks profanity, drops floods and enforces the rate limit.
"""
import re
from typing import Callable, Optional

CHAT_ROOM_RE = re.compile(r"chat-[A-Za-z0-9_.:-]{1,59}")
MESSAGE_ID_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
HISTORY_LIMIT = 200


class ChatService:
    def __init__(self, db: dict, lock, error_cls, feed, now: Callable[[], str],
                 moderate: Optional[Callable[[dict], dict]] = None):
        self.db = db
        self.lock = lock
        self.error_cls = error_cls
        self.feed = feed
        self.now = now
        self._moderate = moderate

    def set_moderator(self, moderate: Callable[[dict], dict]) -> None:
        """Plugs in the moderation engine (Group 3 ModerationService.moderate_live)."""
        self._moderate = moderate

    @staticmethod
    def valid_room(room_id) -> bool:
        return isinstance(room_id, str) and CHAT_ROOM_RE.fullmatch(room_id) is not None

    def _room(self, room_id: str) -> dict:
        return self.db.setdefault("chat_rooms", {}).setdefault(room_id, {"seq": 0, "messages": []})

    def history(self, room_id: str) -> dict:
        if not self.valid_room(room_id):
            raise self.error_cls(400, "VALIDATION_ERROR", "Invalid chat room id", {"fields": ["chat_room_id"]})
        with self.lock:
            room = self.db.get("chat_rooms", {}).get(room_id, {"messages": []})
            return {"chat_room_id": room_id, "messages": list(room["messages"])}

    def moderate(self, message: dict) -> dict:
        """Returns the message with ``text`` masked and ``flagged``/``reason`` set, or with ``dropped: True``
        for floods, rate-limit violations and blocked senders (spec 5.8 rules 1-3)."""
        if self._moderate is None:
            # Broadcasting unmoderated chat is never acceptable; a missing moderator is a wiring error
            raise RuntimeError("ChatService has no moderator; main.py must call set_moderator()")
        return self._moderate(message)

    def post(self, claims: dict, body) -> tuple:
        """Validates, moderates, appends with the next room sequence number and broadcasts. -> (body, status)."""
        fields = []
        if not isinstance(body, dict):
            body, fields = {}, ["body"]
        room_id, text, message_id = body.get("chat_room_id"), body.get("text"), body.get("message_id")
        if not self.valid_room(room_id):
            fields.append("chat_room_id")
        if not isinstance(text, str) or not text.strip() or len(text) > 500:
            fields.append("text")
        if message_id is not None and (not isinstance(message_id, str) or not MESSAGE_ID_RE.fullmatch(message_id)):
            fields.append("message_id")
        if fields:
            raise self.error_cls(400, "VALIDATION_ERROR", "Request validation failed", {"fields": fields})

        draft = {"message_id": message_id, "chat_room_id": room_id, "sender": claims["sub"], "text": text}
        moderated = self.moderate(draft)
        if moderated.get("dropped"):
            return {"chat_room_id": room_id, "status": "dropped", "reason": moderated.get("reason")}, 200
        with self.lock:
            room = self._room(room_id)
            room["seq"] += 1
            message = {"sequence": room["seq"], "message_id": message_id or f"{room_id}-{room['seq']}",
                       "chat_room_id": room_id, "sender": claims["sub"], "text": moderated["text"],
                       "flagged": bool(moderated.get("flagged")), "reason": moderated.get("reason"),
                       "sent_at": self.now()}
            room["messages"].append(message)
            del room["messages"][:-HISTORY_LIMIT]
        self.feed.publish(f"chat:{room_id}", "chat", message)
        return message, 201
