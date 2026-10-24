/* LeagueHub Guest Web Player.
   - Guests get a read-only token from POST /api/v1/guest/session; every write the server refuses (403
     GUEST_WRITE_FORBIDDEN) is answered here by opening the sign-in dialog, never by faking success.
   - The guest cart lives on this device (localStorage) until a member merges it; it never reserves stock.
   - Score and chat come from the SSE streams; EventSource reconnects by itself after network drops. */
(function () {
  "use strict";

  var KEYS = { guest: "leaguehub.guest.v1", cart: "leaguehub.guestCart.v1",
               member: "leaguehub.member.v1", playback: "leaguehub.playback.v1" };
  var STATUS_LABELS = { upcoming: "Upcoming", in_progress: "Live", completed: "Full time" };
  var STATE_TEXT = { upcoming: "This match has not started yet.", in_progress: "This match is live now.",
                     completed: "This match has finished." };
  var REASONS = {
    chat: "Sign in to send chat messages. Guests can read the chat but not post.",
    checkout: "Sign in to check out. Your cart moves into your account when you continue.",
    account: "Sign in to continue."
  };
  var HLS_JS_URL = "https://cdn.jsdelivr.net/npm/hls.js@1.5.15/dist/hls.min.js";

  var boot = readBoot();
  var state = { guestToken: null, member: null, pendingAction: null, lastFocus: null, seenChat: {} };

  // ------------------------------------------------------------------ helpers
  function $(sel, root) { return (root || document).querySelector(sel); }
  function byTestId(id) { return $('[data-testid="' + id + '"]'); }
  function store(kind) { try { return kind === "session" ? window.sessionStorage : window.localStorage; } catch (e) { return null; } }
  function load(kind, key) {
    var s = store(kind); if (!s) return null;
    try { var raw = s.getItem(key); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
  }
  function save(kind, key, value) {
    var s = store(kind); if (!s) return;
    try { if (value === null) s.removeItem(key); else s.setItem(key, JSON.stringify(value)); } catch (e) { /* storage full or blocked */ }
  }
  function readBoot() {
    try { return JSON.parse(document.getElementById("guest-boot").textContent) || {}; } catch (e) { return {}; }
  }
  function errorCode(res) { return res && res.data && res.data.error ? res.data.error.code : null; }

  function api(method, path, body, token) {
    var headers = { "Accept": "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (token) headers["Authorization"] = "Bearer " + token;
    return fetch(path, { method: method, headers: headers, body: body === undefined ? undefined : JSON.stringify(body) })
      .then(function (res) {
        return res.text().then(function (text) {
          var data = null;
          try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
          return { ok: res.ok, status: res.status, data: data };
        });
      })
      .catch(function () { return { ok: false, status: 0, data: null }; });
  }

  function toast(message, isError) {
    var region = document.getElementById("toast-region"); if (!region) return;
    var el = document.createElement("div");
    el.className = "toast" + (isError ? " is-error" : "");
    el.textContent = message;
    region.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 5000);
  }

  function friendlyError(res) {
    var code = errorCode(res);
    if (res.status === 0) return "Can't reach the server. Check your connection and try again.";
    if (code === "OUT_OF_STOCK") return "Sorry, that item just sold out.";
    if (code === "GUEST_TOKEN_ALREADY_MERGED") return "This cart was already saved to an account.";
    if (code === "RATE_LIMITED") return "Too many requests. Please wait a moment.";
    if (code === "NOT_IMPLEMENTED") return "That isn't switched on yet.";
    return "Something went wrong. Please try again.";
  }

  function setConnection(text, tone) {
    var chip = document.getElementById("connection-status"); if (!chip) return;
    chip.hidden = false;
    chip.textContent = text;
    chip.className = "chip" + (tone ? " is-" + tone : "");
  }

  // ------------------------------------------------------------------ guest token
  function ensureGuestToken() {
    var saved = load("local", KEYS.guest);
    if (saved && saved.guest_token && (!saved.expires_at || Date.parse(saved.expires_at) - Date.now() > 60000)) {
      state.guestToken = saved.guest_token;
      return Promise.resolve(state.guestToken);
    }
    return api("POST", "/api/v1/guest/session", {}).then(function (res) {
      if (res.ok && res.data && res.data.guest_token) {
        save("local", KEYS.guest, res.data);
        state.guestToken = res.data.guest_token;
      }
      return state.guestToken;
    });
  }

  // ------------------------------------------------------------------ member session
  function loadMember() { state.member = load("session", KEYS.member); renderMember(); }
  function setMember(data) {
    state.member = { token: data.token, user: data.user };
    save("session", KEYS.member, state.member);
    renderMember();
  }
  function clearMember() { state.member = null; save("session", KEYS.member, null); renderMember(); }
  function renderMember() {
    var chip = document.getElementById("member-chip"), out = document.getElementById("signout-btn");
    if (!chip || !out) return;
    chip.hidden = out.hidden = !state.member;
    if (state.member) chip.textContent = "Signed in as " + (state.member.user && state.member.user.name || "member");
  }

  // ------------------------------------------------------------------ guest cart (device only)
  function readCart() {
    var cart = load("local", KEYS.cart);
    return cart && Array.isArray(cart.items) ? cart : { guest_token: null, items: [] };
  }
  function cartCount(cart) { return cart.items.reduce(function (n, i) { return n + (i.quantity || 0); }, 0); }
  function renderCart(bump) {
    var count = String(cartCount(readCart()));
    var el = byTestId("guest-cart-count");
    if (el) {
      el.textContent = count;
      if (bump) { el.classList.remove("bump"); void el.offsetWidth; el.classList.add("bump"); }
    }
    Array.prototype.forEach.call(document.querySelectorAll("[data-cart-mirror]"), function (m) { m.textContent = count; });
  }
  function addToCart(variantId) {
    var cart = readCart();
    var line = cart.items.filter(function (i) { return i.variant_id === variantId; })[0];
    if (line) {
      if (line.quantity >= 10) { toast("You can add up to 10 of one item.", true); return; }
      line.quantity += 1;
    } else {
      if (cart.items.length >= 10) { toast("Your cart is full.", true); return; }
      cart.items.push({ variant_id: variantId, quantity: 1 });
    }
    cart.guest_token = cart.guest_token || state.guestToken;
    save("local", KEYS.cart, cart);
    renderCart(true);
    toast("Added to your cart. It stays on this device until you check out.");
  }

  // ------------------------------------------------------------------ live score
  function applySnapshot(snap) {
    if (!snap || !snap.home || !snap.away) return;
    var home = $("[data-score-home]"), away = $("[data-score-away]");
    if (home) home.textContent = String(snap.home.score);
    if (away) away.textContent = String(snap.away.score);
    var th = $("[data-team-home]"), ta = $("[data-team-away]");
    if (th && snap.home.name) th.textContent = snap.home.name;
    if (ta && snap.away.name) ta.textContent = snap.away.name;
    var pill = $("[data-match-status]");
    if (pill) {
      pill.textContent = STATUS_LABELS[snap.status] || snap.status;
      pill.className = "status-pill status-" + snap.status;
    }
    var notice = $("[data-state-notice]");
    if (notice && boot.page_route) {
      var moved = snap.web_route && snap.web_route !== boot.page_route && boot.page !== "match-notice";
      notice.hidden = !moved;
      if (moved) {
        $("[data-state-text]", notice).textContent = STATE_TEXT[snap.status] || "This match has an update.";
        var link = $("[data-state-link]", notice);
        link.href = snap.web_route;
        link.textContent = snap.status === "completed" ? "Watch the replay" : snap.status === "in_progress" ? "Watch live" : "Open the match page";
      }
    }
  }

  function connectScore() {
    if (!boot.match_id || !window.EventSource) return;
    var es = new EventSource("/api/v1/matches/" + encodeURIComponent(boot.match_id) + "/stream");
    es.addEventListener("score", function (e) { try { applySnapshot(JSON.parse(e.data)); } catch (err) { /* ignore bad frame */ } });
    es.onopen = function () { setConnection("Live updates on", "ok"); };
    es.onerror = function () { setConnection("Reconnecting…", "warn"); };
  }

  // ------------------------------------------------------------------ chat
  function chatList() { return byTestId("chat-message-list"); }
  function renderMessage(msg) {
    var list = chatList(); if (!list) return;
    var key = msg.chat_room_id + ":" + msg.sequence;
    if (msg.sequence && state.seenChat[key]) return;
    state.seenChat[key] = true;
    var li = document.createElement("li");
    var who = document.createElement("span"); who.className = "chat-sender"; who.textContent = msg.sender || "fan";
    var text = document.createElement("span"); text.textContent = msg.text;  // already masked by moderation
    li.appendChild(who); li.appendChild(text);
    if (msg.flagged) { var f = document.createElement("span"); f.className = "chat-flag"; f.textContent = "Filtered"; li.appendChild(f); }
    list.appendChild(li);
    list.scrollTop = list.scrollHeight;
    var empty = $("[data-chat-empty]"); if (empty) empty.hidden = true;
  }
  function resetChat(messages) {
    var list = chatList(); if (!list) return;
    while (list.firstChild) list.removeChild(list.firstChild);
    state.seenChat = {};
    (messages || []).forEach(renderMessage);
    var empty = $("[data-chat-empty]"); if (empty) empty.hidden = (messages || []).length > 0;
  }
  function connectChat() {
    if (!boot.chat_room_id || !chatList() || !window.EventSource) return;
    var es = new EventSource("/api/v1/chat/" + encodeURIComponent(boot.chat_room_id) + "/stream");
    es.addEventListener("history", function (e) { try { resetChat(JSON.parse(e.data).messages); } catch (err) { /* ignore */ } });
    es.addEventListener("chat", function (e) { try { renderMessage(JSON.parse(e.data)); } catch (err) { /* ignore */ } });
    es.addEventListener("reset", function () { resetChat([]); });
  }
  function sendChat(event) {
    event.preventDefault();
    var input = byTestId("chat-input-field"); if (!input) return;
    var text = input.value.trim();
    if (!text) { input.focus(); return; }
    var button = byTestId("chat-send-btn"); button.disabled = true;
    // Members post with their JWT; guests try with the guest token so the server enforces the boundary
    var token = state.member ? state.member.token : state.guestToken;
    api("POST", "/api/v1/chat", { chat_room_id: boot.chat_room_id, text: text }, token).then(function (res) {
      button.disabled = false;
      if (res.ok) { input.value = ""; if (res.status === 201 && res.data) renderMessage(res.data); return; }
      var code = errorCode(res);
      if (code === "GUEST_WRITE_FORBIDDEN" || res.status === 401) {
        if (state.member && res.status === 401) clearMember();
        openAuth("chat");  // the message stays in the box and is NOT added to the public list
        return;
      }
      toast(code === "NOT_IMPLEMENTED" ? "Posting opens once chat moderation is switched on." : friendlyError(res), true);
    });
  }

  // ------------------------------------------------------------------ checkout and merge
  function checkout() {
    var cart = readCart();
    if (!cartCount(cart)) { toast("Your cart is empty."); return; }
    if (!state.member) { openAuth("checkout"); return; }
    var btn = document.getElementById("checkout-btn"); btn.disabled = true;
    api("POST", "/api/v1/guest/cart/merge",
        { guest_token: cart.guest_token || state.guestToken, guest_cart: cart.items }, state.member.token)
      .then(function (res) {
        btn.disabled = false;
        if (res.ok && res.data) {
          save("local", KEYS.cart, null);
          renderCart(true);
          toast("Saved to your account cart: " + res.data.active_cart.total_items + " item(s).");
          return;
        }
        if (res.status === 401) { clearMember(); openAuth("checkout"); return; }
        if (errorCode(res) === "NOT_IMPLEMENTED") {
          toast("Moving carts into accounts isn't switched on yet. Your items stay on this device.", true);
          return;
        }
        toast(friendlyError(res), true);
      });
  }

  // ------------------------------------------------------------------ progressive auth dialog
  function modal() { return byTestId("progressive-auth-modal"); }
  function focusables(root) {
    return Array.prototype.filter.call(
      root.querySelectorAll("button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])"),
      function (el) { return !el.disabled && el.offsetParent !== null; });
  }
  function openAuth(reason) {
    var m = modal(); if (!m) return;
    state.pendingAction = reason;
    state.lastFocus = document.activeElement;
    $("#auth-reason").textContent = REASONS[reason] || REASONS.account;
    renderCart(false);
    m.hidden = false;
    $("[data-modal-backdrop]").hidden = false;
    document.body.classList.add("modal-open");
    switchTab("login");
    var first = $("#login-email"); if (first) first.focus();
  }
  function closeAuth() {
    var m = modal(); if (!m || m.hidden) return;
    m.hidden = true;
    $("[data-modal-backdrop]").hidden = true;
    document.body.classList.remove("modal-open");
    if (state.lastFocus && state.lastFocus.focus) state.lastFocus.focus();
  }
  function switchTab(which) {
    ["login", "register"].forEach(function (name) {
      var tab = $("#tab-" + name), panel = $("#panel-" + name), on = name === which;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
      panel.hidden = !on;
    });
  }
  function showFormError(form, message) {
    var el = $("[data-form-error]", form);
    el.hidden = !message;
    el.textContent = message || "";
  }
  function afterSignIn() {
    closeAuth();
    var action = state.pendingAction;
    state.pendingAction = null;
    // The refused action is not replayed automatically; the user chooses to retry it
    if (action === "chat") {
      toast("Signed in. Press Send to post your message.");
      var input = byTestId("chat-input-field"); if (input) input.focus();
    } else if (action === "checkout") {
      toast("Signed in. Press Proceed to checkout to save your cart.");
      var btn = document.getElementById("checkout-btn"); if (btn) btn.focus();
    } else {
      toast("Signed in.");
    }
  }
  function submitAuth(form, path, body, messages) {
    var submit = $("button[type=submit]", form);
    submit.disabled = true;
    showFormError(form, "");
    // No Authorization header here: signing in must not carry the guest token
    api("POST", path, body).then(function (res) {
      submit.disabled = false;
      if (res.ok && res.data && res.data.token) { setMember(res.data); form.reset(); afterSignIn(); return; }
      showFormError(form, messages[errorCode(res)] || messages[res.status] || friendlyError(res));
    });
  }
  function onLogin(e) {
    e.preventDefault();
    var form = e.currentTarget, email = form.email.value.trim(), password = form.password.value;
    if (!email || !password) { showFormError(form, "Enter your email and password."); return; }
    submitAuth(form, "/api/v1/auth/login", { email: email, password: password },
               { 401: "That email and password don't match.", 400: "Enter a valid email and password." });
  }
  function onRegister(e) {
    e.preventDefault();
    var form = e.currentTarget, name = form.name.value.trim(), email = form.email.value.trim(), password = form.password.value;
    if (!name) { showFormError(form, "Enter your name."); return; }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { showFormError(form, "Enter a valid email address."); return; }
    if (password.length < 8) { showFormError(form, "Use at least 8 characters for your password."); return; }
    submitAuth(form, "/api/v1/auth/register", { name: name, email: email, password: password },
               { USER_EXISTS: "An account with this email already exists. Log in instead.",
                 400: "Check the highlighted details and try again." });
  }
  function onModalKey(e) {
    var m = modal(); if (!m || m.hidden) return;
    if (e.key === "Escape") { e.preventDefault(); closeAuth(); return; }
    if (e.key !== "Tab") return;
    var items = focusables(m); if (!items.length) return;
    var first = items[0], last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  // ------------------------------------------------------------------ video
  function playerState(title, detail, canRetry) {
    var box = $("[data-player-state]"); if (!box) return;
    box.classList.remove("is-playing");
    $("[data-player-title]", box).textContent = title;
    $("[data-player-detail]", box).textContent = detail || "";
    $("[data-player-retry]", box).hidden = !canRetry;
  }
  function loadHlsJs() {
    return new Promise(function (resolve, reject) {
      if (window.Hls) { resolve(window.Hls); return; }
      var s = document.createElement("script");
      var timer = setTimeout(function () { reject(new Error("timeout")); }, 5000);
      s.src = HLS_JS_URL; s.async = true;
      s.onload = function () { clearTimeout(timer); window.Hls ? resolve(window.Hls) : reject(new Error("missing")); };
      s.onerror = function () { clearTimeout(timer); reject(new Error("blocked")); };
      document.head.appendChild(s);
    });
  }
  function initPlayer() {
    var video = byTestId("guest-video-player"); if (!video) return;
    var url = video.getAttribute("data-src");
    if (!url) { playerState("Replay not available yet", "Recordings appear here once the broadcast has been archived.", false); return; }
    var positions = load("session", KEYS.playback) || {};
    var resumeAt = Number(new URLSearchParams(location.search).get("t")) || positions[location.pathname] || 0;
    var started = false, watchdog = null;

    function offline(detail) {
      if (started) return;
      clearTimeout(watchdog);
      playerState("Stream offline", detail || "The broadcast hasn't started, or the media server can't be reached.", true);
    }
    function attach() {
      started = false;
      playerState("Connecting to the stream…", "", false);
      clearTimeout(watchdog);
      watchdog = setTimeout(function () { offline(); }, 10000);
      if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = url;
        video.play().catch(function () { /* autoplay may be blocked; controls remain */ });
        return;
      }
      loadHlsJs().then(function (Hls) {
        if (!Hls.isSupported()) { offline("This browser can't play the live stream format."); return; }
        var hls = new Hls();
        hls.on(Hls.Events.ERROR, function (_e, data) { if (data && data.fatal) { hls.destroy(); offline(); } });
        hls.loadSource(url);
        hls.attachMedia(video);
        video.play().catch(function () { /* autoplay may be blocked */ });
      }).catch(function () { offline("The video player library couldn't load on this network."); });
    }
    video.addEventListener("playing", function () {
      started = true; clearTimeout(watchdog);
      $("[data-player-state]").classList.add("is-playing");
      var badge = $("[data-live-badge]"); if (badge && boot.page !== "match-vod") badge.hidden = false;
    });
    video.addEventListener("loadedmetadata", function () { if (resumeAt && isFinite(video.duration)) video.currentTime = resumeAt; });
    video.addEventListener("error", function () { offline(); });
    window.addEventListener("pagehide", function () {
      if (video.currentTime > 0) { positions[location.pathname] = Math.floor(video.currentTime); save("session", KEYS.playback, positions); }
    });
    var retry = $("[data-player-retry]"); if (retry) retry.addEventListener("click", attach);
    attach();
  }

  function localiseTimes() {
    Array.prototype.forEach.call(document.querySelectorAll("time[data-local-time]"), function (t) {
      var d = new Date(t.getAttribute("datetime"));
      if (!isNaN(d)) t.textContent = d.toLocaleString(undefined, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
    });
  }

  // ------------------------------------------------------------------ wiring
  function on(el, type, fn) { if (el) el.addEventListener(type, fn); }
  function init() {
    renderCart(false);
    loadMember();
    localiseTimes();
    on(byTestId("add-to-guest-cart-btn"), "click", function (e) { addToCart(e.currentTarget.getAttribute("data-variant-id")); });
    on(document.getElementById("checkout-btn"), "click", checkout);
    on(document.getElementById("chat-form"), "submit", sendChat);
    on(document.getElementById("signout-btn"), "click", function () { clearMember(); toast("Signed out. You can keep watching as a guest."); });
    on($("[data-modal-close]"), "click", closeAuth);
    on($("[data-modal-backdrop]"), "click", closeAuth);
    on($("#tab-login"), "click", function () { switchTab("login"); });
    on($("#tab-register"), "click", function () { switchTab("register"); });
    on($("#panel-login"), "submit", onLogin);
    on($("#panel-register"), "submit", onRegister);
    document.addEventListener("keydown", onModalKey);
    window.addEventListener("storage", function (e) { if (e.key === KEYS.cart) renderCart(false); });
    ensureGuestToken();
    connectScore();
    connectChat();
    initPlayer();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
