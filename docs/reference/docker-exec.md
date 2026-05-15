# Docker Exec Script Reference

**Script**: `~/.claude/scripts/docker-exec.sh`

Global utility for executing commands inside Docker Compose service containers with automatic container resolution and auto-start.

## Problem Solved

Makefiles and scripts that `docker compose exec <service>` break when:
- A service has an explicit `container_name` that doesn't match the default pattern
- The project directory name changes (which changes the auto-generated container prefix)
- The container isn't running yet

This script resolves the correct container name dynamically and starts the service if needed.

## Usage

```bash
~/.claude/scripts/docker-exec.sh -s <service> [-d <project_dir>] [-- command args...]
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-s`, `--service` | Docker Compose service name (required) | — |
| `-d`, `--dir` | Project directory containing `docker-compose.yml` | Current directory |

Everything after `--` is the command to run inside the container.

### Examples

```bash
# Run pytest in the api service
~/.claude/scripts/docker-exec.sh -s api -- uv run pytest

# Run vitest in the web service
~/.claude/scripts/docker-exec.sh -s web -- npx vitest run

# Specify project directory explicitly
~/.claude/scripts/docker-exec.sh -s api -d /home/eric/projects/task-forge -- uv run pytest --tb=short
```

## Container Resolution Order

The script tries three strategies to find the running container, in order:

1. **Explicit `container_name`** — Parses `docker-compose.yml` for a `container_name:` field under the service. If found and running, uses it.

2. **`docker compose ps`** — Asks Docker Compose directly for the container name of the service. Works regardless of naming conventions.

3. **Auto-generated pattern** — Tries `<project>-<service>-1` through `<project>-<service>-3`, where `<project>` is the lowercased, sanitized directory name.

If none are running, the script runs `docker compose up -d <service>` and waits up to 30 seconds for the container to start.

## Usage in Makefiles

Sub-Makefiles should use this script instead of hardcoding `docker compose exec <service>`:

```makefile
DOCKER_EXEC := ~/.claude/scripts/docker-exec.sh
PROJECT_DIR := $(shell cd .. && pwd)

test-unit:
	$(DOCKER_EXEC) -s api -d $(PROJECT_DIR) -- uv run pytest
```

This decouples the Makefile from container naming details and handles auto-start.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Command executed successfully |
| 1 | Missing arguments, compose file not found, or container couldn't be resolved |
| Other | Exit code from the executed command |
