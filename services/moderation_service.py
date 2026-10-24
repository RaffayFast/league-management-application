"""Synchronous pre-broadcast chat moderation (Day 2 FR-5.3, spec 5.8, api_contract.md Part C6).

Binding endpoint rules (spec 5.8, which wins over the looser FR-5.3 prose; see Architecture.md section 8):
  1. clean message      -> kept unchanged, flagged false, reason null
  2. profanity/leetspeak -> each offending token replaced in place by "***", flagged true,
                            reason "profanity_leetspeak", sender appended to kicked_users (deduplicated,
                            first-violation order). The unmasked text is never broadcast.
  3. flood              -> 4+ identical consecutive characters (case-insensitive) or "!!!" / "???":
                            message dropped from filtered_messages, sender appended to muted_users
                            (FR-5.3 calls this "flood_character_repeat")
  4. DLQ                -> simulate_failed_notifications > 0 dead-letters that many test events first
Live chat additionally limits a sender to 3 messages per 2-second window ("rate_limit_exceeded").

Matching: each word is normalised (lower case, leetspeak substitutions, separators removed) and compared
with the dictionary, allowing common suffixes ("scams", "fucking") but not arbitrary containment, so
"scampi" or "classic" stay clean. "!" is read both as "i" (sh!t) and as a separator (s!c@m). Only the word's
core is masked; surrounding punctuation is kept ("scam!" -> "***!").

Kick/mute state lives in a per-room registry whose updates are atomic and de-duplicated, so the 10-thread
moderator race (hidden scenario 3) yields exactly ["user-spammer"] with no errors.
"""
import re
import time
from collections import deque
from typing import Callable, Optional

from models.moderation import ModerationRequest, ModerationSigPayload

# Configuration from the spec (data, not logic)
LEET_SUBSTITUTIONS = {"@": "a", "0": "o", "1": "i", "!": "i", "3": "e", "$": "s"}
OBFUSCATION_SEPARATORS = "_.-*"
PROFANITY_TERMS = ("badword", "porn", "scam", "fuck", "shit", "bitch", "asshole", "idiot_spam")
MASK = "***"
FLOOD_REPEAT = 4          # identical consecutive characters
FLOOD_PUNCTUATION = 3     # consecutive "!" or "?"
RATE_LIMIT = (3, 2.0)     # messages, seconds
WORD_SUFFIXES = ("", "s", "es", "ing", "ed", "er", "ers", "y", "ty")
LEADING_PUNCTUATION = "\"'([{<"
TRAILING_PUNCTUATION = ".,;:!?\"')]}>"
_FLOOD_REPEAT_RE = re.compile(r"(\S)\1{%d}" % (FLOOD_REPEAT - 1))
_FLOOD_PUNCT_RE = re.compile(r"!{%d}|\?{%d}" % (FLOOD_PUNCTUATION, FLOOD_PUNCTUATION))


def _normalize(token: str) -> str:
    return "".join(LEET_SUBSTITUTIONS.get(ch, ch) for ch in token.lower() if ch not in OBFUSCATION_SEPARATORS)


PROFANE_FORMS = frozenset(_normalize(term) + suffix for term in PROFANITY_TERMS for suffix in WORD_SUFFIXES)


class ModerationRegistry:
    """Per-room moderator state. Every mutation happens under the platform lock and is idempotent."""

    def __init__(self, db: dict, lock):
        self.db, self.lock = db, lock

    def room(self, room_id: str) -> dict:
        return self.db["moderation_rooms"].setdefault(
            room_id, {"kicked": [], "muted": [], "recent": {}, "decisions": {}})

    def kick(self, room_id: str, user: str) -> bool:
        with self.lock:
            kicked = self.room(room_id)["kicked"]
            if user in kicked:
                return False
            kicked.append(user)
            return True

    def mute(self, room_id: str, user: str) -> bool:
        with self.lock:
            muted = self.room(room_id)["muted"]
            if user in muted:
                return False
            muted.append(user)
            return True

    def is_blocked(self, room_id: str, user: str) -> bool:
        with self.lock:
            room = self.room(room_id)
            return user in room["kicked"] or user in room["muted"]

    def remember(self, room_id: str, message_id: str, decision: dict) -> dict:
        """Stores the first decision for a message id and returns the stored one (idempotent replays)."""
        with self.lock:
            return self.room(room_id)["decisions"].setdefault(message_id, decision)

    def recent_times(self, room_id: str, sender: str) -> deque:
        with self.lock:
            return self.room(room_id)["recent"].setdefault(sender, deque(maxlen=RATE_LIMIT[0] + 1))


class ModerationService:
    def __init__(self, db: dict, lock, error_cls, sign_day2: Callable[[str, dict], str], registry: ModerationRegistry,
                 dispatcher, clock: Callable[[], float] = time.monotonic):
        self.db, self.lock, self.error_cls, self.sign_day2 = db, lock, error_cls, sign_day2
        self.registry, self.dispatcher, self.clock = registry, dispatcher, clock

    # ------------------------------------------------------------------ text rules
    def normalize(self, token: str) -> str:
        """Lower case, LEET_SUBSTITUTIONS per character, separators dropped: "b@d_w0rd" -> "badword"."""
        return _normalize(token)

    def is_profane(self, word: str) -> bool:
        """True when ``word`` normalises to a dictionary term (plus an allowed suffix). "!" may stand for
        "i" (sh!t) or be a separator (s!c@m), so both readings are tried."""
        return self.normalize(word) in PROFANE_FORMS or self.normalize(word.replace("!", "")) in PROFANE_FORMS

    def mask_profanity(self, text: str) -> tuple:
        """Returns (masked_text, flagged). Offending words become "***" in place; spacing and punctuation
        around them are preserved."""
        parts = re.split(r"(\s+)", text)
        flagged = False
        for i, part in enumerate(parts):
            if not part or part.isspace():
                continue
            lead = len(part) - len(part.lstrip(LEADING_PUNCTUATION))
            end = len(part.rstrip(TRAILING_PUNCTUATION))
            core = part[lead:end] if end > lead else ""
            if core and self.is_profane(core):
                parts[i] = part[:lead] + MASK + part[end:]
                flagged = True
            elif self.is_profane(part):
                parts[i] = MASK
                flagged = True
        return "".join(parts), flagged

    def is_flood(self, text: str) -> bool:
        """4 identical consecutive non-space characters (case-insensitive) or "!!!" / "???"."""
        return bool(_FLOOD_REPEAT_RE.search(text.lower()) or _FLOOD_PUNCT_RE.search(text))

    def rate_limited(self, room_id: str, sender: str) -> bool:
        """Sliding window: more than RATE_LIMIT[0] messages from one sender within RATE_LIMIT[1] seconds."""
        limit, window = RATE_LIMIT
        with self.lock:
            times = self.registry.recent_times(room_id, sender)
            now = self.clock()
            while times and now - times[0] >= window:
                times.popleft()
            times.append(now)
            return len(times) > limit

    # ------------------------------------------------------------------ signature + endpoint
    def moderation_signature(self, payload: ModerationSigPayload) -> str:
        """Spec 5.3: entity_id = chat_room_id; signed payload = exactly {chat_room_id, flagged_count,
        kicked_users, queue_depth}, keyed with DAY2_SALT (never DAY1_SALT)."""
        return self.sign_day2(payload.chat_room_id, payload.model_dump())

    def _decide(self, text: str) -> dict:
        if self.is_flood(text):
            return {"kind": "flood", "text": None}
        masked, flagged = self.mask_profanity(text)
        return {"kind": "profanity" if flagged else "clean", "text": masked}

    def moderate(self, req: ModerationRequest) -> dict:
        """POST /audit/v1/moderation/test (HTTP 200). Messages are judged on their own content in input
        order; kick/mute state is recorded in the room registry (idempotent), and a repeated message keeps
        its first decision."""
        room = req.chat_room_id
        filtered, kicked, muted = [], [], []
        for m in req.incoming_messages:
            decision = self.registry.remember(room, f"{m.message_id}|{m.sender}|{m.text}", self._decide(m.text))
            if decision["kind"] == "flood":
                if m.sender not in muted:
                    muted.append(m.sender)
                self.registry.mute(room, m.sender)
                continue                                   # never broadcast
            flagged = decision["kind"] == "profanity"
            if flagged:
                if m.sender not in kicked:
                    kicked.append(m.sender)
                self.registry.kick(room, m.sender)
            filtered.append({"message_id": m.message_id, "sender": m.sender, "text": decision["text"],
                             "flagged": flagged, "reason": "profanity_leetspeak" if flagged else None})

        if req.simulate_failed_notifications:
            self.dispatcher.simulate_failures(req.simulate_failed_notifications, context=room)
        dlq = self.dispatcher.status()
        flagged_count = sum(1 for f in filtered if f["flagged"])
        signature = self.moderation_signature(ModerationSigPayload(
            chat_room_id=room, flagged_count=flagged_count, kicked_users=kicked, queue_depth=dlq["queue_depth"]))
        return {"chat_room_id": room, "filtered_messages": filtered, "kicked_users": kicked, "muted_users": muted,
                "dlq_status": dlq, "signature": signature}

    # ------------------------------------------------------------------ live chat adapter
    def moderate_live(self, message: dict) -> dict:
        """ChatService hook: decides one live chat message before it can be broadcast."""
        room, sender, text = message["chat_room_id"], message["sender"], message["text"]
        if self.registry.is_blocked(room, sender):
            return {**message, "dropped": True, "reason": "sender_blocked"}
        if self.rate_limited(room, sender):
            self.registry.mute(room, sender)
            return {**message, "dropped": True, "reason": "rate_limit_exceeded"}
        if self.is_flood(text):
            self.registry.mute(room, sender)
            return {**message, "dropped": True, "reason": "flood_character_repeat"}
        masked, flagged = self.mask_profanity(text)
        if flagged:
            self.registry.kick(room, sender)
        return {**message, "text": masked, "flagged": flagged, "reason": "profanity_leetspeak" if flagged else None}
