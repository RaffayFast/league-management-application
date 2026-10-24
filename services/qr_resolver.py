"""Dynamic QR target routes (Day 2 spec 5.6).

The printed short URL never changes; the route it resolves to follows the entity's live state at scan
time. This module is pure: callers pass the entity type, id and (for matches) the current status.
"""
from urllib.parse import quote

MATCH_STATE_PAGES = {"upcoming": "preview", "in_progress": "live", "completed": "vod"}
NOTICE_STATES = ("postponed", "cancelled", "abandoned")
ENTITY_PAGES = {"player": "players", "club": "clubs", "costream": "costream"}


def target_route(entity_type: str, entity_id: str, status: str = None) -> str:
    """Guest Web Player route for an entity. Matches without a playable state go to the notice page."""
    if entity_type == "match":
        page = MATCH_STATE_PAGES.get(status)
        if page:
            return f"/web/matches/{entity_id}/{page}"
        return f"/web/matches/{entity_id}/notice?state={quote(str(status or 'unknown'))}"
    if entity_type in ENTITY_PAGES:
        return f"/web/{ENTITY_PAGES[entity_type]}/{entity_id}"
    raise ValueError(f"unsupported QR entity type: {entity_type}")
