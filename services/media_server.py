"""Client for the MediaMTX Control API (v3), reached on the internal Docker network only.

Verified against bluenviron/mediamtx:1.9.1: ``GET /v3/paths/list`` and ``GET /v3/paths/get/{name}``
describe paths and their publishing source; ``POST /v3/<kind>/kick/{id}`` closes a session. The API port
(9997) is never published to the host. When ``api_url`` is empty (local tests) every call is a no-op.
"""
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

# source.type reported by MediaMTX -> Control API collection that can kick it
KICKABLE_SOURCES = {
    "rtmpConn": "rtmpconns",
    "rtmpsConn": "rtmpconns",
    "rtspSession": "rtspsessions",
    "rtspsSession": "rtspssessions",
    "webRTCSession": "webrtcsessions",
    "srtConn": "srtconns",
}


class MediaServerClient:
    def __init__(self, api_url: str, timeout: float = 1.0, clock=time.monotonic):
        self.api_url = (api_url or "").rstrip("/")
        self.timeout = timeout
        self.clock = clock
        self._lock = threading.Lock()
        self._bytes: dict = {}           # path -> (monotonic time, bytesReceived) for bitrate deltas
        self._last_bitrate = 0.0

    @property
    def enabled(self) -> bool:
        return bool(self.api_url)

    def _request(self, method: str, path: str) -> Optional[dict]:
        if not self.enabled:
            return None
        req = urllib.request.Request(self.api_url + path, method=method, data=b"" if method == "POST" else None)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
                return json.loads(body) if body else {}
        except (urllib.error.URLError, OSError, ValueError):
            return None

    def reachable(self) -> bool:
        return self._request("GET", "/v3/paths/list?itemsPerPage=1") is not None

    def paths(self) -> list:
        data = self._request("GET", "/v3/paths/list?itemsPerPage=1000")
        return list((data or {}).get("items") or [])

    def ready_paths(self, prefixes=("live/", "costream/")) -> list:
        return [p for p in self.paths() if p.get("ready") and str(p.get("name", "")).startswith(prefixes)]

    def kick_publisher(self, path: str) -> bool:
        """Closes whatever session publishes ``path``. True when a publisher was found and kicked."""
        info = self._request("GET", "/v3/paths/get/" + urllib.parse.quote(path, safe="/"))
        source = (info or {}).get("source") or {}
        kind = KICKABLE_SOURCES.get(source.get("type"))
        if not kind or not source.get("id"):
            return False
        return self._request("POST", f"/v3/{kind}/kick/{source['id']}") is not None

    def kick_prefix(self, prefix: str) -> int:
        """Kicks every publisher whose path starts with ``prefix`` (used for cleanup and reset)."""
        return sum(1 for p in self.paths() if str(p.get("name", "")).startswith(prefix) and self.kick_publisher(p["name"]))

    def stream_stats(self) -> tuple:
        """(ready live/co-stream path count, total inbound kbps) from ONE Control API call.

        kbps comes from bytesReceived deltas between calls; a path's first sample contributes 0."""
        now = self.clock()
        total = 0.0
        ready = [p for p in self.paths() if p.get("ready") and str(p.get("name", "")).startswith(("live/", "costream/"))]
        with self._lock:
            seen = {}
            for p in ready:
                name, received = p["name"], int(p.get("bytesReceived") or 0)
                seen[name] = (now, received)
                prev = self._bytes.get(name)
                if prev and now > prev[0] and received >= prev[1]:
                    total += (received - prev[1]) * 8 / 1000 / (now - prev[0])
            self._bytes = seen
            self._last_bitrate = round(total, 1)
            return len(ready), self._last_bitrate

    def inbound_bitrate_kbps(self) -> float:
        return self.stream_stats()[1]
