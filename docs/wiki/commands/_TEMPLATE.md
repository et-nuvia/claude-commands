---
command: <name>
group: <task-lifecycle | deploy | infra | db | rca | audit | git | ops | code-quality | generators | project-config | architecture | outlier>
backing_script: ~/.claude/scripts/<name>.sh    # or: prompt-only
mutates: [git, files, docker, asana, gitlab, github, aws, infisical, db, infra]
runtime: ~5s                                    # rough order of magnitude
destructive: false
requires_project_yaml: none                     # none | optional | required
project_yaml_fields:                            # list every field the command reads; [] if none
  - <field.path>
  - <field.path>
requires_project_knowledge: none                # none | optional | required
project_knowledge_sections: []                  # named sections read; [] if none
---

# /<command-name>

Two- to three-sentence lede. What the command does, what problem it solves,
what the user has at the end. Plain language — no implementation detail.

<!-- Config-dependency callout. Omit entirely if both are "none".
     When PY is required/optional, list EVERY field the command looks up —
     PROJECT.yaml may exist but be missing the specific keys this command needs. -->
> **Config:** PROJECT.yaml **required** — reads `ci.platform`, `ci.staging_branch`, `ci.production_branch`
> PROJECT-KNOWLEDGE.md optional — reads `## Architecture Decisions`

<!-- Optional. Include only when the command is genuinely dangerous
     (prod deploys, infra destroy, db restore, force operations). Delete otherwise. -->
> ⚠️ **Destructive — confirm twice.** Brief reason (e.g., "applies Terraform
> changes to live infrastructure"; "rewrites production database").

---

## When to use it

- Concrete trigger one
- Concrete trigger two
- Concrete trigger three (cap the list at 3 — example workflows cover the rest)

## Usage

```bash
/<command-name> [arguments]
```

**Common invocations:**

```bash
/<command-name>                  # default: <what defaults do>
/<command-name> <ARG>            # primary argument
/<command-name> --<flag>         # behavior switch
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form text. Used for: <what> |
| `--<flag>`   | No | <What it changes> |

If the command takes no arguments, write "None — invoke with no input."

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `<tool>` | <reason> | `<install hint>` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes / No. Required: `<field.path>`
- `PROJECT-KNOWLEDGE.md` (PK) — Yes / No. <what it reads/writes>
- Other: `<path>` — purpose

If none, write "None — the command is self-contained."

## Backing script

If `backing_script` is `prompt-only`, write "None — pure prompt command; all
logic lives in the LLM." and skip the rest.

Otherwise, this section is strictly the **input/output contract** of the
script. The end-to-end choreography lives in "How it works" — do not repeat
phases here.

**Script**: `~/.claude/scripts/<name>.sh`

**Inputs:** CLI flags, `PROJECT.yaml` fields, env vars it reads.

**Outputs:** structured JSON on stdout (and/or `/tmp/<name>-result.json`)
with the key fields the LLM consumes (`next_action`, scores, findings,
file lists, etc.).

**Invocation surface:**

```bash
~/.claude/scripts/<name>.sh --<stage>           # main entry
~/.claude/scripts/<name>.sh --raw --<stage>     # debug: bypass formatting
```

List every stage flag (`--analyze`, `--execute`, `--verify`, …) when there
are more than a couple — readers debugging a failure jump straight here.

## How it works

The single place the workflow is described end-to-end. Numbered phases, each
a short paragraph. Note where the script returns control to the LLM for
judgment (approval prompts, MCP calls, follow-up routing).

1. **Phase name** — what runs, what comes back, what the LLM does with it.
2. **Phase name** — …
3. **Phase name** — …

## Example workflows

Two or three scenarios showing the command in context. Include **one** with
an abbreviated example of the output the user actually sees.

### Scenario: <short title>

```
/<sibling>              # what it sets up
/<command-name>         # this command
/<next-step>            # logical follow-up
```

One sentence describing when this chain applies.

### Scenario: <short title — with output>

```
/<command-name>
```

```
<example output snippet — 4-8 lines, abbreviated with … as needed>
```

## Notes & gotchas

- Anything non-obvious before running (idempotency, retry safety, shared state)
- **If it fails:** one-line recovery hint per failure mode, with the debug
  command (`~/.claude/scripts/<name>.sh --raw --<stage>`)
- Environment differences (work macOS vs home WSL) when relevant
- Skip the whole section if there's genuinely nothing to say
