"""Phase I contract regression (Day 1 spec / api_contract.md Part A and B)."""
import threading

import main

MINI_CRICKET = {"sport_id": "mini_cricket", "name": "Mini Cricket", "scoring_model": "innings",
                "periods": {"innings_per_team": 1, "overs_per_innings": 2, "balls_per_over": 6,
                            "wickets_per_innings": 10},
                "scoring_events": {"dot": {"runs": 0, "legal_ball": True, "wicket": False},
                                   "one": {"runs": 1, "legal_ball": True, "wicket": False},
                                   "four": {"runs": 4, "legal_ball": True, "wicket": False},
                                   "wd": {"runs": 1, "legal_ball": False, "wicket": False},
                                   "out": {"runs": 0, "legal_ball": True, "wicket": True}},
                "draw_allowed": True}


def _innings_match(post_event, match_id, home_balls, away_balls):
    post_event(f"{match_id}-s", match_id, "match_start")
    for i, e in enumerate(home_balls):
        assert post_event(f"{match_id}-h{i}", match_id, "score", {"team_id": "A", "event_type": e}).status_code == 201
    for i, e in enumerate(away_balls):
        assert post_event(f"{match_id}-a{i}", match_id, "score", {"team_id": "B", "event_type": e}).status_code == 201
    assert post_event(f"{match_id}-e", match_id, "match_end").status_code == 201


def test_health_and_reset_contract(client):
    assert client.get("/health").json() == {"status": "ok"}
    r = client.post("/audit/v1/reset", json={"seed": 42, "stock": {"var-jersey-001-M": 1, "var-jersey-001-L": 5}})
    assert r.status_code == 200
    assert r.json() == {"status": "reset_complete", "seed": 42,
                        "sports": ["football", "basketball", "cricket", "esports"],
                        "tenants": ["tenant-alpha", "tenant-beta"],
                        "stock": {"var-jersey-001-M": 1, "var-jersey-001-L": 5}}


def test_signature_matches_appendix_a_vector_1():
    assert main.sign("demo-salt", "evt-1", {"team_id": "t1", "event_type": "goal"}) == \
        "972a8b558690b19121cc5bea84978f85e8eb15a3735018db36616bab1d7ec501"


def test_mystery_sport_works_end_to_end_without_code_change(client, post_event):
    sport = {"sport_id": "kabaddi", "name": "Kabaddi", "scoring_model": "event",
             "periods": {"count": 2, "duration_minutes": 20},
             "scoring_events": {"raid_point": {"points": 1}, "all_out": {"points": 2}}, "draw_allowed": False}
    assert client.post("/audit/v1/sports", json=sport).status_code == 201
    assert client.post("/audit/v1/sports", json=sport).json()["error"]["code"] == "SPORT_EXISTS"
    assert client.post("/audit/v1/leagues", json={"league_id": "lg-k", "sport_id": "kabaddi", "teams": ["h", "a"],
                                                  "fixtures": [{"match_id": "k1", "home": "h", "away": "a"}]}
                       ).status_code == 201
    post_event("k-1", "k1", "match_start")
    r = post_event("k-2", "k1", "score", {"team_id": "h", "event_type": "all_out"})
    assert r.status_code == 201
    assert r.json()["signature"] == main.sign(main.DAY1_SALT, "k-2", {"team_id": "h", "event_type": "all_out"})
    post_event("k-3", "k1", "score", {"team_id": "a", "event_type": "raid_point"})
    assert post_event("k-4", "k1", "score", {"team_id": "a", "event_type": "goal"}).json()["error"]["code"] == \
        "UNKNOWN_EVENT_TYPE"
    post_event("k-5", "k1", "match_end")
    score = client.get("/audit/v1/score/k1").json()
    assert (score["home"]["score"], score["away"]["score"], score["outcome"]) == (2, 1, "home_win")
    assert client.get("/audit/v1/standings/lg-k").json()["table"][0]["team_id"] == "h"


def test_event_idempotency_and_compensation(client, post_event):
    post_event("x-1", "solo", "match_init", {"sport_id": "football", "home_team_id": "h", "away_team_id": "a"})
    post_event("x-2", "solo", "match_start")
    first = post_event("x-3", "solo", "score", {"team_id": "h", "event_type": "goal"})
    assert first.status_code == 201
    replay = post_event("x-3", "solo", "score", {"team_id": "h", "event_type": "goal"})
    assert (replay.status_code, replay.json()) == (200, first.json())
    assert post_event("x-3", "solo", "score", {"team_id": "a", "event_type": "goal"}).json()["error"]["code"] == \
        "DUPLICATE_EVENT_ID"
    post_event("x-4", "solo", "compensation", {"compensates": "x-3", "reason": "offside"})
    score = client.get("/audit/v1/score/solo").json()
    assert score["home"]["score"] == 0 and score["version"] == 4
    assert [e["compensated"] for e in score["events"]] == [False, False, True, False]


def test_score_fields_per_scoring_model(client, post_event):
    client.post("/audit/v1/sports", json=MINI_CRICKET)
    post_event("c-0", "c1", "match_init", {"sport_id": "mini_cricket", "home_team_id": "A", "away_team_id": "B"})
    post_event("c-1", "c1", "match_start")
    for i, e in enumerate(["four", "wd", "one", "out"]):
        post_event(f"c-b{i}", "c1", "score", {"team_id": "A", "event_type": e})
    home = client.get("/audit/v1/score/c1").json()["home"]
    assert home == {"team_id": "A", "score": 6, "wickets": 1, "balls": 3, "overs": "0.3", "fair_play": 0}

    post_event("r-0", "r1", "match_init", {"sport_id": "esports", "home_team_id": "h", "away_team_id": "a"})
    post_event("r-1", "r1", "match_start")
    post_event("r-2", "r1", "score", {"team_id": "h", "event_type": "round_win"})
    post_event("r-3", "r1", "score", {"team_id": "h", "event_type": "round_win"})
    decided = post_event("r-4", "r1", "score", {"team_id": "a", "event_type": "round_win"})
    assert (decided.status_code, decided.json()["error"]["code"]) == (409, "SERIES_ALREADY_DECIDED")
    away = client.get("/audit/v1/score/r1").json()["away"]
    assert away == {"team_id": "a", "score": 0, "wickets": None, "balls": None, "overs": None, "fair_play": 0}


def test_innings_limit_applies_to_own_balls_not_to_a_completed_chase(client, post_event):
    """Day 1 5.9: only a team's own legal balls or wickets close its innings (no extra chase rule)."""
    client.post("/audit/v1/sports", json={**MINI_CRICKET, "sport_id": "one_over",
                                          "periods": {**MINI_CRICKET["periods"], "overs_per_innings": 1}})
    post_event("o-0", "o1", "match_init", {"sport_id": "one_over", "home_team_id": "A", "away_team_id": "B"})
    post_event("o-1", "o1", "match_start")
    for i in range(6):
        post_event(f"o-a{i}", "o1", "score", {"team_id": "A", "event_type": "dot" if i else "four"})
    assert post_event("o-a6", "o1", "score", {"team_id": "A", "event_type": "one"}).json()["error"]["code"] == \
        "INNINGS_COMPLETE"
    post_event("o-b0", "o1", "score", {"team_id": "B", "event_type": "four"})
    post_event("o-b1", "o1", "score", {"team_id": "B", "event_type": "one"})  # B now leads 5-4
    assert post_event("o-b2", "o1", "score", {"team_id": "B", "event_type": "one"}).status_code == 201


def test_innings_standings_diff_is_net_run_rate(client, post_event):
    client.post("/audit/v1/sports", json=MINI_CRICKET)
    client.post("/audit/v1/leagues", json={"league_id": "lg-c", "sport_id": "mini_cricket", "teams": ["A", "B"],
                                           "fixtures": [{"match_id": "c1", "home": "A", "away": "B"}]})
    # A: 6 runs off 3 legal balls (0.5 overs); B: 8 off 5 balls -> A NRR = 12 - 9.6 = 2.4, B wins on runs
    _innings_match(post_event, "c1", ["four", "wd", "one", "dot"], ["one", "one", "one", "one", "four"])
    table = {row["team_id"]: row for row in client.get("/audit/v1/standings/lg-c").json()["table"]}
    assert (table["B"]["won"], table["B"]["scored"], table["B"]["conceded"]) == (1, 8, 6)
    assert table["A"]["diff"] == 2.4 and table["B"]["diff"] == -2.4


def test_h2h_diff_uses_net_run_rate_for_innings_sports(client, post_event):
    client.post("/audit/v1/sports", json=MINI_CRICKET)
    client.post("/audit/v1/leagues", json={"league_id": "lg-d", "sport_id": "mini_cricket", "teams": ["A", "B"],
                                           "fixtures": [{"match_id": "d1", "home": "A", "away": "B"}]})
    # Level on runs (draw), but A scored 8 off 1 over and B 8 off 2 overs -> h2h NRR A +4, B -4
    _innings_match(post_event, "d1", ["four", "four", "dot", "dot", "dot", "dot"], ["one"] * 8 + ["dot"] * 4)
    table = client.get("/audit/v1/standings/lg-d").json()["table"]
    assert [(r["team_id"], r["points"], r["resolved_by"]) for r in table] == [("A", 1, "h2h_diff"),
                                                                             ("B", 1, "h2h_diff")]
    assert (table[0]["diff"], table[1]["diff"]) == (4.0, -4.0)


def test_draw_lots_key_matches_reference_prefixes():
    assert main._lots_key(42, "lg-1", "t1").startswith("0613316991")
    assert main._lots_key(42, "lg-1", "t2").startswith("e3e3a14e22")
    assert main._lots_key(42, "lg-1", "t3").startswith("c8f28e3c2f")


def test_draw_lots_ordering(client):
    client.post("/audit/v1/leagues", json={"league_id": "lg-1", "sport_id": "football", "teams": ["t1", "t2", "t3"],
                                           "fixtures": [], "lots_seed": 42})
    table = client.get("/audit/v1/standings/lg-1").json()["table"]
    assert [(r["team_id"], r["resolved_by"]) for r in table] == [("t1", "draw_lots"), ("t3", "draw_lots"),
                                                                ("t2", "draw_lots")]
    # draw_lots still applies after the listed criteria when tie_break_order omits it
    client.post("/audit/v1/leagues", json={"league_id": "lg-2", "sport_id": "football", "teams": ["t1", "t2", "t3"],
                                           "fixtures": [], "tie_break_order": ["h2h_points"], "lots_seed": 42})
    keys = sorted(["t1", "t2", "t3"], key=lambda t: main._lots_key(42, "lg-2", t))
    assert [r["team_id"] for r in client.get("/audit/v1/standings/lg-2").json()["table"]] == keys


def test_event_model_standings_and_h2h(client, post_event):
    client.post("/audit/v1/leagues", json={
        "league_id": "lg-e", "sport_id": "football", "teams": ["t1", "t2", "t3"],
        "fixtures": [{"match_id": "e1", "home": "t1", "away": "t2"}, {"match_id": "e2", "home": "t2", "away": "t3"},
                     {"match_id": "e3", "home": "t3", "away": "t1"}], "qualification": {"spots": 1}})
    for mid, home, goals_home, away, goals_away in (("e1", "t1", 2, "t2", 0), ("e2", "t2", 1, "t3", 1),
                                                    ("e3", "t3", 0, "t1", 1)):
        post_event(f"{mid}-s", mid, "match_start")
        for i in range(goals_home):
            post_event(f"{mid}-h{i}", mid, "score", {"team_id": home, "event_type": "goal"})
        for i in range(goals_away):
            post_event(f"{mid}-a{i}", mid, "score", {"team_id": away, "event_type": "goal"})
        post_event(f"{mid}-e", mid, "match_end")
    body = client.get("/audit/v1/standings/lg-e").json()
    # t2 and t3 drew each other, so h2h is level and overall_diff (-1 vs -2) separates them
    assert [(r["team_id"], r["points"], r["diff"], r["status"], r["resolved_by"]) for r in body["table"]] == [
        ("t1", 6, 3, "clinched", None), ("t3", 1, -1, "eliminated", "overall_diff"),
        ("t2", 1, -2, "eliminated", "overall_diff")]
    assert body["h2h"]["t1"]["t2"] == {"played": 1, "points": 3, "scored": 2, "conceded": 0}


def test_checkout_burst_never_oversells(client):
    client.post("/audit/v1/reset", json={"stock": {"var-jersey-001-M": 1}})
    results = []

    def buy(i):
        try:
            main._checkout({"order_id": f"burst-{i}", "customer_id": "c", "discount_code": None,
                            "items": [{"variant_id": "var-jersey-001-M", "quantity": 1}],
                            "payment": {"token": "tok_success"}})
            results.append("ok")
        except main.ApiError as exc:
            results.append(exc.code)

    threads = [threading.Thread(target=buy, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results.count("ok") == 1 and results.count("OUT_OF_STOCK") == 19
    assert client.get("/audit/v1/inventory/var-jersey-001-M").json() == \
        {"variant_id": "var-jersey-001-M", "stock": 0, "reserved": 0}


def test_rbac_probes_and_token_checks(client):
    tokens = client.post("/audit/v1/rbac-matrix").json()["tokens"]
    assert client.post("/audit/v1/rbac/tenants", headers={"Authorization": f"Bearer {tokens['super_admin']}"}
                       ).json() == {"authorized": True}
    denied = client.post("/audit/v1/rbac/tenants", headers={"Authorization": f"Bearer {tokens['viewer']}"})
    assert (denied.status_code, denied.json()["error"]["code"]) == (403, "FORBIDDEN")
    assert client.post("/audit/v1/rbac/tenants").status_code == 401
    cross = client.post("/audit/v1/rbac/clubs/club-beta-1/roster",
                        headers={"Authorization": f"Bearer {tokens['club_manager']}"})
    assert cross.status_code == 403


def test_offline_sync_replay_is_duplicate(client):
    body = {"device_id": "dev-1", "actions": [
        {"action_id": "a1", "type": "score_event", "queued_at": "2026-10-17T11:00:00Z", "base_version": 3,
         "payload": {"event_id": "sy-1", "match_id": "demo-m2", "type": "score",
                     "payload": {"team_id": "club-alpha-1", "event_type": "goal"}}}]}
    first = client.post("/audit/v1/offline-sync", json=body).json()
    assert first["results"][0]["status"] == "applied" and first["results"][0]["resolution"] == "appended"
    again = client.post("/audit/v1/offline-sync", json=body).json()
    assert again["results"][0]["status"] == "duplicate" and again["summary"]["duplicate"] == 1


def test_app_login_and_demo_routes(client):
    login = client.post("/api/v1/auth/login", json={"email": "organizer@nascon.test", "password": "Nascon@26"})
    assert login.status_code == 200 and login.json()["user"]["league_id"] == "league-alpha-1"
    auth = {"Authorization": f"Bearer {login.json()['token']}"}
    fixtures = client.get("/api/v1/leagues/league-alpha-1/fixtures", headers=auth).json()["fixtures"]
    assert [f["match_id"] for f in fixtures][:3] == ["demo-m1", "demo-m2", "demo-m3"]
    match = client.get("/api/v1/matches/demo-m2", headers=auth).json()
    assert match["pinned_product"]["product_id"] == "prod-jersey-001" and match["home"]["score"] == 1


def test_errors_use_the_standard_envelope(client):
    r = client.post("/audit/v1/events", content=b"{not json", headers={"Content-Type": "application/json"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    big = client.post("/audit/v1/events", content=b"{" + b" " * (1024 * 1024 + 1) + b"}",
                      headers={"Content-Type": "application/json"})
    assert big.status_code == 413 and big.json()["error"]["code"] == "PAYLOAD_TOO_LARGE"
    bad_model = client.post("/audit/v1/sports", json={"sport_id": "s1", "name": "S", "scoring_model": ["event"],
                                                      "periods": {}, "scoring_events": {"x": {"points": 1}}})
    assert bad_model.status_code == 400 and "scoring_model" in bad_model.json()["error"]["details"]["fields"]
