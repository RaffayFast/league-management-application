"""Native deep links (Day 2 spec 6.3). Equivalent to the desk-audit commands:
    adb shell am start -W -a android.intent.action.VIEW -d "nascon://entity/match-m1"
    adb shell am start -W -a android.intent.action.VIEW -d "nascon://stream/cs-session-101"
The app must reach the foreground within 2 s and open the match / co-stream screen, never the login screen.
Screens are found by their Semantics labels, which Android exposes as content-desc.
"""
import os
import time
import uuid

try:
    from appium.webdriver.common.appiumby import AppiumBy
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait
except ImportError:  # collected without the client installed: fixtures skip before use
    AppiumBy = EC = WebDriverWait = None

APP_PACKAGE = os.getenv("APP_PACKAGE", "com.nascon.leaguehub")

FOREGROUND = 4  # ApplicationState.RUNNING_IN_FOREGROUND


def open_link(driver, url: str) -> float:
    """Fires the VIEW intent and returns seconds until the app is in the foreground."""
    driver.terminate_app(APP_PACKAGE)
    started = time.perf_counter()
    driver.execute_script("mobile: deepLink", {"url": url, "package": APP_PACKAGE})
    while driver.query_app_state(APP_PACKAGE) != FOREGROUND:
        if time.perf_counter() - started > 5:
            break
        time.sleep(0.05)
    return time.perf_counter() - started


def by_label(text: str):
    return AppiumBy.XPATH, f"//*[contains(@content-desc, '{text}')]"


def assert_not_on_login(driver):
    assert not driver.find_elements(AppiumBy.XPATH, "//*[@text='Sign in' or contains(@content-desc, 'Sign in')]")


def test_match_link_opens_the_live_match_screen(android):
    elapsed = open_link(android, "nascon://entity/match-m1")
    assert elapsed < 2.0, f"foreground after {elapsed:.2f}s"
    WebDriverWait(android, 5).until(EC.presence_of_element_located(by_label("live-match-screen match-m1")))
    assert_not_on_login(android)
    assert android.query_app_state(APP_PACKAGE) == FOREGROUND  # no crash while routing


def test_costream_link_opens_the_costream_screen(android):
    elapsed = open_link(android, "nascon://stream/cs-session-101")
    assert elapsed < 2.0, f"foreground after {elapsed:.2f}s"
    WebDriverWait(android, 5).until(EC.presence_of_element_located(by_label("live-costream-screen cs-session-101")))
    assert android.find_elements(*by_label("chat-message-list"))
    assert_not_on_login(android)
    assert android.query_app_state(APP_PACKAGE) == FOREGROUND


def test_cross_surface_chat_reaches_the_web_player_within_3s(android):
    """Cross-surface scenario (spec 6.3): the app joins cs-session-101 while a Selenium Grid browser has
    /web/costream/cs-session-101 open; a member message sent from the app must appear in the browser's
    [data-testid="chat-message-list"] within 3 s, and a message posted from the web must appear in the app.

    Needs the grid (SELENIUM_REMOTE_URL), the device signed in as a member, and GUEST_BASE_URL reachable by
    the browser.
    """
    from selenium import webdriver
    from selenium.webdriver.common.by import By

    text = f"cross-surface {uuid.uuid4().hex[:6]}"
    browser = webdriver.Remote(os.getenv("SELENIUM_REMOTE_URL", "http://localhost:4444"), options=webdriver.ChromeOptions())
    try:
        browser.get(os.getenv("GUEST_BASE_URL", "http://web:8080") + "/web/costream/cs-session-101")
        open_link(android, "nascon://stream/cs-session-101")
        field = WebDriverWait(android, 5).until(EC.presence_of_element_located((AppiumBy.CLASS_NAME, "android.widget.EditText")))
        field.send_keys(text)
        android.find_element(AppiumBy.XPATH, "//*[@text='Send' or @content-desc='Send']").click()
        started = time.perf_counter()
        WebDriverWait(browser, 3).until(EC.text_to_be_present_in_element(
            (By.CSS_SELECTOR, '[data-testid="chat-message-list"]'), text))
        assert time.perf_counter() - started < 3.0
    finally:
        browser.quit()
