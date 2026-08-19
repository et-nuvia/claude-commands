#!/usr/bin/env python3
"""Sprint capacity math and backlog selection for sprint-plan.sh.

Reads a decisions document on stdin (produced by the LLM classification /
scoring step) and prints the sprint plan as JSON on stdout: the capacity
breakdown, the selected work, what was deferred and why, and the flat list of
Asana mutations the apply step should perform.

The split is deliberate: the LLM supplies *judgement* (feature vs bug, a 1-10
relevance score, an effort estimate where Asana has none) and this module
supplies *arithmetic*. Keeping the arithmetic here makes the fill reproducible
and reviewable — the same decisions always yield the same sprint.

Input schema (stdin):
    {
      "sprint_label":    "2026-S17",
      "capacity_points": 20,
      "feature_ratio":   0.8,
      "default_points":  3,
      "sections":        {"current_sprint": "...", "bugs": "...", "backlog": "..."},
      "carryover":       [{"gid","name","points","remaining_points","repo"}],
      "bugs":            [{"gid","name","points","section"}],
      "candidates":      [{"gid","name","points","relevance","classification","rationale"}],
      "missing":         [{"name","notes","classification","points","relevance","repo","source"}]
    }

Every task-shaped entry may omit "points"; `default_points` fills the gap.
"gid" is absent for tasks that do not exist in Asana yet (see "missing").
"""

from __future__ import annotations

import json
import sys
from typing import Any

DEFAULT_CAPACITY = 20
DEFAULT_RATIO = 0.8
DEFAULT_POINTS = 3

# Asana's Score enum. An LLM estimate of 4 is not a legal field value, so every
# estimate is snapped up to the next legal point value — rounding *down* would
# quietly understate the sprint and let it overcommit.
FIBONACCI_POINTS = [1, 2, 3, 5, 8, 15, 25]


def snap_points(value: Any, default: int = DEFAULT_POINTS) -> int:
    """Coerce an arbitrary estimate to the nearest legal Score value, rounding up."""
    try:
        n = int(round(float(value)))
    except (TypeError, ValueError):
        n = default
    if n <= 0:
        n = default
    for legal in FIBONACCI_POINTS:
        if n <= legal:
            return legal
    return FIBONACCI_POINTS[-1]


def _points(item: dict, default: int) -> int:
    raw = item.get("points")
    if raw in (None, "", "null"):
        raw = item.get("estimated_points")
    if raw in (None, "", "null"):
        return default
    return snap_points(raw, default)


def _relevance(item: dict) -> int:
    """Clamp relevance into 1-10. Unscored work sorts last, never first."""
    try:
        n = int(round(float(item.get("relevance"))))
    except (TypeError, ValueError):
        return 0
    return max(0, min(10, n))


def select_backlog(
    candidates: list[dict], budget: int, default_points: int, strict_rank: bool = False
) -> tuple[list[dict], list[dict]]:
    """Fill `budget` points with the combination of candidates that moves the
    project furthest toward its goal.

    Default is an exact 0/1 knapsack maximising summed relevance, because
    "highest rated first" and "most goal progress per sprint" are not the same
    thing: taking a 15-point relevance-10 item can starve a relevance-9 and a
    relevance-8 item that together fit the same budget and deliver far more. Ties
    on total relevance are broken toward using fewer points, then toward the
    higher single-item relevance, so the optimiser never pads a sprint with
    filler when a leaner equally-valuable sprint exists.

    strict_rank=True restores a simple greedy pass in strict relevance order —
    useful when the top-rated item must be in the sprint regardless of what that
    costs the total.
    """
    ranked = sorted(
        candidates,
        key=lambda c: (-_relevance(c), _points(c, default_points), (c.get("name") or "")),
    )
    prepared: list[dict] = []
    for cand in ranked:
        entry = dict(cand)
        entry["points"] = _points(cand, default_points)
        entry["relevance"] = _relevance(cand)
        prepared.append(entry)

    chosen_idx: set[int] = set()

    if strict_rank or budget <= 0:
        remaining = budget
        for idx, entry in enumerate(prepared):
            if entry["points"] <= remaining:
                remaining -= entry["points"]
                chosen_idx.add(idx)
    else:
        # dp[w] = (total_relevance, -points_used, best_single_relevance, frozenset(indices))
        neg_inf = float("-inf")
        dp: list[tuple[float, int, int, frozenset[int]]] = [
            (0.0, 0, 0, frozenset()) for _ in range(budget + 1)
        ]
        for idx, entry in enumerate(prepared):
            pts = entry["points"]
            rel = entry["relevance"]
            if pts <= 0 or pts > budget:
                continue
            for w in range(budget, pts - 1, -1):
                prev = dp[w - pts]
                if prev[0] == neg_inf:
                    continue
                cand_state = (
                    prev[0] + rel,
                    prev[1] - pts,
                    max(prev[2], rel),
                    prev[3] | {idx},
                )
                if cand_state[:3] > dp[w][:3]:
                    dp[w] = cand_state
        best = max(dp, key=lambda s: s[:3])
        chosen_idx = set(best[3])

    selected = [prepared[i] for i in range(len(prepared)) if i in chosen_idx]
    used = sum(e["points"] for e in selected)
    slack = budget - used

    deferred = []
    for i, entry in enumerate(prepared):
        if i in chosen_idx:
            continue
        entry = dict(entry)
        if entry["points"] > slack:
            entry["deferred_reason"] = (
                f"does not fit the {slack} pt(s) left in the feature budget "
                f"(needs {entry['points']})"
            )
        else:
            entry["deferred_reason"] = (
                "a higher-value combination filled the budget "
                f"(relevance {entry['relevance']}/10)"
            )
        deferred.append(entry)

    # Report in relevance order regardless of how the fill was computed.
    selected.sort(key=lambda e: (-e["relevance"], e["points"], e.get("name") or ""))
    return selected, deferred


def build_plan(doc: dict) -> dict:
    sections = doc.get("sections") or {}
    sprint_section = sections.get("current_sprint") or "Current Sprint"
    bugs_section = sections.get("bugs") or "Bugs"

    capacity = int(doc.get("capacity_points") or DEFAULT_CAPACITY)
    ratio = float(doc.get("feature_ratio") or DEFAULT_RATIO)
    default_points = int(doc.get("default_points") or DEFAULT_POINTS)
    sprint_label = doc.get("sprint_label") or ""

    feature_budget = int(round(capacity * ratio))
    reserve = capacity - feature_budget

    # Work already in flight that the user said carries into this sprint is not
    # a choice — it consumes the feature budget before anything is selected.
    carryover = []
    for item in doc.get("carryover") or []:
        entry = dict(item)
        remaining_raw = item.get("remaining_points", item.get("points"))
        entry["points"] = _points({"points": remaining_raw}, default_points)
        carryover.append(entry)
    carryover_points = sum(c["points"] for c in carryover)

    selectable_budget = max(0, feature_budget - carryover_points)
    candidates = [c for c in (doc.get("candidates") or []) if (c.get("classification") or "feature") != "bug"]
    selected, deferred = select_backlog(
        candidates, selectable_budget, default_points, strict_rank=bool(doc.get("strict_rank"))
    )

    selected_points = sum(s["points"] for s in selected)
    committed = carryover_points + selected_points

    bugs = []
    for item in doc.get("bugs") or []:
        entry = dict(item)
        entry["points"] = _points(item, default_points)
        bugs.append(entry)
    bug_points = sum(b["points"] for b in bugs)

    # --- Asana mutations -----------------------------------------------------
    actions: list[dict] = []

    for item in doc.get("missing") or []:
        is_bug = (item.get("classification") or "").lower() == "bug"
        actions.append(
            {
                "action": "create_task",
                "name": item.get("name"),
                "notes": item.get("notes") or "",
                "section": bugs_section if is_bug else (sections.get("backlog") or "Backlog"),
                "classification": "bug" if is_bug else "feature",
                "points": _points(item, default_points),
                "relevance": _relevance(item),
                "source": item.get("source") or "",
                "repo": item.get("repo") or "",
            }
        )

    for item in bugs:
        current = (item.get("section") or "").strip()
        if current.lower() not in {sprint_section.lower(), bugs_section.lower()}:
            actions.append(
                {
                    "action": "move_task",
                    "gid": item.get("gid"),
                    "name": item.get("name"),
                    "section": bugs_section,
                    "reason": f"bug parked in '{current or 'unknown'}' — bugs belong in "
                    f"'{bugs_section}' or '{sprint_section}'",
                }
            )

    # A feature parked in the Bugs section is misfiled. If it was selected it
    # moves into the sprint below anyway; if not, it belongs in the backlog so
    # the Bugs section stays a true bug list.
    selected_gids = {s.get("gid") for s in selected if s.get("gid")}
    for cand in candidates:
        gid = cand.get("gid")
        if not gid or gid in selected_gids:
            continue
        if (cand.get("section") or "").strip().lower() == bugs_section.lower():
            actions.append(
                {
                    "action": "move_task",
                    "gid": gid,
                    "name": cand.get("name"),
                    "section": sections.get("backlog") or "Backlog",
                    "reason": f"classified as a feature but filed under '{bugs_section}'",
                }
            )

    for item in selected:
        actions.append(
            {
                "action": "move_task",
                "gid": item.get("gid"),
                "name": item.get("name"),
                "section": sprint_section,
                "reason": f"selected: relevance {item['relevance']}/10, {item['points']} pts",
            }
        )
        actions.append(
            {
                "action": "set_score",
                "gid": item.get("gid"),
                "name": item.get("name"),
                "points": item["points"],
            }
        )
        if sprint_label:
            actions.append(
                {
                    "action": "set_sprint",
                    "gid": item.get("gid"),
                    "name": item.get("name"),
                    "sprint": sprint_label,
                }
            )
        if item.get("relevance"):
            actions.append(
                {
                    "action": "set_relevance",
                    "gid": item.get("gid"),
                    "name": item.get("name"),
                    "relevance": item["relevance"],
                }
            )

    for item in carryover:
        if sprint_label and item.get("gid"):
            actions.append(
                {
                    "action": "set_sprint",
                    "gid": item.get("gid"),
                    "name": item.get("name"),
                    "sprint": sprint_label,
                    "reason": "carried into this sprint",
                }
            )

    warnings: list[str] = []
    if carryover_points > feature_budget:
        warnings.append(
            f"carry-over alone ({carryover_points} pts) exceeds the {feature_budget}-pt feature "
            "budget — the sprint is fully committed before any new work is picked"
        )
    if bug_points > reserve and reserve > 0:
        warnings.append(
            f"open bug load ({bug_points} pts) exceeds the {reserve}-pt bug/fill reserve — "
            "expect bugs to displace planned work"
        )
    if not doc.get("candidates"):
        warnings.append("no scored backlog candidates were supplied — nothing could be selected")
    unscored = [c.get("name") for c in candidates if _relevance(c) == 0]
    if unscored:
        warnings.append(f"{len(unscored)} candidate(s) had no relevance score and ranked last")

    return {
        "sprint_label": sprint_label,
        "capacity": {
            "total_points": capacity,
            "feature_budget": feature_budget,
            "bug_fill_reserve": reserve,
            "carryover_points": carryover_points,
            "selectable_budget": selectable_budget,
            "selected_points": selected_points,
            "committed_points": committed,
            "unused_feature_points": max(0, selectable_budget - selected_points),
            "open_bug_points": bug_points,
            "feature_ratio": ratio,
        },
        "carryover": carryover,
        "selected": selected,
        "deferred": deferred,
        "bugs": bugs,
        "actions": actions,
        "warnings": warnings,
        "counts": {
            "carryover": len(carryover),
            "selected": len(selected),
            "deferred": len(deferred),
            "bugs": len(bugs),
            "to_create": len(doc.get("missing") or []),
            "actions": len(actions),
        },
    }


def main() -> int:
    try:
        doc = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        json.dump({"error": f"invalid decisions JSON: {exc}"}, sys.stdout)
        return 1
    json.dump(build_plan(doc), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
