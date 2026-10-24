"""MediaMTX integration plumbing: auth-hook policy, presence events, composition plan, readiness."""
import pytest

import main
from services.media_access import MediaAccessPolicy

TOKEN = main.MEDIA_HOOK_TOKEN


def _auth(client, action, path, user="", password="", query="", token=TOKEN):
    return client.post(f"/internal/media/auth?token={token}", json={
        "user": user, "password": password, "ip": "172.18.0.5", "action": action, "path": path,
        "protocol": "rtmp", "id": "conn-1", "query": query})


def _session(session_id="cs-v", participants=("player-alpha-1", "player-alpha-2"), status="active", layout="grid_2"):
    main.DB["costream_sessions"][session_id] = {
        "session_id": session_id, "status": status, "layout": layout, "active_host": participants[0] if participants else None,
        "active_participants": list(participants), "participant_count": len(participants),
        "composite_playback_url": main.MEDIA_URLS.composite(session_id), "chat_room_id": f"chat-{session_id}"}


def test_hook_requires_the_internal_token(client):
    assert _auth(client, "publish", "live/sk_live_101", token="wrong").status_code == 403
    assert client.post("/internal/media/events?event=ready&path=live/x").status_code == 403


def test_internal_routes_are_hidden_from_the_schema(client):
    assert not [p for p in client.get("/openapi.json").json()["paths"] if p.startswith("/internal")]


def test_policy_matrix(client):
    main.STREAM_KEY_STORE.put_active("player-alpha-1", "sk_live_1111111111111111", "a", main.now_ts())
    main.STREAM_KEY_STORE.put_active("player-alpha-2", "sk_live_2222222222222222", "b", main.now_ts())
    _session()
    assert _auth(client, "read", "costream/cs-v").status_code == 200                       # public composite
    assert _auth(client, "publish", "costream/cs-v").status_code == 403                    # only the compositor
    assert _auth(client, "publish", "costream/cs-v", main.MEDIA_INTERNAL_USER, main.MEDIA_INTERNAL_PASS).status_code == 200
    assert _auth(client, "publish", "costream/cs-v/player-alpha-1", query="key=sk_live_1111111111111111").status_code == 200
    assert _auth(client, "publish", "costream/cs-v/player-alpha-1", query="key=sk_live_2222222222222222").status_code == 403
    assert _auth(client, "publish", "costream/cs-v/player-beta-1", query="key=sk_live_1111111111111111").status_code == 403
    assert _auth(client, "publish", "costream/cs-v/player-alpha-1").status_code == 404     # no key
    assert _auth(client, "publish", "elsewhere/x").status_code == 403
    assert _auth(client, "api", "").status_code == 403


def test_policy_is_pure_and_reusable():
    policy = MediaAccessPolicy(lambda k: {"player_id": "p", "status": "active"} if k == "sk_live_ok" else None,
                               lambda s: None, "u", "p")
    assert policy.decide({"action": "publish", "path": "live/sk_live_ok"})[0] == 200
    assert policy.decide({"action": "publish", "path": "live/sk_live_no"})[0] == 404
    assert policy.decide({"action": "publish", "path": "x", "user": "u", "password": "p"})[0] == 200


def test_presence_events_are_recorded(client):
    r = client.post(f"/internal/media/events?token={TOKEN}&event=ready&path=live/sk_live_101")
    assert r.status_code == 200 and "live/sk_live_101" in main.DB["media_presence"]
    client.post(f"/internal/media/events?token={TOKEN}&event=not_ready&path=live/sk_live_101")
    assert "live/sk_live_101" not in main.DB["media_presence"]
    assert [e["event"] for e in main.DB["media_event_log"][-2:]] == ["ready", "not_ready"]
    assert client.post(f"/internal/media/events?token={TOKEN}&event=boom&path=x").status_code == 400


def test_participant_disconnect_reaches_the_costream_service(client):
    _session()
    body = client.post(f"/internal/media/events?token={TOKEN}&event=not_ready&path=costream/cs-v/player-alpha-1").json()
    assert body["path"] == "costream/cs-v/player-alpha-1"
    assert body["session"]["active_host"] == "player-alpha-2" and body["session"]["handoff_occurred"] is True
    assert body["session"]["chat_room_id"] == "chat-cs-v"


def test_composition_plan(client):
    _session(participants=("player-alpha-1", "player-alpha-2", "player-beta-1"), layout="grid_4")
    r = client.get(f"/internal/media/costream/cs-v/plan?token={TOKEN}")
    assert r.status_code == 200 and r.text.splitlines() == [
        "LAYOUT grid_4", "XSTACK 0_0|w0_0|0_h0",
        "INPUT costream/cs-v/player-alpha-1", "INPUT costream/cs-v/player-alpha-2", "INPUT costream/cs-v/player-beta-1"]
    _session("cs-spot", layout="spotlight")
    assert client.get(f"/internal/media/costream/cs-spot/plan?token={TOKEN}").text.splitlines()[2:] == \
        ["INPUT costream/cs-spot/player-alpha-1"]
    _session("cs-dead", participants=(), status="terminated")
    assert client.get(f"/internal/media/costream/cs-dead/plan?token={TOKEN}").status_code == 404


def test_health_reports_an_unreachable_media_server(client, monkeypatch):
    monkeypatch.setattr(main, "HEALTH_CHECK_MEDIA", True)
    monkeypatch.setattr(main.MEDIA, "api_url", "http://127.0.0.1:9")   # nothing listens there
    r = client.get("/health")
    assert (r.status_code, r.json()["error"]["code"]) == (503, "NOT_READY")
    assert r.json()["error"]["details"]["failed"] == ["media_server"]


def test_reset_clears_media_state(client):
    main.STREAM_KEY_STORE.put_active("player-alpha-1", "sk_live_3333333333333333", "a", main.now_ts())
    _session()
    client.post("/audit/v1/reset", json={})
    assert main.DB["stream_keys"] == {} and main.DB["costream_sessions"] == {}
