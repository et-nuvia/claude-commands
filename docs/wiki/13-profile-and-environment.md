# The Profile File

Every machine that runs these commands has one file describing where that
machine's work goes: which git host, which CI, which registry, which
secrets backend, which task tracker. That file is
`~/.claude/profiles/active.yaml`, and it is the reason the same commands
behave correctly on a work laptop and a home box without either one
carrying the other's settings.

It is **gitignored and never committed.** The repo ships
`profiles/default.yaml.example` as a template; you copy it once per
machine.

```bash
cp ~/.claude/profiles/default.yaml.example ~/.claude/profiles/active.yaml
$EDITOR ~/.claude/profiles/active.yaml
```

## The one idea worth understanding

**Environment is declared, never inferred.**

It is tempting for a script to run `uname -s`, see Darwin, and conclude
"this is the work machine, so use GitHub and AWS." That inference is
wrong the moment anyone's setup differs from the person who wrote it —
and it fails silently, pushing to the wrong registry or opening an issue
in the wrong tracker, because a guess produces a plausible answer rather
than an error.

So the repo keeps two axes strictly separate:

| Axis | Answers | Read it with | Legitimate uses |
|---|---|---|---|
| **Platform** | What kernel am I on? | `env_platform` in `lib/platform.sh` → `darwin` \| `linux` \| `wsl` \| `unknown` | `sed -i ''` vs `sed -i`, `date -v` vs `date -d`, launchd vs systemd, `osascript` |
| **Profile** | What environment is this? | `profile_env_get` in `lib/load-profile.sh` | Git host, CI, registry, secrets backend, task tracker, deploy method |

Anything that is a **policy choice** follows the profile. Anything that is
an **OS capability** follows the platform. A script that reads `uname` to
decide which secrets manager to use has crossed the line, and that is the
single most common bug this design exists to prevent.

## What goes in it

### `identity` — who you are

Used in commit messages, PR descriptions, and document headers.

```yaml
identity:
  name: "Your Name"
  email: "you@example.com"
```

### `active_environment` — which block is live

A single string naming one key under `environments`. **Required.** If it's
missing, or names an environment that isn't defined, `load_profile` fails
loudly rather than picking one.

```yaml
active_environment: home
```

### `environments` — one coherent bundle per context

An environment is not "a machine" and not "a deployment stage". It is a
**coherent bundle** of the five things that travel together: git platform,
CI platform, container registry, secrets backend, and task backend.

The common work/home split is just two environments. Nothing stops you
having more — a contract client, a personal fork, a lab box.

```yaml
environments:
  home:
    description: "Personal / WSL"
    git:
      platform: gitlab           # github | gitlab
      instance: git.example.com
      token_file: ~/.gitlab-token
    ci:
      platform: gitlab-ci        # github-actions | gitlab-ci
    registry:
      host: docker.example.com
      auth: infisical            # iam | infisical | docker-hub
    secrets:
      backend: infisical         # infisical | aws-secrets-manager | none
      bootstrap_dir: .secrets
      url: https://secrets.example.com   # self-hosted Infisical only
    task_management:
      backend: gitlab            # asana | gitlab | github | none
    deploy:
      targets: [unraid, proxmox, gcp]

  work:
    description: "Work / macOS"
    git:
      platform: github
      instance: github.com
    ci:
      platform: github-actions
    registry:
      host: 000000000000.dkr.ecr.us-east-1.amazonaws.com
      auth: iam
    secrets:
      backend: aws-secrets-manager
    task_management:
      backend: asana
      asana:
        workspace_id: ""
        default_project: "Engineering"
    deploy:
      targets: [aws]
```

Each `backend` and `platform` value selects a real adapter file — see
[Mental Model](02-mental-model). `task_management.backend: gitlab`
resolves `scripts/lib/task-backends/gitlab-tasks.sh`;
`secrets.backend: aws-secrets-manager` resolves
`scripts/lib/secrets-backends/aws-sm.sh`. **A value with no matching
adapter is a configuration error, not a fallback.**

### `paths` and `defaults` — the small stuff

```yaml
paths:
  projects_root: ~/projects
  wiki_root: ~/projects/wiki

defaults:
  task_doc_format: v4            # v3 | v4
  commit_signoff: false
  use_worktrees: true
```

`defaults` exists to skip prompts. Setting `use_worktrees: true` means
`/task-start` stops asking.

## How scripts read it

```bash
source "${SCRIPT_DIR}/lib/load-profile.sh"

load_profile                                # ensure loaded (idempotent)
env=$(profile_active_environment)           # "home"
host=$(profile_env_get .registry.host)      # environments.home.registry.host
name=$(profile_get .identity.name)          # root-level lookup
port=$(profile_env_get .registry.port 5000) # second arg is the default
```

The distinction that trips people up: `profile_get` takes a **root-level**
path, `profile_env_get` takes a path **relative to the active
environment**. `profile_env_get .registry.host` resolves to
`.environments.home.registry.host`, not `.registry.host`.

Two more accessors matter occasionally:

- `profile_is_fallback` — true when running off the bundled example rather
  than a real profile. Gate side effects on this: don't push to a registry
  whose host came from `default.yaml.example`.
- `profile_dump` — prints the resolved environment block. The first thing
  to run when a command targets the wrong place.

```bash
bash -c 'source ~/.claude/scripts/lib/load-profile.sh && profile_dump'
```

## Where the file is found

Resolution order, first hit wins:

1. `$CLAUDE_PROFILE` — explicit override. If set and the file doesn't
   exist, that's a hard error, not a fall-through. Setting it to a
   nonexistent path never silently uses your real profile.
2. `$CLAUDE_HOME/profiles/active.yaml` — when `CLAUDE_HOME` is set
3. `~/.claude/profiles/active.yaml` — the standard install

If none exists, `load_profile` falls back to the bundled example and
**warns on stderr**. That keeps a first run or a CI invocation working
instead of hard-failing, while making it obvious you're running on
placeholder values. Treat the warning as a to-do, not as noise.

## The layering

```
profile defaults
  → environments.<active>.*
    → PROJECT.yaml (per project)
      → command flags
```

Later layers override earlier ones. In practice:

- **The profile** says what this *machine* does. It never knows about a
  specific project.
- **PROJECT.yaml** says what this *project* does, overriding the machine
  default where the project genuinely differs — a repo that lives on
  GitHub while the rest of your work is on GitLab, say.
- **A flag** overrides both, for one invocation.

A concrete example, `get-config.sh` resolving the secrets backend: it
reads `PROJECT.yaml` `.secrets.backend` first; if absent, the profile's
`.secrets.backend`; if that's absent too, `none`. It never consults the
operating system.

## Valid and invalid

**Valid:**

- Any number of environments, named whatever you like. `home` and `work`
  are conventions, not keywords.
- An environment that omits blocks it doesn't need. A machine that never
  deploys can skip `deploy` entirely; missing keys return the default you
  passed, or empty.
- `secrets.backend: none` — a real, supported choice for a project with no
  secrets. It selects `secrets-backends/none.sh`.
- Paths with `~`, which are expanded on read.

**Invalid — these fail loudly, by design:**

| Mistake | What happens |
|---|---|
| No `active_environment` | `load_profile` fails: "profile is missing 'active_environment'" |
| `active_environment: staging` with no `environments.staging` | Fails naming both the value and the file |
| `$CLAUDE_PROFILE` pointing at a missing file | Hard error — never falls through to the default location |
| A `backend`/`platform` value with no adapter file | The adapter dispatcher fails to load |

**Invalid — and worth stating plainly:**

- **Never commit `active.yaml`.** It carries your registry hosts, git
  instance, and token *paths*. It is gitignored; keep it that way.
- **Never put secret values in it.** Token *file paths* (`token_file:
  ~/.gitlab-token`) belong here; the tokens themselves do not. Same for
  passwords, client secrets, and API keys — those live in the secrets
  backend the profile *points at*.
- **Never use an environment as a deployment stage.** `staging` and
  `production` are not environments in this sense; they're deploy targets
  configured in `PROJECT.yaml`. An environment is the bundle of tooling
  you work *through*, not the place you deploy *to*.
- **Don't encode per-project settings here.** If it varies by repo, it
  belongs in `PROJECT.yaml` — otherwise switching projects silently
  changes machine-wide behaviour.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "WARN no active profile, using example values" | You never copied the example. Everything downstream is placeholder config. |
| A command targets the wrong registry or tracker | Check `profile_dump` first — `active_environment` is probably pointing at the other block. |
| Works on one machine, not another | Compare `profile_dump` output on both. This is what the file exists to make visible. |
| A script behaves differently on macOS vs Linux in a way that isn't syntax | Something is reading `uname` to make a policy decision. That's the bug — route it through `profile_env_get`. |

---

**See also:** [Getting Started](01-getting-started) ·
[Mental Model](02-mental-model) ·
[PROJECT.yaml Reference](03-project-yaml) ·
[Customization](06-customization)
