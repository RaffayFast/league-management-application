"""POST /audit/v1/guest/cart-merge (Day 2 spec 5.7, api_contract.md Part C5).

"""
import threading

import pytest

import main
from models.guest_cart import CartMergeRequest, MergeSigPayload

URL = "/audit/v1/guest/cart-merge"
BASE = {"guest_token": "guest_anon_tok_7721", "registered_user_id": "player-alpha-1",
        "guest_cart": [{"variant_id": "var-jersey-001-L", "quantity": 1}], "test_write_block": True}


def _merge(client, **overrides):
    return client.post(URL, json={**BASE, **overrides})


def _sig(token, user, total, merged=True, code=403):
    return main.sign(main.DAY2_SALT, token, {"cart_merged": merged, "guest_token": token, "registered_user_id": user,
                                             "total_items": total, "write_rejection_code": code})


# ---------------------------------------------------------------- schema and routing
@pytest.mark.parametrize("body,field", [
    ({}, "guest_token"),
    ({**BASE, "guest_token": "anon_7721"}, "guest_token"),
    ({**BASE, "guest_token": ""}, "guest_token"),
    ({**BASE, "registered_user_id": 7}, "registered_user_id"),
    ({**BASE, "guest_cart": []}, "guest_cart"),
    ({**BASE, "guest_cart": [{"variant_id": "var-jersey-001-L", "quantity": 1}] * 11}, "guest_cart"),
    ({**BASE, "guest_cart": [{"variant_id": "var-jersey-001-L", "quantity": 0}]}, "guest_cart.0.quantity"),
    ({**BASE, "guest_cart": [{"variant_id": "var-jersey-001-L", "quantity": "1"}]}, "guest_cart.0.quantity"),
    ({**BASE, "guest_cart": [{"quantity": 1}]}, "guest_cart.0.variant_id"),
    ({**BASE, "test_write_block": "yes"}, "test_write_block"),
])
def test_schema_violations_are_400_with_field_names(client, body, field):
    r = client.post(URL, json=body)
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and field in err["details"]["fields"]


def test_non_object_body_is_400(client):
    r = client.post(URL, json=["not", "an", "object"])
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_signature_payload_has_exactly_the_contract_keys():
    assert set(MergeSigPayload.model_fields) == {"cart_merged", "guest_token", "registered_user_id", "total_items",
                                                 "write_rejection_code"}
    with pytest.raises(Exception):
        MergeSigPayload(cart_merged=True, guest_token="g", registered_user_id="u", total_items=1,
                        write_rejection_code=403, extra_key=1)


def test_merge_is_implemented_and_never_501(client):
    r = _merge(client)
    assert r.status_code == 200 and r.json()["cart_merged"] is True


def test_member_merge_route_requires_a_member_and_blocks_guests(client):
    body = {"guest_token": "guest_anon_tok_7721", "guest_cart": BASE["guest_cart"]}
    assert client.post("/api/v1/guest/cart/merge", json=body).json()["error"]["code"] == "UNAUTHENTICATED"
    guest = client.post("/api/v1/guest/cart/merge", json=body, headers={"Authorization": "Bearer guest_anon_tok_7721"})
    assert guest.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"


def test_member_cart_starts_empty(client):
    token = client.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"}).json()["token"]
    cart = client.get("/api/v1/cart", headers={"Authorization": f"Bearer {token}"}).json()
    assert cart == {"user_id": "player-alpha-1", "currency": "PKR", "total_items": 0, "subtotal_minor": 0, "items": []}


# ---------------------------------------------------------------- contract behaviour
def test_merge_matches_the_contract_example(client):
    r = _merge(client)
    assert r.status_code == 200
    assert r.json() == {
        "guest_token": "guest_anon_tok_7721", "write_block_verified": True, "write_rejection_code": 403,
        "cart_merged": True,
        "active_cart": {"user_id": "player-alpha-1", "currency": "PKR", "total_items": 1, "subtotal_minor": 450000,
                        "items": [{"variant_id": "var-jersey-001-L", "quantity": 1, "unit_price_minor": 450000}]},
        "signature": _sig("guest_anon_tok_7721", "player-alpha-1", 1),
    }
    # merging checks stock but never reserves or deducts it
    assert client.get("/audit/v1/inventory/var-jersey-001-L").json() == \
        {"variant_id": "var-jersey-001-L", "stock": 5, "reserved": 0}


def test_network_retry_returns_the_same_cart_without_double_adding(client):
    first = _merge(client).json()
    again = _merge(client)
    assert again.status_code == 200 and again.json() == first
    assert again.json()["active_cart"]["total_items"] == 1
    assert main.DB["carts"]["player-alpha-1"]["items"] == [{"variant_id": "var-jersey-001-L", "quantity": 1}]


def test_reused_token_with_another_user_or_cart_is_409(client):
    assert _merge(client).status_code == 200
    other_user = _merge(client, registered_user_id="player-alpha-2")
    assert (other_user.status_code, other_user.json()["error"]["code"]) == (409, "GUEST_TOKEN_ALREADY_MERGED")
    other_cart = _merge(client, guest_cart=[{"variant_id": "var-jersey-001-L", "quantity": 2}])
    assert (other_cart.status_code, other_cart.json()["error"]["code"]) == (409, "GUEST_TOKEN_ALREADY_MERGED")


def test_quantities_add_to_the_existing_member_cart(client):
    main.DB["carts"]["player-alpha-1"]["items"].append({"variant_id": "var-jersey-001-L", "quantity": 2})
    body = _merge(client, guest_cart=[{"variant_id": "var-jersey-001-L", "quantity": 1},
                                      {"variant_id": "var-jersey-001-M", "quantity": 1}]).json()
    assert body["active_cart"]["items"] == [{"variant_id": "var-jersey-001-L", "quantity": 3, "unit_price_minor": 450000},
                                            {"variant_id": "var-jersey-001-M", "quantity": 1, "unit_price_minor": 450000}]
    assert (body["active_cart"]["total_items"], body["active_cart"]["subtotal_minor"]) == (4, 1800000)
    assert body["signature"] == _sig("guest_anon_tok_7721", "player-alpha-1", 4)


def test_merged_quantity_above_stock_is_409_and_changes_nothing(client):
    main.DB["carts"]["player-alpha-1"]["items"].append({"variant_id": "var-jersey-001-L", "quantity": 4})
    r = _merge(client, guest_cart=[{"variant_id": "var-jersey-001-L", "quantity": 2}])  # 4 + 2 > 5 in stock
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "OUT_OF_STOCK" and r.json()["error"]["details"]["variant_id"] == "var-jersey-001-L"
    assert main.DB["carts"]["player-alpha-1"]["items"] == [{"variant_id": "var-jersey-001-L", "quantity": 4}]
    assert main.DB["guest_tokens"]["guest_anon_tok_7721"]["merged"] is False


def test_unknown_member_and_variant_are_404_before_stock(client):
    r = _merge(client, registered_user_id="player-nobody", guest_cart=[{"variant_id": "var-jersey-001-M", "quantity": 9}])
    assert (r.status_code, r.json()["error"]["code"]) == (404, "PLAYER_NOT_FOUND")
    r = _merge(client, guest_cart=[{"variant_id": "var-missing", "quantity": 1}])
    assert (r.status_code, r.json()["error"]["code"]) == (404, "VARIANT_NOT_FOUND")
    assert r.json()["error"]["details"]["variant_id"] == "var-missing"


def test_concurrent_duplicate_requests_merge_once(client):
    results = []

    def attempt():
        try:
            results.append(main.GUEST_CARTS.merge(CartMergeRequest.model_validate(BASE))[1])
        except Exception as exc:  # noqa: BLE001 - surfaced through the assertion below
            results.append(exc)

    threads = [threading.Thread(target=attempt) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results == [200] * 10
    assert main.DB["carts"]["player-alpha-1"]["items"] == [{"variant_id": "var-jersey-001-L", "quantity": 1}]


def test_member_flow_merges_into_the_signed_in_account(client):
    token = client.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"}).json()["token"]
    r = client.post("/api/v1/guest/cart/merge", headers={"Authorization": f"Bearer {token}"},
                    json={"guest_token": "guest_anon_tok_7721", "guest_cart": BASE["guest_cart"]})
    assert r.status_code == 200 and r.json()["active_cart"]["user_id"] == "player-alpha-1"
    assert client.get("/api/v1/cart", headers={"Authorization": f"Bearer {token}"}).json()["total_items"] == 1


def test_reset_restores_an_unmerged_token_and_empty_cart(client):
    assert _merge(client).status_code == 200
    client.post("/audit/v1/reset", json={})
    assert main.DB["guest_tokens"]["guest_anon_tok_7721"]["merged"] is False
    assert main.DB["carts"]["player-alpha-1"]["items"] == []
