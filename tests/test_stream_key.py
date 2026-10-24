"""POST /audit/v1/stream/key and media-path enforcement (Day 2 FR-3.2, spec 5.4).

"""
import re
import time

import pytest

import main
from models.stream_key import StreamKeySigPayload
from services.stream_key_service import MediaUrls, new_stream_key

URL = "/audit/v1/stream/key"
KEY_RE = re.compile(r"^sk_live_[a-f0-9]{16}$")
HOOK = f"/internal/media/auth?token={main.MEDIA_HOOK_TOKEN}"


def _sig(key, player, status, action):
    return main.sign(main.DAY2_SALT, key, {"action": action, "player_id": player, "status": status, "stream_key": key})


def _publish(client, key, action="publish"):
    return client.post(HOOK, json={"user": "", "password": "", "ip": "172.18.0.9", "action": action,
                                   "path": f"live/{key}", "protocol": "rtmp", "id": "x", "query": ""})


# ---------------------------------------------------------------- schema, helpers, plumbing
@pytest.mark.parametrize("body,field", [
    ({"action": "pause", "player_id": "player-alpha-1"}, "action"),
    ({"player_id": "player-alpha-1"}, "action"),
    ({"action": "generate"}, "player_id"),
    ({"action": "generate", "player_id": "player-alpha-1", "label": ""}, "label"),
    ({"action": "generate", "player_id": "player-alpha-1", "label": "x" * 65}, "label"),
    ({"action": "generate", "player_id": "player-alpha-1", "stream_key_override": "bad key|"}, "stream_key_override"),
    ({"action": 1, "player_id": "player-alpha-1"}, "action"),
])
def test_schema_violations_are_400(client, body, field):
    r = client.post(URL, json=body)
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert field in r.json()["error"]["details"]["fields"]


def test_generated_keys_match_the_format_and_are_unique():
    keys = {new_stream_key() for _ in range(500)}
    assert len(keys) == 500 and all(KEY_RE.fullmatch(k) for k in keys)


def test_contract_urls_use_the_external_host():
    urls = MediaUrls("localhost")
    assert urls.ingest("sk_live_9f83a1b2c3d4e5f6") == {
        "rtmp": "rtmp://localhost:1935/live/sk_live_9f83a1b2c3d4e5f6",
        "webrtc": "http://localhost:8889/live/sk_live_9f83a1b2c3d4e5f6/whip"}
    assert urls.playback("sk_live_9f83a1b2c3d4e5f6") == "http://localhost:8888/live/sk_live_9f83a1b2c3d4e5f6/index.m3u8"


def test_revoked_response_has_null_endpoints():
    record = {"player_id": "p", "label": "OBS", "stream_key": "sk_live_101", "status": "revoked"}
    body = main.STREAM_KEYS.response(record, "s" * 64)
    assert body["ingest_endpoints"] is None and body["playback_url"] is None and body["status"] == "revoked"


def test_signature_payload_has_exactly_the_contract_keys():
    assert set(StreamKeySigPayload.model_fields) == {"action", "player_id", "status", "stream_key"}


def test_media_hook_enforces_key_state(client):
    store = main.STREAM_KEY_STORE
    store.put_active("player-alpha-1", "sk_live_aaaaaaaaaaaaaaaa", "OBS", main.now_ts())
    assert _publish(client, "sk_live_aaaaaaaaaaaaaaaa").status_code == 200
    assert _publish(client, "sk_live_aaaaaaaaaaaaaaaa", action="read").status_code == 200
    store.mark_revoked("sk_live_aaaaaaaaaaaaaaaa", main.now_ts())
    r = _publish(client, "sk_live_aaaaaaaaaaaaaaaa")
    assert (r.status_code, r.json()["error"]["code"]) == (409, "KEY_REVOKED")
    assert _publish(client, "sk_live_aaaaaaaaaaaaaaaa", action="read").status_code == 409
    unknown = _publish(client, "sk_live_bbbbbbbbbbbbbbbb")
    assert (unknown.status_code, unknown.json()["error"]["code"]) == (404, "STREAM_NOT_FOUND")


def test_disconnect_kicks_the_live_publisher(fake_media):
    assert main.STREAM_KEYS.disconnect("sk_live_aaaaaaaaaaaaaaaa") is True
    assert fake_media.kicked == ["live/sk_live_aaaaaaaaaaaaaaaa"]


def test_lifecycle_is_implemented_and_never_501(client, fake_media):
    r = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1"})
    assert r.status_code == 201 and r.json()["status"] == "active"


# ---------------------------------------------------------------- contract behaviour
def test_generate_returns_201_with_endpoints_and_signature(client, fake_media):
    r = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1", "label": "OBS-Main-Desk"})
    assert r.status_code == 201
    body = r.json()
    key = body["stream_key"]
    assert KEY_RE.fullmatch(key) and body["status"] == "active" and body["label"] == "OBS-Main-Desk"
    assert body["ingest_endpoints"]["rtmp"] == f"rtmp://localhost:1935/live/{key}"
    assert body["playback_url"] == f"http://localhost:8888/live/{key}/index.m3u8"
    assert body["signature"] == _sig(key, "player-alpha-1", "active", "generate")
    assert list(body) == ["player_id", "label", "stream_key", "status", "ingest_endpoints", "playback_url", "signature"]


def test_override_is_honoured_and_matches_appendix_vector_1_shape(client, fake_media):
    r = client.post(URL, json={"action": "rotate", "player_id": "player-alpha-1", "label": "OBS-Main-Desk",
                               "stream_key_override": "sk_live_9f83a1b2c3d4e5f6"})
    assert r.status_code == 200 and r.json()["stream_key"] == "sk_live_9f83a1b2c3d4e5f6"
    assert r.json()["signature"] == _sig("sk_live_9f83a1b2c3d4e5f6", "player-alpha-1", "active", "rotate")


def test_rotate_invalidates_and_disconnects_the_old_key(client, fake_media):
    old = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1"}).json()["stream_key"]
    started = time.perf_counter()
    r = client.post(URL, json={"action": "rotate", "player_id": "player-alpha-1"})
    assert time.perf_counter() - started < 2.0
    new = r.json()["stream_key"]
    assert r.status_code == 200 and new != old and r.json()["status"] == "active"
    assert f"live/{old}" in fake_media.kicked
    assert _publish(client, old).json()["error"]["code"] == "KEY_REVOKED"
    assert _publish(client, new).status_code == 200


def test_generate_again_replaces_the_active_key(client, fake_media):
    first = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1"}).json()["stream_key"]
    second = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1"})
    assert second.status_code == 201 and second.json()["stream_key"] != first
    assert _publish(client, first).status_code == 409


def test_revoke_returns_null_endpoints_and_blocks_publishing(client, fake_media):
    key = client.post(URL, json={"action": "generate", "player_id": "player-alpha-1"}).json()["stream_key"]
    r = client.post(URL, json={"action": "revoke", "player_id": "player-alpha-1"})
    body = r.json()
    assert r.status_code == 200 and body["status"] == "revoked" and body["stream_key"] == key
    assert body["ingest_endpoints"] is None and body["playback_url"] is None
    assert body["signature"] == _sig(key, "player-alpha-1", "revoked", "revoke")
    assert f"live/{key}" in fake_media.kicked
    assert (_publish(client, key).status_code, _publish(client, key).json()["error"]["code"]) == (409, "KEY_REVOKED")


def test_revoke_without_a_key_is_404_stream_not_found(client, fake_media):
    r = client.post(URL, json={"action": "revoke", "player_id": "player-alpha-2"})
    assert (r.status_code, r.json()["error"]["code"]) == (404, "STREAM_NOT_FOUND")


def test_unknown_player_is_404_player_not_found(client, fake_media):
    r = client.post(URL, json={"action": "generate", "player_id": "player-nobody"})
    assert (r.status_code, r.json()["error"]["code"]) == (404, "PLAYER_NOT_FOUND")
