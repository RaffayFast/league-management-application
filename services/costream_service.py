"""Synchronized 4-way co-streaming (Day 2 FR-3.3, spec 5.5, api_contract.md Part C3).

Session state machine:
    (none) --open--> active --host drop, >= 2 participants--> active (next participant in array order hosts)
                       \\--host drop, sole participant------> terminated (media released)
    active --last participant leaves--> terminated

Identity never changes during a handoff: ``composite_playback_url`` (http://<host>:8888/costream/{id}/
index.m3u8) and ``chat_room_id`` (chat-{id}) stay the same, and chat history is untouched.

Composition: MediaMTX does not mix video. The composite path ``costream/{id}`` is published on demand by an
ffmpeg process that MediaMTX itself starts (runOnDemand -> media/compose.sh) and stops when nobody watches,
so no orphan encoder survives. compose.sh asks ``plan()`` for the participant paths and the layout.

Validation order of ``open_session`` (first failure wins): schema (in models/costream.py) -> 404 unknown
player -> 400 host not a participant -> 409 more than 4 -> 400 UNSUPPORTED_LAYOUT -> handoff. All state
changes hold the platform lock, so concurrent disconnect callbacks can never promote two hosts.
"""
import copy
from typing import Callable, Optional

from models.costream import CostreamRequest, CostreamSigPayload

MAX_PARTICIPANTS = 4
LAYOUT_CAPACITY = {"solo": 1, "grid_2": 2, "grid_4": 4, "spotlight": 4}
# ffmpeg xstack positions for 1..4 tiles of equal size (w0/h0 = tile width/height)
XSTACK_LAYOUTS = {1: "0_0", 2: "0_0|w0_0", 3: "0_0|w0_0|0_h0", 4: "0_0|w0_0|0_h0|w0_h0"}


class CostreamService:
    def __init__(self, db: dict, lock, error_cls, sign_day2: Callable[[str, dict], str], urls,
                 player_exists: Callable[[str], bool], media, fingerprint: Callable[[object], str]):
        self.db, self.lock, self.error_cls, self.sign_day2 = db, lock, error_cls, sign_day2
        self.urls, self.player_exists, self.media, self.fingerprint = urls, player_exists, media, fingerprint

    # ------------------------------------------------------------------ implemented helpers
    def sessions(self) -> dict:
        return self.db["costream_sessions"]

    def get(self, session_id: str) -> Optional[dict]:
        with self.lock:
            session = self.sessions().get(session_id)
            return dict(session) if session else None

    def chat_room_id(self, session_id: str) -> str:
        return f"chat-{session_id}"   # exactly one room per co-stream, shared by every host and viewer

    def composite_playback_url(self, session_id: str) -> str:
        return self.urls.composite(session_id)

    def request_key(self, req: CostreamRequest) -> str:
        return self.fingerprint(req.model_dump())

    def public_view(self, session_id: str) -> Optional[dict]:
        """Read-only session view for the Guest Web Player and the mobile co-stream screen."""
        s = self.get(session_id)
        if not s:
            return None
        return {k: s.get(k) for k in ("session_id", "status", "active_host", "active_participants", "layout",
                                      "participant_count", "composite_playback_url", "chat_room_id")}

    def plan(self, session_id: str) -> Optional[dict]:
        """Inputs and filter for the compositor; None when the session is missing or terminated."""
        s = self.get(session_id)
        if not s or s.get("status") != "active" or not s.get("active_participants"):
            return None
        people = s["active_participants"][:LAYOUT_CAPACITY.get(s["layout"], MAX_PARTICIPANTS)]
        if s["layout"] == "spotlight":   # host alone, full frame; others stay in the session as guests
            people = [s["active_host"]] if s.get("active_host") else people[:1]
        return {"session_id": session_id, "layout": s["layout"],
                "inputs": [f"costream/{session_id}/{p}" for p in people],
                "xstack": XSTACK_LAYOUTS[len(people)]}

    def release_media(self, session_id: str) -> int:
        """Kicks the composite and every participant publisher of a terminated session."""
        return self.media.kick_prefix(f"costream/{session_id}")

    def restart_composite(self, session_id: str) -> bool:
        """After a handoff the compositor is restarted (runOnDemandRestart) and re-reads ``plan``."""
        return self.media.kick_publisher(f"costream/{session_id}")

    # ------------------------------------------------------------------ signature
    def session_signature(self, payload: CostreamSigPayload) -> str:
        """Spec 5.3: entity_id = session_id; signed payload = exactly {active_host, handoff_occurred, layout,
        participant_count, session_id, status}."""
        return self.sign_day2(payload.session_id, payload.model_dump())

    def _response(self, s: dict) -> dict:
        """Contract body (field order of models.costream.CostreamResponse), signed over the current state."""
        handoff = bool(s.get("handoff_occurred", False))
        body = {"session_id": s["session_id"], "status": s["status"], "active_host": s["active_host"],
                "handoff_occurred": handoff, "participant_count": len(s["active_participants"]),
                "active_participants": list(s["active_participants"]), "layout": s["layout"],
                "composite_playback_url": self.composite_playback_url(s["session_id"]),
                "chat_room_id": self.chat_room_id(s["session_id"])}
        body["signature"] = self.session_signature(CostreamSigPayload(
            active_host=body["active_host"], handoff_occurred=handoff, layout=body["layout"],
            participant_count=body["participant_count"], session_id=body["session_id"], status=body["status"]))
        return body

    # ------------------------------------------------------------------ open + simulated host drop
    def open_session(self, req: CostreamRequest) -> tuple:
        """Evaluates a co-stream request. Returns (response_dict, http_status). Step 1 (schema) is done."""
        release = restart = False
        with self.lock:
            key = self.request_key(req)
            stored = self.sessions().get(req.session_id)
            if stored and stored.get("request_key") == key:          # identical replay
                return copy.deepcopy(stored["response"]), 200

            missing = next((p for p in [*req.participants, req.host_player_id] if not self.player_exists(p)), None)
            if missing is not None:
                raise self.error_cls(404, "PLAYER_NOT_FOUND", "Player not found", {"player_id": missing})
            if req.host_player_id not in req.participants:
                raise self.error_cls(400, "VALIDATION_ERROR", "host_player_id must be one of the participants",
                                     {"fields": ["host_player_id"]})
            count = len(req.participants)
            if count > MAX_PARTICIPANTS:
                raise self.error_cls(409, "COSTREAM_SESSION_FULL", "A co-stream holds at most 4 broadcasters",
                                     {"participant_count": count, "max_participants": MAX_PARTICIPANTS})
            effective = count - 1 if req.simulate_host_drop else count
            if effective > LAYOUT_CAPACITY[req.layout]:
                raise self.error_cls(400, "UNSUPPORTED_LAYOUT", f"Layout {req.layout} cannot show {effective} participants",
                                     {"layout": req.layout, "participant_count": effective,
                                      "capacity": LAYOUT_CAPACITY[req.layout]})

            if not req.simulate_host_drop:
                active, host, handoff, status = list(req.participants), req.host_player_id, False, "active"
            elif count >= 2:
                active = [p for p in req.participants if p != req.host_player_id]   # array order kept
                host, handoff, status, restart = active[0], True, "active", True
            else:
                active, host, handoff, status, release = [], None, False, "terminated", True

            session = {"session_id": req.session_id, "host_player_id": req.host_player_id,
                       "participants": list(req.participants), "active_participants": active, "active_host": host,
                       "layout": req.layout, "status": status, "handoff_occurred": handoff,
                       "participant_count": len(active),
                       "composite_playback_url": self.composite_playback_url(req.session_id),
                       "chat_room_id": self.chat_room_id(req.session_id), "request_key": key}
            session["response"] = self._response(session)
            self.sessions()[req.session_id] = session
            response = copy.deepcopy(session["response"])

        if release:
            self.release_media(req.session_id)       # sole host gone: no orphan encoder or publisher
        if restart:
            self.restart_composite(req.session_id)   # compositor re-reads the plan with the new host
        return response, 201

    # ------------------------------------------------------------------ real disconnects
    def handle_disconnect(self, session_id: str, player_id: str) -> Optional[dict]:
        """Called by the media event hook when a participant's publisher goes away (target: handoff < 1.5 s).
        Idempotent: a second callback for the same player finds nothing to do and returns None."""
        release = restart = False
        with self.lock:
            s = self.sessions().get(session_id)
            if not s or s.get("status") != "active" or player_id not in s.get("active_participants", []):
                return None
            s["active_participants"] = [p for p in s["active_participants"] if p != player_id]
            s["participant_count"] = len(s["active_participants"])
            if not s["active_participants"]:
                s["status"], s["active_host"], release = "terminated", None, True
            elif s.get("active_host") == player_id:
                # next participant in the original array order; chat room and composite URL stay the same
                s["active_host"], s["handoff_occurred"], restart = s["active_participants"][0], True, True
            s["response"] = self._response(s)
            result = copy.deepcopy(s)

        if release:
            self.release_media(session_id)
        if restart:
            self.restart_composite(session_id)
        return result
