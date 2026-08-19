---
command: git-history-scrub
group: git
backing_script: ~/.claude/scripts/git-history-scrub.sh
mutates: [git]
runtime: ~10min
destructive: true
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /git-history-scrub

Removes leaked secrets from git history: gitleaks scans every branch, you
classify each finding, git-filter-repo rewrites history in an isolated
mirror clone, and the force-push happens only after explicit approval and
confirmed rotation.

> ⚠️ **Destructive — rewrites published history.** Every collaborator must
> re-clone or reset afterwards. The force-push is gated behind explicit
> approval and confirmation that the secrets were rotated.

---

## When to use it

- gitleaks or a reviewer found a credential in history
- A secret was committed and removing the file didn't remove the history
- Before making a private repository public

## Usage

```bash
/git-history-scrub
```

## Arguments

None — invoke with no input.

## Backing script

**Script**: `~/.claude/scripts/git-history-scrub.sh`

```bash
~/.claude/scripts/git-history-scrub.sh --json --scan
~/.claude/scripts/git-history-scrub.sh --json --plan
~/.claude/scripts/git-history-scrub.sh --json --rewrite
~/.claude/scripts/git-history-scrub.sh --json --push --confirm
```

Requires `gitleaks`, `git-filter-repo`, and `jq`; the script verifies all
three before doing anything. State lives in `<git-dir>/history-scrub/` —
never committed, secrets `chmod 600`.

## How it works

1. **Scan** the full history across all branches, honouring the repo's
   `.gitleaks.toml` when present. Findings are deduped into distinct
   secrets, each flagged with whether it is still live in `HEAD`.
2. **Classify** each as `scrub` (a real credential) or `allowlist` (a
   placeholder like `YOUR_API_KEY`).
3. **Rewrite** history with git-filter-repo, in an isolated mirror clone.
4. **Push** — only after explicit approval and confirmed rotation.

## Notes & gotchas

- **Rotate first, scrub second.** Rewriting history does not un-leak a
  secret that was public: anyone who cloned still has it, and so may any
  cache or fork. The rewrite is cleanup; rotation is the fix.
- **Never guess on a real credential.** Where a finding is genuinely
  ambiguous — a client-side Maps key that is public by design, say — the
  command asks rather than deciding.
- Coordinate with everyone who has a clone before the force-push.

---

**See also:** [`/security-audit`](security-audit.md) · [`/rotate-secret`](rotate-secret.md)
