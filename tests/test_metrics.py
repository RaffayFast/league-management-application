"""GET /metrics in Prometheus text format (Day 2 NFR-6). Values must track live state."""
import asyncio
import re

import main
from services.media_server import MediaServerClient
from services.metrics_service import MetricsService
from services.notification_dlq import Notification

REQUIRED = {"nascon_active_ws_connections": "gauge", "nascon_active_streams_total": "gauge",
            "nascon_stream_bitrate_kbps": "gauge", "nascon_dlq_depth": "gauge", "nascon_qr_scans_total": "counter"}


def parse(text):
    types, values = {}, {}
    for line in text.splitlines():
        if line.startswith("# TYPE "):
            _, _, name, kind = line.split(" ", 3)
            types[name] = kind
        elif line and not line.startswith("#"):
            name, value = line.rsplit(" ", 1)
            assert re.fullmatch(r"[a-zA-Z_:][a-zA-Z0-9_:]*", name)
            values[name] = float(value)
    return types, values


def test_exposition_format_and_required_metrics(client):
    r = client.get("/metrics")
    assert r.status_code == 200 and r.headers["content-type"] == "text/plain; version=0.0.4"
    types, values = parse(r.text)
    for name, kind in REQUIRED.items():
        assert types[name] == kind and name in values and f"# HELP {name} " in r.text
    assert set(types) == set(values)          # every sample has metadata and vice versa


def test_values_follow_live_state(client):
    _, before = parse(client.get("/metrics").text)
    client.get("/q/m1-live", follow_redirects=False)
    client.get("/audit/v1/qr/match-m1")
    main.DLQ_STORE.add(Notification("test", "chat-x", {}, event_id="ntf-metrics"), 3, "x", [])
    _, after = parse(client.get("/metrics").text)
    assert after["nascon_qr_scans_total"] == before["nascon_qr_scans_total"] + 2
    assert after["nascon_dlq_depth"] == before["nascon_dlq_depth"] + 1
    assert after["nascon_active_streams_total"] == 0 and after["nascon_stream_bitrate_kbps"] == 0  # no media in tests


def test_open_live_connections_are_counted():
    async def scenario():
        sub = main.LIVE_FEED.subscribe("match:match-m1")
        try:
            return parse(main.METRICS.render())[1]["nascon_active_ws_connections"]
        finally:
            main.LIVE_FEED.unsubscribe(sub)

    base = main.LIVE_FEED.subscriber_count()
    assert asyncio.run(scenario()) == base + 1


class _Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def test_stream_metrics_come_from_media_server_counters(monkeypatch):
    clock = _Clock()
    media = MediaServerClient("http://mediamtx:9997", clock=clock)
    samples = iter([[{"name": "live/sk_live_101", "ready": True, "bytesReceived": 1_000_000}],
                    [{"name": "live/sk_live_101", "ready": True, "bytesReceived": 1_312_500}]])
    monkeypatch.setattr(media, "reachable", lambda: True)
    monkeypatch.setattr(media, "paths", lambda: next(samples))
    metrics = MetricsService(lambda: 0, media, lambda: 0, lambda: 0)
    assert parse(metrics.render())[1]["nascon_stream_bitrate_kbps"] == 0.0     # first sample: no delta yet
    clock.t += 1.0
    values = parse(metrics.render())[1]
    assert values["nascon_active_streams_total"] == 1 and values["nascon_stream_bitrate_kbps"] == 2500.0
