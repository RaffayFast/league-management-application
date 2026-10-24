"""DELETE /audit/v1/privacy/user/{user_id} (Day 2 NFR-9)."""
import time

import main

URL = "/audit/v1/privacy/user/"


def _login(client, who="player"):
    return client.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})


# ---------------------------------------------------------------- schema, helpers, plumbing
def test_invalid_id_is_400(client):
    r = client.delete(URL + "bad%7Cid")
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_response_shape_and_subject_resolution():
    assert main.PRIVACY.response("player-alpha-1") == {"user_id": "player-alpha-1", "status": "anonymized",
                                                       "pii_retained": False, "tokens_wiped": True}
    assert main.PRIVACY.resolve("player-alpha-1") == {"accounts": ["user-player"], "players": ["player-alpha-1"]}
    assert main.PRIVACY.resolve("user-viewer") == {"accounts": ["user-viewer"], "players": []}


def test_erased_subjects_lose_their_tokens(client):
    token = _login(client).json()["token"]
    main.DB["erased_subjects"].add("user-player")
    r = client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert (r.status_code, r.json()["error"]["code"]) == (401, "UNAUTHENTICATED")


# ---------------------------------------------------------------- contract behaviour
def test_erasure_anonymises_within_one_second(client):
    token = _login(client).json()["token"]
    main.DB["guest_tokens"]["guest_anon_tok_7721"]["merged_into"] = "player-alpha-1"
    scans, events = main.qr_scans_total(), len(main.DB["events"]["match-m1"])
    started = time.perf_counter()
    r = client.delete(URL + "player-alpha-1")
    assert time.perf_counter() - started < 1.0
    assert (r.status_code, r.json()) == (200, {"user_id": "player-alpha-1", "status": "anonymized",
                                               "pii_retained": False, "tokens_wiped": True})
    assert client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"}).status_code == 401
    assert _login(client).status_code == 401
    assert "player@nascon.test" not in main.DB["users"]
    assert main.DB["roster_players"]["player-alpha-1"]["name"] != "Ali"
    assert "guest_anon_tok_7721" not in main.DB["guest_tokens"]
    # nothing else touched
    assert _login(client, "viewer").status_code == 200
    assert main.DB["roster_players"]["player-alpha-2"]["name"] == "Rehan"
    assert main.qr_scans_total() == scans and len(main.DB["events"]["match-m1"]) == events
    assert client.get("/audit/v1/score/match-m1").json()["home"]["score"] == 1


def test_erasure_is_repeatable_and_unknown_users_are_404(client):
    assert client.delete(URL + "player-alpha-1").status_code == 200
    assert client.delete(URL + "player-alpha-1").status_code == 200
    r = client.delete(URL + "player-nobody")
    assert (r.status_code, r.json()["error"]["code"]) == (404, "PLAYER_NOT_FOUND")
