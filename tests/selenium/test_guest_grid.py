"""Guest Web Player browser tests on Selenium Grid 4 (Day 2 spec 6.2.3). Real browsers, real backend, no mocks.

Each test opens its own WebDriver session, so every test starts as a fresh guest with empty storage.
Test 3 posts score events, so it creates its own match: parallel browsers never see each other's goals.
"""
import uuid
from urllib.parse import urlparse

import pytest
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

LIVE_PATH = "/web/matches/match-m1/live"


def tid(testid: str):
    return By.CSS_SELECTOR, f'[data-testid="{testid}"]'


def open_live(driver, base, path=LIVE_PATH):
    driver.get(base + path)
    WebDriverWait(driver, 5).until(EC.visibility_of_element_located(tid("live-score-banner")))


def wait_count(driver, expected: str):
    WebDriverWait(driver, 3).until(EC.text_to_be_present_in_element(tid("guest-cart-count"), expected))
    assert driver.find_element(*tid("guest-cart-count")).text == expected


def test_1_qr_redirect_and_zero_friction_load(driver, api, guest_base_url):
    status, headers, _ = api.get("/q/m1-live")
    assert status == 302 and headers.get("location") == LIVE_PATH

    driver.get(guest_base_url + "/q/m1-live")
    wait = WebDriverWait(driver, 3)
    wait.until(EC.visibility_of_element_located(tid("guest-video-player")))
    wait.until(EC.visibility_of_element_located(tid("live-score-banner")))
    assert urlparse(driver.current_url).path == LIVE_PATH
    assert not driver.find_element(*tid("progressive-auth-modal")).is_displayed()
    for testid in ("pinned-merch-card", "add-to-guest-cart-btn", "guest-cart-count", "chat-message-list",
                   "chat-input-field", "chat-send-btn"):
        assert driver.find_elements(*tid(testid)), testid


def test_2_guest_write_block_opens_progressive_modal(driver, guest_base_url):
    open_live(driver, guest_base_url)
    before = len(driver.find_elements(By.CSS_SELECTOR, '[data-testid="chat-message-list"] li'))
    text = f"hello from a guest {uuid.uuid4().hex[:6]}"
    field = driver.find_element(*tid("chat-input-field"))
    field.send_keys(text)
    driver.find_element(*tid("chat-send-btn")).click()

    WebDriverWait(driver, 3).until(EC.visibility_of_element_located(tid("progressive-auth-modal")))
    items = driver.find_elements(By.CSS_SELECTOR, '[data-testid="chat-message-list"] li')
    assert len(items) == before
    assert all(text not in li.text for li in items)
    assert field.get_attribute("value") == text  # kept for an explicit retry after signing in


SCORE_LATENCY_JS = """
const evt = arguments[0], done = arguments[arguments.length - 1];
const banner = document.querySelector('[data-testid="live-score-banner"]');
const before = banner.textContent;
const t0 = performance.now();
const obs = new MutationObserver(() => {
  if (banner.textContent !== before) { obs.disconnect(); done({ms: performance.now() - t0, text: banner.textContent}); }
});
obs.observe(banner, {childList: true, subtree: true, characterData: true});
fetch('/audit/v1/events', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(evt)})
  .then(r => { if (r.status !== 201) { obs.disconnect(); done({error: r.status}); } })
  .catch(e => { obs.disconnect(); done({error: String(e)}); });
setTimeout(() => { obs.disconnect(); done({timeout: true, text: banner.textContent}); }, 3000);
"""


def test_3_guest_cart_staging_and_realtime_score(driver, api, guest_base_url):
    match_id = f"sel-{uuid.uuid4().hex[:10]}"
    status, _, body = api.post("/audit/v1/events", {
        "event_id": f"{match_id}-init", "match_id": match_id, "type": "match_init",
        "payload": {"sport_id": "football", "home_team_id": "club-alpha-1", "away_team_id": "club-alpha-2"}})
    assert status == 201, body
    assert api.post("/audit/v1/events", {"event_id": f"{match_id}-start", "match_id": match_id,
                                         "type": "match_start", "payload": {}})[0] == 201

    open_live(driver, guest_base_url, f"/web/matches/{match_id}/live")
    assert driver.find_element(*tid("live-score-banner")).text == "0 - 0"
    wait_count(driver, "0")
    driver.find_element(*tid("add-to-guest-cart-btn")).click()
    wait_count(driver, "1")

    WebDriverWait(driver, 5).until(EC.text_to_be_present_in_element((By.ID, "connection-status"), "Live updates on"))
    result = driver.execute_async_script(SCORE_LATENCY_JS, {
        "event_id": f"{match_id}-goal", "match_id": match_id, "type": "score",
        "payload": {"team_id": "club-alpha-1", "event_type": "goal"}})
    assert result.get("text") == "1 - 0", result
    assert result["ms"] < 500, f"banner updated after {result['ms']:.0f} ms"
    assert urlparse(driver.current_url).path == f"/web/matches/{match_id}/live"  # no reload
    wait_count(driver, "1")


def test_4_cart_survives_reload_and_progressive_auth(driver, guest_base_url):
    open_live(driver, guest_base_url)
    driver.find_element(*tid("add-to-guest-cart-btn")).click()
    wait_count(driver, "1")
    driver.refresh()
    WebDriverWait(driver, 5).until(EC.visibility_of_element_located(tid("live-score-banner")))
    wait_count(driver, "1")  # a reload does not erase the staged cart

    driver.find_element(By.ID, "checkout-btn").click()
    modal = WebDriverWait(driver, 3).until(EC.visibility_of_element_located(tid("progressive-auth-modal")))
    assert modal.find_element(By.CSS_SELECTOR, "[data-cart-mirror]").text == "1"
    driver.find_element(*tid("auth-login-email")).send_keys("player@nascon.test")
    driver.find_element(*tid("auth-login-password")).send_keys("Nascon@26")
    driver.find_element(*tid("auth-login-submit")).click()

    WebDriverWait(driver, 5).until(EC.invisibility_of_element_located(tid("progressive-auth-modal")))
    WebDriverWait(driver, 3).until(EC.text_to_be_present_in_element((By.ID, "member-chip"), "Signed in"))
    assert urlparse(driver.current_url).path == LIVE_PATH
    wait_count(driver, "1")
    cart = driver.execute_script("return JSON.parse(localStorage.getItem('leaguehub.guestCart.v1'))")
    assert cart["items"] == [{"variant_id": "var-jersey-001-L", "quantity": 1}]
    assert cart["guest_token"].startswith("guest_anon_tok_")  # still available for the member merge
