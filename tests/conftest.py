import os
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
# Test defaults only; real salts always come from the environment (docker-compose / grader)
os.environ.setdefault("DAY1_SALT", "demo-salt")
os.environ.setdefault("DAY2_SALT", "T01D27ad7ffff12e")
# Tests reset state constantly; keep the persistent DLQ in a throwaway file, never data/ in the repo
import tempfile  # noqa: E402
os.environ.setdefault("DLQ_PATH", os.path.join(tempfile.mkdtemp(prefix="nascon-dlq-"), "dlq.sqlite3"))

import main  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from support import FakeMedia  # noqa: E402


@pytest.fixture()
def fake_media(monkeypatch):
    """Replaces the MediaMTX client of the stream-key and co-stream services with a recorder."""
    media = FakeMedia()
    for svc in (main.STREAM_KEYS, main.COSTREAMS):
        monkeypatch.setattr(svc, "media", media)
    return media


@pytest.fixture()
def client():
    """A client on freshly reset state (Phase I + Phase II baseline)."""
    c = TestClient(main.app)
    assert c.post("/audit/v1/reset", json={}).status_code == 200
    return c


@pytest.fixture(scope="module")
def live_server():
    """A real uvicorn process (python main.py) on a free port, for streaming tests TestClient can't do."""
    import json
    import socket
    import subprocess
    import time
    import urllib.request

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    env = {k: v for k, v in os.environ.items() if k not in ("PORT", "HOST")}
    env.update(PORT=str(port), HOST="127.0.0.1", PYTHONDONTWRITEBYTECODE="1")
    proc = subprocess.Popen([sys.executable, "main.py"], cwd=str(ROOT), env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(80):
            try:
                with urllib.request.urlopen(base + "/health", timeout=1) as r:
                    if json.loads(r.read()) == {"status": "ok"}:
                        break
            except OSError:
                time.sleep(0.25)
        else:
            pytest.fail("live server did not become healthy")
        yield base
    finally:
        proc.terminate()
        proc.wait(timeout=10)


@pytest.fixture()
def post_event(client):
    def _post(event_id, match_id, evt_type, payload=None):
        return client.post("/audit/v1/events", json={"event_id": event_id, "match_id": match_id, "type": evt_type,
                                                     "payload": payload or {}})
    return _post
