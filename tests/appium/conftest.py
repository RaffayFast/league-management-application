"""Appium 2 fixtures for native deep-link tests (Day 2 spec 6.3).

Needs: Appium on APPIUM_URL (default http://localhost:4723) with the uiautomator2 driver, an Android device or
emulator visible to adb, and the LeagueHub APK installed (package com.nascon.leaguehub). Without them the tests
skip and say why; set APPIUM_REQUIRED=1 to fail instead.
"""
import json
import os
import urllib.request

import pytest

try:
    from appium import webdriver as appium_webdriver
    from appium.options.android import UiAutomator2Options
    HAVE_APPIUM_CLIENT = True
except ImportError:
    HAVE_APPIUM_CLIENT = False

APPIUM_URL = os.getenv("APPIUM_URL", "http://localhost:4723").rstrip("/")
APP_PACKAGE = os.getenv("APP_PACKAGE", "com.nascon.leaguehub")


def _unavailable(reason: str):
    if os.getenv("APPIUM_REQUIRED") == "1":
        pytest.fail(reason)
    pytest.skip(reason)


@pytest.fixture(scope="session")
def appium_ready():
    if not HAVE_APPIUM_CLIENT:
        _unavailable("Appium-Python-Client is not installed: pip install -r requirements-dev.txt")
    try:
        with urllib.request.urlopen(APPIUM_URL + "/status", timeout=5) as r:
            status = json.loads(r.read())["value"]
    except Exception as exc:  # noqa: BLE001
        _unavailable(f"Appium is not reachable at {APPIUM_URL}: {exc}")
    if not status.get("ready"):
        _unavailable(f"Appium at {APPIUM_URL} is not ready")
    return status


@pytest.fixture()
def android(appium_ready):
    options = UiAutomator2Options()
    options.platform_name = "Android"
    options.automation_name = "UiAutomator2"
    options.app_package = APP_PACKAGE
    options.app_activity = ".MainActivity"
    options.no_reset = True
    options.auto_grant_permissions = True
    try:
        drv = appium_webdriver.Remote(APPIUM_URL, options=options)
    except Exception as exc:  # noqa: BLE001 - no device, app not installed, driver missing
        _unavailable(f"could not start an Android session: {exc}")
    yield drv
    drv.quit()
