"""Zero-install Guest Web Player pages (Day 2 section 1.1 item 3, FR-4.1, FR-4.2, spec 6.2.2).

Every page is rendered from live backend state (event-sourced score, roster, store) and then kept current
by guest_player.js over the SSE streams. No page needs an account; nothing here mutates state except the
QR scan counter on ``/q/{short_code}``.

Uses from core: DB, LOCK, ApiError, is_id, live_snapshot, scan_short_code, _money, PHASE2_MATCH,
MEDIA_HLS_BASE_URL, MATCH_PLAYBACK_URL_TEMPLATE.
"""
import re
from pathlib import Path
from typing import Optional

import jinja2
from fastapi import APIRouter
from fastapi.responses import HTMLResponse, RedirectResponse

WEB_DIR = Path(__file__).resolve().parent.parent / "web"
TEMPLATES = jinja2.Environment(loader=jinja2.FileSystemLoader(str(WEB_DIR / "templates")),
                               autoescape=jinja2.select_autoescape(["html"]), trim_blocks=True, lstrip_blocks=True)
STATE_RE = re.compile(r"[a-z_]{1,24}")
NOTICE_COPY = {
    "postponed": "This match has been postponed. The new date will appear here once it is confirmed.",
    "cancelled": "This match has been cancelled.",
    "abandoned": "This match was abandoned before full time.",
    "upcoming": "This match has not started yet.",
    "in_progress": "This match is live right now.",
    "completed": "This match has finished.",
}


def build_router(core) -> APIRouter:
    router = APIRouter()

    def render(template: str, status: int = 200, **ctx) -> HTMLResponse:
        html = TEMPLATES.get_template(template).render(**ctx)
        return HTMLResponse(html, status_code=status, headers={"Cache-Control": "no-store"})

    def not_found(what: str, ident: str) -> HTMLResponse:
        return render("not_found.html", 404, page="not-found", title="Not found", what=what, ident=ident,
                      boot={"page": "not-found"})

    def offer(product_id: Optional[str], variant_id: Optional[str] = None) -> Optional[dict]:
        """A product card for the pinned variant, or the first variant in stock."""
        with core.LOCK:
            product = core.DB["products"].get(product_id)
            if not product or not product["variant_ids"]:
                return None
            ids = product["variant_ids"]
            vid = variant_id if variant_id in ids else next(
                (v for v in ids if core.DB["variants"][v]["stock"] > 0), ids[0])
            v = core.DB["variants"][vid]
            return {"product_id": product["product_id"], "name": product["name"],
                    "description": product["description"], "variant_id": vid, "label": v["label"],
                    "size": v["size"], "color": v["color"], "price_minor": v["price_minor"],
                    "price_text": core._money(v["price_minor"]), "currency": "PKR", "in_stock": v["stock"] > 0}

    def club_offer(club_id: Optional[str]) -> Optional[dict]:
        with core.LOCK:
            product_id = next((p["product_id"] for p in core.DB["products"].values() if p["club_id"] == club_id), None)
        return offer(product_id)

    def default_offer() -> Optional[dict]:
        m = core.PHASE2_MATCH
        return offer(m["pinned_product_id"], m["pinned_variant_id"])

    def match_context(match_id: str) -> Optional[dict]:
        if not core.is_id(match_id):
            return None
        try:
            snap = core.live_snapshot(match_id)
        except core.ApiError:
            return None
        with core.LOCK:
            league = core.DB["leagues"].get(snap["league_id"]) or {}
            sport = core.DB["sports"].get(snap["sport_id"]) or {}
            product_id = core.DB["pinned_products"].get(match_id)
            variant_id = core.DB["pinned_variants"].get(match_id)
        # Pinned product if the match has one, otherwise the home club's merchandise
        card = offer(product_id, variant_id) if product_id else club_offer(snap["home"]["team_id"])
        return {"match_id": match_id, "snapshot": snap, "league_name": league.get("name"),
                "sport_name": sport.get("name"), "offer": card, "chat_room_id": f"chat-{match_id}"}

    def match_page(match_id: str, page: str, template: str, **extra) -> HTMLResponse:
        ctx = match_context(match_id)
        if ctx is None:
            return not_found("match", match_id)
        snap = ctx["snapshot"]
        title = f"{snap['home']['name']} vs {snap['away']['name']}"
        boot = {"page": page, "match_id": match_id, "snapshot": snap, "chat_room_id": ctx["chat_room_id"],
                "offer": ctx["offer"], "page_route": f"/web/matches/{match_id}/{page.split('-')[-1]}",
                **{k: v for k, v in extra.items() if k in ("playback_url",)}}
        return render(template, page=page, title=title, boot=boot, **ctx, **extra)

    # ------------------------------------------------------------------ QR entry point
    @router.get("/q/{short_code}")
    def qr_redirect(short_code: str):
        """Stable printed short link -> 302 to the route for the entity's state at scan time."""
        return RedirectResponse(core.scan_short_code(short_code), status_code=302)

    # ------------------------------------------------------------------ pages
    @router.get("/web", response_class=HTMLResponse)
    @router.get("/web/", response_class=HTMLResponse)
    def index():
        with core.LOCK:
            match_ids = list(core.DB["matches"])
        fixtures = [core.live_snapshot(mid) for mid in match_ids]
        return render("web_index.html", page="index", title="Live and upcoming", fixtures=fixtures,
                      boot={"page": "index"})

    @router.get("/web/matches/{match_id}/live", response_class=HTMLResponse)
    def match_live(match_id: str):
        url = core.MATCH_PLAYBACK_URL_TEMPLATE.format(hls_base=core.MEDIA_HLS_BASE_URL, match_id=match_id)
        return match_page(match_id, "match-live", "match_live.html", playback_url=url)

    @router.get("/web/matches/{match_id}/preview", response_class=HTMLResponse)
    def match_preview(match_id: str):
        return match_page(match_id, "match-preview", "match_preview.html")

    @router.get("/web/matches/{match_id}/vod", response_class=HTMLResponse)
    def match_vod(match_id: str):
        # Recording to object storage (FR-3.2) is not built yet, so there is no replay URL to offer
        return match_page(match_id, "match-vod", "match_vod.html", playback_url=None)

    @router.get("/web/matches/{match_id}/notice", response_class=HTMLResponse)
    def match_notice(match_id: str, state: Optional[str] = None):
        ctx_state = state if isinstance(state, str) and STATE_RE.fullmatch(state) else None
        ctx = match_context(match_id)
        if ctx is None:
            return not_found("match", match_id)
        notice_state = ctx_state or ctx["snapshot"]["status"]
        return match_page(match_id, "match-notice", "match_notice.html", notice_state=notice_state,
                          notice_text=NOTICE_COPY.get(notice_state, "There is an update about this match."))

    @router.get("/web/players/{player_id}", response_class=HTMLResponse)
    def player_profile(player_id: str):
        if not core.is_id(player_id):
            return not_found("player", player_id)
        with core.LOCK:
            reg = core.DB["roster_players"].get(player_id)
            if reg is None:
                return not_found("player", player_id)
            squad = core.DB["squads"].get(reg["squad_id"] or reg["parent_squad_id"]) or {}
            club = core.DB["clubs"].get(squad.get("club_id")) or {}
            player = {"player_id": player_id, "name": reg["name"], "position": reg["position"], "role": reg["role"],
                      "squad_name": squad.get("name"), "club_id": club.get("club_id"), "club_name": club.get("name"),
                      "on_loan": reg["parent_squad_id"] is not None}
        fixtures = [core.live_snapshot(mid) for mid in core.club_match_ids(player["club_id"])]
        card = club_offer(player["club_id"])
        return render("player_profile.html", page="player", title=player["name"], player=player, fixtures=fixtures,
                      offer=card, merch_label="Club store", boot={"page": "player", "offer": card})

    @router.get("/web/clubs/{club_id}", response_class=HTMLResponse)
    def club_profile(club_id: str):
        if not core.is_id(club_id):
            return not_found("club", club_id)
        with core.LOCK:
            club = core.DB["clubs"].get(club_id)
            if club is None:
                return not_found("club", club_id)
            squads = {sid for sid, sq in core.DB["squads"].items() if sq["club_id"] == club_id}
            roster = [{"player_id": p["player_id"], "name": p["name"], "position": p["position"], "role": p["role"]}
                      for p in core.DB["roster_players"].values() if p["squad_id"] in squads]
            club = dict(club)
        fixtures = [core.live_snapshot(mid) for mid in core.club_match_ids(club_id)]
        card = club_offer(club_id)
        return render("club_profile.html", page="club", title=club["name"], club=club, roster=roster,
                      fixtures=fixtures, offer=card, merch_label="Club store", boot={"page": "club", "offer": card})

    @router.get("/web/costream/{session_id}", response_class=HTMLResponse)
    def costream(session_id: str, match: Optional[str] = None):
        if not core.is_id(session_id):
            return not_found("co-stream", session_id)
        with core.LOCK:
            session = dict(core.DB.get("costream_sessions", {}).get(session_id) or {})
        linked = match_context(match) if match else None
        playback = f"{core.MEDIA_HLS_BASE_URL}/costream/{session_id}/index.m3u8"
        # One unified room per co-stream, shared by every host and viewer (FR-3.3)
        room = f"chat-{session_id}"
        boot = {"page": "costream", "session_id": session_id, "chat_room_id": room, "playback_url": playback,
                "offer": default_offer(), "match_id": linked["match_id"] if linked else None,
                "snapshot": linked["snapshot"] if linked else None}
        return render("costream.html", page="costream", title=f"Co-stream {session_id}", session_id=session_id,
                      session=session, linked=linked, chat_room_id=room, playback_url=playback,
                      offer=default_offer(), boot=boot)

    return router
