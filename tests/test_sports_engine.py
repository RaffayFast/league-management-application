"""Unit tests for the scoring-model strategies (pure functions, no HTTP)."""
import ast
import pathlib

import pytest

import main
from sports_engine import (EventScoring, InningsScoring, MatchTally, RoundScoring, SCORING_STRATEGIES, SportStrategy,
                           strategy_for)

T20 = {"scoring_model": "innings",
       "periods": {"innings_per_team": 1, "overs_per_innings": 20, "balls_per_over": 6, "wickets_per_innings": 10},
       "scoring_events": {"wd": {"runs": 1, "legal_ball": False, "wicket": False},
                          "one": {"runs": 1, "legal_ball": True, "wicket": False},
                          "four": {"runs": 4, "legal_ball": True, "wicket": False},
                          "out": {"runs": 0, "legal_ball": True, "wicket": True}}}
MYSTERY = {"scoring_model": "event", "scoring_events": {"zork": {"points": 3}, "blip": {"points": 1}}}
BO3 = {"scoring_model": "round", "periods": {"best_of": 3}, "scoring_events": {"map": {"rounds": 1}}}


def test_registry_is_keyed_by_scoring_model_only():
    assert set(SCORING_STRATEGIES) == {"event", "innings", "round"}
    assert isinstance(strategy_for(T20), InningsScoring)
    assert isinstance(strategy_for(BO3), RoundScoring)
    assert isinstance(strategy_for(MYSTERY), EventScoring)
    # unknown or missing sport keeps the Phase I fallback to the event model
    assert isinstance(strategy_for(None), EventScoring)
    assert isinstance(strategy_for({"scoring_model": "quidditch"}), EventScoring)


def test_architecture_interface_is_implemented():
    for name in ("validate_score_event", "calculate_match_state", "get_supported_events"):
        assert callable(getattr(SportStrategy, name))


def test_event_model_uses_config_points_for_any_event_names():
    s = strategy_for(MYSTERY)
    tally = s.calculate_match_state(MYSTERY, ["h", "a"], [("h", "zork"), ("a", "blip"), ("h", "blip"),
                                                          ("ghost", "zork")])
    assert tally.totals == {"h": 4, "a": 1}
    assert s.get_supported_events(MYSTERY) == ["zork", "blip"]
    assert s.unit_event(MYSTERY) == "blip"
    assert s.side_extras(MYSTERY, tally, "h") == {"wickets": None, "balls": None, "overs": None}
    assert s.validate_score_event(MYSTERY, tally, "h", "m") is None
    assert s.differential(s.diff_components(MYSTERY, tally, "h", "a")) == 3


def test_innings_tally_and_score_fields():
    s = strategy_for(T20)
    tally = s.calculate_match_state(T20, ["h", "a"], [("h", "four"), ("h", "wd"), ("h", "one"), ("h", "out"),
                                                      ("a", "one")])
    assert (tally.totals["h"], tally.balls["h"], tally.wickets["h"]) == (6, 3, 1)
    assert s.side_extras(T20, tally, "h") == {"wickets": 1, "balls": 3, "overs": "0.3"}
    assert s.side_extras(T20, tally, None) == {"wickets": None, "balls": None, "overs": None}


def test_innings_limits_are_balls_or_wickets_only():
    sport = {**T20, "periods": {**T20["periods"], "overs_per_innings": 1, "wickets_per_innings": 2}}
    s = strategy_for(sport)
    done_by_balls = MatchTally({"h": 4, "a": 5}, {"h": 6, "a": 2}, {"h": 0, "a": 0})
    assert s.validate_score_event(sport, done_by_balls, "h", "m").code == "INNINGS_COMPLETE"
    # Day 1 5.9 lists no chase rule: the side that passed the target may keep scoring until its own limit
    assert s.validate_score_event(sport, done_by_balls, "a", "m") is None
    done_by_wickets = MatchTally({"h": 0, "a": 0}, {"h": 2, "a": 0}, {"h": 2, "a": 0})
    v = s.validate_score_event(sport, done_by_wickets, "h", "m")
    assert (v.status, v.code, v.details) == (409, "INNINGS_COMPLETE", {"team_id": "h"})


def test_net_run_rate_uses_decimal_overs_and_full_overs_when_all_out():
    s = strategy_for(T20)
    # 160 off 97 balls (16.1667 overs) vs 159 off 120 balls: 960/97 - 159/20 = 1.946907...
    chase = MatchTally({"h": 160, "a": 159}, {"h": 97, "a": 120}, {"h": 3, "a": 6})
    assert s.differential(s.diff_components(T20, chase, "h", "a")) == 1.947
    assert s.differential(s.diff_components(T20, chase, "a", "h")) == -1.947
    # all out after 100 legal balls still counts as the full 20 overs
    all_out = MatchTally({"h": 150, "a": 140}, {"h": 120, "a": 100}, {"h": 4, "a": 10})
    assert s.overs_faced(T20, all_out, "a") == 20.0
    assert s.differential(s.diff_components(T20, all_out, "h", "a")) == 0.5
    assert s.differential({}) == 0.0


def test_round_model_limits_and_config_rules():
    s = strategy_for(BO3)
    assert s.validate_score_event(BO3, MatchTally({"h": 1, "a": 1}, {}, {}), "h", "m") is None
    v = s.validate_score_event(BO3, MatchTally({"h": 2, "a": 0}, {}, {}), "a", "m-9")
    assert (v.status, v.code, v.details) == (409, "SERIES_ALREADY_DECIDED", {"match_id": "m-9"})
    assert s.invalid_period_fields({"best_of": 4}) == ["periods.best_of"]
    assert s.invalid_period_fields({"best_of": 0}) == ["periods.best_of"]
    assert s.invalid_period_fields({"best_of": 5}) == []
    assert s.is_valid_event_config({"rounds": 1}) and not s.is_valid_event_config({"rounds": 0})


@pytest.mark.parametrize("model,cfg,ok", [
    ("event", {"points": 2}, True), ("event", {"points": 0}, False), ("event", {"points": True}, False),
    ("innings", {"runs": 0, "legal_ball": True, "wicket": True}, True), ("innings", {"runs": 1}, False),
    ("round", {"rounds": 1}, True), ("round", {"rounds": "1"}, False),
])
def test_event_config_validation_per_model(model, cfg, ok):
    assert SCORING_STRATEGIES[model].is_valid_event_config(cfg) is ok


def test_no_branching_on_sport_or_event_names():
    """rules.md hard rule (-8): code may branch on scoring_model, never on sport ids or event names."""
    names = {s["sport_id"] for s in main.BASELINE_SPORTS}
    names |= {e for s in main.BASELINE_SPORTS for e in s["scoring_events"]}
    root = pathlib.Path(main.__file__).parent
    offenders = []
    for file in ("main.py", "sports_engine.py"):
        tree = ast.parse((root / file).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            # == / != / in comparisons and match-case literals are how a name-based branch would look
            if isinstance(node, (ast.Compare, ast.MatchValue)):
                for sub in ast.walk(node):
                    if isinstance(sub, ast.Constant) and sub.value in names:
                        offenders.append(f"{file}:{sub.lineno} {sub.value!r}")
    assert offenders == []
