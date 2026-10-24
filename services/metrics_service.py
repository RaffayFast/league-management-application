"""Prometheus text exposition for GET /metrics (Day 2 NFR-6, spec 5.9). Every value comes from live state.

- nascon_active_ws_connections  gauge    open live connections. The platform pushes over SSE (no WebSocket
                                         route exists), so this counts open SSE streams under the contract name.
- nascon_active_streams_total   gauge    ready ``live/*`` and ``costream/*`` paths reported by MediaMTX
- nascon_stream_bitrate_kbps    gauge    inbound kbps over those paths, from bytesReceived deltas (0 when idle)
- nascon_dlq_depth              gauge    rows in the persistent dead-letter queue
- nascon_qr_scans_total         counter  scans recorded on QR mappings since the last reset
- nascon_media_server_up        gauge    1 when the MediaMTX Control API answers (extra, for diagnosis)
"""
from typing import Callable

CONTENT_TYPE = "text/plain; version=0.0.4"


class MetricsService:
    def __init__(self, live_connections: Callable[[], int], media, dlq_depth: Callable[[], int],
                 qr_scans: Callable[[], int]):
        self.live_connections, self.media, self.dlq_depth, self.qr_scans = live_connections, media, dlq_depth, qr_scans

    def samples(self) -> list:
        """(name, type, help, value) tuples in exposition order."""
        media_up = 1 if (self.media.enabled and self.media.reachable()) else 0
        streams, bitrate = self.media.stream_stats() if media_up else (0, 0.0)
        return [
            ("nascon_active_ws_connections", "gauge", "Current active live-update connections (SSE)",
             self.live_connections()),
            ("nascon_active_streams_total", "gauge", "Total live broadcast streams", streams),
            ("nascon_stream_bitrate_kbps", "gauge", "Active stream bitrate in kbps", bitrate),
            ("nascon_dlq_depth", "gauge", "Dead letter queue message depth", self.dlq_depth()),
            ("nascon_qr_scans_total", "counter", "Cumulative dynamic QR scan count", self.qr_scans()),
            ("nascon_media_server_up", "gauge", "1 when the media server Control API is reachable", media_up),
        ]

    def render(self) -> str:
        lines = []
        for name, kind, help_text, value in self.samples():
            lines += [f"# HELP {name} {help_text}", f"# TYPE {name} {kind}", f"{name} {value}"]
        return "\n".join(lines) + "\n"
