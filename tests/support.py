"""Shared test helpers (a plain module: importing from conftest is ambiguous with two conftest.py files)."""


class FakeMedia:
    """Stands in for MediaServerClient: records kicks and serves canned paths."""

    def __init__(self, paths=None):
        self.kicked, self._paths = [], list(paths or [])
        self.enabled = True

    def kick_publisher(self, path):
        self.kicked.append(path)
        return True

    def kick_prefix(self, prefix):
        hits = [p["name"] for p in self._paths if p["name"].startswith(prefix)] or [prefix]
        self.kicked.extend(hits)
        return len(hits)

    def paths(self):
        return list(self._paths)

    def ready_paths(self, prefixes=("live/", "costream/")):
        return [p for p in self._paths if p.get("ready") and p["name"].startswith(prefixes)]

    def reachable(self):
        return True

    def inbound_bitrate_kbps(self):
        return 0.0

    def stream_stats(self):
        return len(self.ready_paths()), 0.0
