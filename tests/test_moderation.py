"""POST /audit/v1/moderation/test and live-chat moderation (Day 2 FR-5.3, spec 5.8, hidden scenario 3)."""
import threading

import pytest

import main
from models.moderation import ModerationSigPayload
from services.moderation_service import ModerationRegistry

URL = "/audit/v1/moderation/test"
SPEC = {"chat_room_id": "chat-cs-session-101", "incoming_messages": [
    {"message_id": "msg-1", "sender": "user-guest-1", "text": "Clean sports commentary"},
    {"message_id": "msg-2", "sender": "user-spammer", "text": "Watch this illegal stream b@d_w0rd now!"},
    {"message_id": "msg-3", "sender": "user-flooder", "text": "GOAL! AAAA!!!"}],
    "check_dlq": True, "simulate_failed_notifications": 0}


def _one(text, sender="user-x", room="chat-room-1"):
    return {"chat_room_id": room, "incoming_messages": [{"message_id": "m-1", "sender": sender, "text": text}]}


# ---------------------------------------------------------------- schema, helpers, plumbing
@pytest.mark.parametrize("body,field", [
    ({}, "chat_room_id"),
    ({**SPEC, "incoming_messages": [{"message_id": "m", "text": "hi"}]}, "incoming_messages.0.sender"),
    ({**SPEC, "simulate_failed_notifications": -1}, "simulate_failed_notifications"),
    ({**SPEC, "simulate_failed_notifications": "3"}, "simulate_failed_notifications"),
    ({**SPEC, "check_dlq": "yes"}, "check_dlq"),
])
def test_schema_violations_are_400(client, body, field):
    r = client.post(URL, json=body)
    assert r.status_code == 400 and field in r.json()["error"]["details"]["fields"]


def test_signature_payload_has_exactly_the_contract_keys():
    assert set(ModerationSigPayload.model_fields) == {"chat_room_id", "flagged_count", "kicked_users", "queue_depth"}


def test_registry_is_deduplicated_under_a_ten_thread_race():
    registry = ModerationRegistry({"moderation_rooms": {}}, main.LOCK)
    threads = [threading.Thread(target=registry.kick, args=("chat-r", "user-spammer")) for _ in range(10)]
    threads += [threading.Thread(target=registry.mute, args=("chat-r", "user-flooder")) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    room = registry.room("chat-r")
    assert room["kicked"] == ["user-spammer"] and room["muted"] == ["user-flooder"]
    assert registry.remember("chat-r", "m1", {"a": 1}) == registry.remember("chat-r", "m1", {"a": 2}) == {"a": 1}


def test_blocked_senders_never_reach_the_broadcast_path():
    main.MODERATION.registry.kick("chat-match-m1", "user-player")
    decision = main.MODERATION.moderate_live({"chat_room_id": "chat-match-m1", "sender": "user-player", "text": "hi"})
    assert decision["dropped"] is True and decision["reason"] == "sender_blocked"


def test_clean_live_chat_is_broadcast_unchanged(client):
    token = client.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"}).json()["token"]
    r = client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": "hello"},
                    headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 201 and r.json()["text"] == "hello" and r.json()["flagged"] is False


# ---------------------------------------------------------------- contract behaviour
def test_spec_example(client):
    r = client.post(URL, json=SPEC)
    assert r.status_code == 200
    body = r.json()
    assert body["filtered_messages"] == [
        {"message_id": "msg-1", "sender": "user-guest-1", "text": "Clean sports commentary", "flagged": False, "reason": None},
        {"message_id": "msg-2", "sender": "user-spammer", "text": "Watch this illegal stream *** now!", "flagged": True,
         "reason": "profanity_leetspeak"}]
    assert (body["kicked_users"], body["muted_users"]) == (["user-spammer"], ["user-flooder"])
    assert body["dlq_status"] == {"queue_depth": 0, "undelivered_events": []}
    assert body["signature"] == main.sign(main.DAY2_SALT, "chat-cs-session-101", {
        "chat_room_id": "chat-cs-session-101", "flagged_count": 1, "kicked_users": ["user-spammer"], "queue_depth": 0})
    assert body["signature"] != main.sign(main.DAY1_SALT, "chat-cs-session-101", {
        "chat_room_id": "chat-cs-session-101", "flagged_count": 1, "kicked_users": ["user-spammer"], "queue_depth": 0})


@pytest.mark.parametrize("text,masked", [
    ("b@d_w0rd", "***"), ("bad_word here", "*** here"), ("p.0.r.n", "***"), ("p0rn", "***"), ("s!c@m alert", "*** alert"),
    ("sc@m", "***"), ("f*u*c*k", "***"), ("a$$h0le", "***"), ("SHIT happens", "*** happens"), ("bitch", "***"),
    ("idiot_spam", "***"), ("nice goal, keeper", "nice goal, keeper"),
])
def test_leetspeak_masking(client, text, masked):
    msg = client.post(URL, json=_one(text)).json()["filtered_messages"][0]
    assert msg["text"] == masked and msg["flagged"] is (masked != text)


@pytest.mark.parametrize("text", ["GOAL! AAAA!!!", "aaaa", "AaAa", "what???", "wow!!!", "zzzzz"])
def test_floods_are_dropped_and_muted(client, text):
    body = client.post(URL, json=_one(text, sender="user-flooder")).json()
    assert body["filtered_messages"] == [] and body["muted_users"] == ["user-flooder"]


def test_kicked_users_are_deduplicated_in_first_violation_order(client):
    msgs = [{"message_id": f"m{i}", "sender": s, "text": "scam " + str(i)} for i, s in
            enumerate(["user-b", "user-a", "user-b", "user-a"])]
    body = client.post(URL, json={"chat_room_id": "chat-room-2", "incoming_messages": msgs}).json()
    assert body["kicked_users"] == ["user-b", "user-a"]


def test_ten_concurrent_moderators_agree(client):
    results = []

    def call():
        results.append(client.post(URL, json=SPEC))

    threads = [threading.Thread(target=call) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert [r.status_code for r in results] == [200] * 10
    assert all(r.json()["kicked_users"] == ["user-spammer"] for r in results)
    assert main.DB["moderation_rooms"]["chat-cs-session-101"]["kicked"] == ["user-spammer"]


def test_simulated_failures_fill_the_dlq_and_reset_empties_it(client):
    body = client.post(URL, json={**SPEC, "simulate_failed_notifications": 3}).json()
    assert body["dlq_status"]["queue_depth"] == 3 and len(body["dlq_status"]["undelivered_events"]) == 3
    assert body["signature"] == main.sign(main.DAY2_SALT, "chat-cs-session-101", {
        "chat_room_id": "chat-cs-session-101", "flagged_count": 1, "kicked_users": ["user-spammer"], "queue_depth": 3})
    client.post("/audit/v1/reset", json={})
    assert client.post(URL, json=SPEC).json()["dlq_status"]["queue_depth"] == 0


def test_member_chat_is_masked_before_broadcast(client):
    token = client.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"}).json()["token"]
    r = client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": "what a sc@m"},
                    headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 201 and r.json()["text"] == "what a ***" and r.json()["flagged"] is True
    assert client.get("/api/v1/chat/chat-match-m1").json()["messages"][0]["text"] == "what a ***"


def test_live_rate_limit_three_messages_per_two_seconds(client):
    token = client.post("/api/v1/auth/login", json={"email": "viewer@nascon.test", "password": "Nascon@26"}).json()["token"]
    codes = [client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": f"hi {i}"},
                         headers={"Authorization": f"Bearer {token}"}).json().get("status", "sent") for i in range(4)]
    assert codes == ["sent", "sent", "sent", "dropped"]
