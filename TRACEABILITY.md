# Traceability

Maps requirement IDs from the Day 1 and Day 2 specs to source and tests. Run the tests with `./run_tests.sh`.
A golden-master replay of 356 Phase I requests is compared after every group; after Group 3 it is still identical to the post-Group 1 baseline.

## Phase II (Day 2)

Status words: **done** = implemented and tested; **partial** / **written** as stated.

| Requirement | Status | Source | Tests | Verified result |
|---|---|---|---|---|
| Group 1: multi-sport abstraction | done | `sports_engine.py`, `main.py` | `test_sports_engine.py` | passing |
| §5.2 reset baseline, readiness | done | `main.py` `_seed_phase2`, `health_probe`; compose health checks | `test_phase2_group1.py`, `test_media_access.py` | passing |
| §5.3 DAY2_SALT signatures | done | `main.py` `sign_day2`; `*_signature` methods in each service; `qr_view` | signature asserts in every endpoint suite | passing |
| FR-3.1 athlete profile, follow graph | partial: profile page only | `routers/guest_web.py` | `test_guest_web.py` | follow graph not built |
| FR-3.2 stream keys (§5.4) | done | `models/stream_key.py`, `services/stream_key_service.py`, `services/media_access.py`, `services/media_server.py`, `routers/stream.py`, `routers/media.py`, `media/mediamtx.yml` | `test_stream_key.py`, `test_media_access.py` | passing; on the stack, rotate cut a live publisher off in 0.42 s and its reconnect got KEY_REVOKED |
| FR-3.2 overlays, VOD to MinIO | overlays via Guest Web Player SSE; VOD not built | `web/static/guest_player.js` | Selenium test 3 | VOD not built |
| FR-3.3 co-stream, handoff (§5.5) | done | `models/costream.py`, `services/costream_service.py`, `routers/costream.py`, `media/compose.sh` | `test_costream.py`, `test_media_access.py` | passing; on the stack, a killed host was replaced in 0.65 s and no compositor remained |
| FR-4.1 dynamic QR (§5.6) | done | `services/qr_resolver.py`, `services/qr_export.py`, `routers/qr.py`, `main.py` `qr_view` | `test_qr.py`, `test_guest_web.py`, Selenium test 1 | passing |
| FR-4.2 / FR-4.3 guest access, 403 boundary | done | `routers/guest_web.py`, `middleware/guest_boundary.py`, `services/guest_session.py` | `test_guest_boundary.py`, Selenium tests 1-2 | passing |
| FR-4.4 cart merge (§5.7) | done | `services/guest_cart.py`, `routers/guest_cart.py` | `test_guest_cart_merge.py`, Selenium test 4 | passing |
| FR-5.2 notification bus, DLQ | done | `services/notification_dlq.py`, `services/live_feed.py` | `test_notification_dlq.py` | passing |
| FR-5.3 chat moderation (§5.8) | done | `services/moderation_service.py`, `routers/moderation.py`, `services/chat.py` | `test_moderation.py` | passing |
| NFR-1 score push p95 < 500 ms | done (SSE) | `routers/live.py`, `main.py` `publish_match` | `test_guest_web.py`, Selenium test 3 | passing (4-16 ms in browsers) |
| NFR-2 k6 500 + 50 VUs | done | `tests/k6_load.js` | k6 run, `tests/reports/k6-summary.json` | 46,258 requests, 0% failed, p95 97 ms on the desk laptop |
| NFR-6 /metrics | done | `services/metrics_service.py`, `routers/metrics.py` | `test_metrics.py` | passing |
| NFR-8 guest web accessibility | partial | `web/static/guest_player.css`, templates | - | no automated WCAG audit |
| NFR-9 privacy erasure | done | `services/privacy_service.py`, `routers/privacy.py`, `main.py` `_authenticate` | `test_privacy.py` | passing |
| §6.2 Selenium Grid 4 | done | `docker-compose.yml`, `tests/selenium/` | 8 browser tests | 8/8 passing on the full stack |
| §6.3 Appium deep links, cross-surface chat | written | `AndroidManifest.xml`, `MainActivity.kt`, `mobile/lib/core/deeplink/`, `mobile/lib/features/live/`, `tests/appium/` | `tests/appium/test_mobile_deeplink.py`, `mobile/test/deep_link_test.dart` | not run: no Android SDK/device; Dart not compiled |
| §1.3 CI, coverage | done | `.github/workflows/autograde.yml`, `COVERAGE_DAY2.json` | - | workflow not yet run on GitHub |

## Phase I (Day 1) regression coverage

| Requirement | Scope | Source | Tests |
|---|---|---|---|
| FR-1.1 | Multi-sport taxonomy, event-sourced scoring | `main.py` GROUP 2-3 (`_validate_sport`, `_fold`, `_check_transition`), `sports_engine.py` | `test_sports_engine.py`; `test_phase1_regression.py::test_mystery_sport_works_end_to_end_without_code_change`, `test_score_fields_per_scoring_model`, `test_event_idempotency_and_compensation`, `test_innings_limit_applies_to_own_balls_not_to_a_completed_chase` |
| FR-1.2 / FR-1.3 | Leagues, round-robin fixtures (swiss / elimination not implemented) | `main.py` GROUP 2-3 (`generate_fixtures`, `create_league`) | covered by the golden-master replay only (no dedicated unit test yet) |
| FR-1.4 | Standings, tie-breakers, NRR, draw_lots | `main.py` `_standings`, `_lots_key`; `sports_engine.py` `diff_components` / `differential` | `test_phase1_regression.py::test_event_model_standings_and_h2h`, `test_innings_standings_diff_is_net_run_rate`, `test_h2h_diff_uses_net_run_rate_for_innings_sports`, `test_draw_lots_*` |
| FR-2.1 / FR-2.2 | Clubs, tenant isolation, roster and transfers | `main.py` roster section, GROUP 7 | `test_phase1_regression.py::test_rbac_probes_and_token_checks`, `test_app_login_and_demo_routes` |
| FR-2.3 / NFR-3 | Store checkout, no oversell | `main.py` GROUP 4 (`_checkout`) | `test_phase1_regression.py::test_checkout_burst_never_oversells` |
| FR-5.1 | Five-tier RBAC | `main.py` GROUP 5 (`RBAC_MATRIX`, `_authenticate`) | `test_phase1_regression.py::test_rbac_probes_and_token_checks` |
| Offline sync | `/audit/v1/offline-sync`, `/api/v1/sync` | `main.py` GROUP 6 | `test_phase1_regression.py::test_offline_sync_replay_is_duplicate` |
