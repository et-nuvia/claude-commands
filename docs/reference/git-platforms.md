# Git Platform Integration

Cross-platform git and CI/CD pipeline management for GitHub and GitLab.

## Overview

The global pipeline scripts automatically detect the git platform from `PROJECT.yaml` and use the appropriate API (GitLab or GitHub) for pipeline operations.

## Configuration

### PROJECT.yaml

Each project must have a `PROJECT.yaml` file with git configuration:

```yaml
git:
  platform: gitlab  # or "github"
  instance: git.turnersrus.com  # or "github.com"
  repo: ""  # Optional, auto-detected from git remote if empty
```

**Fields:**
- `platform`: Git platform (`gitlab` or `github`)
- `instance`: Git server hostname
- `repo`: Repository path (e.g., `docker/mcps` or `owner/repo`)

### Authentication

**GitLab:**
- Token file: `~/.gitlab-token`
- Create token: Settings → Access Tokens → Create personal access token
- Scopes needed: `api`, `read_api`, `read_repository`

**GitHub:**
- Uses `gh` CLI for authentication
- Install: `brew install gh` (macOS) or `sudo apt install gh` (Linux)
- Login: `gh auth login`

## Global Pipeline Scripts

All scripts are located in `~/.claude/scripts/` and work across both platforms.

### pipeline-status.sh

Check pipeline/workflow status.

**Usage:**
```bash
# Latest pipeline
~/.claude/scripts/pipeline-status.sh

# Specific pipeline
~/.claude/scripts/pipeline-status.sh --pipeline-id 2221
```

**Output:**
```
Pipeline #2221
  Status: success
  Ref: master
  SHA: 79baa92f
  Duration: 145s
  Created: 2024-02-08T21:40:15.000Z
  URL: https://git.turnersrus.com/docker/mcps/-/pipelines/2221
```

**Token Usage:** ~50 tokens (compact output)

### pipeline-watch.sh

Watch pipeline until completion.

**Usage:**
```bash
# Watch latest pipeline (10s interval)
~/.claude/scripts/pipeline-watch.sh

# Watch specific pipeline (5s interval)
~/.claude/scripts/pipeline-watch.sh --pipeline-id 2221 --interval 5
```

**Output:**
```
Watching pipeline: #2221
Polling every 10s (Ctrl+C to stop)

[2024-02-08 21:40:20] Pipeline #2221: running (45s)
[2024-02-08 21:40:30] Pipeline #2221: running (55s)
[2024-02-08 21:40:40] Pipeline #2221: success (145s)

Pipeline finished: success

Job Summary:
  build:asana: success
  build:invoice-ninja: success
  build:bitwarden: success
  tag:asana:latest: success
  tag:invoice-ninja:latest: success
  tag:bitwarden:latest: success
```

**Token Usage:** Runs without user prompts, minimal output

### pipeline-jobs.sh

List jobs in a pipeline.

**Usage:**
```bash
# Latest pipeline
~/.claude/scripts/pipeline-jobs.sh

# Specific pipeline
~/.claude/scripts/pipeline-jobs.sh --pipeline-id 2221
```

**Output:**
```
Jobs for pipeline #2221:

Job: build:asana (ID: 12345)
  Stage: build
  Status: success
  Duration: 45s
  URL: https://git.turnersrus.com/docker/mcps/-/jobs/12345

Job: build:invoice-ninja (ID: 12346)
  Stage: build
  Status: success
  Duration: 48s
  URL: https://git.turnersrus.com/docker/mcps/-/jobs/12346
```

**Token Usage:** ~100-200 tokens depending on job count

### pipeline-logs.sh

Get job logs.

**Usage:**
```bash
# Last 50 lines (default)
~/.claude/scripts/pipeline-logs.sh --job-id 12345

# Last 100 lines
~/.claude/scripts/pipeline-logs.sh --job-id 12345 --lines 100
```

**Output:**
```
Last 50 lines of job #12345:
========================================

Successfully built docker.turnersrus.com/asana-mcp:79baa92f
Successfully tagged docker.turnersrus.com/asana-mcp:master
...
```

**Token Usage:** ~200-500 tokens for 50 lines

## Platform Detection

The `git-detect.sh` script is sourced by all pipeline scripts to detect platform configuration.

**How it works:**
1. Searches for `PROJECT.yaml` in current directory and parent directories
2. Parses `git.platform`, `git.instance`, and `git.repo` fields
3. If `git.repo` is empty, extracts from `git remote get-url origin`
4. Exports environment variables for platform-specific API calls

**Exported variables:**
- `GIT_PLATFORM`: `gitlab` or `github`
- `GIT_INSTANCE`: Server hostname
- `GIT_REPO`: Repository path
- `GIT_PROJECT_PATH`: URL-encoded path for API calls
- `GIT_API_URL`: Platform API base URL
- `GIT_TOKEN_FILE`: Token file path (GitLab only)

## Best Practices for Agents

### Token Efficiency

**DO:**
- ✅ Use `pipeline-watch.sh` to monitor pipelines (no prompts, runs automatically)
- ✅ Use compact scripts instead of manual API calls
- ✅ Call `pipeline-status.sh` once to check latest status
- ✅ Use `pipeline-jobs.sh` to identify failed jobs before fetching logs

**DON'T:**
- ❌ Create polling loops with bash that require user approval
- ❌ Make direct curl calls when scripts exist
- ❌ Fetch full pipeline output repeatedly
- ❌ Fetch all job logs - only fetch failed job logs

### Typical Workflow

```bash
# 1. Push code (triggers pipeline)
git push

# 2. Get latest pipeline status
~/.claude/scripts/pipeline-status.sh

# 3. If running, watch until completion
~/.claude/scripts/pipeline-watch.sh

# 4. If failed, list jobs to find failures
~/.claude/scripts/pipeline-jobs.sh

# 5. Get logs for failed job
~/.claude/scripts/pipeline-logs.sh --job-id 12345 --lines 100
```

### Example Agent Usage

**Inefficient (400+ tokens, requires approval):**
```bash
# DON'T DO THIS
for i in {1..30}; do
  STATUS=$(curl -s --header "PRIVATE-TOKEN: $TOKEN" "$URL" | jq -r '.status')
  echo "[$i/30] Pipeline status: $STATUS"
  sleep 10
done
```

**Efficient (50 tokens, no prompts):**
```bash
# DO THIS
~/.claude/scripts/pipeline-watch.sh
```

## Troubleshooting

### "PROJECT.yaml not found"

Ensure you're in a project directory with a `PROJECT.yaml` file or a subdirectory of one.

```bash
# Check for PROJECT.yaml
find . -name "PROJECT.yaml" -o -name "project.yaml"
```

### "Token file not found" (GitLab)

Create token file:
```bash
echo "your-gitlab-token" > ~/.gitlab-token
chmod 600 ~/.gitlab-token
```

### "gh CLI not installed" (GitHub)

Install gh CLI:
```bash
# macOS
brew install gh

# Linux
sudo apt install gh

# Authenticate
gh auth login
```

### "Unsupported platform"

Valid platforms are `gitlab` and `github`. Check `git.platform` in `PROJECT.yaml`.

## API Mappings

### GitLab API → GitHub API

| Operation | GitLab | GitHub |
|-----------|--------|--------|
| List pipelines | `GET /projects/:id/pipelines` | `gh run list` |
| Get pipeline | `GET /projects/:id/pipelines/:id` | `gh run view` |
| List jobs | `GET /projects/:id/pipelines/:id/jobs` | `gh run view --json jobs` |
| Get logs | `GET /projects/:id/jobs/:id/trace` | `gh run view --job :id --log` |
| Watch pipeline | Poll pipeline status | `gh run watch` |

### Terminology

| GitLab | GitHub |
|--------|--------|
| Pipeline | Workflow Run |
| Job | Job |
| Stage | N/A (implicit in dependencies) |
| Runner | Runner |

## References

- [GitLab API Documentation](https://docs.gitlab.com/ee/api/)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [GitHub REST API](https://docs.github.com/en/rest)
