# command-health.jq - Per-command / per-script health signals for one transcript
#
# Input: slurped array of ALL records from a single .jsonl transcript, in order.
# Args: --arg sid <session_id> --arg proj <project-dir-name> --argjson stall <seconds>
#
# Attributes every tool call to the slash command invocation that was in effect
# when it ran, so cost/latency/failure can be blamed on a specific command
# rather than on the session as a whole.

# Transcript timestamps carry fractional seconds ("...:28.422Z"), which
# fromdateiso8601 rejects — truncate to whole seconds before parsing.
def epoch:
  if . == null then null
  else ((.[0:19] + "Z") | fromdateiso8601? // null)
  end;

def text_of:
  if type == "array" then [.[] | select(.type? == "text") | .text // ""] | join(" ")
  elif type == "string" then .
  else "" end;

# Harness built-ins are not user-authored commands, and the work after one is
# not attributable to it — treat them as "no command in effect".
def builtins:
  ["clear","compact","cost","config","model","help","resume","exit","login",
   "logout","status","doctor","memory","vim","terminal-setup","release-notes",
   "bug","review","pr-comments","add-dir","mcp","hooks","output-style"];

def slash_command:
  . as $t
  | if ($t | test("<command-name>")) then
      ($t | capture("<command-name>/?(?<c>[^<]+)</command-name>") | .c
          | . as $c
          | if (builtins | index($c)) then "(no command)" else $c end)
    else null end;

# Bash commands are normalized so the same command from different sessions,
# users, or branches aggregates into one row.
def normalize_cmd:
  gsub("/Users/[a-zA-Z0-9._-]+/"; "~/")
  | gsub("/home/[a-zA-Z0-9._-]+/"; "~/")
  | gsub("(feature|fix|task|bugfix)/[^ \"']+"; "<branch>")
  | split("\n")[0]
  | .[0:180];

def script_name:
  . as $c
  | if ($c | test("[a-zA-Z0-9_.-]+\\.(sh|py)")) then
      ($c | capture("(?<s>[a-zA-Z0-9_.-]+\\.(sh|py))") | .s)
    else null end;

# Anti-patterns from CLAUDE.md's Command Hygiene rules. Each hit is a concrete,
# fixable cause of a permission prompt or wasted tokens.
def antipatterns:
  . as $c
  | [ (if ($c | test("(^|[;&|]\\s*)(cat|head|tail|ls|find|grep|egrep|rg|wc|sed)\\b")) then "shell_file_inspection" else empty end),
      (if ($c | test("(make |\\.sh|\\.py)[^|]*\\|")) then "piped_make_or_script" else empty end),
      (if ($c | test("^cd .*(&&|\\||>)")) then "cd_chain" else empty end),
      (if ($c | test("\\$\\(|`")) then "subshell" else empty end),
      (if ($c | test("[^0-9|&]>[^&]")) then "output_redirect" else empty end),
      (if ($c | test("&&|;")) then "compound_command" else empty end),
      (if ($c | test("\\|\\s*(head|tail|jq|grep|python3|node)\\b")) then "piped_truncation" else empty end)
    ];

# ---------------------------------------------------------------------------
# Pass 1: flatten records, tag each with the slash-command span it belongs to
# ---------------------------------------------------------------------------

[ .[]
  | { ts:  (.timestamp | epoch),
      cmd: (if .type == "user" then (.message.content | text_of | slash_command) else null end),
      tu:  (if .type == "assistant"
            then [ (.message.content // []) | if type == "array" then .[] else empty end
                   | select(.type? == "tool_use")
                   | { id: .id, name: .name,
                       bash: (if .name == "Bash" then (.input.command // "" | normalize_cmd) else null end),
                       target: (.input.file_path // .input.pattern // null) } ]
            else [] end),
      tr:  (if .type == "user"
            then [ (.message.content // []) | if type == "array" then .[] else empty end
                   | select(.type? == "tool_result")
                   | { id: .tool_use_id, err: (.is_error == true),
                       text: (.content | tostring | .[0:200]) } ]
            else [] end) } ]
| [ foreach .[] as $e ({ cur: "(no command)", n: 0 };
      (if $e.cmd then { cur: $e.cmd, n: (.n + 1) } else . end);
      ($e + { cmd_name: .cur, span: "\(.cur)#\(.n)" })) ] as $ev

# ---------------------------------------------------------------------------
# Pass 2: join tool_use -> tool_result by id to get outcome + wall duration
# ---------------------------------------------------------------------------

| ( [ $ev[] | . as $r | $r.tr[] | { key: .id, value: { err: .err, text: .text, ts: $r.ts } } ]
    | from_entries ) as $res

| [ $ev[] | . as $r | $r.tu[]
    | ($res[.id] // null) as $o
    | (if ($o.ts != null and $r.ts != null) then ($o.ts - $r.ts) else null end) as $raw
    # A gap over STALL_S almost always means the call sat waiting on a
    # permission prompt or the user walked away — that is prompt friction, not
    # execution time, so it is counted separately and kept out of latency stats.
    | { span: $r.span, cmd: $r.cmd_name, name: .name, bash: .bash, target: .target,
        err: ($o.err // false),
        err_text: (if ($o.err // false) then ($o.text // "") else null end),
        stalled: ($raw != null and $raw > $stall),
        # A non-zero exit that still emits the output framework's next_action is
        # a designed gate (review_failed, blocked, validation_failed), not a
        # defect — separating these keeps real breakage visible.
        gated: (($o.err // false) and (($o.text // "") | test("next_action"))),
        dur: (if ($raw != null and $raw <= $stall) then $raw else null end) } ] as $calls

# ---------------------------------------------------------------------------
# Pass 3: per-command and per-script rollups
# ---------------------------------------------------------------------------

| { session_id: $sid,
    project: $proj,
    records: ($ev | length),

    commands: (
      $calls | group_by(.cmd) | map(
        { name: .[0].cmd,
          invocations: ([.[].span] | unique | length),
          tool_calls: length,
          errors: ([.[] | select(.err)] | length),
          unexpected_errors: ([.[] | select(.err and (.gated | not))] | length),
          stalled_calls: ([.[] | select(.stalled)] | length),
          # Wall-clock per invocation = sum of its tool-call durations. Thinking
          # and model latency are excluded, so this measures tool cost only.
          invocation_seconds: (group_by(.span) | map([.[].dur | select(. != null)] | add // 0)),
          durations: [.[].dur | select(. != null)],
          antipattern_hits: ([.[] | select(.bash != null) | .bash | antipatterns[]]
                             | group_by(.) | map({ pattern: .[0], count: length })
                             | sort_by(-.count)),
          failing_bash: ([.[] | select(.err and .bash != null) | .bash]
                         | group_by(.) | map({ cmd: .[0], count: length })
                         | sort_by(-.count) | .[0:5]),
          slow_calls: ([.[] | select(.dur != null and .dur >= 20)
                        | { tool: .name, seconds: (.dur | floor),
                            what: (.bash // .target // "") | tostring | .[0:120] }]
                       | sort_by(-.seconds) | .[0:5]),
          tool_mix: ([.[].name] | group_by(.) | map({ tool: .[0], count: length })
                     | sort_by(-.count) | .[0:6]) })
      | sort_by(-.tool_calls) ),

    scripts: (
      $calls | map(select(.bash != null)
                   | . + { script: (.bash | script_name),
                           # Only ~/.claude/scripts belong to the user — nvm.sh,
                           # tsc wrappers, and ad-hoc probes are not theirs to fix.
                           own: (.bash | test("(~|/Users/[^/ ]+|/home/[^/ ]+)/\\.claude/scripts/")) })
      | map(select(.script != null)) | group_by(.script)
      | map({ name: .[0].script,
              own: ([.[].own] | any),
              calls: length,
              errors: ([.[] | select(.err)] | length),
              gated_errors: ([.[] | select(.err and .gated)] | length),
              unexpected_errors: ([.[] | select(.err and (.gated | not))] | length),
              durations: [.[].dur | select(. != null)],
              commands: ([.[].cmd] | unique),
              sample_errors: ([.[] | select(.err and (.gated | not)) | .err_text | select(. != null) | .[0:160]] | unique | .[0:3]) })
      | sort_by(-.calls) ),

    tools: (
      $calls | group_by(.name)
      | map({ name: .[0].name, calls: length,
              errors: ([.[] | select(.err)] | length),
              durations: [.[].dur | select(. != null)] }) ),

    bash_commands: (
      # A bare `cd <worktree>` is the prescribed one-time cwd move, not a
      # candidate for automation — excluding it stops it swamping the ranking.
      $calls | map(select(.bash != null and (.bash | test("^cd [^;&|]*$") | not)))
      | group_by(.bash)
      | map({ cmd: .[0].bash, count: length, errors: ([.[] | select(.err)] | length),
              durations: [.[].dur | select(. != null)] })
      | sort_by(-.count) | .[0:40] ),

    # Files read 3+ times in one session — the re-read budget in CLAUDE.md.
    reread_files: (
      $calls | map(select(.name == "Read" and .target != null) | .target)
      | group_by(.) | map(select(length >= 3) | { file: .[0], reads: length })
      | sort_by(-.reads) | .[0:10] ) }
