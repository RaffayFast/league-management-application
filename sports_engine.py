"""Multi-sport scoring engine: one strategy per scoring model, while sports stay pure data.

Architecture.md section 4.1 asks for a ``SportStrategy`` interface with ``validate_score_event``,
``calculate_match_state`` and ``get_supported_events``. The Day 1 rules forbid branching on sport or
event names (rules.md hard rule, -8) and require a sport posted to /audit/v1/sports to work with no code
change. Strategies are therefore keyed by ``scoring_model`` ("event" | "innings" | "round"), never by
sport_id, and every sport-specific value (event names, points, periods, limits) is read from the sport's
JSON config. Football, basketball, kabaddi or any mystery sport all run through the same three classes.

This module is framework-free: it never touches HTTP or the in-memory DB. Rule violations are returned
as ``Violation`` values and the API layer turns them into error responses.
"""
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Iterable, Optional


@dataclass(frozen=True)
class Violation:
    status: int
    code: str
    message: str
    details: dict


@dataclass
class MatchTally:
    """Per-team totals of one match, built only from active (non-compensated) score events."""
    totals: dict
    balls: dict
    wickets: dict

    @classmethod
    def empty(cls, teams: Iterable[str]) -> "MatchTally":
        teams = list(teams)
        return cls({t: 0 for t in teams}, {t: 0 for t in teams}, {t: 0 for t in teams})


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _pos_int(v) -> bool:
    return _is_int(v) and v >= 1


class SportStrategy(ABC):
    """Scoring rules shared by every sport that uses one scoring model."""
    scoring_model = ""
    period_fields: tuple = ()

    # ---- sport config validation (POST /audit/v1/sports)
    def invalid_period_fields(self, periods: dict) -> list:
        return [f"periods.{key}" for key in self.period_fields if not _pos_int(periods.get(key))]

    @abstractmethod
    def is_valid_event_config(self, cfg: dict) -> bool:
        """Whether one scoring_events entry is valid for this model."""

    # ---- Architecture.md 4.1 interface
    def get_supported_events(self, sport: dict) -> list:
        return list(sport.get("scoring_events") or {})

    def calculate_match_state(self, sport: dict, teams: Iterable[str], score_events: Iterable[tuple]) -> MatchTally:
        """Folds (team_id, event_type) pairs, in log order, into a tally. Unknown teams are ignored."""
        tally = MatchTally.empty(teams)
        configs = sport.get("scoring_events") or {}
        for team_id, event_type in score_events:
            if team_id in tally.totals:
                self.apply_score(tally, team_id, configs.get(event_type, {}))
        return tally

    def validate_score_event(self, sport: dict, tally: MatchTally, team_id: str, match_id: str) -> Optional[Violation]:
        """Model limits for one more score event by team_id. The caller checks event type and status first."""
        return None

    # ---- per-model hooks
    @abstractmethod
    def score_value(self, cfg: dict) -> int:
        """Points, runs or rounds one event of this config adds."""

    def apply_score(self, tally: MatchTally, team_id: str, cfg: dict) -> None:
        tally.totals[team_id] += self.score_value(cfg)

    def unit_event(self, sport: dict) -> Optional[str]:
        """First configured event worth exactly one unit (a goal, a run, a round), else the first event."""
        configs = sport.get("scoring_events") or {}
        return next((name for name, cfg in configs.items() if self.score_value(cfg) == 1), next(iter(configs), None))

    def side_extras(self, sport: dict, tally: MatchTally, team_id: Optional[str]) -> dict:
        """Model-specific score fields; only the innings model fills them (Day 1 5.9)."""
        return {"wickets": None, "balls": None, "overs": None}

    def diff_components(self, sport: dict, tally: MatchTally, team_id: str, opponent_id: str) -> dict:
        """Additive per-match ingredients of the standings differential, summed across matches by the caller."""
        return {"for": tally.totals.get(team_id, 0), "against": tally.totals.get(opponent_id, 0)}

    def differential(self, components: dict):
        return components.get("for", 0) - components.get("against", 0)


class EventScoring(SportStrategy):
    """Points per event (goals, baskets, raid points). diff = scored - conceded."""
    scoring_model = "event"
    period_fields = ("count", "duration_minutes")

    def is_valid_event_config(self, cfg: dict) -> bool:
        return _pos_int(cfg.get("points"))

    def score_value(self, cfg: dict) -> int:
        return cfg.get("points", 1)


class InningsScoring(SportStrategy):
    """Runs, legal balls and wickets. diff = net run rate (Day 1 5.10)."""
    scoring_model = "innings"
    period_fields = ("innings_per_team", "overs_per_innings", "balls_per_over", "wickets_per_innings")

    def is_valid_event_config(self, cfg: dict) -> bool:
        return (_is_int(cfg.get("runs")) and cfg["runs"] >= 0
                and isinstance(cfg.get("legal_ball"), bool) and isinstance(cfg.get("wicket"), bool))

    def score_value(self, cfg: dict) -> int:
        return cfg.get("runs", 0)

    def apply_score(self, tally: MatchTally, team_id: str, cfg: dict) -> None:
        tally.totals[team_id] += self.score_value(cfg)
        tally.balls[team_id] += 1 if cfg.get("legal_ball") else 0
        tally.wickets[team_id] += 1 if cfg.get("wicket") else 0

    @staticmethod
    def _periods(sport: dict) -> tuple:
        p = sport.get("periods") or {}
        return (p.get("innings_per_team", 1), p.get("overs_per_innings", 20), p.get("balls_per_over", 6),
                p.get("wickets_per_innings", 10))

    def validate_score_event(self, sport, tally, team_id, match_id):
        # Day 1 5.9 model limits: only the team's own legal balls or wickets close its innings
        per_team, overs, bpo, wickets = self._periods(sport)
        if tally.balls.get(team_id, 0) >= per_team * overs * bpo or tally.wickets.get(team_id, 0) >= per_team * wickets:
            return Violation(409, "INNINGS_COMPLETE", "This team's innings is complete", {"team_id": team_id})
        return None

    def side_extras(self, sport, tally, team_id):
        if team_id is None:
            return super().side_extras(sport, tally, team_id)
        bpo = self._periods(sport)[2]
        balls = tally.balls.get(team_id, 0)
        return {"wickets": tally.wickets.get(team_id, 0), "balls": balls, "overs": f"{balls // bpo}.{balls % bpo}"}

    def overs_faced(self, sport: dict, tally: MatchTally, team_id: str) -> float:
        """Decimal overs; an all-out innings counts as the full overs allocation (Day 1 5.10)."""
        per_team, overs, bpo, wickets = self._periods(sport)
        if tally.wickets.get(team_id, 0) >= per_team * wickets:
            return float(per_team * overs)
        return tally.balls.get(team_id, 0) / bpo

    def diff_components(self, sport, tally, team_id, opponent_id):
        return {"runs_for": tally.totals.get(team_id, 0), "overs_for": self.overs_faced(sport, tally, team_id),
                "runs_against": tally.totals.get(opponent_id, 0),
                "overs_against": self.overs_faced(sport, tally, opponent_id)}

    def differential(self, components: dict) -> float:
        def rate(runs, overs):
            return runs / overs if overs else 0.0

        nrr = (rate(components.get("runs_for", 0), components.get("overs_for", 0))
               - rate(components.get("runs_against", 0), components.get("overs_against", 0)))
        return round(nrr, 3) + 0.0  # + 0.0 turns -0.0 into 0.0


class RoundScoring(SportStrategy):
    """Rounds or maps won in a best-of-N series. diff = rounds won - rounds lost."""
    scoring_model = "round"
    period_fields = ("best_of",)

    def invalid_period_fields(self, periods: dict) -> list:
        bad = super().invalid_period_fields(periods)
        best_of = periods.get("best_of")
        if _is_int(best_of) and best_of % 2 == 0 and "periods.best_of" not in bad:
            bad.append("periods.best_of")
        return bad

    def is_valid_event_config(self, cfg: dict) -> bool:
        return _pos_int(cfg.get("rounds"))

    def score_value(self, cfg: dict) -> int:
        return cfg.get("rounds", 1)

    def validate_score_event(self, sport, tally, team_id, match_id):
        needed = (sport.get("periods") or {}).get("best_of", 1) // 2 + 1
        if max(tally.totals.values(), default=0) >= needed:
            return Violation(409, "SERIES_ALREADY_DECIDED", "The series has already been decided", {"match_id": match_id})
        return None


SCORING_STRATEGIES = {s.scoring_model: s for s in (EventScoring(), InningsScoring(), RoundScoring())}
DEFAULT_STRATEGY = SCORING_STRATEGIES["event"]


def strategy_for(sport: Optional[dict]) -> SportStrategy:
    """Strategy for a sport config; unknown sports fall back to the event model, as Phase 1 did."""
    return SCORING_STRATEGIES.get((sport or {}).get("scoring_model"), DEFAULT_STRATEGY)
