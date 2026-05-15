# Customization

## Profiles

`profiles/active.yaml` (gitignored) holds your environment-specific values:
git platform, CI platform, container registry, secrets backend, task
backend, deploy targets. Scripts read it via `scripts/lib/load-profile.sh`.

Define multiple environments (e.g., `work` and `home`) and switch with
`active_environment:`. Same scripts, different values.

See `profiles/default.yaml.example` for the full schema.

## Local-only commands

Need a command that's specific to you and shouldn't go in the shared repo?
Drop it in `~/.claude/commands-local/` (gitignored). Claude Code picks it up
the same way it picks up commands from the symlinked `commands/`.

## Forking

Fork this repo if your team needs substantially different defaults
(different task backend conventions, different doc types, different
scaffolds). Pull from upstream periodically for new commands.

## Adding a new environment

1. Edit `profiles/active.yaml`, add an entry under `environments:`
2. If your environment introduces a new task backend / CI platform / cloud,
   you may need to add cases to a handful of scripts in `scripts/`
3. Update `profiles/default.yaml.example` so others can see the new option
