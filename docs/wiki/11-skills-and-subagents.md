# Skills and Subagents

Commands are the front door. Behind them sit two mechanisms that decide
how much a command costs and how good its answer is: **skills**, which
load reference knowledge on demand, and **subagents**, which do work in
their own context and hand back only the conclusion.

Both exist for the same reason — a context window is a budget, not a
container. Everything resident in it is paid for on every turn.

## Skills

A skill is a folder under `skills/` containing a `SKILL.md` with YAML
frontmatter. The `description` is the only part always in context; the
body loads only when a task matches.

```yaml
---
name: worktree-docker-isolation
description: The per-worktree Docker isolation pattern. Load when a project
  uses git worktrees together with Docker, or when worktree stacks collide.
---
```

That makes the `description` the load-bearing field. It is not a summary
for humans — it is the retrieval key. A description reading "Docker stuff"
will never fire; one naming the symptoms ("worktree stacks collide, share
containers, migrations run against the wrong checkout") fires exactly when
someone hits them.

### Skills in this repo

| Skill | Load it when |
|---|---|
| [`cicd-reference`](#) | Setting up or debugging a pipeline, checking status/logs/jobs, wiring `docker exec` into a Makefile |
| [`secrets-reference`](#) | Setting up secrets for a project or wiring bootstrap credentials into compose |
| [`task-doc-types`](05-templates-and-docs) | Creating, naming, or identifying a task document (TSK, PLN, DSN, INV, RDM…) |
| [`version-management`](#) | Determining, bumping, or tagging a version; naming a release |
| [`worktree-docker-isolation`](12-worktrees-and-docker) | A project uses worktrees *and* Docker |
| [`migration-timestamps`](#) | Creating, renaming, or auditing a database migration file |
| [`migration-prompts`](#) | Running a one-time whole-codebase migration |
| [`understand-graph-ops`](#) | Configuring or troubleshooting the per-project knowledge graph |
| [`scratchpad`](#) | Offloading session detail that shouldn't stay resident |

### The scratchpad, specifically

`scratchpad` is the one skill worth understanding before you need it,
because it changes how a long session behaves. When you find a detail
worth keeping but not worth carrying every turn — a file location found
while exploring, an approach you rejected and why, an exact error string,
a command that worked — write it out:

```bash
~/.claude/scripts/scratchpad.sh write --summary "<one line>" [--tags "a,b"]
~/.claude/scripts/scratchpad.sh list                  # manifest of {id, summary}
~/.claude/scripts/scratchpad.sh recall --id <id>      # pull one note back
~/.claude/scripts/scratchpad.sh promote --id <id>     # graduate it to a wiki page
```

A `SessionStart` hook re-injects the one-line manifest after compaction,
so the *pointers* survive a context reset even though the bodies don't.
The distinction that keeps this useful: scratchpad is session-local
working detail; a durable fact about you or the project belongs in memory,
and a reusable pattern belongs in this wiki via `promote`.

## Subagents

A subagent runs a task in a **separate context window** and returns only
its final report. Everything it read, every dead end it explored, every
stack trace it printed stays in its context and never enters yours.

That framing makes the right use obvious: dispatch a subagent when the
work involves reading a lot to conclude a little.

### The agents in this repo

| Agent | Does | Writes files? |
|---|---|---|
| `explore-efficient` | Read-only find / map / where-is / what-calls sweeps, preferring compact-output scripts over raw grep | No |
| `code-explorer` | Traces how one feature actually works — call chains, transformations, layers | No |
| `code-architect` | Delivers a committed implementation blueprint, not a menu of options | No |
| `code-reviewer` | Full-diff review with confidence-based filtering | No |
| `incremental-reviewer` | Reviews only the delta since the last pass, ledger-aware | No |
| `security-auditor` | Auth/authz, injection, secrets, crypto, dependency, CI exposure | No |
| `deploy-risk-analyst` | Blast radius, breaking changes, mitigation list | No |
| `rca-investigator` | Correlates logs, deploys, and code into a timeline; drives 5-Whys | No |
| `debug-investigator` | Isolates a debugging spiral | **Yes** |
| `feature-implementer` | Implements a scoped change, loading the stack's conventions first | **Yes** |
| `fix-implementer` | Applies review findings, returns a finding→commit→hunks ledger | **Yes** |
| `test-engineer` | Writes and repairs tests (AAA, independent, idempotent) | **Yes** |
| `doc-synthesizer` | Reads many docs, writes one | **Yes** |
| `pipeline-watcher` | Watches CI to a terminal state, returns a compact verdict | No |
| `input-parser` | Parses ambiguous free-text into structured TSK fields. Tool-less by design — it cannot wander into the repo | No |

### Choosing a model

Subagents are the largest single line item in most token bills, so the
default matters more than the exceptions.

**Default to sonnet.** Escalate to opus only when deeper reasoning changes
the outcome.

| Sonnet | Opus |
|---|---|
| Codebase exploration, file mapping | Architecture synthesis across 3+ services |
| Standard review of a single service | Security review (auth, crypto, secrets) |
| Feature implementation (CRUD, hooks, UI) | Multi-service coordination, schema migrations |
| Test writing, fixture generation | Multi-step-reasoning debugging |
| Config changes, docs, formatting | API contract design, breaking-change analysis |

Always name the model explicitly when dispatching. The difference is
roughly 5× and it compounds across every subtask in a ten-step command —
an unspecified model is a decision made by default, repeatedly.

### Two habits that pay for themselves

**Dispatch independent work in parallel.** Two or more analyses that don't
depend on each other should go out in one message. Same tokens, two to
three times the wall-clock, and the parent context stays clean either way.

**Steer the subagent in its prompt, not in your config.** Subagents do not
reliably read your `CLAUDE.md`. If you want pointer-only output —
conclusions plus `file:line` references rather than pasted file contents —
say so in the prompt. Every time. A subagent that returns file dumps has
undone the reason you dispatched it.

## When to reach for which

- **A fact you'll need repeatedly across projects** → a skill
- **A fact you'll need for the rest of *this* session** → the scratchpad
- **A question whose answer is short but whose research is long** → a
  read-only subagent
- **A spiral that has already failed twice** → `debug-investigator`, before
  the third attempt lands in your context alongside the first two

---

**See also:** [Mental Model](02-mental-model) ·
[Customization](06-customization) · [Workflows](08-workflows)
