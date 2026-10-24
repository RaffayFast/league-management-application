"""Guest Web Player pages, QR entry point and live transport (Day 2 FR-4.1, FR-4.2, NFR-1, spec 6.2.2)."""
import http.client
import json
import re
import time
import urllib.request
from urllib.parse import urlparse

import pytest

import main
from services.qr_resolver import target_route

TESTIDS = ["guest-video-player", "live-score-banner", "pinned-merch-card", "add-to-guest-cart-btn",
           "guest-cart-count", "chat-message-list", "chat-input-field", "chat-send-btn", "progressive-auth-modal"]


def _tag(html, testid):
    match = re.search(r"<[^>]*data-testid=\"%s\"[^>]*>" % re.escape(testid), html)
    assert match, f"missing data-testid={testid}"
    return match.group(0)


def _element_text(html, testid):
    """Text content of the element carrying ``testid`` (children's tags stripped)."""
    match = re.search(r"<(\w+)[^>]*data-testid=\"%s\"[^>]*>(.*?)</\1>" % re.escape(testid), html, re.S)
    return re.sub(r"<[^>]+>", "", match.group(2)) if match else None


def _boot(html):
    return json.loads(re.search(r'<script type="application/json" id="guest-boot">(.*?)</script>', html, re.S).group(1))


# ---------------------------------------------------------------- pages
def test_live_page_exposes_the_dom_contract_without_any_login(client):
    r = client.get("/web/matches/match-m1/live")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    html = r.text
    for testid in TESTIDS:
        _tag(html, testid)
    assert _tag(html, "guest-video-player").startswith("<video")
    assert _tag(html, "chat-input-field").startswith("<input")
    assert _tag(html, "chat-send-btn").startswith("<button") and _tag(html, "add-to-guest-cart-btn").startswith("<button")
    modal = _tag(html, "progressive-auth-modal")
    assert "role=\"dialog\"" in modal and "aria-modal=\"true\"" in modal and " hidden" in modal  # closed on load
    assert re.search(r'data-testid="chat-message-list"[^>]*>\s*</ul>', html), "chat list starts empty"
    assert _element_text(html, "guest-cart-count") == "0"


def test_live_page_renders_real_backend_state(client, post_event):
    html = client.get("/web/matches/match-m1/live").text
    assert _element_text(html, "live-score-banner") == "1 - 0"
    assert "Alpha FC" in html and "Beta United" in html
    assert 'data-variant-id="var-jersey-001-L"' in html and "PKR 4500.00" in html
    boot = _boot(html)
    assert boot["chat_room_id"] == "chat-match-m1" and boot["snapshot"]["status"] == "in_progress"
    assert boot["playback_url"] == "http://localhost:8888/live/match-m1/index.m3u8"
    post_event("w-1", "match-m1", "score", {"team_id": "club-alpha-1", "event_type": "goal"})
    assert _element_text(client.get("/web/matches/match-m1/live").text, "live-score-banner") == "2 - 0"


@pytest.mark.parametrize("path,needle", [
    ("/web/matches/match-m1/preview", "Kick-off"),
    ("/web/matches/match-m1/vod", "Replay not available yet"),
    ("/web/matches/match-m1/notice?state=postponed", "postponed"),
    ("/web/players/player-alpha-1", "Ali"),
    ("/web/clubs/club-alpha-1", "Alpha Stadium"),
    ("/web/costream/cs-session-101", "chat-cs-session-101"),
    ("/web/", "Live and upcoming matches"),
])
def test_state_aware_pages_render(client, path, needle):
    r = client.get(path)
    assert r.status_code == 200 and needle in r.text


def test_costream_page_uses_one_unified_chat_room_and_full_dom_contract(client):
    html = client.get("/web/costream/cs-session-101?match=match-m1").text
    for testid in TESTIDS:
        _tag(html, testid)
    boot = _boot(html)
    assert boot["chat_room_id"] == "chat-cs-session-101" and boot["match_id"] == "match-m1"
    assert boot["playback_url"] == "http://localhost:8888/costream/cs-session-101/index.m3u8"
    assert _element_text(html, "live-score-banner") == "1 - 0"


@pytest.mark.parametrize("path", ["/web/matches/nope/live", "/web/players/nope", "/web/clubs/nope",
                                  "/web/matches/bad%7Cid/live"])
def test_unknown_entities_get_a_friendly_404_page(client, path):
    r = client.get(path)
    assert r.status_code == 404 and r.headers["content-type"].startswith("text/html")
    assert "couldn" in r.text


def test_page_text_is_html_escaped(client):
    client.post("/audit/v1/leagues", json={"league_id": "lg-x", "sport_id": "football",
                                           "teams": ["<script>a</script>", "b"],
                                           "fixtures": []})
    client.post("/audit/v1/events", json={"event_id": "x1", "match_id": "xss-1", "type": "match_init",
                                          "payload": {"sport_id": "football", "home_team_id": "h-1",
                                                      "away_team_id": "a-1"}})
    main.DB["clubs"]["h-1"] = {**main.DB["clubs"]["club-alpha-1"], "club_id": "h-1", "name": "<b>Evil</b>"}
    html = client.get("/web/matches/xss-1/preview").text
    assert "<b>Evil</b>" not in html and "&lt;b&gt;Evil&lt;/b&gt;" in html


def test_static_assets_are_served(client):
    css = client.get("/web/static/guest_player.css")
    js = client.get("/web/static/guest_player.js")
    assert css.status_code == 200 and "text/css" in css.headers["content-type"]
    assert js.status_code == 200 and "javascript" in js.headers["content-type"]
    assert "GUEST_WRITE_FORBIDDEN" in js.text and "EventSource" in js.text


# ---------------------------------------------------------------- QR entry point
def test_short_link_redirects_to_the_live_state_route(client, post_event):
    r = client.get("/q/m1-live", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/web/matches/match-m1/live"
    assert main.DB["qr_codes"]["match-m1"]["scan_count"] == 1
    post_event("q-end", "match-m1", "match_end")
    r = client.get("/q/m1-live", follow_redirects=False)
    assert r.headers["location"] == "/web/matches/match-m1/vod"  # same printed link, new target
    assert main.DB["qr_codes"]["match-m1"]["short_url"] == "http://localhost:8080/q/m1-live"


def test_player_and_club_short_links(client):
    assert client.get("/q/p-alpha-1", follow_redirects=False).headers["location"] == "/web/players/player-alpha-1"
    assert client.get("/q/c-alpha-1", follow_redirects=False).headers["location"] == "/web/clubs/club-alpha-1"
    r = client.get("/q/nope", follow_redirects=False)
    assert (r.status_code, r.json()["error"]["code"]) == (404, "QR_NOT_FOUND")


@pytest.mark.parametrize("entity_type,entity_id,status,route", [
    ("match", "m", "upcoming", "/web/matches/m/preview"),
    ("match", "m", "in_progress", "/web/matches/m/live"),
    ("match", "m", "completed", "/web/matches/m/vod"),
    ("match", "m", "postponed", "/web/matches/m/notice?state=postponed"),
    ("match", "m", "cancelled", "/web/matches/m/notice?state=cancelled"),
    ("match", "m", "abandoned", "/web/matches/m/notice?state=abandoned"),
    ("player", "player-alpha-1", None, "/web/players/player-alpha-1"),
    ("club", "club-alpha-1", None, "/web/clubs/club-alpha-1"),
    ("costream", "cs-session-101", None, "/web/costream/cs-session-101"),
])
def test_target_route_rules(entity_type, entity_id, status, route):
    assert target_route(entity_type, entity_id, status) == route


# ---------------------------------------------------------------- live transport against a real server
def _open_stream(base, path):
    url = urlparse(base)
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
    conn.request("GET", path, headers={"Accept": "text/event-stream"})
    resp = conn.getresponse()
    assert resp.status == 200 and resp.getheader("content-type").startswith("text/event-stream")
    return conn, resp


def _next_event(resp):
    event = data = None
    while True:
        line = resp.readline()
        if not line:
            raise EOFError("stream closed")
        line = line.decode("utf-8").rstrip("\r\n")
        if line.startswith(":") or line.startswith("retry:"):
            continue
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data = json.loads(line[5:].strip())
        elif line == "" and event:
            return event, data


def _post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def test_score_stream_pushes_new_score_within_500ms(live_server):
    _post(live_server, "/audit/v1/reset", {})
    conn, resp = _open_stream(live_server, "/api/v1/matches/match-m1/stream")
    try:
        event, snap = _next_event(resp)
        assert event == "score" and (snap["home"]["score"], snap["away"]["score"]) == (1, 0)
        started = time.perf_counter()
        assert _post(live_server, "/audit/v1/events", {"event_id": "sse-1", "match_id": "match-m1", "type": "score",
                                                       "payload": {"team_id": "club-alpha-1", "event_type": "goal"}}) == 201
        event, snap = _next_event(resp)
        elapsed = time.perf_counter() - started
        assert event == "score" and snap["home"]["score"] == 2
        assert elapsed < 0.5, f"score push took {elapsed:.3f}s"
        _post(live_server, "/audit/v1/reset", {})  # open pages get the re-seeded score
        event, snap = _next_event(resp)
        assert snap["home"]["score"] == 1 and snap["version"] == 3
    finally:
        conn.close()


def test_chat_stream_starts_with_history_and_unknown_match_stream_is_404(live_server):
    conn, resp = _open_stream(live_server, "/api/v1/chat/chat-match-m1/stream")
    try:
        assert _next_event(resp) == ("history", {"chat_room_id": "chat-match-m1", "messages": []})
    finally:
        conn.close()
    with pytest.raises(urllib.error.HTTPError) as err:
        urllib.request.urlopen(live_server + "/api/v1/matches/nope/stream", timeout=5)
    assert err.value.code == 404 and json.loads(err.value.read())["error"]["code"] == "MATCH_NOT_FOUND"
