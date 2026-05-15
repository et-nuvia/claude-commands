# analyze-conversation.jq - Extract signals from a conversation's messages
# Input: slurped array of {type, message, toolUseResult, data} objects
# Args: --arg sid <session_id> --arg proj <project>

{
  session_id: $sid,
  project: $proj,
  message_counts: {
    user: [.[] | select(.type == "user")] | length,
    assistant: [.[] | select(.type == "assistant")] | length,
    tool_result: [.[] | select(.type == "tool-result")] | length,
    error: [.[] | select(.type == "error")] | length
  },

  skills_used: [
    .[] | select(.type == "user") |
    .message.content // "" |
    if type == "array" then .[0].text // "" else . end |
    capture("<command-name>(?<cmd>[^<]+)</command-name>") | .cmd
  ] | group_by(.) | map({name: .[0], count: length}) | sort_by(-.count),

  tools_used: [
    .[] | select(.type == "assistant") |
    .message.content // [] | if type == "array" then .[] else empty end |
    select(.type? == "tool_use") | .name
  ] | group_by(.) | map({name: .[0], count: length}) | sort_by(-.count),

  errors: (
    [
      .[] | select(.type == "tool-result") |
      (.toolUseResult // "") | tostring |
      select(test("error|Error|ERROR|failed|Failed|FAILED|exception|Exception|traceback|Traceback|command not found|No such file|exit code [1-9]|Permission denied"; "i")) |
      .[0:200]
    ] + [
      .[] | select(.type == "error") | .data // .message // "" | tostring
    ]
  ) | length,

  corrections: [
    .[] | select(.type == "user") |
    .message.content // "" |
    if type == "array" then .[0].text // "" else . end |
    select(type == "string") |
    select(test("no[, ]|stop|don't|do not|wrong|incorrect|that's not|fix |still |again |retry|broken|not working|doesn't work|didn't work"; "i"))
  ] | length,

  retry_signals: [
    .[] | select(.type == "assistant") |
    .message.content // [] | if type == "array" then .[] else empty end |
    select(.type? == "tool_use") |
    {name, input_key: (.input | tostring | .[0:100])}
  ] | group_by(.name + "|" + .input_key) | map(select(length > 2)) | map({tool: .[0].name, count: length}) |
  group_by(.tool) | map({tool: .[0].tool, repeated_calls: [.[].count] | add}) | sort_by(-.repeated_calls),

  bash_commands: [
    .[] | select(.type == "assistant") |
    .message.content // [] | if type == "array" then .[] else empty end |
    select(.type? == "tool_use" and .name == "Bash") |
    .input.command // "" |
    select(length > 0) |
    gsub("/home/[a-zA-Z0-9._-]+/"; "~/") |
    gsub("/Users/[a-zA-Z0-9._-]+/"; "~/") |
    gsub("feature/[^ \"']+"; "feature/<branch>") |
    gsub("fix/[^ \"']+"; "fix/<branch>") |
    split("\n")[0] |
    .[0:200]
  ] | group_by(.) | map({cmd: .[0], count: length}) | sort_by(-.count) | .[0:50],

  bash_sequences: (
    [
      .[] | select(.type == "assistant") |
      .message.content // [] | if type == "array" then .[] else empty end |
      select(.type? == "tool_use" and .name == "Bash") |
      .input.command // "" | select(length > 0) |
      split(" ")[0] | split("/") | last
    ] | [range(0; length - 1) as $i | "\(.[$i])->>\(.[$i+1])"] |
    group_by(.) | map({sequence: .[0], count: length}) |
    sort_by(-.count) | map(select(.count > 2)) | .[0:20]
  ),

  total_messages: length
}
