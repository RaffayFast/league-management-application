"""Selenium Grid 4 fixtures for the Guest Web Player suite (Day 2 spec 6.2.3).

Configuration (environment variables):
  SELENIUM_REMOTE_URL  Grid hub, default http://localhost:4444
  GUEST_BASE_URL       URL the *browser containers* use to reach the backend. Inside the compose network the
                       backend service is ``web``, so the default is http://web:8080. Use
                       http://host.docker.internal:8080 when the backend runs outside compose.
  API_BASE_URL         URL *this test process* uses for direct API calls, default http://localhost:8080
  SELENIUM_BROWSERS    comma-separated, default "chrome,firefox"
  SELENIUM_REQUIRED=1  fail instead of skip when Selenium or the Grid is unavailable

Run (grid up):  pytest -n 3 tests/selenium/ --junitxml=tests/reports/selenium-report.xml
"""
import http.client
import json
import os
import urllib.request
from urllib.parse import urlparse

import pytest

try:
    from selenium import webdriver
    HAVE_SELENIUM = True
except ImportError:  # backend-only environments
    HAVE_SELENIUM = False

REMOTE_URL = os.getenv("SELENIUM_REMOTE_URL", "http://localhost:4444").rstrip("/")
GUEST_BASE_URL = os.getenv("GUEST_BASE_URL", "http://web:8080").rstrip("/")
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8080").rstrip("/")
BROWSERS = [b.strip() for b in os.getenv("SELENIUM_BROWSERS", "chrome,firefox").split(",") if b.strip()]


def pytest_collection_modifyitems(items):
    for item in items:
        if "tests/selenium" in item.nodeid.replace("\\", "/"):
            item.add_marker(pytest.mark.selenium)


def _unavailable(reason: str):
    if os.getenv("SELENIUM_REQUIRED") == "1":
        pytest.fail(reason)
    pytest.skip(reason)


@pytest.fixture(scope="session")
def grid():
    if not HAVE_SELENIUM:
        _unavailable("selenium is not installed: pip install -r requirements-dev.txt")
    try:
        with urllib.request.urlopen(REMOTE_URL + "/status", timeout=5) as r:
            status = json.loads(r.read())["value"]
    except Exception as exc:  # noqa: BLE001
        _unavailable(f"Selenium Grid is not reachable at {REMOTE_URL}: {exc}")
    if not status.get("ready"):
        _unavailable(f"Selenium Grid at {REMOTE_URL} is not ready")
    return status


@pytest.fixture(scope="session")
def guest_base_url():
    return GUEST_BASE_URL


@pytest.fixture(params=BROWSERS)
def driver(request, grid):
    if request.param == "chrome":
        options = webdriver.ChromeOptions()
        options.add_argument("--headless=new")
    elif request.param == "firefox":
        options = webdriver.FirefoxOptions()
        options.add_argument("-headless")
    else:
        pytest.fail(f"unsupported browser {request.param}")
    drv = webdriver.Remote(command_executor=REMOTE_URL, options=options)
    drv.set_window_size(412, 915)  # phone-sized viewport: the player is mobile-first
    drv.set_script_timeout(10)
    yield drv
    drv.quit()


class Api:
    """Direct backend calls from the test process (not through the browser)."""

    def request(self, method: str, path: str, body=None):
        url = urlparse(API_BASE_URL)
        conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=10)
        headers = {"Content-Type": "application/json"} if body is not None else {}
        conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        try:
            data = json.loads(raw) if raw else None
        except ValueError:
            data = raw.decode("utf-8", "replace")
        return resp.status, dict(resp.getheaders()), data

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, body):
        return self.request("POST", path, body)


@pytest.fixture(scope="session")
def api(grid):
    client = Api()
    try:
        status, _, body = client.get("/health")
    except OSError as exc:
        _unavailable(f"backend not reachable at {API_BASE_URL}: {exc}")
    if status != 200 or body != {"status": "ok"}:
        _unavailable(f"backend at {API_BASE_URL} is not healthy: {status} {body}")
    return client
