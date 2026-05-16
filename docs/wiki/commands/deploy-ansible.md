---
command: deploy-ansible
group: deploy
backing_script: ~/.claude/scripts/deploy-ansible.sh
mutates: [infra]
runtime: ~1-10min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /deploy-ansible

Runs Ansible playbooks safely through a consolidated script that validates
infrastructure, selects environment and inventory, executes the playbook, and
saves a log. Handles staging automatically; production requires interactive
`--raw` mode for confirmation.

---

## When to use it

- You need to run an Ansible playbook against staging or production hosts
- You want a guided environment/inventory/playbook selection instead of
  hand-crafting `ansible-playbook` commands
- You need a saved execution log for audit purposes

## Usage

```bash
/deploy-ansible [--env ENV] [--playbook FILE] [--check] [--limit PATTERN] [--verbose] [--extra-vars JSON]
```

**Common invocations:**

```bash
/deploy-ansible                                   # guided: prompts for env + playbook
/deploy-ansible --env staging --playbook deploy.yml
/deploy-ansible --env staging --check             # dry-run (check mode)
/deploy-ansible --env staging --limit web_servers # restrict to a host pattern
/deploy-ansible --env staging --verbose           # full Ansible output
/deploy-ansible --env staging --extra-vars '{"version":"1.2.3"}'
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--env ENV` | No | Target environment (`staging` or `production`). Prompted if omitted. |
| `--playbook FILE` | No | Playbook filename. Prompted from discovered playbooks if omitted. |
| `--check` | No | Ansible check mode — dry-run, no changes applied |
| `--limit PATTERN` | No | Restrict execution to a host pattern (passed to `--limit`) |
| `--verbose` | No | Enable verbose Ansible output (`-v`) |
| `--extra-vars JSON` | No | Extra variables as a JSON string |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `ansible` / `ansible-playbook` | Executes playbooks | `pip install ansible` or package manager |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| SSH key | Host authentication | configured in `~/.ssh/` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Not required; the script discovers
  inventories and playbooks from the local directory structure.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `inventory/` or `hosts` — Ansible inventory files (discovered automatically)
- `*.yml` playbooks — discovered in the current directory and subdirectories
- Execution log saved to a timestamped file (path returned in `log_file`)

## Backing script

**Script**: `~/.claude/scripts/deploy-ansible.sh`

**Inputs:** `--full` (main entry), plus optional `--env`, `--playbook`,
`--check`, `--limit`, `--verbose`, `--extra-vars`. Section flags for targeted
execution.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`,
`notify_user_blocked`, `fix_error`}, plus `environment`, `playbook`,
`inventory`, `log_file`, `exit_code`, `error_output`.

**Invocation surface:**

```bash
~/.claude/scripts/deploy-ansible.sh --full                            # guided full run
~/.claude/scripts/deploy-ansible.sh --full --env staging --playbook deploy.yml
~/.claude/scripts/deploy-ansible.sh --validate                        # infra check only
~/.claude/scripts/deploy-ansible.sh --prepare --env staging           # config only, skip exec
~/.claude/scripts/deploy-ansible.sh --execute --env staging --playbook deploy.yml
~/.claude/scripts/deploy-ansible.sh --raw --execute --env staging --playbook deploy.yml
```

## How it works

1. **Validate** — script checks that Ansible is installed, SSH keys are
   accessible, and inventory files exist. Returns `fix_error` with details if
   any prerequisite is missing.
2. **Prepare** — discovers available playbooks and inventories, resolves the
   target environment and inventory file. If `--env` or `--playbook` are
   omitted, the script prompts.
3. **Production gate** — if `--env production` is specified without `--raw`
   mode, the script returns `notify_user_blocked`. The LLM tells the user to
   run the script manually in raw mode so they can confirm interactively.
   Production cannot be executed non-interactively.
4. **Execute** — runs `ansible-playbook` with the resolved inventory and
   playbook. Real-time output goes to the log file; a summary is captured in
   `error_output` on failure.
5. **Summary** — `display_summary` reports environment, playbook, inventory,
   log path, and exit code. The LLM surfaces any warnings from the Ansible
   output.

## Example workflows

### Scenario: Staging infrastructure update

```
/infra-verify           # confirm current state
/deploy-ansible --env staging --playbook update-nginx.yml
/test-smoke             # verify after change
```

Typical infrastructure change flow for staging.

### Scenario: Dry-run before applying

```
/deploy-ansible --env staging --playbook deploy.yml --check
```

```
Ansible Check Mode (dry-run)
─────────────────────────────────────────
Environment: staging
Playbook:    deploy.yml
Inventory:   inventory/staging
Exit code:   0

  changed: [web01] (would change)
  ok:      [web02]
  …

Log: /tmp/ansible-staging-20260516-143022.log
No changes applied — re-run without --check to execute.
```

### Scenario: Production blocked output

```
/deploy-ansible --env production --playbook deploy.yml
```

```
Production deployment blocked — interactive confirmation required.

Run manually:
  ~/.claude/scripts/deploy-ansible.sh --raw --execute \
    --env production --playbook deploy.yml
```

## Notes & gotchas

- **Production always requires interactive `--raw` mode.** The script blocks
  non-interactive production runs intentionally. This is not a bug.
- `--check` (dry-run) is strongly recommended before any production Ansible
  run. Some modules do not support check mode and may report inaccurate results.
- The log file is always saved regardless of exit code — include it when
  reporting failures.
- **If it fails (SSH):** verify the key is loaded (`ssh-add -l`) and the
  inventory hostname resolves. Debug with
  `~/.claude/scripts/deploy-ansible.sh --raw --execute --env staging --playbook <name>`.
- **If it fails (syntax error):** run `ansible-playbook --syntax-check <playbook>`
  directly to get the exact line and fix it before retrying.
- **If it fails (unreachable hosts):** confirm VPN / network access to the
  target environment. Use `--limit` to isolate a single host for diagnosis.
- **Home (WSL) only** — Ansible deployments target Unraid/Proxmox/GCP. Work
  (macOS) uses AWS SSM via CI; use `/deploy-to-stage` or `/deploy-to-prod` instead.
