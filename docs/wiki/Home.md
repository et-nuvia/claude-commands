# claude-commands

A profile-driven collection of slash commands, scripts, and skills for
[Claude Code](https://claude.com/claude-code). Install once, configure a
profile, and get a consistent workflow across every project.

> **Source of truth.** This wiki is auto-generated from
> [`docs/wiki/`](https://github.com/et-nuvia/claude-commands/tree/main/docs/wiki)
> on every push to `main`. Edit the markdown there, not here — direct wiki
> edits will be overwritten on the next sync.

## Start here

- [Getting Started](01-getting-started) — install, profile, first command
- [Mental Model](02-mental-model) — how commands, scripts, skills, and
  profiles fit together
- [The Profile File](13-profile-and-environment) — the per-machine
  `active.yaml`: what goes in it, what's valid, and why environment is
  declared rather than inferred
- [PROJECT.yaml Reference](03-project-yaml) — required and optional fields
- [Command Catalog](04-command-catalog) — every command, grouped by purpose

## Going deeper

- [Workflows](08-workflows) — canonical command chains and where the
  human owns the gap between steps
- [Hooks](09-hooks) — optional Claude Code hooks shipped with this repo
  (notifications, auto-allow of repo scripts) — opt in per-hook
- [Testing](10-testing) — how to run the Bats + Python suite, what each
  file covers, and how to add new tests
- [Templates and Documents](05-templates-and-docs) — TSK, PLN, RCA, and
  friends
- [Skills and Subagents](11-skills-and-subagents) — on-demand reference
  knowledge, the agent roster, and how to pick a model without
  overpaying 5×
- [Worktrees and Docker Isolation](12-worktrees-and-docker) — the default
  task-isolation mode, and why an unconfigured worktree runs your
  migrations against the wrong checkout
- [Customization](06-customization) — adding your own commands and skills
- [Contributing](07-contributing) — how to land changes

## Per-command pages

Every command has its own page with required `PROJECT.yaml` fields,
inputs/outputs, and examples. Browse them under
[`commands/`](https://github.com/et-nuvia/claude-commands/tree/main/docs/wiki/commands)
or use the catalog above as the index.
