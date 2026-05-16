---
command: training-videos
group: outlier
backing_script: ~/.claude/scripts/training-videos.sh
mutates: [files]
runtime: ~2-10min per video
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /training-videos

Produces professional training videos by combining Playwright browser
recordings, edge-tts voiceover synthesis, and ffmpeg assembly. Reads a
per-project configuration file (`~/.claude/templates/training-videos.yaml`)
that defines which videos to build, their scripts, and voice settings.
Output is a set of `.mp4` files ready for distribution.

> **Config:** `~/.claude/templates/training-videos.yaml` **required** — defines video IDs, voiceover scripts, Playwright test paths, voice, and resolution settings. Copy the template and customize before first use.

---

## When to use it

- A feature or workflow has changed and the corresponding training video needs to be regenerated
- You want to check which videos are out of date before a release
- You need to regenerate only the audio or only the video phase of a specific recording

## Usage

```bash
/training-videos [intent or video ID]
```

**Common invocations:**

```bash
/training-videos                             # check status: which videos need updates
/training-videos create video for <id>       # generate one complete video
/training-videos generate all               # regenerate all videos
/training-videos just audio for <id>         # audio phase only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form intent. The LLM maps phrases like "create video for login", "generate all", "just audio for <id>", or "check status" to the corresponding script flags. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `edge-tts` | Text-to-speech voiceover synthesis | `pip install edge-tts` |
| `ffmpeg` | Merge audio + video into `.mp4` | `brew install ffmpeg` / `apt install ffmpeg` |
| `npx` / Playwright | Browser recording for the video phase | `npm install -g playwright` then `npx playwright install` |
| `yq` | Parse `training-videos.yaml` config | `brew install yq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.claude/templates/training-videos.yaml` — required; defines all video metadata, scripts, voices, and resolutions
- Playwright test files referenced in the config — required for the video phase
- Output `.mp4` files — written to the path configured in `training-videos.yaml`

## Backing script

**Script**: `~/.claude/scripts/training-videos.sh`

**Inputs:** `--full` (default), `--status`, `--validate`. Optional `--video <id>` to target one video, `--phase <audio|video|assembly>` to run a single phase, `--voice <name>` to override the configured voice, `--yes` to skip confirmation prompts.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `investigate_failures`, `fix_error`}
- `processed[]` — video IDs successfully built with duration
- `failed[]` — video IDs that failed, with error context
- `message` and `suggestion` (on `fix_error`) — setup error description

**Invocation surface:**

```bash
~/.claude/scripts/training-videos.sh --status                                   # list stale videos
~/.claude/scripts/training-videos.sh --validate                                  # check tools only
~/.claude/scripts/training-videos.sh --full                                      # all videos
~/.claude/scripts/training-videos.sh --video <id> --yes                          # one video
~/.claude/scripts/training-videos.sh --video <id> --phase audio                  # audio only
~/.claude/scripts/training-videos.sh --video <id> --phase video                  # recording only
~/.claude/scripts/training-videos.sh --video <id> --phase assembly               # merge only
~/.claude/scripts/training-videos.sh --video <id> --voice en-US-GuyNeural --yes  # override voice
~/.claude/scripts/training-videos.sh --raw --validate                            # debug
~/.claude/scripts/training-videos.sh --raw --video <id> --phase audio            # debug audio
```

## How it works

1. **Validate** — script checks that `edge-tts`, `ffmpeg`, `npx`, `yq`, and the
   config file are all present. Returns `fix_error` with a specific
   `suggestion` if anything is missing.
2. **Status check** — compares each video's output `.mp4` modification time
   against its Playwright test and voiceover script. Returns a list of videos
   that are stale or missing.
3. **Audio phase** — `edge-tts` synthesizes speech from the voiceover script in
   the config, producing a `.wav` file.
4. **Video phase** — Playwright runs the browser test and records a `.webm`
   or `.mp4` capture.
5. **Assembly phase** — `ffmpeg` merges audio and video into the final `.mp4`,
   applying resolution and encoding settings from the config.
6. **Result routing** — on full success, returns `display_summary` with each
   video ID and duration. On partial failure, returns `investigate_failures`
   listing which succeeded and which failed. The LLM re-runs failed videos with
   `--raw` to surface the specific error.

## Example workflows

### Scenario: Pre-release video refresh

```
/training-videos                          # check status
/training-videos generate all             # regenerate stale videos
/git-commit                               # commit updated .mp4 files (or upload to CDN)
```

### Scenario: Quick audio-only fix

```
# manual: update voiceover text in training-videos.yaml
/training-videos just audio for onboarding
/training-videos just assembly for onboarding
```

Regenerates only the TTS audio and re-merges, skipping the full Playwright recording.

### Scenario: Status output

```
/training-videos
```

```
Training Video Status
  onboarding      STALE    (test updated 2026-05-10, video 2026-04-01)
  password-reset  OK       (current)
  invite-flow     MISSING  (never built)

2 videos need regeneration. Proceed?  [Yes / No]
```

## Notes & gotchas

- `~/.claude/templates/training-videos.yaml` must exist before the first run.
  Copy and edit the provided template — the command returns `fix_error` with
  a path hint if the file is missing.
- Playwright headless recording requires a display. On headless CI servers, set
  `DISPLAY=:0` or use `xvfb-run`.
- Assembly phase is idempotent: re-running it with existing audio and video
  files is safe and cheap.
- **If it fails:** `investigate_failures` — re-run the specific phase with
  `~/.claude/scripts/training-videos.sh --raw --video <id> --phase <phase>` to
  see the full tool output. Most failures are missing tools (validate with
  `--raw --validate`) or a voiceover script pointing to a non-existent file.
- Home (WSL) users: `edge-tts` requires network access to Microsoft's TTS
  service. Offline environments will fail at the audio phase.
