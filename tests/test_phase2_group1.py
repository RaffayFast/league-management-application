"""Phase II Group 1: Day 2 baseline seed on reset, readiness, DAY2_SALT signing, startup configuration."""
import copy
import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

import pytest

import main

DAY2_VECTOR_SALT = "T01D27ad7ffff12e"


def _phase2_snapshot():
    return copy.deepcopy({k: main.DB[k] for k in ("qr_codes", "guest_tokens", "carts")})


def test_reset_seeds_match_m1_live_at_one_nil(client):
    score = client.get("/audit/v1/score/match-m1").json()
    assert (score["sport_id"], score["league_id"], score["status"]) == ("football", "league-alpha-1", "in_progress")
    assert (score["home"]["team_id"], score["home"]["score"]) == ("club-alpha-1", 1)
    assert (score["away"]["team_id"], score["away"]["score"]) == ("club-alpha-2", 0)
    # built through the signed event log, not a mutable counter
    assert [e["type"] for e in score["events"]] == ["match_init", "match_start", "score"]
    assert all(len(e["signature"]) == 64 for e in score["events"])


def test_match_m1_follows_normal_event_rules(client, post_event):
    assert post_event("g-1", "match-m1", "score", {"team_id": "club-alpha-2", "event_type": "goal"}).status_code == 201
    assert post_event("g-2", "match-m1", "match_end").status_code == 201
    score = client.get("/audit/v1/score/match-m1").json()
    assert (score["status"], score["outcome"]) == ("completed", "draw")


def test_reset_seeds_player_beta_2_in_club_beta_1(client):
    history = client.get("/audit/v1/roster/history/player-beta-2?as_of=2026-10-18").json()
    assert history["current_squad_id"] == "sq-beta-1"
    assert main.DB["squads"]["sq-beta-1"]["club_id"] == "club-beta-1"


def test_reset_seeds_qr_mappings_guest_token_and_empty_cart(client):
    qr = main.DB["qr_codes"]
    assert {k: (v["entity_type"], v["short_url"], v["scan_count"]) for k, v in qr.items()} == {
        "match-m1": ("match", "http://localhost:8080/q/m1-live", 0),
        "player-alpha-1": ("player", "http://localhost:8080/q/p-alpha-1", 0),
        "club-alpha-1": ("club", "http://localhost:8080/q/c-alpha-1", 0),
    }
    token = main.DB["guest_tokens"]["guest_anon_tok_7721"]
    assert (token["read_only"], token["merged"], token["merged_into"]) == (True, False, None)
    assert main.DB["carts"]["player-alpha-1"] == {"user_id": "player-alpha-1", "currency": "PKR", "items": []}
    assert main.DB["pinned_products"]["match-m1"] == "prod-jersey-001"


def test_reset_restores_identical_phase2_state(client, post_event):
    baseline = _phase2_snapshot()
    score_before = client.get("/audit/v1/score/match-m1").json()
    post_event("z-1", "match-m1", "match_end")
    main.DB["qr_codes"]["match-m1"]["scan_count"] = 9
    main.DB["guest_tokens"]["guest_anon_tok_7721"]["merged"] = True
    main.DB["carts"]["player-alpha-1"]["items"].append({"variant_id": "var-jersey-001-L", "quantity": 1})
    assert client.post("/audit/v1/reset", json={}).status_code == 200
    assert _phase2_snapshot() == baseline
    assert client.get("/audit/v1/score/match-m1").json() == score_before


def test_health_is_ready_only_with_baseline_seed(client):
    ok = client.get("/health")
    assert (ok.status_code, ok.json()) == (200, {"status": "ok"})
    saved = main.DB.pop("guest_tokens")
    try:
        r = client.get("/health")
        assert (r.status_code, r.json()["error"]["code"]) == (503, "NOT_READY")
    finally:
        main.DB["guest_tokens"] = saved


def test_day2_signature_recipe_matches_appendix_a():
    # Vector 2: the message bytes are spelled out in the spec
    expected_msg = b'sk_live_101|{"action":"rotate","player_id":"player-alpha-1"}'
    expected = hmac.new(DAY2_VECTOR_SALT.encode(), expected_msg, hashlib.sha256).hexdigest()
    assert main.sign(DAY2_VECTOR_SALT, "sk_live_101", {"player_id": "player-alpha-1", "action": "rotate"}) == expected
    # Vector 1: canonical payload is one line, keys sorted, no spaces
    payload = {"stream_key": "sk_live_9f83a1b2c3d4e5f6", "status": "active", "player_id": "player-alpha-1",
               "action": "rotate"}
    assert main.canonical_json(payload) == ('{"action":"rotate","player_id":"player-alpha-1","status":"active",'
                                            '"stream_key":"sk_live_9f83a1b2c3d4e5f6"}')
    sig = main.sign(DAY2_VECTOR_SALT, "sk_live_9f83a1b2c3d4e5f6", payload)
    assert len(sig) == 64 and sig == sig.lower()


def test_sign_day2_uses_day2_salt_not_day1(monkeypatch):
    monkeypatch.setattr(main, "DAY1_SALT", "day1-salt")
    monkeypatch.setattr(main, "DAY2_SALT", DAY2_VECTOR_SALT)
    payload = {"action": "rotate", "player_id": "player-alpha-1"}
    assert main.sign_day2("sk_live_101", payload) == main.sign(DAY2_VECTOR_SALT, "sk_live_101", payload)
    assert main.sign_day2("sk_live_101", payload) != main.sign("day1-salt", "sk_live_101", payload)


def _env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in ("DAY1_SALT", "DAY2_SALT", "PORT", "HOST")}
    env.update(extra)
    return env


def test_salts_are_read_from_environment():
    out = subprocess.run([sys.executable, "-c", "import main; print(main.DAY1_SALT, main.DAY2_SALT)"],
                         cwd=os.path.dirname(main.__file__), env=_env(DAY1_SALT="s1-env", DAY2_SALT="s2-env"),
                         capture_output=True, text=True, timeout=60)
    assert out.stdout.split() == ["s1-env", "s2-env"], out.stderr


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_server_listens_on_port_from_environment():
    """docker-compose sets PORT=8080 and maps host 8080 to it; python main.py must honour PORT."""
    port = _free_port()
    proc = subprocess.Popen([sys.executable, "main.py"], cwd=os.path.dirname(main.__file__),
                            env=_env(PORT=str(port), HOST="127.0.0.1"),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        body = None
        for _ in range(60):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as r:
                    body = json.loads(r.read())
                break
            except OSError:
                time.sleep(0.25)
        assert body == {"status": "ok"}
    finally:
        proc.terminate()
        proc.wait(timeout=10)
