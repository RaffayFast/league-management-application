"""GET /audit/v1/qr/{entity_id} and exports (Day 2 FR-4.1, spec 5.6, hidden scenario 2)."""
import pytest

import main


def _sig(entity_id, short_url, route):
    return main.sign(main.DAY2_SALT, entity_id, {"entity_id": entity_id, "short_url": short_url, "target_route": route})


def test_match_resolution_matches_the_contract(client):
    r = client.get("/audit/v1/qr/match-m1")
    assert r.status_code == 200
    assert r.json() == {
        "entity_id": "match-m1", "entity_type": "match", "entity_status": "in_progress",
        "short_url": "http://localhost:8080/q/m1-live", "target_route": "/web/matches/match-m1/live",
        "deep_link_uri": "nascon://entity/match-m1", "scan_count": 1,
        "export_formats": {"svg": "http://localhost:8080/audit/v1/qr/match-m1/export.svg",
                           "png": "http://localhost:8080/audit/v1/qr/match-m1/export.png",
                           "pdf": "http://localhost:8080/audit/v1/qr/match-m1/export.pdf"},
        "signature": _sig("match-m1", "http://localhost:8080/q/m1-live", "/web/matches/match-m1/live")}


def test_inspect_reads_without_counting(client):
    client.get("/audit/v1/qr/match-m1?inspect=true")
    assert client.get("/audit/v1/qr/match-m1?inspect=true").json()["scan_count"] == 0
    assert client.get("/audit/v1/qr/match-m1").json()["scan_count"] == 1


def test_target_and_signature_follow_state_but_the_printed_link_does_not(client, post_event):
    live = client.get("/audit/v1/qr/match-m1?inspect=true").json()
    post_event("qr-end", "match-m1", "match_end")
    done = client.get("/audit/v1/qr/match-m1?inspect=true").json()
    assert done["short_url"] == live["short_url"] and done["target_route"] == "/web/matches/match-m1/vod"
    assert done["entity_status"] == "completed" and done["signature"] != live["signature"]
    assert done["signature"] == _sig("match-m1", done["short_url"], "/web/matches/match-m1/vod")


def test_seeded_player_and_club_and_generated_mappings(client):
    assert client.get("/audit/v1/qr/player-alpha-1").json()["target_route"] == "/web/players/player-alpha-1"
    assert client.get("/audit/v1/qr/club-alpha-1").json()["short_url"] == "http://localhost:8080/q/c-alpha-1"
    beta = client.get("/audit/v1/qr/club-beta-1").json()            # not seeded: generated on first use
    assert beta["entity_type"] == "club" and beta["short_url"].startswith("http://localhost:8080/q/c-")
    code = beta["short_url"].rsplit("/", 1)[1]
    assert client.get(f"/q/{code}", follow_redirects=False).headers["location"] == "/web/clubs/club-beta-1"
    main.DB["costream_sessions"]["cs-session-101"] = {"status": "active"}
    cs = client.get("/audit/v1/qr/cs-session-101").json()
    assert cs["deep_link_uri"] == "nascon://stream/cs-session-101" and cs["target_route"] == "/web/costream/cs-session-101"


def test_unknown_entity_is_404(client):
    r = client.get("/audit/v1/qr/nothing-here")
    assert (r.status_code, r.json()["error"]["code"]) == (404, "QR_NOT_FOUND")
    assert client.get("/audit/v1/qr/nothing-here/export.png").status_code == 404


@pytest.mark.parametrize("fmt,ctype,magic", [("svg", "image/svg+xml", b"<?xml"), ("png", "image/png", b"\x89PNG\r\n\x1a\n"),
                                             ("pdf", "application/pdf", b"%PDF-")])
def test_exports(client, fmt, ctype, magic):
    r = client.get(f"/audit/v1/qr/match-m1/export.{fmt}")
    assert r.status_code == 200 and r.headers["content-type"].startswith(ctype) and r.content.startswith(magic)
    if fmt == "svg":
        assert b"<svg" in r.content and b"http://localhost:8080/q/m1-live" in r.content
    if fmt == "pdf":
        assert b"match-m1" in r.content and b"http://localhost:8080/q/m1-live" in r.content
