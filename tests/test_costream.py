"""POST /audit/v1/costream/session (Day 2 FR-3.3, spec 5.5, hidden scenario 1)."""
import threading

import pytest

import main
from models.costream import CostreamSigPayload

URL = "/audit/v1/costream/session"
FOUR = ["player-alpha-1", "player-alpha-2", "player-beta-1", "player-beta-2"]
BASE = {"session_id": "cs-session-101", "host_player_id": "player-alpha-1", "participants": FOUR,
        "layout": "grid_4", "simulate_host_drop": True}


def _post(client, **overrides):
    return client.post(URL, json={**BASE, **overrides})


def _sig(body):
    return main.sign(main.DAY2_SALT, body["session_id"], {k: body[k] for k in (
        "active_host", "handoff_occurred", "layout", "participant_count", "session_id", "status")})


# ---------------------------------------------------------------- schema, helpers, plumbing
@pytest.mark.parametrize("body,field", [
    ({**BASE, "participants": ["player-alpha-1", "player-alpha-1"]}, "participants"),
    ({**BASE, "participants": []}, "participants"),
    ({k: v for k, v in BASE.items() if k != "participants"}, "participants"),
    ({k: v for k, v in BASE.items() if k != "host_player_id"}, "host_player_id"),
    ({**BASE, "layout": "grid_9"}, "layout"),
    ({**BASE, "simulate_host_drop": "yes"}, "simulate_host_drop"),
    ({**BASE, "participants": ["ok", "bad|id"]}, "participants.1"),
])
def test_schema_step_comes_first(client, body, field):
    r = client.post(URL, json=body)
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert field in r.json()["error"]["details"]["fields"]


def test_identity_helpers_follow_the_contract():
    assert main.COSTREAMS.composite_playback_url("cs-session-101") == \
        "http://localhost:8888/costream/cs-session-101/index.m3u8"
    assert main.COSTREAMS.chat_room_id("cs-session-101") == "chat-cs-session-101"
    assert set(CostreamSigPayload.model_fields) == {"active_host", "handoff_occurred", "layout", "participant_count",
                                                    "session_id", "status"}


def test_release_media_cleans_every_session_path(fake_media):
    main.COSTREAMS.release_media("cs-session-101")
    assert fake_media.kicked == ["costream/cs-session-101"]


def test_public_view_is_404_until_a_session_exists(client):
    r = client.get("/api/v1/live/costream/cs-session-101")
    assert (r.status_code, r.json()["error"]["code"]) == (404, "STREAM_NOT_FOUND")


# ---------------------------------------------------------------- contract behaviour
def test_four_way_host_drop_promotes_the_next_participant(client, fake_media):
    r = _post(client)
    assert r.status_code == 201
    body = r.json()
    assert body == {"session_id": "cs-session-101", "status": "active", "active_host": "player-alpha-2",
                    "handoff_occurred": True, "participant_count": 3,
                    "active_participants": ["player-alpha-2", "player-beta-1", "player-beta-2"], "layout": "grid_4",
                    "composite_playback_url": "http://localhost:8888/costream/cs-session-101/index.m3u8",
                    "chat_room_id": "chat-cs-session-101", "signature": _sig(body)}


def test_no_drop_keeps_everyone(client, fake_media):
    body = _post(client, simulate_host_drop=False).json()
    assert (body["active_host"], body["handoff_occurred"], body["participant_count"], body["status"]) == \
        ("player-alpha-1", False, 4, "active")
    assert body["active_participants"] == FOUR


def test_sole_host_drop_terminates_cleanly(client, fake_media):
    body = _post(client, session_id="cs-solo", participants=["player-alpha-1"], layout="solo").json()
    assert (body["status"], body["active_host"], body["participant_count"], body["handoff_occurred"]) == \
        ("terminated", None, 0, False)
    assert body["active_participants"] == [] and "costream/cs-solo" in fake_media.kicked  # no orphan media


@pytest.mark.parametrize("overrides,status,code", [
    ({"participants": FOUR + ["player-nobody"]}, 404, "PLAYER_NOT_FOUND"),          # 404 before 409
    ({"host_player_id": "player-nobody"}, 404, "PLAYER_NOT_FOUND"),
    ({"host_player_id": "player-beta-1", "participants": ["player-alpha-1", "player-alpha-2"]}, 400, "VALIDATION_ERROR"),
    ({"participants": FOUR + ["demo-pa-02"], "layout": "solo"}, 409, "COSTREAM_SESSION_FULL"),  # 409 before layout
    ({"participants": FOUR[:3], "layout": "grid_2", "simulate_host_drop": False}, 400, "UNSUPPORTED_LAYOUT"),
    ({"participants": FOUR[:2], "layout": "solo", "simulate_host_drop": False}, 400, "UNSUPPORTED_LAYOUT"),
])
def test_validation_precedence(client, fake_media, overrides, status, code):
    r = _post(client, **overrides)
    assert (r.status_code, r.json()["error"]["code"]) == (status, code)


def test_layout_is_checked_against_the_count_after_the_drop(client, fake_media):
    r = _post(client, participants=FOUR[:3], layout="grid_2", simulate_host_drop=True)
    assert r.status_code == 201 and r.json()["participant_count"] == 2


def test_identical_replay_returns_the_stored_result(client, fake_media):
    first = _post(client)
    again = _post(client)
    assert (first.status_code, again.status_code) == (201, 200) and again.json() == first.json()


def test_concurrent_disconnects_promote_exactly_one_host(client, fake_media):
    _post(client, simulate_host_drop=False)
    errors = []

    def drop():
        try:
            main.COSTREAMS.handle_disconnect("cs-session-101", "player-alpha-1")
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=drop) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    session = main.COSTREAMS.get("cs-session-101")
    assert errors == []
    assert session["active_host"] == "player-alpha-2" and session["participant_count"] == 3
    assert session["chat_room_id"] == "chat-cs-session-101"
    assert session["composite_playback_url"].endswith("/costream/cs-session-101/index.m3u8")


def test_last_participant_leaving_terminates_and_releases_media(client, fake_media):
    _post(client, session_id="cs-two", participants=FOUR[:2], layout="grid_2", simulate_host_drop=False)
    main.COSTREAMS.handle_disconnect("cs-two", "player-alpha-1")
    session = main.COSTREAMS.handle_disconnect("cs-two", "player-alpha-2")
    assert session["status"] == "terminated" and session["active_host"] is None
    assert "costream/cs-two" in fake_media.kicked
    assert main.COSTREAMS.plan("cs-two") is None
