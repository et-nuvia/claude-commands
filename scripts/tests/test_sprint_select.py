"""
Tests for lib/sprint_select.py

Covers the capacity arithmetic and the backlog fill: Fibonacci snapping, the
80/20 split, carry-over consuming the feature budget first, knapsack optimality
versus greedy ordering, and the Asana mutations that fall out of a plan.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_MODULE_PATH = Path(__file__).parent.parent / "lib" / "sprint_select.py"
_spec = importlib.util.spec_from_file_location("sprint_select", _MODULE_PATH)
ss = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ss)


# ── snap_points ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize(
    "raw,expected",
    [
        (1, 1), (2, 2), (3, 3), (5, 5), (8, 8), (15, 15), (25, 25),
        (4, 5),        # off-scale rounds UP, never down
        (6, 8),
        (9, 15),
        (26, 25),      # capped at the top of the scale
        (999, 25),
        (0, 3),        # non-positive falls back to the default
        (-2, 3),
        (None, 3),
        ("", 3),
        ("bogus", 3),
    ],
)
def test_snap_points(raw, expected):
    assert ss.snap_points(raw) == expected


def test_snap_points_never_understates_the_sprint():
    """Rounding down would let a sprint quietly overcommit."""
    for raw in (4, 6, 7, 9, 14, 16, 24):
        assert ss.snap_points(raw) >= raw


# ── capacity split ────────────────────────────────────────────────────────────

def test_default_capacity_is_80_20():
    plan = ss.build_plan({})
    cap = plan["capacity"]
    assert cap["total_points"] == 20
    assert cap["feature_budget"] == 16
    assert cap["bug_fill_reserve"] == 4


def test_feature_ratio_is_configurable():
    cap = ss.build_plan({"capacity_points": 30, "feature_ratio": 0.5})["capacity"]
    assert cap["feature_budget"] == 15
    assert cap["bug_fill_reserve"] == 15


def test_carryover_consumes_feature_budget_before_selection():
    plan = ss.build_plan(
        {
            "capacity_points": 20,  # feature budget 16
            "carryover": [{"gid": "1", "name": "carried", "remaining_points": 8}],
            "candidates": [
                {"gid": "2", "name": "a", "points": 8, "relevance": 9},
                {"gid": "3", "name": "b", "points": 8, "relevance": 8},
            ],
        }
    )
    cap = plan["capacity"]
    assert cap["carryover_points"] == 8
    assert cap["selectable_budget"] == 8
    assert cap["selected_points"] == 8          # only one of the two 8-pt items fits
    assert cap["committed_points"] == 16
    assert [s["name"] for s in plan["selected"]] == ["a"]


def test_carryover_uses_remaining_not_original_points():
    plan = ss.build_plan(
        {"carryover": [{"gid": "1", "name": "c", "points": 15, "remaining_points": 2}]}
    )
    assert plan["capacity"]["carryover_points"] == 2


def test_carryover_exceeding_budget_warns_and_selects_nothing():
    plan = ss.build_plan(
        {
            "capacity_points": 10,
            "carryover": [{"gid": "1", "name": "big", "remaining_points": 15}],
            "candidates": [{"gid": "2", "name": "a", "points": 1, "relevance": 10}],
        }
    )
    assert plan["capacity"]["selectable_budget"] == 0
    assert plan["counts"]["selected"] == 0
    assert any("exceeds" in w for w in plan["warnings"])


def test_bug_load_over_reserve_warns():
    plan = ss.build_plan(
        {
            "capacity_points": 20,  # reserve 4
            "bugs": [
                {"gid": "1", "name": "b1", "points": 5, "section": "Bugs"},
                {"gid": "2", "name": "b2", "points": 3, "section": "Bugs"},
            ],
        }
    )
    assert plan["capacity"]["open_bug_points"] == 8
    assert any("bug/fill reserve" in w for w in plan["warnings"])


# ── selection ─────────────────────────────────────────────────────────────────

def test_knapsack_beats_greedy_rating_order():
    """The regression this optimiser exists for.

    Greedy takes the 15-pt relevance-10 item and strands the budget; the optimal
    fill takes three items worth far more relevance for the same points.
    """
    doc = {
        "capacity_points": 24,          # feature budget 19
        "feature_ratio": 1.0,
        "candidates": [
            {"gid": "1", "name": "sso", "points": 15, "relevance": 10},
            {"gid": "2", "name": "remodel", "points": 8, "relevance": 9},
            {"gid": "3", "name": "staleness", "points": 5, "relevance": 8},
            {"gid": "4", "name": "secrets", "points": 3, "relevance": 6},
            {"gid": "5", "name": "hygiene", "points": 2, "relevance": 3},
        ],
    }
    optimal = ss.build_plan({**doc, "capacity_points": 19, "feature_ratio": 1.0})
    greedy = ss.build_plan({**doc, "capacity_points": 19, "feature_ratio": 1.0, "strict_rank": True})

    opt_rel = sum(s["relevance"] for s in optimal["selected"])
    grd_rel = sum(s["relevance"] for s in greedy["selected"])

    assert opt_rel > grd_rel
    assert opt_rel == 26
    assert grd_rel == 16
    assert optimal["capacity"]["selected_points"] <= 19
    assert greedy["capacity"]["selected_points"] <= 19


def test_strict_rank_keeps_the_top_rated_item():
    plan = ss.build_plan(
        {
            "capacity_points": 19,
            "feature_ratio": 1.0,
            "strict_rank": True,
            "candidates": [
                {"gid": "1", "name": "sso", "points": 15, "relevance": 10},
                {"gid": "2", "name": "remodel", "points": 8, "relevance": 9},
            ],
        }
    )
    assert "sso" in [s["name"] for s in plan["selected"]]


def test_never_exceeds_budget():
    plan = ss.build_plan(
        {
            "capacity_points": 10,
            "feature_ratio": 1.0,
            "candidates": [
                {"gid": str(i), "name": f"t{i}", "points": 3, "relevance": 5} for i in range(10)
            ],
        }
    )
    assert plan["capacity"]["selected_points"] <= 10


def test_bugs_are_never_selected_as_features():
    plan = ss.build_plan(
        {
            "capacity_points": 20,
            "candidates": [
                {"gid": "1", "name": "bug", "points": 2, "relevance": 10, "classification": "bug"},
                {"gid": "2", "name": "feat", "points": 2, "relevance": 4, "classification": "feature"},
            ],
        }
    )
    assert [s["name"] for s in plan["selected"]] == ["feat"]


def test_unscored_candidates_rank_last_and_warn():
    plan = ss.build_plan(
        {
            "capacity_points": 5,
            "feature_ratio": 1.0,
            "candidates": [
                {"gid": "1", "name": "unscored", "points": 5},
                {"gid": "2", "name": "scored", "points": 5, "relevance": 7},
            ],
        }
    )
    assert [s["name"] for s in plan["selected"]] == ["scored"]
    assert any("no relevance score" in w for w in plan["warnings"])


def test_deferred_items_carry_a_reason():
    plan = ss.build_plan(
        {
            "capacity_points": 3,
            "feature_ratio": 1.0,
            "candidates": [
                {"gid": "1", "name": "fits", "points": 3, "relevance": 9},
                {"gid": "2", "name": "toobig", "points": 15, "relevance": 8},
            ],
        }
    )
    assert plan["counts"]["deferred"] == 1
    assert plan["deferred"][0]["deferred_reason"]


# ── actions ───────────────────────────────────────────────────────────────────

def test_missing_items_become_create_actions_in_the_right_section():
    plan = ss.build_plan(
        {
            "missing": [
                {"name": "new feature", "classification": "feature", "points": 3},
                {"name": "new bug", "classification": "bug", "points": 2},
            ]
        }
    )
    creates = {a["name"]: a for a in plan["actions"] if a["action"] == "create_task"}
    assert creates["new feature"]["section"] == "Backlog"
    assert creates["new bug"]["section"] == "Bugs"


def test_misfiled_bug_is_moved_into_the_bugs_section():
    plan = ss.build_plan({"bugs": [{"gid": "9", "name": "b", "points": 2, "section": "Backlog"}]})
    moves = [a for a in plan["actions"] if a["action"] == "move_task"]
    assert len(moves) == 1
    assert moves[0]["section"] == "Bugs"


def test_bug_already_in_sprint_or_bugs_is_left_alone():
    for section in ("Bugs", "Current Sprint"):
        plan = ss.build_plan({"bugs": [{"gid": "9", "name": "b", "points": 2, "section": section}]})
        assert not [a for a in plan["actions"] if a["action"] == "move_task"]


def test_unselected_feature_in_bugs_section_is_relocated_to_backlog():
    plan = ss.build_plan(
        {
            "capacity_points": 1,
            "feature_ratio": 1.0,
            "candidates": [
                {"gid": "7", "name": "misfiled feature", "points": 8,
                 "relevance": 5, "classification": "feature", "section": "Bugs"}
            ],
        }
    )
    moves = [a for a in plan["actions"] if a["action"] == "move_task"]
    assert [m["section"] for m in moves] == ["Backlog"]


def test_selected_items_get_move_score_and_sprint_actions():
    plan = ss.build_plan(
        {
            "sprint_label": "2026-S34",
            "capacity_points": 10,
            "feature_ratio": 1.0,
            "candidates": [{"gid": "5", "name": "a", "points": 3, "relevance": 7}],
        }
    )
    kinds = {a["action"] for a in plan["actions"] if a.get("gid") == "5"}
    assert kinds == {"move_task", "set_score", "set_sprint", "set_relevance"}
    move = next(a for a in plan["actions"] if a["action"] == "move_task")
    assert move["section"] == "Current Sprint"


def test_no_sprint_label_means_no_sprint_stamp():
    plan = ss.build_plan(
        {
            "capacity_points": 10,
            "feature_ratio": 1.0,
            "candidates": [{"gid": "5", "name": "a", "points": 3, "relevance": 7}],
        }
    )
    assert not [a for a in plan["actions"] if a["action"] == "set_sprint"]


def test_carryover_is_stamped_with_the_sprint_label():
    plan = ss.build_plan(
        {
            "sprint_label": "2026-S34",
            "carryover": [{"gid": "1", "name": "c", "remaining_points": 3}],
        }
    )
    stamps = [a for a in plan["actions"] if a["action"] == "set_sprint"]
    assert len(stamps) == 1
    assert stamps[0]["gid"] == "1"


def test_empty_input_produces_a_valid_empty_plan():
    plan = ss.build_plan({})
    assert plan["actions"] == []
    assert plan["counts"] == {
        "carryover": 0, "selected": 0, "deferred": 0,
        "bugs": 0, "to_create": 0, "actions": 0,
    }
