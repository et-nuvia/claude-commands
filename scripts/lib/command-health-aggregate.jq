# command-health-aggregate.jq - Merge per-transcript results into a ranked report
#
# Input: slurped array of per-file objects produced by command-health.jq
# Args: --argjson top <n> --argjson all_scripts <bool>

def pct($p):
  sort as $s
  | if ($s | length) == 0 then null
    else ($s[ ((($s | length) - 1) * $p) | floor ] | . * 10 | round / 10) end;

def stats:
  { n: length, p50: pct(0.5), p90: pct(0.9),
    max: (if length == 0 then null else (max | . * 10 | round / 10) end),
    total: ((add // 0) | floor) };

def rate($num; $den): if $den == 0 then 0 else (($num / $den) * 1000 | round / 10) end;

. as $files

| ([$files[].commands[]] | group_by(.name) | map(
    { name: .[0].name,
      sessions: length,
      invocations: ([.[].invocations] | add),
      tool_calls: ([.[].tool_calls] | add),
      errors: ([.[].errors] | add),
      unexpected_errors: ([.[].unexpected_errors // 0] | add),
      stalled_calls: ([.[].stalled_calls // 0] | add),
      error_rate_pct: rate(([.[].errors] | add); ([.[].tool_calls] | add)),
      calls_per_invocation: (([.[].tool_calls] | add) / (([.[].invocations] | add) | if . == 0 then 1 else . end) | . * 10 | round / 10),
      invocation_seconds: ([.[].invocation_seconds[]] | stats),
      antipatterns: ([.[].antipattern_hits[]] | group_by(.pattern)
                     | map({ pattern: .[0].pattern, count: ([.[].count] | add) })
                     | sort_by(-.count)),
      antipattern_total: ([.[].antipattern_hits[].count] | add // 0),
      failing_bash: ([.[].failing_bash[]] | group_by(.cmd)
                     | map({ cmd: .[0].cmd, count: ([.[].count] | add) })
                     | sort_by(-.count) | .[0:5]),
      slow_calls: ([.[].slow_calls[]] | sort_by(-.seconds) | .[0:5]),
      tool_mix: ([.[].tool_mix[]] | group_by(.tool)
                 | map({ tool: .[0].tool, count: ([.[].count] | add) })
                 | sort_by(-.count) | .[0:6]) })) as $cmds

| ([$files[].scripts[]] | map(select($all_scripts or (.own // false))) | group_by(.name) | map(
    { name: .[0].name,
      calls: ([.[].calls] | add),
      errors: ([.[].errors] | add),
      gated_errors: ([.[].gated_errors // 0] | add),
      unexpected_errors: ([.[].unexpected_errors // 0] | add),
      error_rate_pct: rate(([.[].errors] | add); ([.[].calls] | add)),
      unexpected_rate_pct: rate(([.[].unexpected_errors // 0] | add); ([.[].calls] | add)),
      seconds: ([.[].durations[]] | stats),
      called_by: ([.[].commands[]] | unique),
      sample_errors: ([.[].sample_errors[]] | unique | .[0:3]) })) as $scripts

| ([$files[].bash_commands[]] | group_by(.cmd) | map(
    { cmd: .[0].cmd,
      count: ([.[].count] | add),
      errors: ([.[].errors] | add),
      seconds: ([.[].durations[]] | stats),
      antipatterns: (.[0].cmd | [ (if test("(^|[;&|]\\s*)(cat|head|tail|ls|find|grep|egrep|rg|wc|sed)\\b") then "shell_file_inspection" else empty end),
                                  (if test("(make |\\.sh|\\.py)[^|]*\\|") then "piped_make_or_script" else empty end),
                                  (if test("^cd .*(&&|\\||>)") then "cd_chain" else empty end),
                                  (if test("\\$\\(|`") then "subshell" else empty end),
                                  (if test("&&|;") then "compound_command" else empty end) ]) })) as $bash

# ---------------------------------------------------------------------------
# Rule-driven candidate improvements. Each is evidence-backed and names the
# exact command/script to change — synthesis and prioritization is the LLM's job.
# ---------------------------------------------------------------------------
| [ ($cmds[] | select(.invocation_seconds.p90 != null and .invocation_seconds.p90 >= 600 and .invocations >= 3)
      | { kind: "slow_command", target: .name, severity: "high",
          evidence: "p90 tool wall-clock \(.invocation_seconds.p90)s over \(.invocations) invocations (\(.calls_per_invocation) tool calls each)",
          fix: "Consolidate tool calls into one script section; return a single JSON payload instead of many small calls" }),

    ($cmds[] | select(.unexpected_errors >= 5 and .tool_calls >= 20)
      | { kind: "error_prone_command", target: .name, severity: "high",
          evidence: "\(.unexpected_errors) unexpected failures in \(.tool_calls) tool calls; top failure: \(.failing_bash[0].cmd // "n/a")",
          fix: "Add preflight validation and a clear next_action for the failing path" }),

    ($cmds[] | select(.calls_per_invocation >= 45 and .invocations >= 3)
      | { kind: "chatty_command", target: .name, severity: "medium",
          evidence: "\(.calls_per_invocation) tool calls per invocation; mix: \([.tool_mix[] | "\(.tool)x\(.count)"] | join(", "))",
          fix: "Move the discovery/read loop into the backing script so the command makes one call" }),

    ($cmds[] | select(.stalled_calls >= 10)
      | { kind: "stalling_command", target: .name, severity: "medium",
          evidence: "\(.stalled_calls) tool calls stalled (waiting on a permission prompt or user input)",
          fix: "Allowlist the blocking calls or restructure them to auto-approve; see the hygiene rules in CLAUDE.md" }),

    ($cmds[] | select(.antipattern_total >= 100)
      | { kind: "permission_prompt_source", target: .name, severity: "medium",
          evidence: "\(.antipattern_total) hygiene violations: \([.antipatterns[] | "\(.pattern)x\(.count)"] | join(", "))",
          fix: "Replace shell inspection with Read/Grep tools; drop pipes and redirects from make/script calls" }),

    ($scripts[] | select(.unexpected_rate_pct >= 12 and .calls >= 8 and .unexpected_errors >= 3)
      | { kind: "failing_script", target: .name, severity: "high",
          evidence: "\(.unexpected_errors)/\(.calls) invocations failed unexpectedly (\(.unexpected_rate_pct)%, excluding \(.gated_errors) designed gates); e.g. \(.sample_errors[0] // "n/a")",
          fix: "Handle this failure mode in the script and return a structured error instead of a non-zero exit" }),

    ($scripts[] | select(.seconds.p90 != null and .seconds.p90 >= 60 and .calls >= 5)
      | { kind: "slow_script", target: .name, severity: "medium",
          evidence: "p90 \(.seconds.p90)s, max \(.seconds.max)s over \(.calls) calls; called by \(.called_by | join(", "))",
          fix: "Cache/manifest expensive work, parallelize independent steps, or add an incremental mode" }),

    ($bash[] | select(.count >= 15 and (.antipatterns | length) > 0)
      | { kind: "repeated_shell_pattern", target: .cmd, severity: "low",
          evidence: "run \(.count)x, \(.errors) failed, patterns: \(.antipatterns | join(", "))",
          fix: "Wrap in a make target or script so it is one allowlisted call" }),

    ($bash[] | select(.count >= 25 and (.antipatterns | length) == 0)
      | { kind: "automation_candidate", target: .cmd, severity: "low",
          evidence: "run \(.count)x across sessions (p50 \(.seconds.p50)s)",
          fix: "Promote to a make target or script section" }) ] as $recs

| { scope: { transcripts: ($files | length),
             records: ([$files[].records] | add),
             commands_seen: ($cmds | length),
             tool_calls: ([$files[].tools[].calls] | add) },

    slowest_commands: ($cmds | map(select(.invocation_seconds.p90 != null))
                       | sort_by(-.invocation_seconds.p90)
                       | map({ name, invocations, calls_per_invocation, stalled_calls,
                               p50_s: .invocation_seconds.p50, p90_s: .invocation_seconds.p90,
                               max_s: .invocation_seconds.max, total_s: .invocation_seconds.total })
                       | .[0:$top]),

    most_error_prone_commands: ($cmds | map(select(.tool_calls >= 5))
                               | sort_by(-.unexpected_errors)
                               | map({ name, errors, unexpected_errors, tool_calls,
                                       error_rate_pct, failing_bash })
                               | .[0:$top]),

    chattiest_commands: ($cmds | sort_by(-.calls_per_invocation)
                         | map({ name, invocations, calls_per_invocation, tool_calls, tool_mix })
                         | .[0:$top]),

    slowest_scripts: ($scripts | map(select(.seconds.p90 != null))
                      | sort_by(-.seconds.p90)
                      | map({ name, calls, errors, error_rate_pct,
                              p50_s: .seconds.p50, p90_s: .seconds.p90, max_s: .seconds.max,
                              total_s: .seconds.total, called_by })
                      | .[0:$top]),

    failing_scripts: ($scripts | map(select(.unexpected_errors > 0)) | sort_by(-.unexpected_errors)
                      | map({ name, calls, errors, gated_errors, unexpected_errors,
                              unexpected_rate_pct, sample_errors })
                      | .[0:$top]),

    permission_prompt_hotspots: ($cmds | map(select(.antipattern_total > 0))
                                 | sort_by(-.antipattern_total)
                                 | map({ name, antipattern_total, antipatterns }) | .[0:$top]),

    antipattern_totals: ([$cmds[].antipatterns[]] | group_by(.pattern)
                         | map({ pattern: .[0].pattern, count: ([.[].count] | add) })
                         | sort_by(-.count)),

    slowest_individual_calls: ([$cmds[] | .name as $c | .slow_calls[] | . + { command: $c }]
                               | sort_by(-.seconds) | .[0:$top]),

    reread_hotspots: ([$files[].reread_files[]] | group_by(.file)
                      | map({ file: .[0].file, total_reads: ([.[].reads] | add), sessions: length })
                      | sort_by(-.total_reads) | .[0:$top]),

    automation_candidates: ($bash | map(select(.count >= 8))
                            | sort_by(-.count)
                            | map({ cmd, count, errors, p50_s: .seconds.p50, antipatterns })
                            | .[0:$top]),

    # Capped per kind so one noisy rule cannot crowd out the others.
    recommendations: ($recs
                      | group_by(.kind) | map(.[0:$top]) | add // []
                      | map(. + { rank: (if .severity == "high" then 0 elif .severity == "medium" then 1 else 2 end) })
                      | sort_by(.rank) | map(del(.rank))),

    recommendation_counts: ($recs | group_by(.kind)
                            | map({ kind: .[0].kind, found: length })
                            | sort_by(-.found)) }
