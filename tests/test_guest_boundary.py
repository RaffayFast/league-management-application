"""Zero-trust guest write boundary (Day 2 FR-4.3, spec 5.7 direct enforcement) and guest onboarding routes."""
import pytest

import main
from middleware.guest_boundary import guest_write_violation, simulate_guest_write

GUEST = {"Authorization": "Bearer guest_anon_tok_7721"}
SCORE_EVENT = {"event_id": "guest-evt-1", "match_id": "match-m1", "type": "score",
               "payload": {"team_id": "club-alpha-2", "event_type": "goal"}}
ORDER = {"order_id": "guest-ord-1", "customer_id": "guest", "discount_code": None,
         "items": [{"variant_id": "var-jersey-001-L", "quantity": 1}], "payment": {"token": "tok_success"}}


def _login(client, who="player"):
    r = client.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _assert_guest_forbidden(r, route):
    assert r.status_code == 403
    err = r.json()["error"]
    assert err["code"] == "GUEST_WRITE_FORBIDDEN"
    assert isinstance(err["message"], str) and err["message"]
    assert isinstance(err["details"], dict)
    assert err["details"]["guest_token"] == "guest_anon_tok_7721"
    assert err["details"]["attempted_route"] == route


@pytest.mark.parametrize("path,body", [
    ("/api/v1/chat", {"chat_room_id": "chat-match-m1", "text": "hello"}),
    ("/audit/v1/checkout", ORDER),
    ("/audit/v1/events", SCORE_EVENT),
])
def test_direct_contract_probes_are_refused(client, path, body):
    _assert_guest_forbidden(client.post(path, json=body, headers=GUEST), path)


@pytest.mark.parametrize("path", ["/api/v1/chat", "/audit/v1/checkout", "/audit/v1/events"])
def test_guard_runs_before_body_validation(client, path):
    _assert_guest_forbidden(client.post(path, json={}, headers=GUEST), path)
    r = client.post(path, content=b"{not json", headers={**GUEST, "Content-Type": "application/json"})
    assert r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"


@pytest.mark.parametrize("method,path", [
    ("POST", "/api/v1/events"), ("POST", "/api/v1/roster/transfer"), ("POST", "/api/v1/store/checkout"),
    ("POST", "/api/v1/sync"), ("POST", "/audit/v1/roster/transfer"), ("POST", "/audit/v1/offline-sync"),
    ("POST", "/audit/v1/guest/cart-merge"), ("POST", "/api/v1/guest/cart/merge"),
    ("PATCH", "/audit/v1/rbac/players/player-alpha-1"), ("DELETE", "/audit/v1/privacy/user/player-alpha-1"),
])
def test_every_other_write_surface_is_refused(client, method, path):
    _assert_guest_forbidden(client.request(method, path, json={}, headers=GUEST), path)


def test_refused_writes_change_nothing(client):
    client.post("/audit/v1/events", json=SCORE_EVENT, headers=GUEST)
    client.post("/audit/v1/checkout", json=ORDER, headers=GUEST)
    score = client.get("/audit/v1/score/match-m1").json()
    assert (score["home"]["score"], score["away"]["score"], score["version"]) == (1, 0, 3)
    assert client.get("/audit/v1/inventory/var-jersey-001-L").json() == \
        {"variant_id": "var-jersey-001-L", "stock": 5, "reserved": 0}


@pytest.mark.parametrize("header", ["Bearer guest_anon_tok_unknown123", "bearer guest_anon_tok_7721",
                                    "guest_anon_tok_7721"])
def test_any_guest_scoped_bearer_is_refused(client, header):
    r = client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": "x"},
                    headers={"Authorization": header})
    assert (r.status_code, r.json()["error"]["code"]) == (403, "GUEST_WRITE_FORBIDDEN")


def test_guests_can_read(client):
    assert client.get("/health", headers=GUEST).status_code == 200
    assert client.get("/audit/v1/score/match-m1", headers=GUEST).status_code == 200
    assert client.get("/web/matches/match-m1/live", headers=GUEST).status_code == 200
    assert client.get("/api/v1/chat/chat-match-m1", headers=GUEST).json() == \
        {"chat_room_id": "chat-match-m1", "messages": []}


def test_member_requests_carrying_guest_data_in_the_body_are_not_blocked(client):
    member = _login(client, "viewer")
    body = {**ORDER, "order_id": "member-ord-1", "customer_id": "user-viewer",
            "guest_token": "guest_anon_tok_7721", "guest_cart": [{"variant_id": "var-jersey-001-L", "quantity": 1}]}
    r = client.post("/api/v1/store/checkout", json=body, headers=member)
    assert r.status_code == 201 and r.json()["status"] == "paid"


def test_non_guest_auth_failures_keep_their_codes(client):
    assert client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": "x"}).json()["error"]["code"] == \
        "UNAUTHENTICATED"
    r = client.post("/api/v1/events", json=SCORE_EVENT, headers={"Authorization": "Bearer not-a-jwt"})
    assert (r.status_code, r.json()["error"]["code"]) == (401, "UNAUTHENTICATED")
    r = client.post("/api/v1/events", json=SCORE_EVENT, headers=_login(client, "viewer"))
    assert (r.status_code, r.json()["error"]["code"]) == (403, "FORBIDDEN")


def test_member_chat_passes_the_boundary_and_is_moderated(client):
    """Members pass the boundary; their message is moderated, sequenced and broadcast."""
    r = client.post("/api/v1/chat", json={"chat_room_id": "chat-match-m1", "text": "great goal"},
                    headers=_login(client))
    assert r.status_code == 201 and r.json()["text"] == "great goal" and r.json()["sequence"] == 1
    bad = client.post("/api/v1/chat", json={"chat_room_id": "room-1", "text": ""}, headers=_login(client))
    assert bad.status_code == 400 and set(bad.json()["error"]["details"]["fields"]) == {"chat_room_id", "text"}


def test_guard_decision_helpers():
    assert simulate_guest_write("guest_anon_tok_7721") == 403
    assert simulate_guest_write("eyJhbGciOiJIUzI1NiJ9.e30.x") == 200
    assert guest_write_violation("GET", "/audit/v1/score/m1", "Bearer guest_anon_tok_7721") is None
    assert guest_write_violation("POST", "/api/v1/auth/login", "Bearer guest_anon_tok_7721") is None
    assert guest_write_violation("POST", "/api/v1/chat/", "Bearer guest_anon_tok_7721")["attempted_route"] == \
        "/api/v1/chat"


def test_guest_session_issues_short_lived_read_only_tokens(client):
    r = client.post("/api/v1/guest/session", headers=GUEST)  # onboarding stays open to guests
    body = r.json()
    assert r.status_code == 201 and body["guest_token"].startswith("guest_anon_tok_")
    assert body["role"] == "guest" and body["read_only"] is True and body["expires_at"].endswith("Z")
    assert main.GUEST_SESSIONS.lookup(body["guest_token"]) is not None
    blocked = client.post("/audit/v1/events", json=SCORE_EVENT,
                          headers={"Authorization": f"Bearer {body['guest_token']}"})
    assert blocked.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"


def test_guest_tokens_expire_and_are_pruned():
    from services.guest_session import GuestSessionService
    now = [1000.0]
    db = {"guest_tokens": {"guest_anon_tok_7721": {"guest_token": "guest_anon_tok_7721", "role": "guest",
                                                   "read_only": True, "merged": False, "merged_into": None}}}
    svc = GuestSessionService(db, main.LOCK, ttl_seconds=60, max_tokens=2, clock=lambda: now[0])
    first = svc.issue()["guest_token"]
    assert svc.lookup(first) is not None
    now[0] += 61
    assert svc.lookup(first) is None and svc.lookup("guest_anon_tok_7721") is not None  # seed never expires
    svc.issue(), svc.issue(), svc.issue()
    assert first not in db["guest_tokens"]
    assert len([t for t in db["guest_tokens"].values() if t.get("expires_at")]) == 2


def test_progressive_registration(client):
    r = client.post("/api/v1/auth/register", json={"name": "New Fan", "email": "Fan@Example.com",
                                                   "password": "goal-goal"}, headers=GUEST)
    assert r.status_code == 201 and r.json()["user"]["role"] == "viewer"
    me = client.get("/api/v1/me", headers={"Authorization": f"Bearer {r.json()['token']}"})
    assert me.json()["user"]["email"] == "fan@example.com"
    dup = client.post("/api/v1/auth/register", json={"name": "x", "email": "fan@example.com", "password": "12345678"})
    assert (dup.status_code, dup.json()["error"]["code"]) == (409, "USER_EXISTS")
    bad = client.post("/api/v1/auth/register", json={"name": "", "email": "nope", "password": "short"})
    assert bad.status_code == 400 and set(bad.json()["error"]["details"]["fields"]) == {"name", "email", "password"}
    login = client.post("/api/v1/auth/login", json={"email": "fan@example.com", "password": "goal-goal"})
    assert login.status_code == 200
