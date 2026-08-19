---
name: predict-issues
description: Predict potential issues from recent changes before deployment
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



# Predictive Code Analysis  

I'll analyze your codebase to predict potential problems before they impact your project.

**Analysis agent**: for the deployment-facing risk in recent changes (breaking changes, blast radius, data-safety, test gaps), dispatch `subagent_type: "deploy-risk-analyst"` (opus, read-only) to keep the parent context clean and reuse its scored, mitigation-oriented output.

## Strategic Thinking Process

<think>
To make accurate predictions, I need to consider:

1. **Pattern Recognition**
   - Which code patterns commonly lead to problems?
   - Are there growing complexity hotspots?
   - Do I see anti-patterns that will cause issues at scale?
   - Are there ticking time bombs (hardcoded values, assumptions)?

2. **Risk Assessment Framework**
   - Likelihood: How probable is this issue to occur?
   - Impact: How severe would the consequences be?
   - Timeline: When might this become a problem?
   - Effort: How hard would it be to fix now vs later?

3. **Common Problem Categories**
   - Performance: O(n²) algorithms, memory leaks, inefficient queries
   - Maintainability: High complexity, poor naming, tight coupling
   - Security: Input validation gaps, exposed secrets, weak auth
   - Scalability: Hardcoded limits, single points of failure

4. **Prediction Strategy**
   - Start with highest risk areas (critical path code)
   - Look for patterns that break at 10x, 100x scale
   - Check for technical debt accumulation
   - Identify brittleness in integration points
</think>

## Load structural context (if available)

Before scanning, check if `.understand/graph.json` exists in cwd. If yes, derive a relevance source — the current task ID (from `.current-task`) for task-scoped prediction, or recently changed files (`git diff --name-only HEAD~5`) for change-scoped prediction. Pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --for-task <TASK_ID>
# or, when no task:
~/.claude/scripts/understand-explore.sh --json --search "<keywords from changed files>"
```

Hold the top ~20 nodes as structural context. Most useful query for issue prediction: **ripple via reverse-edges from changed nodes** — every caller of a modified symbol is a candidate site for hidden breakage, and high fan-in nodes are the ones whose latent issues impact the most surface area. This focuses predictions on real downstream risk, not generic anti-patterns. Skip silently if graph absent, no relevance source, script errors, or empty result.

Based on this analysis framework, I'll use native tools for comprehensive analysis:
- **Grep tool** to search for problematic patterns
- **Glob tool** to analyze file structures and growth
- **Read tool** to examine complex functions and hotspots

I'll examine:
- Code complexity trends and potential hotspots
- Performance bottleneck patterns forming
- Maintenance difficulty indicators
- Architecture stress points and scaling issues
- Error handling gaps

For each prediction, I'll:
- Show specific code locations with file references
- Explain why it's likely to cause future issues
- Estimate potential timeline and impact
- Suggest preventive measures with priority levels

When I find multiple issues, I'll create a todo list for systematic review and prioritization.

Analysis areas:
- Functions approaching complexity thresholds
- Files with high change frequency (potential hotspots)
- Dependencies with known issues or update requirements
- Performance patterns that don't scale
- Code duplication leading to maintenance issues

After analysis, I'll ask: "How would you like to track these predictions?"
- Create todos: I'll add items to track resolution progress
- Create GitHub issues: I'll generate properly formatted issues with details
- Summary only: I'll provide actionable report without task creation

**Important**: I will NEVER:
- Add "Created by Claude" or any AI attribution to issues
- Include "Generated with Claude Code" in descriptions
- Modify repository settings or permissions
- Add any AI/assistant signatures or watermarks

Predictions will include:
- Risk level assessment (Critical/High/Medium/Low)
- Estimated timeline for potential issues
- Specific remediation recommendations
- Impact assessment on project goals

This helps prevent problems before they impact your project, saving time and maintaining code quality proactively.

